#!/bin/sh
# ============================================================================
# deploy-macos.sh — despliega runners EFÍMEROS de GitHub Actions en un Mac de
# Apple Silicon, con VMs de Tart en vez de contenedores.
#
#   sh -c "$(curl -fsSL https://raw.githubusercontent.com/JoseAmador95/gh_runner/main/deploy-macos.sh)" -- \
#       --repo OWNER/REPO --token <PAT> --count 1 --memory 20G --prefix ci --up
#
# Es el HERMANO de deploy.sh, y a propósito tiene la MISMA superficie de CLI:
# quien despliega el camino Linux no tiene que aprender nada nuevo. Lo que
# cambia es lo que hay debajo, y solo porque en macOS no existe la pieza que
# usa el otro camino:
#
#   Linux/Windows            macOS (aquí)
#   ----------------------   ------------------------------------------------
#   imagen OCI               VM "golden" de Tart (hornear-macos.sh)
#   contenedor efímero       clon efímero de la golden (tart clone/run/delete)
#   restart: always          supervisar-macos.sh, un proceso por slot
#   compose up -d            LaunchAgent con KeepAlive (launchctl bootstrap)
#   servicio `vigia`         LaunchAgent del vigía, en el host
#   volúmenes con nombre     — (ver --cache-dirs más abajo)
#
# ESTE SCRIPT NO INVENTA NINGÚN CONTRATO: genera exactamente el directorio de
# despliegue que supervisar-macos.sh espera (montaje/, latidos/, estado/, .env
# y el tarball del agente) y lo arranca con launchd. Si cambia el contrato,
# cambia allí primero.
#
# --- POR QUÉ EL PAT NO VA EN EL PLIST ---------------------------------------
# `up` enlaza los plists en ~/Library/LaunchAgents, que lo lee CUALQUIER proceso
# del usuario, y `launchctl print` enseña el entorno de un servicio cargado. El
# PAT vive solo en ./.env (0600) y en ./montaje/access_token (0600), que es de
# donde ya lo leen el supervisor y el invitado. Es la misma regla que deploy.sh
# aplica al no pasarlo por argv del contenedor: invisible en `ps`.
#
# --- POR QUÉ SE ESCAPA XML ---------------------------------------------------
# Un plist es XML, y aquí se interpolan valores libres: el prefijo del cluster,
# el nombre de la máquina y la RUTA del despliegue. Un solo '&' en cualquiera de
# ellos deja el fichero mal formado, y launchd no dice "XML inválido": se niega a
# cargar el servicio y el fleet se queda sin arrancar sin más pista que un
# "Bootstrap failed: 5: Input/output error". assert_clean (heredado de deploy.sh)
# solo para saltos de línea; para el resto está xml_esc, y todo lo que entra al
# plist pasa por ella.
#
# --- DIMENSIONADO (léelo antes de poner --count 2) --------------------------
# El Mac de destino tiene 32 GB. Cada VM se lleva lo que le des en --memory y el
# anfitrión necesita lo suyo. Dos VMs compilando Xcode y Rust a la vez dejan al
# host con ~8 GB, el conjunto entra a swap y los DOS jobs tardan más que uno
# solo. Recomendado: --count 1 --memory 20G. Sube a 2 solo si de verdad ves
# jobs encolados, y entonces baja --memory a 12G.
#
# POSIX sh a propósito, sin `local` (SC3043), igual que deploy.sh y el resto de
# los scripts del repo.
# ============================================================================
set -eu

# ---- Valores por defecto ---------------------------------------------------
# La imagen base OCI de Tart de la que hornear-macos.sh clona la golden. Mismo
# default que ese script: un solo Xcode (macos-runner:tahoe trae tres y ronda
# los 100 GB).
IMAGE_DEFAULT="ghcr.io/cirruslabs/macos-sequoia-xcode:16.4"

# Tope duro de VMs por Mac. NO es un aviso: ver la comprobación de --count.
MAX_VMS=2

# Captura del entorno para el fallback (env IMAGE se lee antes de reusar la var).
ENV_IMAGE="${IMAGE:-}"

REPO=""
OWNER=""
NAME=""
TOKEN=""
TOKEN_SRC=""
PREFIX=""
COUNT=""
LABELS=""
GROUP=""
IMAGE=""
ENV_FILE=".env"
CACHE_DIRS_CSV=""
DO_UP="auto"        # auto|yes|no
SKIP_VALIDATION="no"
FORCE="no"
CPUS=""
MEMORY=""
USE_SECRET="no"
SECRET_FILE="access_token"
ENGINE_PREF=""
BOOTSTRAP="yes"
PM=""               # gestor de paquetes detectado (brew)
VIGILAR="no"
VIGILAR_CADA="300"
VIGILAR_MINIMO="1"
HOST_LABEL="yes"
HOST_LABEL_SEP=":"

# La golden y el watchdog por vuelta: no son flags (la CLI es la de deploy.sh),
# pero sí variables de entorno, que es como los lee supervisar-macos.sh.
GOLDEN="${SUPERVISAR_GOLDEN:-gh-runner-golden}"
LIMITE_JOB="${SUPERVISAR_LIMITE_JOB:-90min}"

RAW_BASE="https://raw.githubusercontent.com/JoseAmador95/gh_runner/main"

# Directorio del propio script, SI se ejecuta desde un fichero. Con `sh -c "$(curl …)"`
# queda vacío y las piezas se bajan del repo. Mismo criterio que deploy.sh.
_DIR_SCRIPT=""
case "$0" in
    */*) [ -f "$0" ] && _DIR_SCRIPT="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" ;;
esac

# ---- Utilidades ------------------------------------------------------------
err()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*" >&2; }

# Prefijo que deploy.sh y deploy.ps1 ponen en la PRIMERA línea de lo que generan.
MARKER="# GENERADO por deploy"
# El nuestro NO empieza por el de ellos, y eso es deliberado: así el guard de
# deploy.sh (que compara el PRINCIPIO de la primera línea con $MARKER) NO
# reconoce un .env de macOS y se niega a pisarlo sin --force. La otra dirección
# la cubre guard_overwrite de aquí abajo. Un despliegue por directorio, como ya
# obliga el diseño de los dos scripts.
MARKER_MACOS="# macOS · GENERADO por deploy-macos.sh"
MARKER_ID="GENERADO por deploy-macos.sh"

# No pisar ficheros que no generó ESTE script. Se miran las 3 primeras líneas
# porque en un plist el marcador va en un comentario XML, que no puede ir antes
# de la declaración `<?xml …?>`.
guard_overwrite() {
    [ -e "$1" ] || return 0
    head -n 3 "$1" 2>/dev/null | grep -Fq "$MARKER_ID" && return 0
    [ "$FORCE" = "yes" ] && return 0
    case "$(head -n1 "$1" 2>/dev/null || true)" in
        "$MARKER"*)
            err "'$1' es de un despliegue del camino LINUX (lo generó deploy.sh/deploy.ps1).
       Un directorio no puede ser las dos cosas: los runners se llamarían igual y,
       como config.sh usa --replace, se robarían el registro entre sí.
       Usa un directorio dedicado para el Mac, o --force si sabes lo que haces." ;;
    esac
    err "ya existe '$1' y no lo generó deploy-macos.sh.
       Corre deploy-macos.sh en un directorio DEDICADO (recomendado) o usa --force."
}

# El fichero del secret se lee verbatim (sin marcador posible); no lo pisamos.
guard_secret_file() {
    [ -e "$1" ] || return 0
    [ "$FORCE" = "yes" ] && return 0
    err "ya existe '$1' (fichero del secret). Bórralo o usa --force para sobreescribir."
}

# Rechaza valores con saltos de línea / caracteres de control antes de escribirlos
# al .env o al plist. Copiado de deploy.sh, incluido el motivo de contar bytes con
# `wc -c` en vez de mirar el residuo con $(...): la sustitución come los \n finales
# y dejaría pasar justo la inyección por newline.
assert_clean() {
    _ctrl="$(printf '%s' "$2" | LC_ALL=C tr -cd '[:cntrl:]' | wc -c | tr -dc '0-9')"
    if [ "${_ctrl:-0}" -gt 0 ]; then
        err "valor inválido para $1: contiene saltos de línea o caracteres de control (posible inyección)."
    fi
}

# Escapado XML para todo lo que se interpola en un plist. El '&' va PRIMERO o se
# volvería a escapar el '&' de las entidades que introducen las reglas siguientes
# ('&lt;' acabaría como '&amp;lt;'). En el reemplazo de sed '&' significa "lo que
# casó", así que se escribe '\&' para poner un ampersand literal.
xml_esc() {
    printf '%s' "$1" | sed \
        -e 's/&/\&amp;/g' \
        -e 's/</\&lt;/g' \
        -e 's/>/\&gt;/g' \
        -e 's/"/\&quot;/g' \
        -e "s/'/\&apos;/g"
}

# Pares <key>/<string> y <key>/<integer> de un plist, ya escapados.
p_str() { printf '\t<key>%s</key>\n\t<string>%s</string>\n' "$(xml_esc "$1")" "$(xml_esc "$2")"; }
p_int() { printf '\t<key>%s</key>\n\t<integer>%s</integer>\n' "$(xml_esc "$1")" "$2"; }
p_env() { printf '\t\t<key>%s</key>\n\t\t<string>%s</string>\n' "$(xml_esc "$1")" "$(xml_esc "$2")"; }

prompt() {  # $1 = texto; $2 = error si no hay terminal
    [ -t 0 ] || err "$2"
    printf '%s' "$1" >&2
    read -r _reply
    printf '%s' "$_reply"
}
prompt_secret() {
    [ -t 0 ] || err "$2"
    printf '%s' "$1" >&2
    stty -echo 2>/dev/null || true
    read -r _reply
    stty echo 2>/dev/null || true
    printf '\n' >&2
    printf '%s' "$_reply"
}

# Duraciones a segundos, mismo criterio que deploy.sh y supervisar-macos.sh.
a_segundos() {
    case "$1" in
        *[!0-9smhin]*) err "$2: '$1' no es una duración válida (300, 5min, 1h)" ;;
    esac
    _n="$(printf '%s' "$1" | tr -cd '0-9')"
    [ -n "$_n" ] || err "$2: falta el número en '$1'"
    case "$1" in
        *h)      printf '%s' "$(( _n * 3600 ))" ;;
        *min|*m) printf '%s' "$(( _n * 60 ))" ;;
        *)       printf '%s' "$_n" ;;
    esac
}

# --memory de deploy.sh habla en unidades de contenedor (2g, 512m); `tart set`
# quiere MEGABYTES a secas. Traducir aquí y no en el plist deja el fallo en el
# despliegue —donde hay alguien mirando— y no a las 3 de la mañana en el primer
# `tart set`, que además se traga el error y sigue con la memoria de la golden.
a_megas() {
    _n="$(printf '%s' "$1" | tr -cd '0-9')"
    [ -n "$_n" ] || err "--memory: falta el número en '$1'"
    case "$1" in
        *[Gg]|*[Gg][Bb]) printf '%s' "$(( _n * 1024 ))" ;;
        *[Mm]|*[Mm][Bb]) printf '%s' "$_n" ;;
        *[0-9])          printf '%s' "$_n" ;;   # sin sufijo: MB, como tart
        *) err "--memory: '$1' no es un tamaño válido (20G, 12g, 8192m, 8192)" ;;
    esac
}

usage() {
    cat >&2 <<'EOF'
Uso: deploy-macos.sh [opciones]

Runners EFÍMEROS de GitHub Actions en un Mac (Apple Silicon), con VMs de Tart.
Misma CLI que deploy.sh (el camino Linux/Windows con contenedores).

Repositorio y credenciales:
  --repo OWNER/REPO      Repositorio objetivo (o usar --owner y --name)
  --owner OWNER          Owner del repo
  --name REPO            Nombre del repo
  --token PAT            Personal Access Token (Administration: Read and write).
                         Si se omite: env ACCESS_TOKEN -> ./.env previo ->
                         `gh auth token` -> prompt.

Despliegue:
  --count N              Runners a crear (por defecto 1). MÁXIMO 2 EN MACOS.
  --prefix P             Prefijo del nombre de runner (por defecto: el nombre
                         del directorio del despliegue)
  --labels L             Etiquetas extra separadas por comas (GitHub ya añade
                         self-hosted, macOS y la arquitectura)
  --group G              Runner group (opcional)
  --image REF            Imagen base OCI de Tart de la que se hornea la golden
                         (por defecto ghcr.io/cirruslabs/macos-sequoia-xcode:16.4)
  --cpus N               CPUs por VM (entero; `tart set --cpu`)
  --memory SIZE          Memoria por VM (20G, 12g, 8192m; `tart set --memory`)
  --cache-dirs A,B       Aceptado por paridad de CLI, HOY SIN EFECTO en macOS
                         (la VM se destruye en cada vuelta y el supervisor solo
                         monta gh-runner y latidos). Ver el aviso al usarlo.

DIMENSIONADO (Mac de 32 GB): lo recomendado es --count 1 --memory 20G. Con
--count 2 las dos VMs y el anfitrión no caben sin swap; usa 2 solo si de verdad
se te encolan jobs, y entonces baja --memory a 12G.

Seguridad:
  --secret               El PAT no queda en ./.env: solo en ./access_token (0600)
  --token-in-env         Fuerza el modo por defecto (PAT en ./.env)

Vigilancia (opt-in):
  --vigilar              Añade el LaunchAgent del vigía: comprueba los runners
                         cada pocos minutos y entrega un informe a tus hooks.
                         Su configuración va en ./vigia, igual que en Linux.
  --vigilar-cada N       Cadencia de la ronda (por defecto 300; acepta 5min, 1h)
  --vigilar-minimo N     Runners sanos por debajo de los cuales el estado pasa
                         de 'parcial' a 'degradado' (por defecto 1)
  --no-host-label        No añadir la etiqueta host:<hostname> a los runners

Ejecución:
  --up                   Carga los LaunchAgents tras generar los ficheros
  --no-up                No los carga (solo genera)
  --skip-validation      No validar el token contra la API antes de escribir
  --force                Sobreescribe ficheros aunque no los generara este script
  --no-bootstrap         No instalar tart ni comprobar el entorno
  -h, --help             Esta ayuda

No aplican en macOS:
  --engine               Aquí el motor es Tart; no hay podman ni docker.

Variables de entorno usadas como fallback:
  ACCESS_TOKEN, REPO_USER, REPO_NAME, RUNNER_PREFIX, RUNNER_COUNT,
  RUNNER_LABELS, RUNNER_GROUP, IMAGE, RUNNER_CPUS, RUNNER_MEMORY,
  SUPERVISAR_GOLDEN (por defecto gh-runner-golden),
  SUPERVISAR_LIMITE_JOB (watchdog por vuelta; por defecto 90min)
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
        --engine)      ENGINE_PREF="${2:-}"; shift 2 ;;
        --cache-dirs)  CACHE_DIRS_CSV="${2:?}"; shift 2 ;;
        --cpus)        CPUS="${2:?}"; shift 2 ;;
        --memory)      MEMORY="${2:?}"; shift 2 ;;
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

# --engine no se ignora en silencio: quien lo pasa cree que puede elegir motor, y
# aceptarlo callando dejaría un despliegue que no hace lo que su comando dice.
if [ -n "$ENGINE_PREF" ]; then
    err "--engine no existe en macOS: aquí el motor es Tart (VMs), no hay podman ni docker en este camino.
       Los runners corren en VMs efímeras clonadas de una golden (hornear-macos.sh).
       Si querías el camino de contenedores, ese es deploy.sh."
fi

# ---- Resolución de campos (flag -> env -> prompt) --------------------------
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

VIGILAR_CADA="$(a_segundos "$VIGILAR_CADA" '--vigilar-cada')"
[ "$VIGILAR_CADA" -ge 60 ] 2>/dev/null || err "--vigilar-cada: mínimo 60 segundos (recibí ${VIGILAR_CADA}s)."
case "$VIGILAR_MINIMO" in ''|*[!0-9]*) err "--vigilar-minimo debe ser un número" ;; esac
LIMITE_JOB_S="$(a_segundos "$LIMITE_JOB" 'SUPERVISAR_LIMITE_JOB')"

# Identidad del cluster: el nombre del directorio del despliegue, saneado. Mismo
# cálculo, letra por letra, que deploy.sh y que supervisar-macos.sh: si difiriera,
# el censo del vigía y el nombre de la VM dejarían de casar y el vigía daría por
# caído a un slot sano.
CLUSTER="$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-')"
CLUSTER="${CLUSTER%-}"
[ -n "$CLUSTER" ] || CLUSTER="gh"

PREFIX="${PREFIX:-${RUNNER_PREFIX:-$CLUSTER}}"
# UN SOLO NOMBRE para el fleet, igual que en deploy.sh: el prefijo ES la
# identidad del cluster.
CLUSTER="$PREFIX"
COUNT="${COUNT:-${RUNNER_COUNT:-1}}"
LABELS="${LABELS:-${RUNNER_LABELS:-}}"
GROUP="${GROUP:-${RUNNER_GROUP:-}}"
IMAGE="${IMAGE:-${ENV_IMAGE:-$IMAGE_DEFAULT}}"
CPUS="${CPUS:-${RUNNER_CPUS:-}}"
MEMORY="${MEMORY:-${RUNNER_MEMORY:-}}"

assert_clean owner "$OWNER"
assert_clean name "$NAME"
assert_clean prefix "$PREFIX"
assert_clean labels "$LABELS"
assert_clean group "$GROUP"
assert_clean image "$IMAGE"
assert_clean cpus "$CPUS"
assert_clean memory "$MEMORY"
assert_clean cache-dirs "$CACHE_DIRS_CSV"
assert_clean golden "$GOLDEN"

# ---- Cuántas VMs: tope duro, no aviso --------------------------------------
# Un aviso se ignora, y el fallo sale de madrugada: la tercera VM no arranca, el
# LaunchAgent la reintenta con KeepAlive y el slot queda en un bucle de fallos
# que nadie mira hasta que falta un runner en la CI del día siguiente.
case "$COUNT" in ''|*[!0-9]*) err "--count debe ser un entero positivo" ;; esac
[ "$COUNT" -ge 1 ] || err "--count debe ser >= 1"
if [ "$COUNT" -gt "$MAX_VMS" ]; then
    err "--count ${COUNT}: en macOS el máximo son ${MAX_VMS} runners por Mac, y no es un límite de este script.
       * EULA de macOS: Apple autoriza como mucho DOS instancias virtualizadas de
         macOS a la vez sobre un Mac con licencia. Un tercer runner es una
         infracción de licencia, no un problema técnico.
       * Virtualization.framework aplica ese mismo tope: la tercera VM no
         arranca, y con KeepAlive el slot se queda reintentando en bucle.
       Si necesitas más capacidad, añade otro Mac con su propio despliegue."
fi
if [ "$COUNT" -eq 2 ]; then
    info "AVISO: --count 2 en un Mac de 32 GB. Dos VMs compilando a la vez dejan"
    info "  ~8 GB al anfitrión y el conjunto entra a swap: los dos jobs tardan más"
    info "  que uno solo. Lo recomendado es --count 1 --memory 20G; con 2, baja"
    info "  --memory a 12G y usa 2 solo si de verdad se te encolan jobs."
fi

# CPUs y memoria en las unidades que entiende `tart set`.
if [ -n "$CPUS" ]; then
    case "$CPUS" in
        ''|*[!0-9]*) err "--cpus en macOS tiene que ser un entero: 'tart set --cpu' no acepta fracciones (recibí '${CPUS}')." ;;
    esac
fi
MEMORIA_MB=""
[ -n "$MEMORY" ] && MEMORIA_MB="$(a_megas "$MEMORY")"

if [ -n "$CACHE_DIRS_CSV" ]; then
    info "AVISO: --cache-dirs se acepta por paridad con deploy.sh, pero HOY NO HACE NADA en macOS."
    info "  La VM se destruye en cada vuelta y el supervisor solo monta gh-runner (ro) y latidos (rw),"
    info "  así que no hay dónde persistir un cache entre jobs. Se anota en ${ENV_FILE} para no perder"
    info "  la intención, y lo que de verdad ahorra tiempo aquí es hornear las dependencias en la golden"
    info "  (hornear-macos.sh --provisionar TU_SCRIPT)."
fi

# ---- Token: --token -> ACCESS_TOKEN -> .env anterior -> gh -> prompt -------
if [ -z "$TOKEN" ]; then
    if [ -n "${ACCESS_TOKEN:-}" ]; then
        TOKEN="$ACCESS_TOKEN"; TOKEN_SRC="env ACCESS_TOKEN"
    elif [ -r "$ENV_FILE" ] && [ "$USE_SECRET" != "yes" ] \
         && head -n1 "$ENV_FILE" 2>/dev/null | grep -Fq "$MARKER_ID" \
         && grep -q '^ACCESS_TOKEN=.' "$ENV_FILE" 2>/dev/null; then
        # Re-ejecutar el comando es el flujo normal (se reajusta algo y se vuelve
        # a lanzar); sin esto habría que teclear el PAT cada vez.
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

# ---- Entorno: esto despliega SOBRE un Mac ----------------------------------
SO="$(uname -s 2>/dev/null || echo unknown)"
if [ "$SO" != "Darwin" ]; then
    # No es un error: generar los ficheros desde otra máquina (o desde el CI) es
    # legítimo y útil. Levantarlos no, porque no hay ni launchd ni Tart.
    info "AVISO: esto genera un despliegue para un HOST macOS y estás en '${SO}'."
    info "  Se escriben los ficheros, pero no se puede levantar nada aquí."
    [ "$DO_UP" = "yes" ] && err "--up necesita un host macOS (aquí no hay launchd ni Tart)."
    DO_UP="no"
    BOOTSTRAP="no"
fi

ensure_tart() {
    command -v tart >/dev/null 2>&1 && return 0
    [ -n "$PM" ] || err "falta 'tart' y no encontré Homebrew. Instálalo con:
       brew install cirruslabs/cli/tart      (o usa --no-bootstrap si lo gestionas tú)"
    info "tart no está instalado; instalando con brew..."
    brew install cirruslabs/cli/tart
    command -v tart >/dev/null 2>&1 || err "la instalación de tart no dejó 'tart' en el PATH."
}
bootstrap_env() {
    command -v brew >/dev/null 2>&1 && PM="brew"
    # Tart exige Apple Silicon y macOS 13+; sin esto el fallo aparece en el
    # primer `tart clone`, dentro de un LaunchAgent, y solo en su log.
    if command -v sw_vers >/dev/null 2>&1; then
        _ver="$(sw_vers -productVersion 2>/dev/null || echo '')"
        case "${_ver%%.*}" in
            ''|*[!0-9]*) : ;;
            *) [ "${_ver%%.*}" -ge 13 ] || err "Tart necesita macOS 13 (Ventura) o superior; este Mac tiene ${_ver}." ;;
        esac
    fi
    case "$(uname -m 2>/dev/null || echo)" in
        arm64) : ;;
        '') : ;;
        *) info "AVISO: Tart solo virtualiza macOS en Apple Silicon; esta máquina dice ser '$(uname -m)'." ;;
    esac
    ensure_tart
}
[ "$BOOTSTRAP" = "yes" ] && bootstrap_env

# ---- Validación del token contra la API (fail-fast) -----------------------
if [ "$SKIP_VALIDATION" != "yes" ]; then
    command -v curl >/dev/null 2>&1 || err "falta 'curl' para validar el token. Instálalo o pasa --skip-validation."
    info "Validando el token contra la API de GitHub..."
    # mktemp CON plantilla: el `mktemp` a secas de BSD (y esto corre en macOS por
    # definición) exige plantilla o -t, y con `set -eu` el script moriría aquí
    # escupiendo el `usage:` de mktemp justo después de "Validando el token", que
    # se lee como un problema del PAT. Ya mordió dos veces en este repo.
    _tmp="$(mktemp "${TMPDIR:-/tmp}/gh-runner-deploy-macos.XXXXXX")"
    # El PAT va por --config (stdin), NO por argv: invisible en `ps`.
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

case "$(printf '%s' "$CLUSTER" | tr '[:upper:]' '[:lower:]')" in
    *"$(printf '%s' "$HOST" | tr '[:upper:]' '[:lower:]')"*)
        info "AVISO: el nombre del cluster ('$CLUSTER') ya contiene la máquina ('$HOST')."
        info "  La máquina se añade sola, así que quedará repetida:"
        info "    runners : ${PREFIX}-${HOST}-1"
        info "    check   : ${CLUSTER}-${HOST}"
        info "  Usa --prefix con el nombre del PROYECTO (p. ej. --prefix sherman)."
        ;;
esac

# La etiqueta de host viaja APARTE de RUNNER_LABELS, igual que en Linux: dentro
# borraría el default de entrypoint-macos.sh (self-hosted,macOS,ARM64) y un
# `runs-on` que casaba dejaría de casar.
HOST_LABEL_VALUE=""
[ "$HOST_LABEL" = "yes" ] && HOST_LABEL_VALUE="host${HOST_LABEL_SEP}${HOST}"

# ---- Rutas del despliegue --------------------------------------------------
# Absolutas: launchd no tiene un "directorio actual" que valga y un plist con
# rutas relativas carga pero no encuentra nada.
DIR="$(pwd)"
MONTAJE_DIR="${DIR}/montaje"
LATIDOS_DIR="${DIR}/latidos"
ESTADO_DIR="${DIR}/estado"
LOG_DIR="${DIR}/log"
DIR_VIGIA="${DIR}/vigia"
AGENTS_DIR="${DIR}/LaunchAgents"
CTL="${DIR}/macos-ctl.sh"

# PATH del LaunchAgent. launchd arranca los servicios con un PATH mínimo que NO
# incluye /opt/homebrew/bin, así que sin esto el supervisor muere en su primera
# línea de verdad ("falta 'tart'") aunque tart esté perfectamente instalado, y el
# único rastro queda en log/runner-N.err.log.
PATH_AGENTE="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# ---- No pisar ficheros ajenos ---------------------------------------------
guard_overwrite "$ENV_FILE"
guard_overwrite "montaje/.env"
guard_overwrite "macos-ctl.sh"
if [ "$USE_SECRET" = "yes" ]; then guard_secret_file "$SECRET_FILE"; fi

umask 077
mkdir -p "$MONTAJE_DIR" "$LATIDOS_DIR" "$ESTADO_DIR" "$LOG_DIR" "$AGENTS_DIR"
i=1
while [ "$i" -le "$COUNT" ]; do
    mkdir -p "${ESTADO_DIR}/runner-${i}"
    i=$((i + 1))
done

# ---- .env del host (lo lee supervisar-macos.sh con --conf) -----------------
# PLATAFORMA=macos no es decorativo: es lo que permite a este script y a deploy.sh
# reconocer de quién es un directorio (ver MARKER_MACOS).
{
    printf '%s — no editar a mano.\n' "$MARKER_MACOS"
    printf '# Runners: %s | repo: %s/%s | base OCI: %s | golden: %s\n' "$COUNT" "$OWNER" "$NAME" "$IMAGE" "$GOLDEN"
    printf 'PLATAFORMA=macos\n'
    [ "$USE_SECRET" = "yes" ] || printf 'ACCESS_TOKEN=%s\n' "$TOKEN"
    printf 'REPO_USER=%s\n' "$OWNER"
    printf 'REPO_NAME=%s\n' "$NAME"
    # El supervisor deduce el cluster de RUNNER_PREFIX cuando no se lo pasan por
    # flag; el plist además le pasa SUPERVISAR_CLUSTER. Que estén los dos es
    # deliberado: si alguien lanza el supervisor a mano desde este directorio,
    # sale con el mismo nombre que bajo launchd.
    printf 'RUNNER_PREFIX=%s\n' "$PREFIX"
    [ -n "$LABELS" ] && printf 'RUNNER_LABELS=%s\n' "$LABELS"
    [ -n "$HOST_LABEL_VALUE" ] && printf 'RUNNER_HOST_LABEL=%s\n' "$HOST_LABEL_VALUE"
    [ -n "$GROUP" ]  && printf 'RUNNER_GROUP=%s\n' "$GROUP"
    [ -n "$CACHE_DIRS_CSV" ] && printf 'CACHE_DIRS=%s\n' "$CACHE_DIRS_CSV"
    :
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"
info "Escrito $ENV_FILE (chmod 600)."

# ---- .env del INVITADO (lo lee entrypoint-macos.sh dentro de la VM) --------
# Va aparte del de arriba y SIN el PAT: el supervisor copia este directorio a
# estado/runner-N/montaje y lo monta en la VM, donde corre código arbitrario de
# CI. El PAT llega por su propio fichero (montaje/access_token, 0600), que es de
# donde ya lo lee entrypoint-macos.sh. RUNNER_NAME lo antepone el supervisor por
# slot, así que aquí NO se escribe (cargar_env respeta la primera aparición).
{
    printf '%s — no editar a mano (lo regenera el despliegue).\n' "$MARKER_MACOS"
    printf 'REPO_USER=%s\n' "$OWNER"
    printf 'REPO_NAME=%s\n' "$NAME"
    [ -n "$LABELS" ] && printf 'RUNNER_LABELS=%s\n' "$LABELS"
    [ -n "$HOST_LABEL_VALUE" ] && printf 'RUNNER_HOST_LABEL=%s\n' "$HOST_LABEL_VALUE"
    [ -n "$GROUP" ]  && printf 'RUNNER_GROUP=%s\n' "$GROUP"
    :
} > "${MONTAJE_DIR}/.env"
chmod 600 "${MONTAJE_DIR}/.env"

# El PAT para el invitado. Existe SIEMPRE (con o sin --secret): dentro de la VM
# no hay file-secrets de compose y el agente tiene que poder pedir su token de
# registro. Con --secret, además, se deja la copia canónica en ./access_token y
# el .env del host se queda sin ACCESS_TOKEN.
printf '%s' "$TOKEN" > "${MONTAJE_DIR}/access_token"
chmod 600 "${MONTAJE_DIR}/access_token"
if [ "$USE_SECRET" = "yes" ]; then
    printf '%s' "$TOKEN" > "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"
    info "Escrito $SECRET_FILE (chmod 600); el PAT no queda en ${ENV_FILE}."
fi

# ---- Piezas del repo -------------------------------------------------------
# Si este script se ejecuta desde un clon, se copian del hermano; si vino por
# curl, se bajan. Mismo helper que deploy.sh.
traer_del_repo() {  # $1 = ruta en el repo, $2 = destino
    if [ -n "${_DIR_SCRIPT:-}" ] && [ -f "${_DIR_SCRIPT}/$1" ]; then
        [ "${_DIR_SCRIPT}/$1" = "$2" ] && return 0
        cp "${_DIR_SCRIPT}/$1" "$2"
        return 0
    fi
    command -v curl >/dev/null 2>&1 || err "necesito 'curl' para bajar $1 (o corre deploy-macos.sh desde un clon del repo)."
    curl -fsSL "${RAW_BASE}/$1" -o "$2" || err "no pude bajar $1 desde ${RAW_BASE}.
       Clona el repo y corre deploy-macos.sh desde ahí: coge los ficheros del clon en vez de bajarlos."
}

# En el HOST: el supervisor (uno por slot) y el horneado de la golden.
for _f in supervisar-macos.sh hornear-macos.sh; do
    traer_del_repo "$_f" "${DIR}/${_f}"
    chmod 755 "${DIR}/${_f}"
done
# En el MONTAJE (solo lectura dentro de la VM): lo que corre el invitado.
for _f in entrypoint-macos.sh mint.sh latido.sh healthcheck.sh; do
    traer_del_repo "$_f" "${MONTAJE_DIR}/${_f}"
    chmod 755 "${MONTAJE_DIR}/${_f}"
done
if [ "$VIGILAR" = "yes" ]; then
    traer_del_repo vigilar.sh "${DIR}/vigilar.sh"
    chmod 755 "${DIR}/vigilar.sh"
fi

# ---- Los LaunchAgents ------------------------------------------------------
# KeepAlive es el `restart: always` del compose y RunAtLoad arranca al cargar.
#
# ExitTimeOut 120 NO es un número redondo cualquiera: es lo que el supervisor
# necesita para su parada elegante —pedirle al invitado que drene el job por ssh
# (90 s de gracia), `tart stop`, `tart delete` y borrar el runner fantasma en la
# API—. Con el default de launchd (20 s) llega el SIGKILL a mitad, y lo que queda
# es exactamente lo que `recoger_huerfanas` tiene que barrer: una VM de decenas
# de GB encendida y un runner offline en Settings que nadie limpia.
LABEL_BASE="com.gh-runner.${CLUSTER}"

plist_runner() {  # $1 = slot
    _f="${AGENTS_DIR}/${LABEL_BASE}.runner-${1}.plist"
    guard_overwrite "$_f"
    {
        printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
        # El marcador va aquí y no antes: un comentario XML no puede preceder a
        # la declaración. guard_overwrite mira las 3 primeras líneas por esto.
        printf '<!-- %s -->\n' "$(xml_esc "${MARKER_MACOS} — no editar a mano")"
        printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
        printf '%s\n' '<plist version="1.0">'
        printf '<dict>\n'
        p_str Label "${LABEL_BASE}.runner-${1}"
        # ProgramArguments: el supervisor y su slot. Todo lo demás viaja por
        # EnvironmentVariables o por el .env, y el PAT por ninguno de los dos.
        # --cpu/--memoria SÍ van aquí porque supervisar-macos.sh solo los lee
        # como flags (no tienen variable de entorno).
        printf '\t<key>ProgramArguments</key>\n\t<array>\n'
        printf '\t\t<string>%s</string>\n' "$(xml_esc "${DIR}/supervisar-macos.sh")"
        printf '\t\t<string>--slot</string>\n\t\t<string>%s</string>\n' "$1"
        [ -n "$CPUS" ]      && printf '\t\t<string>--cpu</string>\n\t\t<string>%s</string>\n' "$CPUS"
        [ -n "$MEMORIA_MB" ] && printf '\t\t<string>--memoria</string>\n\t\t<string>%s</string>\n' "$MEMORIA_MB"
        printf '\t</array>\n'
        printf '\t<key>EnvironmentVariables</key>\n\t<dict>\n'
        p_env PATH "$PATH_AGENTE"
        p_env SUPERVISAR_MONTAJE "$MONTAJE_DIR"
        p_env SUPERVISAR_LATIDOS "$LATIDOS_DIR"
        p_env SUPERVISAR_ESTADO "$ESTADO_DIR"
        p_env SUPERVISAR_CLUSTER "$CLUSTER"
        p_env SUPERVISAR_HOST "$HOST"
        p_env SUPERVISAR_GOLDEN "$GOLDEN"
        p_env SUPERVISAR_LIMITE_JOB "$LIMITE_JOB_S"
        printf '\t</dict>\n'
        # El supervisor lee su configuración de ./.env (su --conf por defecto),
        # así que el directorio de trabajo ES el del despliegue.
        p_str WorkingDirectory "$DIR"
        printf '\t<key>KeepAlive</key>\n\t<true/>\n'
        printf '\t<key>RunAtLoad</key>\n\t<true/>\n'
        p_int ExitTimeOut 120
        # Suelo entre relanzamientos. El backoff de verdad vive en el supervisor
        # (estado/runner-N/.gh_runner_*); esto solo evita que un fallo instantáneo
        # —tart desinstalado, golden borrada— gire a toda velocidad.
        p_int ThrottleInterval 30
        # A propósito NO se pone ProcessType: 'Background' le mete al proceso (y a
        # la VM, que es hija suya) las prioridades de CPU y de E/S rebajadas de
        # macOS, y un job de CI tardaría el doble sin que nada lo explique.
        p_str StandardOutPath "${LOG_DIR}/runner-${1}.log"
        p_str StandardErrorPath "${LOG_DIR}/runner-${1}.err.log"
        printf '</dict>\n</plist>\n'
    } > "$_f"
    chmod 644 "$_f"
}

i=1
while [ "$i" -le "$COUNT" ]; do
    plist_runner "$i"
    i=$((i + 1))
done

# ---- Servicios que sobran de un despliegue anterior ------------------------
# Bajar de 2 runners a 1, o quitar --vigilar, dejaba su plist en LaunchAgents y,
# si estaba cargado, su LaunchAgent SEGUÍA levantando VMs: un runner que ya nadie
# cuenta —no está en el censo del vigía— pero que toma jobs y ocupa disco. Se
# borran solo los nuestros (los del marcador y de este cluster).
for _p in "${AGENTS_DIR}/${LABEL_BASE}."*.plist; do
    [ -f "$_p" ] || continue
    head -n 3 "$_p" 2>/dev/null | grep -Fq "$MARKER_ID" || continue
    _sobra="si"
    _i=1
    while [ "$_i" -le "$COUNT" ]; do
        [ "$_p" = "${AGENTS_DIR}/${LABEL_BASE}.runner-${_i}.plist" ] && _sobra="no"
        _i=$((_i + 1))
    done
    [ "$VIGILAR" = "yes" ] && [ "$_p" = "${AGENTS_DIR}/${LABEL_BASE}.vigia.plist" ] && _sobra="no"
    [ "$_sobra" = "si" ] || continue
    _lab="$(basename "$_p" .plist)"
    info "AVISO: '${_lab}' sobra en este despliegue; borro su plist."
    info "  Si estaba cargado, sigue corriendo hasta que lo pares:"
    info "    launchctl bootout gui/$(id -u)/${_lab}; rm -f ~/Library/LaunchAgents/${_lab}.plist"
    rm -f "$_p"
done

# Censo explícito para el vigía: «no hay latido» solo significa algo si sabes a
# quién esperabas. Estos nombres tienen que ser LOS MISMOS que compone el
# supervisor (VM=<cluster>-<host>-<slot>).
CENSO=""
i=1
while [ "$i" -le "$COUNT" ]; do
    CENSO="$CENSO ${PREFIX}-${HOST}-${i}"
    i=$((i + 1))
done
CENSO="${CENSO# }"

if [ "$VIGILAR" = "yes" ]; then
    mkdir -p "${DIR_VIGIA}/hooks.d"
    chmod 700 "$DIR_VIGIA" "${DIR_VIGIA}/hooks.d" 2>/dev/null || true
    # Misma forma que deja deploy.sh (./vigia/avisos.conf + ./vigia/hooks.d), para
    # que configurar-avisos.sh de los repos consumidores funcione SIN cambios.
    _h="10-healthchecks.sh"
    if [ ! -e "${DIR_VIGIA}/hooks.d/${_h}" ] && [ ! -e "${DIR_VIGIA}/hooks.d/${_h}.ejemplo" ]; then
        traer_del_repo "hooks/${_h}.ejemplo" "${DIR_VIGIA}/hooks.d/${_h}.ejemplo"
    fi

    _f="${AGENTS_DIR}/${LABEL_BASE}.vigia.plist"
    guard_overwrite "$_f"
    {
        printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
        printf '<!-- %s -->\n' "$(xml_esc "${MARKER_MACOS} — no editar a mano")"
        printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
        printf '%s\n' '<plist version="1.0">'
        printf '<dict>\n'
        p_str Label "${LABEL_BASE}.vigia"
        printf '\t<key>ProgramArguments</key>\n\t<array>\n'
        printf '\t\t<string>%s</string>\n' "$(xml_esc "${DIR}/vigilar.sh")"
        printf '\t\t<string>--bucle</string>\n'
        printf '\t</array>\n'
        printf '\t<key>EnvironmentVariables</key>\n\t<dict>\n'
        p_env PATH "$PATH_AGENTE"
        # En Linux el vigía es un contenedor y estas tres rutas son las de dentro
        # de la imagen; aquí corre en el host, así que hay que decírselas.
        p_env VIGIA_LATIDOS "$LATIDOS_DIR"
        p_env VIGIA_HOOKS "${DIR_VIGIA}/hooks.d"
        p_env VIGIA_ESTADO_FILE "${ESTADO_DIR}/vigilar.estado"
        # Los hooks leen su configuración de VIGILAR_CONF; su default apunta a la
        # ruta que tenían montada dentro del contenedor (/etc/gh-runner/vigia),
        # que en el host no existe. Sin esto, los hooks se quedan con los valores
        # de ejemplo y los avisos van a la nada, en silencio.
        p_env VIGILAR_CONF "${DIR_VIGIA}/avisos.conf"
        # El disco que de verdad se llena es el de las VMs de Tart, no el de la
        # raíz: cada clon son decenas de GB.
        p_env VIGIA_DISCO_RUTA "${TART_HOME:-$HOME/.tart}"
        p_env VIGIA_CLUSTER "$CLUSTER"
        # El host se PASA, no se deduce: es la mitad del nombre del check y tiene
        # que salir igual que en el camino Linux.
        p_env VIGIA_HOST "$HOST"
        p_env VIGIA_RUNNERS "$CENSO"
        p_env VIGIA_CADA "$VIGILAR_CADA"
        p_env VIGIA_MINIMO "$VIGILAR_MINIMO"
        printf '\t</dict>\n'
        p_str WorkingDirectory "$DIR"
        printf '\t<key>KeepAlive</key>\n\t<true/>\n'
        printf '\t<key>RunAtLoad</key>\n\t<true/>\n'
        p_int ExitTimeOut 120
        p_int ThrottleInterval 30
        p_str StandardOutPath "${LOG_DIR}/vigia.log"
        p_str StandardErrorPath "${LOG_DIR}/vigia.err.log"
        printf '</dict>\n</plist>\n'
    } > "$_f"
    chmod 644 "$_f"
fi

# ---- macos-ctl.sh: los mismos verbos que `podman compose` ------------------
# deploy.sh cierra enseñando `ps`, `logs -f runner-1`, `down` y `down -v`. Aquí
# esos verbos no existen (launchctl no los tiene), así que se generan: el
# operador que ya conoce el camino Linux no tiene que aprender launchctl para
# mirar un log ni para parar el fleet.
#
# Este fichero NO contiene el PAT: solo rutas y nombres. Se puede leer, copiar y
# pegar en un ticket sin filtrar nada.
guard_overwrite "$CTL"
{
    printf '#!/bin/sh\n'
    printf '%s — no editar a mano (lo reescribe deploy-macos.sh).\n' "$MARKER_MACOS"
    printf '# Control del cluster «%s» en la máquina «%s».\n' "$CLUSTER" "$HOST"
    printf 'set -eu\n\n'
    printf 'DIR="%s"\n' "$DIR"
    printf 'CLUSTER="%s"\n' "$CLUSTER"
    printf 'HOST="%s"\n' "$HOST"
    printf 'COUNT=%s\n' "$COUNT"
    printf 'VIGILAR="%s"\n' "$VIGILAR"
    printf 'GOLDEN="%s"\n' "$GOLDEN"
    printf 'BASE_OCI="%s"\n' "$IMAGE"
    printf 'LABEL_BASE="%s"\n' "$LABEL_BASE"
    # El entorno del vigía se hornea aquí, en vez de releerlo del plist: leerlo
    # obligaría a partir por espacios y VIGIA_RUNNERS es una lista separada por
    # espacios ("cl-mac-1 cl-mac-2"), así que el `informe` se lanzaría con un
    # censo a medias y diría que falta un runner que está perfectamente vivo.
    printf 'VIGIA_LATIDOS="%s"\n' "$LATIDOS_DIR"
    printf 'VIGIA_HOOKS="%s"\n' "${DIR_VIGIA}/hooks.d"
    printf 'VIGIA_ESTADO_FILE="%s"\n' "${ESTADO_DIR}/vigilar.estado"
    printf 'VIGILAR_CONF="%s"\n' "${DIR_VIGIA}/avisos.conf"
    printf 'VIGIA_DISCO_RUTA="%s"\n' "${TART_HOME:-$HOME/.tart}"
    printf 'VIGIA_RUNNERS="%s"\n' "$CENSO"
    printf 'VIGIA_CADA="%s"\n' "$VIGILAR_CADA"
    printf 'VIGIA_MINIMO="%s"\n' "$VIGILAR_MINIMO"
    cat <<'CTL_FIN'
AGENTS="${DIR}/LaunchAgents"
DESTINO="${HOME}/Library/LaunchAgents"
DOMINIO="gui/$(id -u)"

err()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*" >&2; }

# Aplica $1 (una función) a cada servicio del despliegue: runners y luego el
# vigía. Es un bucle en ESTE shell y no `etiquetas | while read`, porque una
# tubería corre en una subshell: allí un `err` mataría la subshell, el bucle
# seguiría y `up` acabaría diciendo que todo fue bien tras no cargar nada.
por_cada_servicio() {
    i=1
    while [ "$i" -le "$COUNT" ]; do
        "$1" "${LABEL_BASE}.runner-${i}"
        i=$((i + 1))
    done
    if [ "$VIGILAR" = "yes" ]; then "$1" "${LABEL_BASE}.vigia"; fi
    return 0
}

uso() {
    cat >&2 <<'USO'
Uso: ./macos-ctl.sh <verbo>

  ps               Estado de cada servicio y VMs vivas en Tart
  logs [servicio]  Sigue el log (runner-1, runner-2, vigia; por defecto runner-1)
  up               Carga los LaunchAgents (equivale a `compose up -d`)
  down             Los descarga y para el fleet (equivale a `compose down`)
  down -v          + borra ./estado, los caches y los latidos
  refresh          Rehornea la golden (hornear-macos.sh --completo)
  informe          Ronda del vigía ahora mismo, por pantalla
USO
    exit "${1:-0}"
}

# Las VMs efímeras de ESTE cluster, por nombre. `index()` de awk y no un `grep`
# con `^`: el prefijo es libre y un '.' o un '*' dentro se leerían como comodín.
vms_del_cluster() {
    tart list 2>/dev/null | awk -v p="${CLUSTER}-${HOST}-" 'NR>1 && index($2, p) == 1 { print $2 }'
}

estado_de() {
    if _salida="$(launchctl print "${DOMINIO}/${1}" 2>/dev/null)"; then
        printf '%-46s %s\n' "$1" \
            "$(printf '%s\n' "$_salida" | awk -F' = ' '/^[[:space:]]*(state|pid) = /{ printf "%s ", $2 }')"
    else
        printf '%-46s no cargado\n' "$1"
    fi
}

# El enlace en ~/Library/LaunchAgents es lo que hace que el fleet vuelva solo
# tras reiniciar el Mac; un `launchctl bootstrap` a secas se pierde con la
# sesión. ENLACE y no copia, para que un re-despliegue no deje dos versiones del
# plist divergiendo en silencio.
#
# Dominio `gui/<uid>` y no `system`: Virtualization.framework necesita la sesión
# del usuario, y un demonio de sistema no puede arrancar una VM de macOS.
cargar() {
    ln -sf "${AGENTS}/${1}.plist" "${DESTINO}/${1}.plist"
    launchctl bootout "${DOMINIO}/${1}" 2>/dev/null || true
    launchctl bootstrap "$DOMINIO" "${DESTINO}/${1}.plist" \
        || err "no pude cargar '${1}'. Mira ${DIR}/log/ y comprueba el plist con: plutil -lint ${AGENTS}/${1}.plist"
    launchctl kickstart "${DOMINIO}/${1}" >/dev/null 2>&1 || true
    info "cargado: ${1}"
}

descargar() {
    launchctl bootout "${DOMINIO}/${1}" 2>/dev/null || true
    rm -f "${DESTINO}/${1}.plist"
    info "parado: ${1}"
}

verbo="${1:-}"
[ -n "$verbo" ] || uso 1
shift 2>/dev/null || true

case "$verbo" in
    ps)
        por_cada_servicio estado_de
        printf '\nVMs de Tart:\n'
        tart list 2>/dev/null || info "(tart no responde)"
        ;;

    logs)
        cual="${1:-runner-1}"
        f="${DIR}/log/${cual}.log"
        [ -f "$f" ] || err "no existe '${f}' (¿ya arrancó ese servicio?). Prueba: runner-1 … runner-${COUNT}, vigia"
        # Los dos ficheros: launchd separa stdout de stderr y el supervisor manda
        # sus avisos por stderr, así que mirar solo uno engaña.
        tail -f "$f" "${DIR}/log/${cual}.err.log"
        ;;

    up)
        mkdir -p "$DESTINO"
        por_cada_servicio cargar
        ;;

    down)
        borrar="no"
        case "${1:-}" in -v|--volumes) borrar="yes" ;; esac
        por_cada_servicio descargar
        # Las VMs se borran SIEMPRE al bajar, no solo con -v: son decenas de GB
        # cada una y, si se quedan, la vuelta siguiente ni siquiera puede clonar
        # (`tart clone` falla por nombre duplicado).
        vms_del_cluster | while IFS= read -r vm; do
            [ -n "$vm" ] || continue
            info "borrando la VM efímera '${vm}'..."
            tart delete "$vm" >/dev/null 2>&1 || info "AVISO: no pude borrar '${vm}'; hazlo a mano con 'tart delete ${vm}'."
        done
        if [ "$borrar" = "yes" ]; then
            rm -rf "${DIR}/estado" "${DIR}/cache"
            rm -f "${DIR}"/latidos/* 2>/dev/null || true
            info "borrados ./estado, ./cache y los latidos."
            info "La golden '${GOLDEN}' NO se toca: rehacerla son 60-80 GB y un buen rato ('refresh')."
        fi
        ;;

    refresh)
        [ -x "${DIR}/hornear-macos.sh" ] || err "falta ${DIR}/hornear-macos.sh"
        exec "${DIR}/hornear-macos.sh" --completo --base "$BASE_OCI" --golden "$GOLDEN" "$@"
        ;;

    informe)
        [ -x "${DIR}/vigilar.sh" ] || err "el vigía no está desplegado aquí (relanza deploy-macos.sh con --vigilar)."
        VIGIA_CLUSTER="$CLUSTER" VIGIA_HOST="$HOST" \
        VIGIA_LATIDOS="$VIGIA_LATIDOS" VIGIA_HOOKS="$VIGIA_HOOKS" \
        VIGIA_ESTADO_FILE="$VIGIA_ESTADO_FILE" VIGILAR_CONF="$VIGILAR_CONF" \
        VIGIA_DISCO_RUTA="$VIGIA_DISCO_RUTA" VIGIA_RUNNERS="$VIGIA_RUNNERS" \
        VIGIA_CADA="$VIGIA_CADA" VIGIA_MINIMO="$VIGIA_MINIMO" \
            "${DIR}/vigilar.sh" --informe
        ;;

    -h|--help|help) uso 0 ;;
    *) err "verbo desconocido: ${verbo} (usa --help)" ;;
esac
CTL_FIN
} > "$CTL"
chmod 755 "$CTL"

# ---- Resumen ---------------------------------------------------------------
info ""
info "Resumen:"
info "  Repo    : ${OWNER}/${NAME}"
info "  Runners : ${COUNT} (nombres: ${PREFIX}-${HOST}-1..${COUNT})"
info "  Base OCI: ${IMAGE}"
info "  Golden  : ${GOLDEN}"
info "  Token   : ${TOKEN_SRC:-desconocido}"
if [ "$USE_SECRET" = "yes" ]; then
    info "  PAT     : ./${SECRET_FILE} y ./montaje/access_token (0600 los dos)"
else
    info "  PAT     : ${ENV_FILE} y ./montaje/access_token (0600 los dos)"
fi
[ -n "$CPUS$MEMORIA_MB" ] && info "  Por VM  : cpus=${CPUS:-—} memoria=${MEMORIA_MB:-—}${MEMORIA_MB:+ MB}"
_labels_efectivas="$LABELS"
if [ -n "$HOST_LABEL_VALUE" ]; then
    [ -n "$_labels_efectivas" ] && _labels_efectivas="${_labels_efectivas},"
    _labels_efectivas="${_labels_efectivas}${HOST_LABEL_VALUE}"
fi
[ -n "$_labels_efectivas" ] && info "  Etiquetas: ${_labels_efectivas}"
if [ "$VIGILAR" = "yes" ]; then
    info "  Vigía   : LaunchAgent '${LABEL_BASE}.vigia', ronda cada $(( VIGILAR_CADA / 60 )) min · config en ./vigia"
    info "  Configura los avisos : ${DIR_VIGIA}/avisos.conf"
    info "  Hooks de ejemplo en  : ${DIR_VIGIA}/hooks.d (cópialos sin '.ejemplo' para activarlos)"
else
    info "  Vigía   : no (--vigilar lo instala: avisa si un runner se atasca o se cae)"
fi
info ""
info "DIMENSIONADO (Mac de 32 GB): lo recomendado es --count 1 --memory 20G."
info "  Dos VMs compilando a la vez dejan ~8 GB al anfitrión, el conjunto entra a"
info "  swap y los dos jobs tardan más que uno solo. Usa --count 2 solo si de"
info "  verdad se te encolan jobs, y entonces con --memory 12G."

# ---- Antes de poder levantar: golden y agente ------------------------------
_falta="no"
if command -v tart >/dev/null 2>&1; then
    if ! tart list 2>/dev/null | awk -v n="$GOLDEN" 'NR>1 && $2==n {f=1} END{exit !f}'; then
        _falta="yes"
        info ""
        info "FALTA LA GOLDEN '${GOLDEN}': sin ella no hay de qué clonar. Hornéala (tarda, y ocupa 60-80 GB):"
        info "  ./hornear-macos.sh --completo --base ${IMAGE} --golden ${GOLDEN}"
    fi
fi
if ! ls "${MONTAJE_DIR}"/actions-runner-osx-arm64-*.tar.gz >/dev/null 2>&1; then
    _falta="yes"
    info ""
    info "FALTA EL AGENTE en ./montaje: el invitado no tiene qué desempaquetar. Bájalo (~300 MB):"
    info "  HORNEAR_RUNNER_DIR=${MONTAJE_DIR} ./hornear-macos.sh --runner"
    info "  (repítelo a diario: GitHub sube la versión mínima del agente a menudo)"
fi

# ---- Levantar --------------------------------------------------------------
if [ "$DO_UP" = "auto" ]; then
    if [ -t 0 ] && [ "$_falta" = "no" ]; then DO_UP="yes"; else DO_UP="no"; fi
fi

if [ "$DO_UP" = "yes" ]; then
    info ""
    info "Levantando: ./macos-ctl.sh up"
    "$CTL" up
else
    info ""
    info "Para levantar los runners:"
    info "  ./macos-ctl.sh up"
fi

info ""
info "Comandos útiles (desde este directorio):"
info "  ./macos-ctl.sh ps            # estado"
info "  ./macos-ctl.sh logs runner-1 # logs de un runner"
info "  ./macos-ctl.sh down          # parar y desregistrar"
info "  ./macos-ctl.sh down -v       # + borrar estado, caches y VMs huérfanas"
info "  ./macos-ctl.sh refresh       # rehornear la golden"
info "  ./macos-ctl.sh informe       # ronda del vigía ahora mismo"
