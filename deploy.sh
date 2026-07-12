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
COMPOSE_FILE="compose.yaml"   # nombre autodetectado -> permite usar `podman compose` sin -f
ENV_FILE=".env"
CACHE_DIRS_CSV=""
PULL_ALWAYS="no"
DO_UP="auto"        # auto|yes|no
SKIP_VALIDATION="no"
FORCE="no"          # sobreescribir compose.yaml/.env ajenos
CPUS=""             # límite de CPU por runner
MEMORY=""           # límite de memoria por runner
USE_SECRET="no"     # --secret: PAT como file-secret en vez de en .env
SECRET_FILE="access_token"

# ---- Utilidades ------------------------------------------------------------
err()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*" >&2; }

MARKER="# GENERADO por deploy.sh"

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
  --cpus N               Límite de CPU por runner (p.ej. 2 o 1.5)
  --memory SIZE          Límite de memoria por runner (p.ej. 2g, 512m)
  --pull-always          Añade pull_policy: always al compose
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
        --cache-dirs)  CACHE_DIRS_CSV="${2:?}"; shift 2 ;;
        --cpus)        CPUS="${2:?}"; shift 2 ;;
        --memory)      MEMORY="${2:?}"; shift 2 ;;
        --pull-always) PULL_ALWAYS="yes"; shift ;;
        --file)        COMPOSE_FILE="${2:?}"; shift 2 ;;
        --secret)      USE_SECRET="yes"; shift ;;
        --token-in-env) USE_SECRET="no"; shift ;;
        --up)          DO_UP="yes"; shift ;;
        --no-up)       DO_UP="no"; shift ;;
        --skip-validation) SKIP_VALIDATION="yes"; shift ;;
        --force)       FORCE="yes"; shift ;;
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

{
    printf '# GENERADO por deploy.sh — no editar a mano.\n'
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
    if [ "$USE_SECRET" = "yes" ]; then
        printf '\nsecrets:\n'
        printf '  access_token:\n'
        printf '    file: ./%s\n' "$SECRET_FILE"
    fi
} > "$COMPOSE_FILE"
info "Escrito $COMPOSE_FILE con $COUNT runner(s)."

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
