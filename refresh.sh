#!/bin/sh
# ============================================================================
# refresh.sh — re-baja la imagen :latest y RECREA los runners.
#
# Por qué: los runners no se auto-actualizan (--disableupdate) y un `restart`
# (el ciclo efímero) NO hace `pull`; solo un recreate (`up -d`) adopta la imagen
# nueva. GitHub exige que el runner esté dentro de los ~30 días de la última
# versión (y el mínimo de ejecución avanza con el tiempo), así que hay que
# recrear periódicamente o el runner acabará rechazado.
#
# Corre esto de forma periódica (systemd timer / cron / launchd / Task
# Scheduler — ver README) EN EL DIRECTORIO del despliegue (donde está
# compose.yaml). Sin argumentos; `--file RUTA` para otro compose y
# `--compose-extra FILE` para el override (autodetecta ./compose.override.yaml).
# ============================================================================
set -eu

# En Git Bash / MSYS2 (Windows): no convertir rutas al invocar docker.exe/podman.exe.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

COMPOSE_FILE="compose.yaml"
COMPOSE_EXTRA=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --file)          COMPOSE_FILE="${2:?falta la ruta tras --file}"; shift 2 ;;
        --compose-extra) COMPOSE_EXTRA="${2:?falta la ruta tras --compose-extra}"; shift 2 ;;
        *) err "opción desconocida: $1 (usa --file RUTA / --compose-extra FILE)" ;;
    esac
done

[ -f "$COMPOSE_FILE" ] || err "no encuentro '$COMPOSE_FILE' en $(pwd).
       Corre refresh.sh en el directorio del despliegue, o pasa --file RUTA."

# Detección de motor + proveedor de compose (misma lógica que deploy.sh).
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

COMPOSE=""
for _eng in podman docker; do
    command -v "$_eng" >/dev/null 2>&1 || continue
    _c="$(compose_for "$_eng")"
    if [ -n "$_c" ]; then COMPOSE="$_c"; break; fi
done
[ -n "$COMPOSE" ] || err "no encontré un motor con proveedor de compose (podman/docker). Ver README."

# Override del proyecto: --compose-extra FILE, o autodetecta ./compose.override.yaml.
# Debe encadenarse igual que en deploy.sh; si no, el recreate perdería los
# sidecars/mounts/redes que define el override.
if [ -z "$COMPOSE_EXTRA" ] && [ -f "compose.override.yaml" ]; then
    COMPOSE_EXTRA="compose.override.yaml"
fi
[ -z "$COMPOSE_EXTRA" ] || [ -f "$COMPOSE_EXTRA" ] || err "--compose-extra: no encuentro '$COMPOSE_EXTRA'"

# Con el nombre autodetectado no hace falta -f... salvo que haya override: pasar
# cualquier -f desactiva el autoload del base, así que se encadenan AMBOS.
if [ -n "$COMPOSE_EXTRA" ]; then
    FILE_ARG="-f $COMPOSE_FILE -f $COMPOSE_EXTRA"
else
    case "$COMPOSE_FILE" in
        compose.yaml|compose.yml|docker-compose.yaml|docker-compose.yml) FILE_ARG="" ;;
        *) FILE_ARG="-f $COMPOSE_FILE" ;;
    esac
fi

printf 'Refrescando imagen y recreando runners (%s)...\n' "$COMPOSE" >&2
# shellcheck disable=SC2086
$COMPOSE $FILE_ARG pull
# shellcheck disable=SC2086
$COMPOSE $FILE_ARG up -d
printf 'Listo. Comprueba con: %s ps\n' "$COMPOSE" >&2
