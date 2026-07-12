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
# ./gh-runner.compose.yaml.
# ============================================================================
set -eu

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
COMPOSE_FILE="gh-runner.compose.yaml"
ENV_FILE=".env"
CACHE_DIRS_CSV=""
PULL_ALWAYS="no"
DO_UP="auto"        # auto|yes|no
SKIP_VALIDATION="no"

# ---- Utilidades ------------------------------------------------------------
err()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*" >&2; }

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
  --cache-dirs A,B       Dirs extra de cache por runner (p.ej. .npm,.cargo);
                         relativas a /home/runner o absolutas
  --pull-always          Añade pull_policy: always al compose
  --file PATH            Ruta del compose a generar (por defecto gh-runner.compose.yaml)

Ejecución:
  --up                   Levanta el stack tras generar el compose
  --no-up                No lo levanta (solo genera los ficheros)
  --skip-validation      No validar el token contra la API antes de escribir
  -h, --help             Esta ayuda

Variables de entorno usadas como fallback:
  ACCESS_TOKEN, REPO_USER, REPO_NAME, RUNNER_PREFIX, RUNNER_COUNT,
  RUNNER_LABELS, RUNNER_GROUP, IMAGE
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
        --cache-dirs)  CACHE_DIRS_CSV="${2:?}"; shift 2 ;;
        --pull-always) PULL_ALWAYS="yes"; shift ;;
        --file)        COMPOSE_FILE="${2:?}"; shift 2 ;;
        --up)          DO_UP="yes"; shift ;;
        --no-up)       DO_UP="no"; shift ;;
        --skip-validation) SKIP_VALIDATION="yes"; shift ;;
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

# ---- Detección de motor y compose -----------------------------------------
if command -v podman >/dev/null 2>&1; then
    ENGINE="podman"
elif command -v docker >/dev/null 2>&1; then
    ENGINE="docker"
else
    err "no se encontró 'podman' ni 'docker' en el PATH"
fi

if [ "$ENGINE" = "podman" ]; then
    if podman compose version >/dev/null 2>&1; then
        COMPOSE="podman compose"
    elif command -v podman-compose >/dev/null 2>&1; then
        COMPOSE="podman-compose"
    else
        err "falta un proveedor de compose para podman ('podman compose' o 'podman-compose')"
    fi
else
    if docker compose version >/dev/null 2>&1; then
        COMPOSE="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE="docker-compose"
    else
        err "falta un proveedor de compose para docker ('docker compose' o 'docker-compose')"
    fi
fi

# ---- Validación del token contra la API (fail-fast) -----------------------
if [ "$SKIP_VALIDATION" != "yes" ] && command -v curl >/dev/null 2>&1; then
    info "Validando el token contra la API de GitHub..."
    _tmp="$(mktemp)"
    _http="$(curl -sSL -o "$_tmp" -w '%{http_code}' \
        -X POST \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${TOKEN}" \
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

# ---- Escribir .env (config compartida; el PAT vive solo aquí) --------------
umask 077
{
    printf 'ACCESS_TOKEN=%s\n' "$TOKEN"
    printf 'REPO_USER=%s\n' "$OWNER"
    printf 'REPO_NAME=%s\n' "$NAME"
    [ -n "$LABELS" ] && printf 'RUNNER_LABELS=%s\n' "$LABELS"
    [ -n "$GROUP" ]  && printf 'RUNNER_GROUP=%s\n' "$GROUP"
    :
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"
info "Escrito $ENV_FILE (chmod 600) con ACCESS_TOKEN, REPO_USER, REPO_NAME."

# ---- Generar el compose ----------------------------------------------------
# Helpers para dirs de cache extra.
norm_dir()   { case "$1" in /*) printf '%s' "$1" ;; *) printf '/home/runner/%s' "$1" ;; esac; }
vol_suffix() { printf '%s' "$1" | tr -cd 'A-Za-z0-9'; }

{
    printf '# GENERADO por deploy.sh — no editar a mano.\n'
    printf '# Runners: %s | repo: %s/%s | imagen: %s\n\n' "$COUNT" "$OWNER" "$NAME" "$IMAGE"
    printf 'x-runner-common: &runner-common\n'
    printf '  image: %s\n' "$IMAGE"
    printf '  restart: always\n'
    [ "$PULL_ALWAYS" = "yes" ] && printf '  pull_policy: always\n'
    printf '  env_file: [%s]\n' "$ENV_FILE"
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
} > "$COMPOSE_FILE"
info "Escrito $COMPOSE_FILE con $COUNT runner(s)."

# ---- Resumen ---------------------------------------------------------------
info ""
info "Resumen:"
info "  Repo    : ${OWNER}/${NAME}"
info "  Runners : ${COUNT} (nombres: ${PREFIX}-${HOST}-1..${COUNT})"
info "  Imagen  : ${IMAGE}"
info "  Token   : ${TOKEN_SRC:-desconocido}"
info "  Motor   : ${ENGINE} (${COMPOSE})"

# ---- Levantar el stack -----------------------------------------------------
if [ "$DO_UP" = "auto" ]; then
    if [ -t 0 ]; then DO_UP="yes"; else DO_UP="no"; fi
fi

UP_CMD="$COMPOSE -f $COMPOSE_FILE up -d"
if [ "$DO_UP" = "yes" ]; then
    info ""
    info "Levantando: $UP_CMD"
    # shellcheck disable=SC2086
    $COMPOSE -f "$COMPOSE_FILE" up -d
    info ""
    info "Listo. Comprueba con: $ENGINE ps"
else
    info ""
    info "Para levantar los runners:"
    info "  $UP_CMD"
fi

info ""
info "Teardown:"
info "  $COMPOSE -f $COMPOSE_FILE down       # para y desregistra"
info "  $COMPOSE -f $COMPOSE_FILE down -v    # + borra el cache (volúmenes)"
