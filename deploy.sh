#!/bin/sh
# ============================================================================
# deploy.sh — despliega uno o varios GitHub self-hosted runners (efímeros, con
# auto-reinicio y cache persistente) usando Podman/Docker Compose.
#
# Instalación de un comando (idioma RECOMENDADO: la terminal sigue conectada,
# así que los prompts interactivos funcionan Y se aceptan argumentos):
#
#   sh -c "$(curl -fsSL https://raw.githubusercontent.com/JoseAmador95/gh_runner/main/deploy.sh)" -- \
#       --repo OWNER/REPO --token <PAT> --count 3 --prefix ci --up
#
# Alternativa por tubería (SIN prompts interactivos: solo args/env):
#   curl -fsSL .../deploy.sh | sh -s -- --repo OWNER/REPO --token <PAT> --count 3
#
# También se puede descargar y ejecutar:  ./deploy.sh   (modo interactivo)
#
# El PAT se guarda en ./.env (chmod 600) y NUNCA se pasa por la línea de
# comandos del contenedor (invisible en `ps`). El compose se escribe en
# ./compose.yaml (nombre estándar -> `podman compose` funciona sin -f).
# Ejecuta esto en un directorio DEDICADO (genera compose.yaml y .env ahí).
#
# Windows: funciona en Git Bash (con Docker/Podman Desktop, backend WSL2). El
# CLI docker.exe/podman.exe se invoca desde Git Bash sin problema.
# ============================================================================
set -eu

# En Git Bash / MSYS2 (Windows), evita que se conviertan rutas estilo Unix
# (p.ej. /home/runner) al pasarlas a docker.exe/podman.exe. Inofensivo fuera de
# Windows: estas variables se ignoran en Linux/macOS.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

# ---- Valores por defecto ---------------------------------------------------
IMAGE_DEFAULT="ghcr.io/joseamador95/gh_runner:latest"

# Captura del entorno para el fallback (env IMAGE se lee antes de reusar la var).
ENV_IMAGE="${IMAGE:-}"

# Holders vacíos: los flags los rellenan; luego se aplican env y defaults.
REPO=""            # OWNER/REPO
OWNER=""
NAME=""
TOKEN=""
TOKEN_SRC=""
PREFIX=""
COUNT=""
LABELS=""
GROUP=""
IMAGE=""
COMPOSE_FILE="compose.yaml"   # nombre autodetectado -> permite usar `podman compose` sin -f
ENV_FILE=".env"
CACHE_DIRS_CSV=""
PULL_ALWAYS="yes"   # default: pull_policy: always (cada up -d re-baja :latest; opt-out --no-pull-always)
DO_UP="auto"        # auto|yes|no
SKIP_VALIDATION="no"
FORCE="no"          # sobreescribir compose.yaml/.env ajenos
CPUS=""             # límite de CPU por runner
MEMORY=""           # límite de memoria por runner
USE_SECRET="no"     # --secret: PAT como file-secret en vez de en .env
SECRET_FILE="access_token"
ENGINE_PREF=""      # --engine: forzar podman o docker
BOOTSTRAP="yes"     # instalar podman/compose y crear la machine si faltan (opt-out --no-bootstrap)
PM=""; MACHINE="no" # los rellena bootstrap_env (gestor de paquetes / si hay VM)
VIGILAR="no"        # --vigilar: añade el servicio `vigia` al compose
VIGILAR_CADA="300"  # cadencia de la ronda del vigía, en segundos
VIGILAR_MINIMO="1"  # runners sanos por debajo de los cuales el estado es `degradado`
HOST_LABEL="yes"    # añade la etiqueta host:<hostname> a los runners (opt-out --no-host-label)

# Separador de la etiqueta de host. En UNA constante a propósito: si GitHub
# rechazara ':' en una etiqueta, config.sh fallaría y NINGÚN runner arrancaría;
# cambiarlo a '-' es entonces una sola línea.
HOST_LABEL_SEP=":"

# Base para descargar piezas del repo cuando deploy.sh se ejecuta por curl y no
# tiene ficheros hermanos en disco.
RAW_BASE="https://raw.githubusercontent.com/JoseAmador95/gh_runner/main"

# Directorio del propio deploy.sh, SI se está ejecutando desde un fichero. Con
# `sh -c "$(curl …)"` o por tubería, $0 es "sh" y no hay hermanos en disco: queda
# vacío y quien lo necesite baja del repo.
_DIR_SCRIPT=""
case "$0" in
    */*) [ -f "$0" ] && _DIR_SCRIPT="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" ;;
esac

# ---- Utilidades ------------------------------------------------------------
err()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*" >&2; }

MARKER="# GENERADO por deploy"   # prefijo común con deploy.ps1 (reconocimiento cruzado)

# No pisar un compose.yaml/.env que no generó deploy.sh (nombres genéricos).
guard_overwrite() {
    [ -e "$1" ] || return 0
    case "$(head -n1 "$1" 2>/dev/null || true)" in
        "$MARKER"*) return 0 ;;   # es nuestro -> se puede sobreescribir
    esac
    [ "$FORCE" = "yes" ] && return 0
    err "ya existe '$1' y no lo generó deploy.sh.
       Corre deploy.sh en un directorio DEDICADO (recomendado), usa --file OTRO.yaml,
       o --force para sobreescribir."
}

# El fichero del secret se lee verbatim (sin marker posible); no lo pisamos.
guard_secret_file() {
    [ -e "$1" ] || return 0
    [ "$FORCE" = "yes" ] && return 0
    err "ya existe '$1' (fichero del secret). Bórralo o usa --force para sobreescribir."
}

# Devuelve el comando de compose para el motor $1, o nada si no hay proveedor.
compose_for() {
    case "$1" in
        podman)
            if podman compose version >/dev/null 2>&1; then printf 'podman compose'
            elif command -v podman-compose >/dev/null 2>&1; then printf 'podman-compose'
            fi ;;
        docker)
            if docker compose version >/dev/null 2>&1; then printf 'docker compose'
            elif command -v docker-compose >/dev/null 2>&1; then printf 'docker-compose'
            fi ;;
    esac
}

# Rechaza valores con saltos de línea / caracteres de control antes de escribirlos
# al compose/.env (anti-inyección YAML/.env). Contamos bytes de control con wc -c
# (NO usamos $(...) sobre el residuo: la sustitución elimina los \n finales y
# dejaría pasar justo la inyección por newline).
assert_clean() {
    _ctrl="$(printf '%s' "$2" | LC_ALL=C tr -cd '[:cntrl:]' | wc -c | tr -dc '0-9')"
    if [ "${_ctrl:-0}" -gt 0 ]; then
        err "valor inválido para $1: contiene saltos de línea o caracteres de control (posible inyección)."
    fi
}

# ---- Bootstrap del entorno (podman + compose + machine) --------------------
# Instala lo que falte. Matriz: macOS/brew · Fedora/dnf ·
# Debian·Ubuntu·Raspberry Pi OS/apt · (Windows -> deploy.ps1/winget). Es no-op
# limpio si ya está todo (no exige detectar gestor en ese caso).
_pm_hint="Soportado: macOS (brew), Fedora (dnf), Debian/Ubuntu/Raspberry Pi OS (apt), Windows (deploy.ps1/winget)."
ensure_podman() {
    command -v podman >/dev/null 2>&1 && return 0
    [ -n "$PM" ] || err "falta podman y no detecté un gestor soportado. ${_pm_hint} Instálalo a mano o usa --no-bootstrap."
    info "podman no está instalado; instalando con ${PM}..."
    case "$PM" in
        brew) brew install podman ;;
        dnf)  sudo dnf install -y podman ;;
        apt)  sudo apt-get update && sudo apt-get install -y podman ;;
    esac
    command -v podman >/dev/null 2>&1 || err "la instalación de podman no dejó 'podman' en el PATH."
}
ensure_compose() {
    [ -n "$(compose_for podman)" ] && return 0
    if command -v docker >/dev/null 2>&1 && [ -n "$(compose_for docker)" ]; then return 0; fi
    [ -n "$PM" ] || err "falta un proveedor de compose y no detecté un gestor soportado. ${_pm_hint} Usa --no-bootstrap."
    info "Falta un proveedor de compose; instalando con ${PM}..."
    case "$PM" in
        brew) brew install docker-compose ;;
        dnf)  sudo dnf install -y podman-compose ;;
        apt)  sudo apt-get update && sudo apt-get install -y podman-compose ;;
    esac
    [ -n "$(compose_for podman)" ] && return 0
    if command -v docker >/dev/null 2>&1 && [ -n "$(compose_for docker)" ]; then return 0; fi
    err "tras instalar sigo sin un proveedor de compose funcional."
}
ensure_machine() {
    [ "$MACHINE" = "yes" ] || return 0   # solo macOS/Windows corren podman en una VM
    if [ -z "$(podman machine list --format '{{.Name}}' 2>/dev/null)" ]; then
        info "No hay podman machine; creándola (init --now)..."
        podman machine init --now
    elif ! podman info >/dev/null 2>&1; then
        info "Arrancando la podman machine..."
        podman machine start 2>/dev/null || true
    fi
}
bootstrap_env() {
    # Detecta gestor y si hay VM; NO falla si no hay gestor (las ensure_* solo lo
    # exigen cuando de verdad tienen que instalar → no-op en host ya provisionado).
    case "$(uname -s 2>/dev/null || echo unknown)" in
        Darwin)
            MACHINE="yes"
            if command -v brew >/dev/null 2>&1; then PM="brew"; fi ;;
        Linux)
            if command -v dnf >/dev/null 2>&1; then PM="dnf"
            elif command -v apt-get >/dev/null 2>&1; then PM="apt"; fi ;;
    esac
    ensure_podman
    ensure_compose
    ensure_machine
}

usage() {
    cat >&2 <<'EOF'
Uso: deploy.sh [opciones]

Repositorio y credenciales:
  --repo OWNER/REPO      Repositorio objetivo (o usar --owner y --name)
  --owner OWNER          Owner del repo
  --name REPO            Nombre del repo
  --token PAT            Personal Access Token (Administration: Read and write).
                         Si se omite: env ACCESS_TOKEN -> `gh auth token` -> prompt.

Despliegue:
  --count N              Número de runners a crear (por defecto 1)
  --prefix P             Prefijo del nombre de runner (por defecto "gh")
  --labels L             Etiquetas extra separadas por comas (GitHub ya añade
                         self-hosted, Linux y la arquitectura)
  --group G              Runner group (opcional)
  --image REF            Imagen del contenedor (por defecto ghcr.io/joseamador95/gh_runner:latest)
  --engine E             Fuerza el motor: podman o docker (por defecto: autodetecta,
                         prefiere podman con compose y si no cae a docker)
  --cache-dirs A,B       Dirs extra de cache por runner (p.ej. .npm,.cargo);
                         relativas a /home/runner o absolutas
  --cpus N               Límite de CPU por runner (p.ej. 2 o 1.5)
  --memory SIZE          Límite de memoria por runner (p.ej. 2g, 512m)
  --pull-always          (default) pull_policy: always: cada 'up -d' re-baja :latest
  --no-pull-always       Quita pull_policy: always (fija la imagen local cacheada)
  --file PATH            Ruta del compose a generar (por defecto compose.yaml, que
                         'podman compose' autodetecta sin -f)

Seguridad:
  --secret               Guarda el PAT como file-secret (./access_token) en vez de
                         en .env (no aparece en `podman inspect`). Requiere que el
                         proveedor de compose soporte 'secrets:' (ver README).
  --token-in-env         Fuerza el modo por defecto (PAT en .env).

Vigilancia (opt-in):
  --vigilar              Añade al compose el servicio 'vigia': comprueba los
                         runners cada pocos minutos y entrega un informe a tus
                         hooks (avisos). Detecta el runner ATASCADO (el que sigue
                         "Up" pero no toma jobs), el que no reporta y el reloj
                         desfasado. Sube y baja con el cluster; su configuración
                         va en ./vigia, así que dos clusters de la misma máquina
                         avisan por separado.
  --vigilar-cada N       Cadencia de la ronda (por defecto 300; acepta 5min, 1h)
  --vigilar-minimo N     Runners sanos por debajo de los cuales el estado pasa de
                         'parcial' (se registra) a 'degradado' (alarma). Por
                         defecto 1: con un runner vivo la CI sigue corriendo.
  --no-host-label        No añadir la etiqueta host:<hostname> a los runners

Ejecución:
  --up                   Levanta el stack tras generar el compose
  --no-up                No lo levanta (solo genera los ficheros)
  --skip-validation      No validar el token contra la API antes de escribir
  --force                Sobreescribe compose.yaml/.env aunque no los generara deploy.sh
  --no-bootstrap         No instalar podman/compose ni crear la machine (gestionas el entorno tú)
  -h, --help             Esta ayuda

Variables de entorno usadas como fallback:
  ACCESS_TOKEN, REPO_USER, REPO_NAME, RUNNER_PREFIX, RUNNER_COUNT,
  RUNNER_LABELS, RUNNER_GROUP, IMAGE, RUNNER_CPUS, RUNNER_MEMORY
EOF
    exit "${1:-0}"
}

# ---- Parseo de argumentos --------------------------------------------------
while [ "$#" -gt 0 ]; do
    case "$1" in
        --repo)        REPO="${2:?}"; shift 2 ;;
        --owner)       OWNER="${2:?}"; shift 2 ;;
        --name)        NAME="${2:?}"; shift 2 ;;
        --token)       TOKEN="${2:?}"; TOKEN_SRC="flag --token"; shift 2 ;;
        --count)       COUNT="${2:?}"; shift 2 ;;
        --prefix)      PREFIX="${2:?}"; shift 2 ;;
        --labels)      LABELS="${2:?}"; shift 2 ;;
        --group)       GROUP="${2:?}"; shift 2 ;;
        --image)       IMAGE="${2:?}"; shift 2 ;;
        --engine)      ENGINE_PREF="${2:?}"; shift 2 ;;
        --cache-dirs)  CACHE_DIRS_CSV="${2:?}"; shift 2 ;;
        --cpus)        CPUS="${2:?}"; shift 2 ;;
        --memory)      MEMORY="${2:?}"; shift 2 ;;
        --pull-always) PULL_ALWAYS="yes"; shift ;;
        --no-pull-always) PULL_ALWAYS="no"; shift ;;
        --file)        COMPOSE_FILE="${2:?}"; shift 2 ;;
        --secret)      USE_SECRET="yes"; shift ;;
        --token-in-env) USE_SECRET="no"; shift ;;
        --up)          DO_UP="yes"; shift ;;
        --no-up)       DO_UP="no"; shift ;;
        --skip-validation) SKIP_VALIDATION="yes"; shift ;;
        --force)       FORCE="yes"; shift ;;
        --no-bootstrap) BOOTSTRAP="no"; shift ;;
        --vigilar)     VIGILAR="yes"; shift ;;
        --no-vigilar)  VIGILAR="no"; shift ;;
        --vigilar-cada)  VIGILAR_CADA="${2:?}"; shift 2 ;;
        --vigilar-minimo) VIGILAR_MINIMO="${2:?}"; shift 2 ;;
        --no-host-label) HOST_LABEL="no"; shift ;;
        -h|--help)     usage 0 ;;
        *) err "opción desconocida: $1 (usa --help)" ;;
    esac
done

# ---- Resolución de campos (flag -> env -> prompt) --------------------------
prompt() {  # $1 = texto; imprime el valor leído por stdout
    [ -t 0 ] || err "$2"
    printf '%s' "$1" >&2
    read -r _reply
    printf '%s' "$_reply"
}
prompt_secret() {  # $1 = texto; entrada oculta portable con stty
    [ -t 0 ] || err "$2"
    printf '%s' "$1" >&2
    stty -echo 2>/dev/null || true
    read -r _reply
    stty echo 2>/dev/null || true
    printf '\n' >&2
    printf '%s' "$_reply"
}

# Repo: --repo tiene prioridad; si no, --owner/--name; si no, env; si no, prompt.
if [ -n "$REPO" ]; then
    OWNER="${REPO%%/*}"
    NAME="${REPO#*/}"
    case "$REPO" in */*) : ;; *) err "--repo debe ser OWNER/REPO" ;; esac
fi
[ -n "$OWNER" ] || OWNER="${REPO_USER:-}"
[ -n "$NAME" ]  || NAME="${REPO_NAME:-}"
[ -n "$OWNER" ] || OWNER="$(prompt 'Owner del repo (OWNER): ' 'falta OWNER (--owner/--repo o REPO_USER)')"
[ -n "$NAME" ]  || NAME="$(prompt 'Nombre del repo (REPO): ' 'falta NAME (--name/--repo o REPO_NAME)')"
case "$OWNER/$NAME" in
    */) err "falta el nombre del repositorio" ;;
    /*) err "falta el owner del repositorio" ;;
esac

# La cadencia del vigía va en SEGUNDOS al compose, pero se acepta la forma de
# duración que documentaba el flag cuando esto era un timer de systemd (5min, 1h)
# para no romper a quien ya la tenía escrita.
a_segundos() {
    case "$1" in
        *[!0-9smhin]*) err "--vigilar-cada: '$1' no es una duración válida (300, 5min, 1h)" ;;
    esac
    _n="$(printf '%s' "$1" | tr -cd '0-9')"
    [ -n "$_n" ] || err "--vigilar-cada: falta el número en '$1'"
    case "$1" in
        *h)         printf '%s' "$(( _n * 3600 ))" ;;
        *min|*m)    printf '%s' "$(( _n * 60 ))" ;;
        *s|*[0-9])  printf '%s' "$_n" ;;
        *)          printf '%s' "$_n" ;;
    esac
}
VIGILAR_CADA="$(a_segundos "$VIGILAR_CADA")"
[ "$VIGILAR_CADA" -ge 60 ] 2>/dev/null || err "--vigilar-cada: mínimo 60 segundos (recibí ${VIGILAR_CADA}s)."
case "$VIGILAR_MINIMO" in ''|*[!0-9]*) err "--vigilar-minimo debe ser un número" ;; esac

# Identidad del cluster: el nombre del directorio del despliegue, saneado. Es lo
# que distingue dos clusters de la MISMA máquina, y ya es único por construcción
# porque guard_overwrite obliga a un directorio dedicado.
CLUSTER="$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-')"
CLUSTER="${CLUSTER%-}"
[ -n "$CLUSTER" ] || CLUSTER="gh"

# Otros campos: flag -> env -> default.
# El prefijo por defecto es el CLUSTER, no el literal 'gh'. Con 'gh' fijo, dos
# clusters en la misma máquina generaban runners con nombres idénticos
# (gh-<host>-1) y, como entrypoint.sh usa `config.sh --replace`, se robaban el
# registro mutuamente en bucle. Las ETIQUETAS no cambian, así que ningún `runs-on`
# se ve afectado.
PREFIX="${PREFIX:-${RUNNER_PREFIX:-$CLUSTER}}"

# UN SOLO NOMBRE para el fleet: el que se use de prefijo ES la identidad del
# cluster. Antes iban por caminos separados —`--prefix sherman` renombraba los
# runners pero el check seguía llamándose como el directorio—, así que el nombre
# se bifurcaba y no había forma de arreglar uno sin desalinear el otro.
CLUSTER="$PREFIX"
COUNT="${COUNT:-${RUNNER_COUNT:-1}}"
LABELS="${LABELS:-${RUNNER_LABELS:-}}"
GROUP="${GROUP:-${RUNNER_GROUP:-}}"
IMAGE="${IMAGE:-${ENV_IMAGE:-$IMAGE_DEFAULT}}"
CPUS="${CPUS:-${RUNNER_CPUS:-}}"
MEMORY="${MEMORY:-${RUNNER_MEMORY:-}}"

# Anti-inyección: nada que llegue al compose/.env puede traer saltos de línea
# o caracteres de control.
assert_clean owner "$OWNER"
assert_clean name "$NAME"
assert_clean prefix "$PREFIX"
assert_clean labels "$LABELS"
assert_clean group "$GROUP"
assert_clean image "$IMAGE"
assert_clean cpus "$CPUS"
assert_clean memory "$MEMORY"
assert_clean cache-dirs "$CACHE_DIRS_CSV"

# Token: --token -> ACCESS_TOKEN -> .env anterior -> `gh auth token` -> prompt.
if [ -z "$TOKEN" ]; then
    if [ -n "${ACCESS_TOKEN:-}" ]; then
        TOKEN="$ACCESS_TOKEN"; TOKEN_SRC="env ACCESS_TOKEN"
    elif [ -r "$ENV_FILE" ] && [ "$USE_SECRET" != "yes" ] \
         && case "$(head -n1 "$ENV_FILE" 2>/dev/null || true)" in "$MARKER"*) true ;; *) false ;; esac \
         && grep -q '^ACCESS_TOKEN=.' "$ENV_FILE" 2>/dev/null; then
        # Reusa el PAT del .env que escribió una ejecución anterior. Sin esto,
        # re-ejecutar el comando —que el README documenta como re-ejecutable, y que
        # se re-ejecuta de verdad cada vez que se ajusta algo— vuelve a pedir el
        # token a mano cada vez. Solo se acepta si el fichero lo generó deploy.sh
        # (lleva el marcador) y no estamos en modo --secret, donde el PAT no vive ahí.
        TOKEN="$(sed -n 's/^ACCESS_TOKEN=//p' "$ENV_FILE" | head -n1)"
        TOKEN_SRC="$ENV_FILE (ejecución anterior)"
    elif command -v gh >/dev/null 2>&1 && gh auth token >/dev/null 2>&1; then
        TOKEN="$(gh auth token)"; TOKEN_SRC="gh auth token"
    else
        TOKEN="$(prompt_secret 'PAT (Administration R/W): ' 'falta el token (--token / ACCESS_TOKEN / gh)')"
        TOKEN_SRC="prompt"
    fi
fi
[ -n "$TOKEN" ] || err "el token está vacío"

# Validaciones de forma.
case "$COUNT" in ''|*[!0-9]*) err "--count debe ser un entero positivo" ;; esac
[ "$COUNT" -ge 1 ] || err "--count debe ser >= 1"

# ---- Arquitectura soportada (la imagen es arm64/amd64) --------------------
case "$(uname -m 2>/dev/null || echo)" in
    armv7l|armv6l|armhf|armel)
        err "arquitectura de 32 bits no soportada: la imagen es arm64/amd64. En Raspberry Pi usa un SO de 64 bits (arm64)." ;;
esac

# ---- Bootstrap del entorno (podman/compose/machine), salvo --no-bootstrap --
[ "$BOOTSTRAP" = "yes" ] && bootstrap_env

# ---- Detección de motor y compose -----------------------------------------
case "$ENGINE_PREF" in ''|podman|docker) : ;; *) err "--engine debe ser podman o docker" ;; esac

# Prefiere el motor forzado con --engine; si no, podman y luego docker. Se elige
# el primero que tenga un proveedor de compose funcionando.
_engines="${ENGINE_PREF:-podman docker}"
ENGINE=""; COMPOSE=""
# shellcheck disable=SC2086
for _eng in $_engines; do
    command -v "$_eng" >/dev/null 2>&1 || continue
    _c="$(compose_for "$_eng")"
    if [ -n "$_c" ]; then ENGINE="$_eng"; COMPOSE="$_c"; break; fi
done

if [ -z "$ENGINE" ]; then
    if [ -n "$ENGINE_PREF" ] && ! command -v "$ENGINE_PREF" >/dev/null 2>&1; then
        err "--engine $ENGINE_PREF: no se encontró '$ENGINE_PREF' en el PATH"
    fi
    if command -v podman >/dev/null 2>&1 || command -v docker >/dev/null 2>&1; then
        err "hay motor de contenedores pero falta un proveedor de compose. Instala uno:
       - Podman (no trae compose integrado):
           macOS:   brew install docker-compose      (o: pip3 install podman-compose)
           Fedora:  sudo dnf install podman-compose
           Windows: activa Compose en Podman Desktop, o instala docker-compose
       - Docker: instala el plugin 'docker compose' (Docker Desktop ya lo trae).
       Verifica con 'podman compose version' o 'docker compose version'."
    else
        err "no se encontró 'podman' ni 'docker' en el PATH"
    fi
fi

# Aviso de capacidad: los proveedores "legacy" pueden no soportar todo el compose.
case "$COMPOSE" in
    podman-compose|docker-compose)
        info "AVISO: '$COMPOSE' puede no soportar del todo 'secrets:'/'deploy:'/merge YAML del compose generado. Si 'up' falla, usa 'podman compose' o 'docker compose' (plugin v2)." ;;
esac

# ---- Validación del token contra la API (fail-fast) -----------------------
if [ "$SKIP_VALIDATION" != "yes" ]; then
    command -v curl >/dev/null 2>&1 || err "falta 'curl' para validar el token. Instálalo o pasa --skip-validation."
    info "Validando el token contra la API de GitHub..."
    _tmp="$(mktemp)"
    # El PAT va por --config (stdin), NO por argv, para no exponerlo en `ps`.
    _http="$(printf 'header = "Authorization: Bearer %s"' "$TOKEN" \
        | curl -sSL -o "$_tmp" -w '%{http_code}' --config - \
            -X POST \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "https://api.github.com/repos/${OWNER}/${NAME}/actions/runners/registration-token" \
            2>/dev/null || true)"
    if [ "$_http" != "201" ]; then
        _msg="$(jq -r '.message // "sin mensaje"' <"$_tmp" 2>/dev/null || echo 'sin mensaje')"
        rm -f "$_tmp"
        err "el token no puede registrar runners en ${OWNER}/${NAME} (HTTP ${_http:-000}: ${_msg}).
       Necesita permiso Administration:R/W sobre el repo. Usa --skip-validation para omitir."
    fi
    rm -f "$_tmp"
    info "Token válido."
fi

# ---- Nombre de host corto y saneado ---------------------------------------
HOST="$(hostname 2>/dev/null || echo runner)"
HOST="${HOST%%.*}"
HOST="$(printf '%s' "$HOST" | tr -c 'A-Za-z0-9_-' '-')"
[ -n "$HOST" ] || HOST="runner"

# La máquina se AÑADE sola a los dos sitios donde hace falta: los runners se
# llaman <cluster>-<host>-<n> y el check <cluster>-<host>. Si el nombre del
# cluster ya trae el host, sale repetido —«sherman-mmja-mmJA-1»— y eso pasó de
# verdad: antes el check no llevaba la máquina y la única forma de distinguirlos
# era meterla en el nombre del directorio. Ya no hace falta, así que se avisa en
# vez de dejar que se arrastre.
case "$(printf '%s' "$CLUSTER" | tr '[:upper:]' '[:lower:]')" in
    *"$(printf '%s' "$HOST" | tr '[:upper:]' '[:lower:]')"*)
        info "AVISO: el nombre del cluster ('$CLUSTER') ya contiene la máquina ('$HOST')."
        info "  La máquina se añade sola, así que quedará repetida:"
        info "    runners : ${PREFIX}-${HOST}-1"
        info "    check   : ${CLUSTER}-${HOST}"
        info "  Usa --prefix con el nombre del PROYECTO (p. ej. --prefix sherman)."
        ;;
esac

# ---- Etiqueta de host ------------------------------------------------------
# Hasta ahora el único rastro de en qué máquina vive un runner era su NOMBRE, y
# parsearlo no es fiable: el saneado de arriba CONSERVA guiones y el prefijo es
# libre, así que en "mi-prefijo-mi-host-3" no hay forma de saber dónde acaba uno
# y empieza el otro. Con una etiqueta el dato es explícito.
#
# Va en su PROPIA variable y no concatenada a RUNNER_LABELS: el entrypoint aplica
# un default (`self-hosted,ubuntu-24.04`) solo cuando RUNNER_LABELS viene vacía,
# así que rellenarla aquí lo BORRARÍA y un `runs-on: [self-hosted, ubuntu-24.04]`
# dejaría de casar. El entrypoint la añade encima de lo que haya, que es lo que
# hace la etiqueta de verdad aditiva. $HOST ya viene saneado arriba.
HOST_LABEL_VALUE=""
[ "$HOST_LABEL" = "yes" ] && HOST_LABEL_VALUE="host${HOST_LABEL_SEP}${HOST}"

# ---- No pisar ficheros ajenos ---------------------------------------------
guard_overwrite "$ENV_FILE"
guard_overwrite "$COMPOSE_FILE"
if [ "$USE_SECRET" = "yes" ]; then guard_secret_file "$SECRET_FILE"; fi

umask 077

# ---- (opcional) PAT como file-secret --------------------------------------
if [ "$USE_SECRET" = "yes" ]; then
    printf '%s' "$TOKEN" > "$SECRET_FILE"   # verbatim, sin newline ni marker
    chmod 600 "$SECRET_FILE"
    info "Escrito $SECRET_FILE (chmod 600) con el PAT (montado como secret)."
fi

# ---- Escribir .env (config compartida) ------------------------------------
# En modo --secret el PAT NO va aquí (se monta como secret); el resto sí.
{
    printf '%s (líneas # son comentarios)\n' "$MARKER"
    [ "$USE_SECRET" = "yes" ] || printf 'ACCESS_TOKEN=%s\n' "$TOKEN"
    printf 'REPO_USER=%s\n' "$OWNER"
    printf 'REPO_NAME=%s\n' "$NAME"
    [ -n "$LABELS" ] && printf 'RUNNER_LABELS=%s\n' "$LABELS"
    [ -n "$HOST_LABEL_VALUE" ] && printf 'RUNNER_HOST_LABEL=%s\n' "$HOST_LABEL_VALUE"
    [ -n "$GROUP" ]  && printf 'RUNNER_GROUP=%s\n' "$GROUP"
    :
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"
info "Escrito $ENV_FILE (chmod 600)."

# ---- Generar el compose ----------------------------------------------------
# Helpers para dirs de cache extra.
norm_dir()   { case "$1" in /*) printf '%s' "$1" ;; *) printf '/home/runner/%s' "$1" ;; esac; }
vol_suffix() { printf '%s' "$1" | tr -cd 'A-Za-z0-9'; }

{
    printf '%s — no editar a mano.\n' "$MARKER"
    printf '# Runners: %s | repo: %s/%s | imagen: %s\n\n' "$COUNT" "$OWNER" "$NAME" "$IMAGE"
    printf 'x-runner-common: &runner-common\n'
    printf '  image: %s\n' "$IMAGE"
    printf '  restart: always\n'
    [ "$PULL_ALWAYS" = "yes" ] && printf '  pull_policy: always\n'
    printf '  env_file: [%s]\n' "$ENV_FILE"
    if [ "$USE_SECRET" = "yes" ]; then
        printf '  secrets:\n'
        printf '    - access_token\n'
    fi
    if [ -n "$CPUS" ] || [ -n "$MEMORY" ]; then
        printf '  deploy:\n'
        printf '    resources:\n'
        printf '      limits:\n'
        [ -n "$CPUS" ]   && printf '        cpus: "%s"\n' "$CPUS"
        [ -n "$MEMORY" ] && printf '        memory: %s\n' "$MEMORY"
    fi
    printf '\n'
    printf 'services:\n'
    i=1
    while [ "$i" -le "$COUNT" ]; do
        printf '  runner-%s:\n' "$i"
        printf '    <<: *runner-common\n'
        printf '    environment:\n'
        printf '      RUNNER_NAME: "%s-%s-%s"\n' "$PREFIX" "$HOST" "$i"
        if [ -n "$CACHE_DIRS_CSV" ]; then
            _dirs=""
            OLDIFS=$IFS; IFS=,
            for _d in $CACHE_DIRS_CSV; do
                [ -n "$_d" ] || continue
                _full="$(norm_dir "$_d")"
                _dirs="$_dirs $_full"
            done
            IFS=$OLDIFS
            # trim
            _dirs="${_dirs# }"
            printf '      CACHE_DIRS: "%s"\n' "$_dirs"
        fi
        printf '    volumes:\n'
        printf '      - runner-%s-work:/home/runner/_work\n' "$i"
        printf '      - runner-%s-cache:/home/runner/.cache\n' "$i"
        # Volumen compartido donde este runner publica su latido y el vigía lo lee.
        # Solo con --vigilar, para que el compose por defecto no cambie.
        [ "$VIGILAR" = "yes" ] && printf '      - latidos:/var/lib/gh-runner/latidos\n'
        if [ -n "$CACHE_DIRS_CSV" ]; then
            OLDIFS=$IFS; IFS=,
            for _d in $CACHE_DIRS_CSV; do
                [ -n "$_d" ] || continue
                _full="$(norm_dir "$_d")"
                _sfx="$(vol_suffix "$_d")"
                printf '      - runner-%s-%s:%s\n' "$i" "$_sfx" "$_full"
            done
            IFS=$OLDIFS
        fi
        i=$((i + 1))
    done

    # ---- El vigía, como un servicio más -----------------------------------
    # Vive aquí y no en el host porque el agendado lo hace entonces el motor de
    # contenedores, que es la única capa idéntica en Linux, macOS y Windows.
    # Sube y baja con el cluster: `up -d` lo enciende, `down` se lo lleva.
    if [ "$VIGILAR" = "yes" ]; then
        _nombres=""
        i=1
        while [ "$i" -le "$COUNT" ]; do
            _nombres="$_nombres ${PREFIX}-${HOST}-${i}"
            i=$((i + 1))
        done
        _nombres="${_nombres# }"

        printf '  vigia:\n'
        printf '    image: %s\n' "$IMAGE"
        printf '    restart: always\n'
        # user 0:0 NO es un descuido ni un privilegio de más, y quitarlo rompe los
        # avisos en silencio. ./vigia guarda secretos (la URL de ping, el token del
        # bot) y va a 700 en el host. En podman ROOTLESS el usuario del host mapea
        # al root DEL CONTENEDOR, mientras que el usuario `runner` de la imagen
        # mapea a un subuid distinto: como `runner` no podría leer su propia
        # configuración y los hooks no se ejecutarían. Como root del contenedor sí,
        # y sigue siendo el usuario sin privilegios del host — no se gana acceso a
        # nada. Este contenedor no monta el socket del motor ni nada del host más
        # allá de ./vigia en solo lectura.
        printf '    user: "0:0"\n'
        printf '    entrypoint: ["/home/runner/vigilar.sh"]\n'
        printf '    command: ["--bucle"]\n'
        printf '    environment:\n'
        printf '      VIGIA_CLUSTER: "%s"\n' "$CLUSTER"
        # El host se PASA, no se deduce: dentro del contenedor `hostname` devuelve
        # el ID del contenedor, que además cambia en cada recreate. Como ese valor
        # forma parte del nombre del check, deducirlo daría un check nuevo cada vez
        # que se recrea el vigía, y el anterior quedaría huérfano y en rojo.
        printf '      VIGIA_HOST: "%s"\n' "$HOST"
        # Censo explícito: «no hay latido» solo significa algo si sabes a quién
        # esperabas. Lo sabe deploy.sh, así que lo escribe aquí y el vigía no
        # tiene que adivinarlo ni parsear el compose.
        printf '      VIGIA_RUNNERS: "%s"\n' "$_nombres"
        printf '      VIGIA_CADA: "%s"\n' "$VIGILAR_CADA"
        printf '      VIGIA_MINIMO: "%s"\n' "$VIGILAR_MINIMO"
        printf '    volumes:\n'
        # :ro — el vigía solo lee. Un runner comprometido puede falsear su propio
        # latido, pero no los ajenos, y esto además deja clara la dirección.
        printf '      - latidos:/var/lib/gh-runner/latidos:ro\n'
        printf '      - ./vigia:/etc/gh-runner/vigia:ro\n'
        printf '      - vigia-estado:/var/lib/gh-runner/estado\n'
    fi

    printf '\n'
    printf 'volumes:\n'
    if [ "$VIGILAR" = "yes" ]; then
        printf '  latidos: {}\n'
        printf '  vigia-estado: {}\n'
    fi
    i=1
    while [ "$i" -le "$COUNT" ]; do
        printf '  runner-%s-work: {}\n' "$i"
        printf '  runner-%s-cache: {}\n' "$i"
        if [ -n "$CACHE_DIRS_CSV" ]; then
            OLDIFS=$IFS; IFS=,
            for _d in $CACHE_DIRS_CSV; do
                [ -n "$_d" ] || continue
                _sfx="$(vol_suffix "$_d")"
                printf '  runner-%s-%s: {}\n' "$i" "$_sfx"
            done
            IFS=$OLDIFS
        fi
        i=$((i + 1))
    done
    if [ "$USE_SECRET" = "yes" ]; then
        printf '\nsecrets:\n'
        printf '  access_token:\n'
        printf '    file: ./%s\n' "$SECRET_FILE"
    fi
} > "$COMPOSE_FILE"
info "Escrito $COMPOSE_FILE con $COUNT runner(s)."

# ---- Vigía: configuración local del contenedor (opt-in con --vigilar) -------
# El vigía YA está en el compose (servicio `vigia`, arriba). Aquí solo se prepara
# lo que necesita del disco del host: su directorio de configuración y los hooks
# de ejemplo.
#
# Ese directorio va en el DESPLIEGUE (./vigia), no en ~/.config, y ese cambio es
# la solución al multi-cluster: dos clusters de la misma máquina ya tienen
# directorios distintos (guard_overwrite lo obliga), así que cada uno queda con su
# configuración y su check sin necesidad de flags nuevas. Con la ruta compartida
# de antes, ambos pingeaban el MISMO check y el latido sano de uno mantenía el
# check verde aunque el otro estuviese muerto.
#
# El vigía NO maneja secretos: entrega el informe a los hooks y cada hook guarda
# el suyo. Es deliberado: el .env se inyecta en contenedores que ejecutan código
# arbitrario de CI, así que un token ahí sería una fuga.


# Copia un fichero del repo al directorio del despliegue: si deploy.sh se está
# ejecutando desde un clon, lo coge del hermano; si vino por curl (sin ficheros
# en disco), lo baja.
traer_del_repo() {  # $1 = ruta relativa en el repo, $2 = destino
    if [ -n "${_DIR_SCRIPT:-}" ] && [ -f "${_DIR_SCRIPT}/$1" ]; then
        # Si el despliegue ES el propio clon, origen y destino son el mismo
        # fichero y `cp` aborta ("are the same file"). No hay nada que copiar.
        [ "${_DIR_SCRIPT}/$1" = "$2" ] && return 0
        cp "${_DIR_SCRIPT}/$1" "$2"
        return 0
    fi
    command -v curl >/dev/null 2>&1 || err "necesito 'curl' para bajar $1 (o corre deploy.sh desde un clon del repo)."
    curl -fsSL "${RAW_BASE}/$1" -o "$2" || err "no pude bajar $1 desde ${RAW_BASE}.
       Clona el repo y corre deploy.sh desde ahí: coge los ficheros del clon en vez de bajarlos."
}
if [ "$VIGILAR" = "yes" ]; then
    _vigia_dir="$(pwd)/vigia"
    mkdir -p "${_vigia_dir}/hooks.d"
    chmod 700 "$_vigia_dir" "${_vigia_dir}/hooks.d" 2>/dev/null || true

    # Solo el de healthchecks.io. Es el único que cubre el fallo que la máquina
    # no puede contar por sí misma (que esté apagada), y además REENVÍA el informe
    # entero a Telegram/correo/lo que configures en su web, en <pre>. Un segundo
    # hook mandando lo mismo al mismo chat era un duplicado con un secreto extra
    # que mantener en cada máquina. El ejemplo de Telegram sigue en el repo para
    # quien quiera un canal independiente del proveedor.
    _h="10-healthchecks.sh"
    if [ ! -e "${_vigia_dir}/hooks.d/${_h}" ] && [ ! -e "${_vigia_dir}/hooks.d/${_h}.ejemplo" ]; then
        traer_del_repo "hooks/${_h}.ejemplo" "${_vigia_dir}/hooks.d/${_h}.ejemplo"
    fi

    info "Vigía: servicio 'vigia' en $COMPOSE_FILE, ronda cada $(( VIGILAR_CADA / 60 )) min."
    info "  Configura los avisos : ${_vigia_dir}/avisos.conf"
    info "  Hooks de ejemplo en  : ${_vigia_dir}/hooks.d (cópialos sin '.ejemplo' para activarlos)"
    info "  Ver el informe       : $COMPOSE logs -f vigia"
    info "  Comprobar ahora      : $COMPOSE exec vigia /home/runner/vigilar.sh --informe"
fi

# ---- Resumen ---------------------------------------------------------------
info ""
info "Resumen:"
info "  Repo    : ${OWNER}/${NAME}"
info "  Runners : ${COUNT} (nombres: ${PREFIX}-${HOST}-1..${COUNT})"
info "  Imagen  : ${IMAGE}"
info "  Token   : ${TOKEN_SRC:-desconocido}"
if [ "$USE_SECRET" = "yes" ]; then
    info "  PAT     : file-secret (./${SECRET_FILE})"
else
    info "  PAT     : en ${ENV_FILE}"
fi
[ -n "$CPUS$MEMORY" ] && info "  Límites : cpus=${CPUS:-—} memoria=${MEMORY:-—}"
# Lo que el runner recibirá de verdad: --labels MÁS la etiqueta de host, que
# viaja aparte. Enseñar solo una de las dos daría una idea equivocada.
_labels_efectivas="$LABELS"
if [ -n "$HOST_LABEL_VALUE" ]; then
    [ -n "$_labels_efectivas" ] && _labels_efectivas="${_labels_efectivas},"
    _labels_efectivas="${_labels_efectivas}${HOST_LABEL_VALUE}"
fi
[ -n "$_labels_efectivas" ] && info "  Etiquetas: ${_labels_efectivas}"
info "  Motor   : ${ENGINE} (${COMPOSE})"
if [ "$VIGILAR" = "yes" ]; then
    info "  Vigía   : servicio 'vigia', ronda cada $(( VIGILAR_CADA / 60 )) min · config en ./vigia"
else
    info "  Vigía   : no (--vigilar lo instala: avisa si un runner se atasca o se cae)"
fi

# ---- Comandos de control ---------------------------------------------------
# Con el nombre autodetectado (compose.yaml, etc.) no hace falta -f.
case "$COMPOSE_FILE" in
    compose.yaml|compose.yml|docker-compose.yaml|docker-compose.yml)
        FILE_ARG=""; CTL="$COMPOSE" ;;
    *)
        FILE_ARG="-f $COMPOSE_FILE"; CTL="$COMPOSE -f $COMPOSE_FILE" ;;
esac

# ---- Levantar el stack -----------------------------------------------------
if [ "$DO_UP" = "auto" ]; then
    if [ -t 0 ]; then DO_UP="yes"; else DO_UP="no"; fi
fi

if [ "$DO_UP" = "yes" ]; then
    info ""
    info "Levantando: $CTL up -d"
    # shellcheck disable=SC2086
    $COMPOSE $FILE_ARG up -d
    info ""
    info "Listo. Comprueba con: $CTL ps"
else
    info ""
    info "Para levantar los runners:"
    info "  $CTL up -d"
fi

info ""
info "Comandos útiles (desde este directorio):"
info "  $CTL ps                 # estado"
info "  $CTL logs -f runner-1   # logs de un runner"
info "  $CTL down               # parar y desregistrar"
info "  $CTL down -v            # + borrar el cache (volúmenes)"
