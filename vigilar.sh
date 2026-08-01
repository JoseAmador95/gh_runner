#!/bin/sh
# ============================================================================
# vigilar.sh — mira los runners de ESTA máquina y entrega un informe a los hooks.
#
# Corre EN EL HOST (timer de systemd / cron / launchd), como el usuario dueño de
# los contenedores, en el DIRECTORIO del despliegue (donde está compose.yaml),
# igual que refresh.sh. Al correr como ese usuario habla con podman directamente:
# no hay socket que montar ni contenedor extra que mantener.
#
# Qué mira, en una ronda:
#   1. Contenedores ausentes o parados  (los que restart:always no resucitó)
#   2. Contenedores `unhealthy`         (el runner atascado; ver healthcheck.sh)
#   3. Desfase del reloj contra GitHub  (la causa raíz del incidente del 1-ago)
#
# Qué NO hace: reparar. Diagnostica y avisa; decidir es de quien lee.
#
# CÓMO AVISA: no lo decide este script. Ejecuta todo lo que sea ejecutable en el
# directorio de hooks (convención run-parts, la de cron.d y los hooks de git) y
# les pasa el INFORME COMPLETO por stdin más unas variables de entorno. Así este
# script NO maneja ni un secreto —ni tokens ni URLs de ping—: cada hook guarda
# el suyo. Eso importa porque el .env de los runners se inyecta en contenedores
# que ejecutan código arbitrario de CI: cualquier job puede leer su entorno.
#
# Uso:
#   ./vigilar.sh                 # ronda normal: mira y dispara los hooks
#   ./vigilar.sh --informe       # solo imprime el informe (no toca hooks ni estado)
# ============================================================================
set -eu

# Git Bash / MSYS2 (Windows): no convertir rutas al invocar podman.exe/docker.exe.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

err()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*" >&2; }

# ---- Configuración ---------------------------------------------------------
COMPOSE_FILE="compose.yaml"
HOOKS_DIR="${VIGILAR_HOOKS:-${XDG_CONFIG_HOME:-$HOME/.config}/gh-runner/hooks.d}"
ESTADO_FILE="${VIGILAR_ESTADO_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/gh-runner/vigilar.estado}"
# Umbral de desfase de reloj (segundos) que ya cuenta como degradado. El token de
# registro vive ~10 min, así que un desfase de minutos rompe el runner; 60 s está
# muy por encima de lo que deja cualquier NTP sano, así que no da falsos avisos.
DESFASE_MAX="${VIGILAR_DESFASE_MAX:-60}"
PROYECTO="${COMPOSE_PROJECT_NAME:-}"
SOLO_INFORME="no"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --file)         COMPOSE_FILE="${2:?falta la ruta tras --file}"; shift 2 ;;
        --hooks)        HOOKS_DIR="${2:?falta la ruta tras --hooks}"; shift 2 ;;
        --estado)       ESTADO_FILE="${2:?falta la ruta tras --estado}"; shift 2 ;;
        --desfase-max)  DESFASE_MAX="${2:?falta el valor tras --desfase-max}"; shift 2 ;;
        --proyecto)     PROYECTO="${2:?falta el nombre tras --proyecto}"; shift 2 ;;
        --informe)      SOLO_INFORME="yes"; shift ;;
        -h|--help)
            sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//' >&2
            exit 0 ;;
        *) err "opción desconocida: $1 (usa --help)" ;;
    esac
done

[ -f "$COMPOSE_FILE" ] || err "no encuentro '$COMPOSE_FILE' en $(pwd).
       Corre vigilar.sh en el directorio del despliegue, o pasa --file RUTA."

# ---- Motor de contenedores (misma preferencia que deploy.sh/refresh.sh) ----
ENGINE=""
for _eng in podman docker; do
    if command -v "$_eng" >/dev/null 2>&1; then ENGINE="$_eng"; break; fi
done
[ -n "$ENGINE" ] || err "no encontré 'podman' ni 'docker' en el PATH."

# ¿Además de existir, RESPONDE? No es lo mismo: el binario puede estar instalado
# con el servicio parado (una `podman machine` que no arrancó al iniciar sesión
# en macOS, el daemon de Docker caído). Sin esta comprobación, cada consulta
# devolvería vacío y el informe diría que TODOS los runners desaparecieron —
# diagnóstico equivocado, porque lo que hay que arrancar es el motor, no los
# runners. Y un vigía que da falsas alarmas se acaba silenciando.
MOTOR_VIVO="si"
"$ENGINE" ps -q >/dev/null 2>&1 || MOTOR_VIVO="no"

# Nombre de proyecto de compose: por defecto el del directorio, saneado igual
# que lo hacen docker compose / podman-compose (minúsculas, solo [a-z0-9_-]).
if [ -z "$PROYECTO" ]; then
    PROYECTO="$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
fi

# ---- Servicios declarados y su RUNNER_NAME ---------------------------------
# El nombre que importa en el informe es el que ve GitHub (RUNNER_NAME), no el
# del servicio: es el que aparece en Settings -> Runners y el que reconoce quien
# lee el aviso. deploy.sh lo escribe explícitamente en el compose.
SERVICIOS="$(awk '
    function volcar() {
        if (svc != "") { print svc "\t" (nombre != "" ? nombre : svc); svc = ""; nombre = "" }
    }
    /^services:[[:space:]]*$/            { volcar(); en = 1; next }
    /^[A-Za-z]/ && !/^services:/         { volcar(); en = 0 }
    en && /^  [^ #][^:]*:[[:space:]]*$/  { volcar(); svc = $1; sub(/:$/, "", svc); next }
    svc != "" && /RUNNER_NAME:/ {
        nombre = $0
        sub(/^.*RUNNER_NAME:[[:space:]]*/, "", nombre)
        gsub(/"/, "", nombre)
        sub(/[[:space:]]+$/, "", nombre)
    }
    END { volcar() }
' "$COMPOSE_FILE")"

[ -n "$SERVICIOS" ] || err "no encontré servicios en '$COMPOSE_FILE'. ¿Lo generó deploy.sh?"

ESPERADOS="$(printf '%s\n' "$SERVICIOS" | wc -l | tr -dc '0-9')"

# ---- Localizar el contenedor de un servicio --------------------------------
# Tres intentos, de más preciso a más tolerante. El primero incluye el proyecto
# para no confundirse con OTRO despliegue de la misma máquina que también tenga
# un servicio llamado runner-1.
contenedor_de() {
    _svc="$1"; _c=""
    for _ns in com.docker.compose io.podman.compose; do
        _c="$("$ENGINE" ps -a \
                --filter "label=${_ns}.project=${PROYECTO}" \
                --filter "label=${_ns}.service=${_svc}" \
                --format '{{.Names}}' 2>/dev/null | head -n1)"
        [ -n "$_c" ] && { printf '%s' "$_c"; return 0; }
    done
    for _ns in com.docker.compose io.podman.compose; do
        _c="$("$ENGINE" ps -a --filter "label=${_ns}.service=${_svc}" \
                --format '{{.Names}}' 2>/dev/null | head -n1)"
        [ -n "$_c" ] && { printf '%s' "$_c"; return 0; }
    done
    # Sin etiquetas de compose: por nombre (proyecto_servicio_1, proyecto-servicio…).
    "$ENGINE" ps -a --format '{{.Names}}' 2>/dev/null \
        | grep -E "(^|[_-])${_svc}([_-][0-9]+)?\$" | head -n1
}

# ---- Desfase del reloj contra GitHub ---------------------------------------
# Es la causa raíz del incidente que motivó todo esto: con el host atrasado, el
# runner renueva su credencial tarde SIEMPRE y GitHub la rechaza. Cuesta una
# llamada y sale en el informe pase lo que pase.
a_epoch() {
    date -u -d "$1" +%s 2>/dev/null && return 0                                   # GNU
    date -j -u -f '%a, %d %b %Y %H:%M:%S %Z' "$1" +%s 2>/dev/null && return 0     # BSD/macOS
    return 1
}

DESFASE=""      # vacío = no medido
if command -v curl >/dev/null 2>&1; then
    # GET con el cuerpo tirado (-o /dev/null -D -), no HEAD: algunos proxies
    # corporativos responden 400 a HEAD o le quitan las cabeceras. El cuerpo de
    # la raíz de la API son bytes contados, así que no se gana nada con HEAD.
    _fecha_gh="$(curl -sS -o /dev/null -D - -m 10 https://api.github.com 2>/dev/null \
        | grep -i '^date:' | head -n1 | sed 's/^[Dd][Aa][Tt][Ee]:[[:space:]]*//' | tr -d '\r')"
    if [ -n "$_fecha_gh" ] && _epoch_gh="$(a_epoch "$_fecha_gh")"; then
        DESFASE=$(( $(date -u +%s) - _epoch_gh ))
    fi
fi

# ---- Recorrer los servicios ------------------------------------------------
DEGRADADOS=""   # líneas ya formateadas
SANOS=""
CAIDOS=""       # nombres, separados por espacio (va a los hooks)
HUELLA=""       # firma canónica del estado, para detectar cambios entre rondas
ONLINE=0

# El ancho de la columna de nombres se calcula del contenido: con nombres largos
# una anchura fija parte la tabla, y la tabla alineada es medio valor del aviso.
ANCHO="$(printf '%s\n' "$SERVICIOS" | cut -f2 \
    | awk '{ if (length($0) > m) m = length($0) } END { print (m < 12 ? 12 : m) + 2 }')"

# `IFS=$(printf '\t')` y no una tubería: el bucle debe correr en ESTE shell o
# las variables acumuladas se perderían con el subshell.
# Con el motor muerto no se recorre nada: cada servicio dispararía tres consultas
# que fallan (y con un socket roto, fallar puede tardar), para un resultado que
# de todas formas se descarta más abajo.
_A_RECORRER="$SERVICIOS"
[ "$MOTOR_VIVO" = "no" ] && _A_RECORRER=""

OLDIFS="$IFS"
IFS='
'
for _linea in $_A_RECORRER; do
    IFS="$OLDIFS"
    _svc="${_linea%%	*}"
    _nombre="${_linea#*	}"

    _cont="$(contenedor_de "$_svc" || true)"

    if [ -z "$_cont" ]; then
        DEGRADADOS="${DEGRADADOS}$(printf '  %-*s %-10s %s' "$ANCHO" "$_nombre" "ausente" "no hay contenedor")
"
        CAIDOS="$CAIDOS $_nombre"
        HUELLA="$HUELLA$_nombre=ausente;"
        IFS='
'
        continue
    fi

    # Un solo inspect por contenedor: estado del contenedor y de su healthcheck.
    _insp="$("$ENGINE" inspect --format \
        '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' \
        "$_cont" 2>/dev/null || printf 'desconocido|-')"
    _estado="${_insp%%|*}"
    _salud="${_insp##*|}"

    if [ "$_estado" != "running" ]; then
        DEGRADADOS="${DEGRADADOS}$(printf '  %-*s %-10s %s' "$ANCHO" "$_nombre" "parado" "el contenedor está $_estado")
"
        CAIDOS="$CAIDOS $_nombre"
        HUELLA="$HUELLA$_nombre=$_estado;"
    elif [ "$_salud" = "unhealthy" ]; then
        # El motivo lo escribió healthcheck.sh dentro del contenedor; se recoge
        # la ÚLTIMA entrada del log de salud (con --retries hay varias).
        _motivo="$("$ENGINE" inspect --format \
            '{{if .State.Health}}{{range .State.Health.Log}}{{.Output}}
{{end}}{{end}}' "$_cont" 2>/dev/null | sed '/^[[:space:]]*$/d' | tail -n1)"
        [ -n "$_motivo" ] || _motivo="healthcheck en rojo"
        DEGRADADOS="${DEGRADADOS}$(printf '  %-*s %-10s %s' "$ANCHO" "$_nombre" "atascado" "$_motivo")
"
        CAIDOS="$CAIDOS $_nombre"
        HUELLA="$HUELLA$_nombre=atascado;"
    else
        # Un job en curso levanta un proceso Runner.Worker: se ve desde el host
        # sin entrar al contenedor (`top`, no `exec`).
        if "$ENGINE" top "$_cont" 2>/dev/null | grep -q 'Runner\.Worker'; then
            _act="ocupado"
        else
            _act="libre"
        fi
        case "$_salud" in
            healthy)  _sal="sano" ;;
            starting) _sal="arrancando" ;;
            -)        _sal="sin check" ;;   # el proveedor no lo corre: no es un fallo
            *)        _sal="$_salud" ;;
        esac
        SANOS="${SANOS}$(printf '  %-*s %-10s %s' "$ANCHO" "$_nombre" "$_sal" "$_act")
"
        ONLINE=$(( ONLINE + 1 ))
        HUELLA="$HUELLA$_nombre=ok;"
    fi
    IFS='
'
done
IFS="$OLDIFS"

CAIDOS="${CAIDOS# }"

# ---- Estado global ---------------------------------------------------------
ESTADO="sano"
[ -n "$CAIDOS" ] && ESTADO="degradado"

# El motor caído es degradado —con podman parado los runners tampoco corren—,
# pero se nombra aparte para que el aviso diga QUÉ arreglar. La lista de
# "ausentes" de arriba no significa nada en este caso: se descarta entera, o el
# mensaje culparía a los runners de un problema que no es suyo.
if [ "$MOTOR_VIVO" = "no" ]; then
    ESTADO="degradado"
    DEGRADADOS=""
    SANOS=""
    ONLINE=0
    CAIDOS="motor:$ENGINE"
    HUELLA="motor=$ENGINE-caido;"
fi

AVISO_RELOJ=""
if [ -n "$DESFASE" ]; then
    _abs="$DESFASE"; [ "$_abs" -lt 0 ] && _abs=$(( -_abs ))
    if [ "$_abs" -gt "$DESFASE_MAX" ]; then
        ESTADO="degradado"
        AVISO_RELOJ="  DESFASADO ${_abs}s: el runner renovará su credencial fuera de plazo y GitHub la rechazará."
        HUELLA="${HUELLA}reloj=desfasado;"
    fi
fi

# ---- Informe ---------------------------------------------------------------
HOSTNAME_CORTO="$(hostname 2>/dev/null || echo host)"
HOSTNAME_CORTO="${HOSTNAME_CORTO%%.*}"

# OJO: `{ … }` es un grupo en ESTE shell, no un subshell. Un `exit` aquí dentro
# cortaría el script entero y NO se mandaría el aviso — justo lo contrario de lo
# que hace falta cuando algo va mal. De ahí que las dos formas del informe vayan
# en un if/else y no en una salida temprana.
{
    if [ "$MOTOR_VIVO" = "no" ]; then
        printf 'Fleet %s — NO SE PUEDE COMPROBAR\n\n' "$HOSTNAME_CORTO"
        printf '  %s está instalado pero no responde.\n' "$ENGINE"
        printf '  Con el motor parado los runners tampoco corren, pero lo que hay\n'
        printf '  que arrancar es el motor, no los runners:\n'
        if [ "$(uname -s 2>/dev/null || echo)" = "Darwin" ]; then
            printf '    podman machine start\n'
        else
            printf '    systemctl --user start podman.socket   (o arranca Docker)\n'
        fi
        printf '\nComprobado: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')"
    else
        printf 'Fleet %s — %s/%s en línea\n' "$HOSTNAME_CORTO" "$ONLINE" "$ESPERADOS"
        if [ -n "$DEGRADADOS" ]; then
            printf '\nDEGRADADO\n%s' "$DEGRADADOS"
        fi
        if [ -n "$SANOS" ]; then
            printf '\nEN LÍNEA\n%s' "$SANOS"
        fi
        printf '\n'
        if [ -n "$DESFASE" ]; then
            printf 'Reloj: %+d s vs GitHub\n' "$DESFASE"
            [ -n "$AVISO_RELOJ" ] && printf '%s\n' "$AVISO_RELOJ"
        else
            printf 'Reloj: no medido (sin red o sin `date` compatible)\n'
        fi
        printf 'Comprobado: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')"
    fi
} > /tmp/vigilar.$$.informe
INFORME="$(cat /tmp/vigilar.$$.informe)"
rm -f /tmp/vigilar.$$.informe

if [ "$SOLO_INFORME" = "yes" ]; then
    printf '%s\n' "$INFORME"
    exit 0
fi

# ---- ¿Cambió algo desde la ronda anterior? ---------------------------------
# El anti-spam vive AQUÍ, en un solo sitio, para que cada hook sea trivial: el
# que quiera hablar solo cuando algo cambia mira VIGILAR_CAMBIO; el latido lo
# ignora a propósito, porque necesita mandarse siempre.
CAMBIO="si"
PRIMERA="si"
if [ -f "$ESTADO_FILE" ]; then
    _previa="$(cat "$ESTADO_FILE" 2>/dev/null || true)"
    [ -n "$_previa" ] && PRIMERA="no"
    [ "$_previa" = "$HUELLA" ] && CAMBIO="no"
fi
mkdir -p "$(dirname "$ESTADO_FILE")" 2>/dev/null || true
printf '%s' "$HUELLA" > "$ESTADO_FILE" 2>/dev/null || true

# ---- Hooks -----------------------------------------------------------------
export VIGILAR_ESTADO="$ESTADO"
export VIGILAR_CAMBIO="$CAMBIO"
# Distingue "es la primera ronda" de "se ha recuperado". Sin esto un hook no
# puede saberlo —las dos llegan con estado sano y cambio si—, y el primer aviso
# tras instalar diría "runners de vuelta" sin que se hubiera ido nadie. Es justo
# el mensaje que se mira para comprobar que el montaje funciona.
export VIGILAR_PRIMERA="$PRIMERA"
export VIGILAR_CAIDOS="$CAIDOS"
export VIGILAR_HOST="$HOSTNAME_CORTO"
export VIGILAR_ONLINE="$ONLINE"
export VIGILAR_ESPERADOS="$ESPERADOS"

if [ ! -d "$HOOKS_DIR" ]; then
    info "No hay directorio de hooks ($HOOKS_DIR); solo imprimo el informe."
    printf '%s\n' "$INFORME"
    exit 0
fi

# `timeout` evita que un hook colgado (una API que no responde) atasque el timer
# y se coma la ronda siguiente. Si no está disponible, se corre sin él.
TIMEOUT=""
command -v timeout >/dev/null 2>&1 && TIMEOUT="timeout 15"

# Orden lexicográfico: el prefijo numérico decide quién habla primero. El latido
# va con 10- a propósito, para que un hook roto más abajo no retrase la señal de
# vida. Un hook que falla NO impide los siguientes ni rompe el timer.
_alguno="no"
for _hook in "$HOOKS_DIR"/*; do
    [ -f "$_hook" ] && [ -x "$_hook" ] || continue
    _alguno="yes"
    _rc=0
    # shellcheck disable=SC2086
    printf '%s\n' "$INFORME" | $TIMEOUT "$_hook" >/dev/null 2>&1 || _rc=$?
    [ "$_rc" -eq 0 ] || info "AVISO: el hook '$(basename "$_hook")' falló (rc=$_rc); sigo con los demás."
done

if [ "$_alguno" = "no" ]; then
    info "No hay hooks ejecutables en $HOOKS_DIR; solo imprimo el informe."
    printf '%s\n' "$INFORME"
fi

# Verde siempre: el timer no debe ponerse en rojo porque el fleet esté malito.
# Un fleet degradado no es un fallo de la vigilancia; avisar de él ES su trabajo.
exit 0
