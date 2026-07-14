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
MOUNTS=""           # --mount SRC:DST[:ro] (repetible) — volumen/bind extra en CADA runner (newline-delimited)
NETWORKS=""         # --network NAME[:external] (repetible) — red extra en CADA runner (newline-delimited)
COMPOSE_EXTRA=""    # --compose-extra FILE — override del proyecto (o autodetecta ./compose.override.yaml)
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

# ---- Utilidades ------------------------------------------------------------
err()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*" >&2; }

# Newline literal: acumula flags repetibles (--mount/--network) sin perder el
# separador. No usamos $(...) para esto porque recorta los \n finales; los
# valores pueden llevar espacios (rutas de bind), así que \n es el delimitador.
NL='
'

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
  --mount SRC:DST[:ro]   Volumen/bind extra en CADA runner (repetible). SRC nombre
                         de volumen (compartido; se declara) o ruta host (bind).
  --network NAME[:external]  Red extra en CADA runner (repetible). Para redes
                         externas ya existentes; los sidecars del propio override
                         ya son alcanzables por nombre vía la red por defecto.
  --compose-extra FILE   Override de compose del proyecto a encadenar (por defecto
                         autodetecta ./compose.override.yaml). deploy.sh no lo genera.
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
        --mount)       assert_clean mount "${2:?}";   MOUNTS="${MOUNTS:+$MOUNTS$NL}$2"; shift 2 ;;
        --network)     assert_clean network "${2:?}"; NETWORKS="${NETWORKS:+$NETWORKS$NL}$2"; shift 2 ;;
        --compose-extra) assert_clean compose-extra "${2:?}"; COMPOSE_EXTRA="$2"; shift 2 ;;
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

# Otros campos: flag -> env -> default.
PREFIX="${PREFIX:-${RUNNER_PREFIX:-gh}}"
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

# Token: --token -> ACCESS_TOKEN -> `gh auth token` -> prompt.
if [ -z "$TOKEN" ]; then
    if [ -n "${ACCESS_TOKEN:-}" ]; then
        TOKEN="$ACCESS_TOKEN"; TOKEN_SRC="env ACCESS_TOKEN"
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
    [ -n "$GROUP" ]  && printf 'RUNNER_GROUP=%s\n' "$GROUP"
    :
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"
info "Escrito $ENV_FILE (chmod 600)."

# ---- Generar el compose ----------------------------------------------------
# Helpers para dirs de cache extra.
norm_dir()   { case "$1" in /*) printf '%s' "$1" ;; *) printf '/home/runner/%s' "$1" ;; esac; }
vol_suffix() { printf '%s' "$1" | tr -cd 'A-Za-z0-9'; }

# De --mount: volúmenes NOMBRADOS (1er campo sin '/' ni '.'/'~' inicial) para
# declararlos UNA vez a top-level. Una ruta (bind) no se declara.
NAMED_VOLS=""
if [ -n "$MOUNTS" ]; then
    OLDIFS=$IFS; IFS=$NL
    for _m in $MOUNTS; do
        [ -n "$_m" ] || continue
        _src="${_m%%:*}"
        case "$_src" in /*|.*|~*|*/*) continue ;; esac
        case " $NAMED_VOLS " in *" $_src "*) continue ;; esac
        NAMED_VOLS="${NAMED_VOLS:+$NAMED_VOLS }$_src"
    done
    IFS=$OLDIFS
fi

# De --network: dedup por NOMBRE (1er campo), conservando el sufijo :external.
NETWORKS_UNIQ=""; _seen_net=""
if [ -n "$NETWORKS" ]; then
    OLDIFS=$IFS; IFS=$NL
    for _n in $NETWORKS; do
        [ -n "$_n" ] || continue
        _nname="${_n%%:*}"
        case " $_seen_net " in *" $_nname "*) continue ;; esac
        _seen_net="$_seen_net $_nname"
        NETWORKS_UNIQ="${NETWORKS_UNIQ:+$NETWORKS_UNIQ$NL}$_n"
    done
    IFS=$OLDIFS
fi

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
        # --mount: volúmenes/binds extra (los MISMOS en cada runner).
        if [ -n "$MOUNTS" ]; then
            OLDIFS=$IFS; IFS=$NL
            for _m in $MOUNTS; do
                [ -n "$_m" ] || continue
                printf '      - %s\n' "$_m"
            done
            IFS=$OLDIFS
        fi
        # --network: se listan las redes pedidas + 'default' (para no perder la
        # red por defecto que hace alcanzables por nombre a los sidecars).
        if [ -n "$NETWORKS_UNIQ" ]; then
            printf '    networks:\n'
            printf '      - default\n'
            OLDIFS=$IFS; IFS=$NL
            for _n in $NETWORKS_UNIQ; do
                [ -n "$_n" ] || continue
                printf '      - %s\n' "${_n%%:*}"
            done
            IFS=$OLDIFS
        fi
        i=$((i + 1))
    done
    printf '\n'
    printf 'volumes:\n'
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
    # Volúmenes nombrados de --mount (declarados una vez, compartidos entre runners).
    for _v in $NAMED_VOLS; do
        printf '  %s: {}\n' "$_v"
    done
    # Redes de --network (top-level). 'default' explícito para conservar la red
    # por defecto del proyecto (sidecars alcanzables por nombre).
    if [ -n "$NETWORKS_UNIQ" ]; then
        printf '\nnetworks:\n'
        printf '  default: {}\n'
        OLDIFS=$IFS; IFS=$NL
        for _n in $NETWORKS_UNIQ; do
            [ -n "$_n" ] || continue
            case "$_n" in
                *:external) printf '  %s:\n    external: true\n' "${_n%%:*}" ;;
                *)          printf '  %s: {}\n' "${_n%%:*}" ;;
            esac
        done
        IFS=$OLDIFS
    fi
    if [ "$USE_SECRET" = "yes" ]; then
        printf '\nsecrets:\n'
        printf '  access_token:\n'
        printf '    file: ./%s\n' "$SECRET_FILE"
    fi
} > "$COMPOSE_FILE"
info "Escrito $COMPOSE_FILE con $COUNT runner(s)."

# ---- Override del proyecto (compose.override.yaml) -------------------------
# --compose-extra FILE, o autodetecta ./compose.override.yaml. deploy.sh NO lo
# genera ni lo pisa (lo posee el proyecto: sidecars, volúmenes/redes a medida).
if [ -z "$COMPOSE_EXTRA" ] && [ -f "compose.override.yaml" ]; then
    COMPOSE_EXTRA="compose.override.yaml"
fi
[ -z "$COMPOSE_EXTRA" ] || [ -f "$COMPOSE_EXTRA" ] || err "--compose-extra: no encuentro '$COMPOSE_EXTRA'"

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
info "  Motor   : ${ENGINE} (${COMPOSE})"
[ -n "$COMPOSE_EXTRA" ] && info "  Override: ${COMPOSE_EXTRA}"

# ---- Comandos de control ---------------------------------------------------
# Con el nombre autodetectado (compose.yaml, etc.) no hace falta -f... salvo que
# haya override: pasar cualquier -f desactiva el autoload del base, así que hay
# que encadenar AMBOS explícitamente (-f base -f override).
if [ -n "$COMPOSE_EXTRA" ]; then
    FILE_ARG="-f $COMPOSE_FILE -f $COMPOSE_EXTRA"
else
    case "$COMPOSE_FILE" in
        compose.yaml|compose.yml|docker-compose.yaml|docker-compose.yml) FILE_ARG="" ;;
        *) FILE_ARG="-f $COMPOSE_FILE" ;;
    esac
fi
CTL="$COMPOSE${FILE_ARG:+ $FILE_ARG}"

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
