#!/bin/sh
# ============================================================================
# supervisar-macos.sh — el bucle que en macOS hace de `restart: always`.
#
# Un proceso por SLOT. Cada vuelta clona una VM efímera de la golden de Tart,
# la arranca, espera a que el job termine, y la destruye:
#
#   recoger huérfanas -> backoff -> latir «arrancando» -> tart clone ->
#   tart set -> tart run (job) -> tart stop -> tart delete -> repetir
#
# POR QUÉ EXISTE ESTE FICHERO: en Linux el ciclo lo da el motor de contenedores
# con `restart: always`, que relanza el mismo contenedor sobre el mismo
# filesystem. Aquí no hay motor: la VM se DESTRUYE cada vuelta (es lo que hace
# que un job no pueda ensuciar al siguiente) y con ella se iría cualquier estado.
# Alguien tiene que persistir entre vueltas, y es este proceso.
#
# LO GOBIERNA UN LaunchAgent CON KeepAlive, así que este script solo tiene que
# portarse bien bajo launchd: salir con 0 cuando se le pide parar, atender
# SIGTERM dentro del ExitTimeOut (120 s) y no dejar nada encendido detrás.
#
# --- UN SOLO NOMBRE ---------------------------------------------------------
# $VM == $RUNNER_NAME == nombre del fichero de latido == <cluster>-<host>-<i>,
# la misma convención que deploy.sh usa para los contenedores. Con nombres
# distintos, correlacionar un aviso del vigía con una VM colgada en `tart list`
# es adivinar; con uno solo es un `grep`.
#
# --- CÓMO SE SABE QUE EL JOB TERMINÓ ----------------------------------------
# Porque `tart run` RETORNA. El invitado se apaga solo al acabar (el trap EXIT
# de entrypoint-macos.sh hace `sudo shutdown -h now`), y eso cierra la VM. No se
# pregunta por ssh ni se sondea la API de GitHub: las dos cosas serían un segundo
# criterio de «terminado» que puede discrepar del primero. `ssh` se usa SOLO para
# la parada elegante, que es el único caso en que hay que hablar con el invitado.
#
# --- POR QUÉ EL BACKOFF SE MUDÓ AL HOST -------------------------------------
# entrypoint.sh (Linux) lleva su anti crash-loop en tres marcadores dentro del
# contenedor: .gh_runner_ok / .gh_runner_last / .gh_runner_fails. Ahí funciona
# porque restart:always reusa el mismo filesystem. Aquí morirían con la VM en
# cada vuelta y el backoff no frenaría NADA: un fallo instantáneo repetido
# martillearía la API de GitHub con un registration-token por vuelta hasta agotar
# el rate limit del PAT — que es justo lo que ese backoff existe para evitar.
# Mismos nombres de fichero y misma lógica, pero en ./estado/runner-<i>/ del host.
#
# Dos diferencias obligatorias respecto a Linux, y las dos son de fondo:
#   * El ciclo mínimo sano sube de 20 s a 90 s: una vuelta sana en macOS incluye
#     arrancar la VM (~30-45 s), así que una vuelta de 25 s NO es un job corto,
#     es un fallo. Ver SV_MIN_CICLO.
#   * `$RANDOM` no existe en POSIX sh (es de bash), así que el jitter sale de
#     `date +%s % 10`. Sin jitter, varios slots que fallan a la vez reintentan
#     sincronizados y el pico contra la API es el mismo que sin backoff.
#
# --- POR QUÉ `tart run` RC=0 NO ES SEÑAL DE SALUD ---------------------------
# En Linux el veredicto lo da el código de salida de run.sh, que sabe si tomó un
# job. Aquí lo único que se ve desde el host es que la VM se apagó, y se apaga
# igual si el invitado murió en el primer segundo. Por eso la salud de una vuelta
# la decide su DURACIÓN (>= SV_MIN_CICLO) además del código de salida.
#
# --- LATIDO: QUIÉN ESCRIBE Y POR QUÉ NO HAY CARRERA -------------------------
# Dentro de la VM, latido.sh escribe en el montaje `latidos` (rw). Pero entre
# vuelta y vuelta hay un hueco de 60-90 s sin VM (clone+boot por delante,
# stop+delete por detrás) y VIGIA_RANCIO son 120 s: sin nadie escribiendo, el
# vigía daría por CAÍDO a un slot perfectamente sano en cada rotación. Ese hueco
# lo cubre este supervisor escribiendo la línea `arrancando`.
#
# NO HACE FALTA NINGÚN LOCK, y conviene dejarlo escrito para que nadie añada
# uno: los dos escritores están serializados EN EL TIEMPO, no compitiendo. El
# supervisor solo escribe cuando NO hay VM viva (antes del clone, durante el
# backoff y tras el delete), y latido.sh solo existe mientras la VM está
# encendida. Nunca hay dos escritores a la vez. Lo único que hace falta es que
# cada escritura sea atómica para que el vigía no lea media línea, y eso lo da
# el `mv` dentro del mismo directorio, igual que en latido.sh.
#
# --- HUÉRFANAS --------------------------------------------------------------
# `recoger_huerfanas` corre AL ARRANCAR, no solo al salir. Es lo que cubre el
# caso que la parada elegante no puede cubrir: un `kill -9`, un pánico del
# kernel o un corte de luz dejan la VM del slot encendida o parada pero viva en
# `tart list`. Cada una son decenas de GB en un disco de menos de 500 y un slot
# bloqueado, y nadie las borra nunca porque el supervisor que las creó ya no
# existe.
#
# Uso:
#   supervisar-macos.sh --slot 1 [--conf ./.env] [--ciclos N] [--una-vez]
#                       [--limite-job 90min] [--cpu 4] [--memoria 8192]
#
# POSIX sh a propósito, sin `local` (SC3043): mismo criterio que mint.sh, que se
# sourcea desde aquí. Las variables internas van con prefijo `_sv_`/`SV_` para no
# pisar las `_mt_` de mint.sh ni las del entorno del despliegue.
# ============================================================================
set -eu

err()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*" >&2; }

# ---- Valores por defecto ----------------------------------------------------
SLOT=""
CONF="./.env"
CICLOS=0                     # 0 = sin límite (es el modo normal bajo launchd)
LIMITE_JOB="${SUPERVISAR_LIMITE_JOB:-90min}"
GOLDEN="${SUPERVISAR_GOLDEN:-gh-runner-golden}"
MONTAJE="${SUPERVISAR_MONTAJE:-.}"
LATIDOS_DIR="${SUPERVISAR_LATIDOS:-./latidos}"
ESTADO_BASE="${SUPERVISAR_ESTADO:-./estado}"
CLUSTER="${SUPERVISAR_CLUSTER:-}"
HOST="${SUPERVISAR_HOST:-}"
CPU=""
MEMORIA=""

# Cuánto se le da al invitado para drenar su job tras el SIGTERM. El ExitTimeOut
# del plist son 120 s y ahí dentro tienen que caber TAMBIÉN el `tart stop`, el
# `tart delete` y la llamada a la API; 90 s deja ese margen.
PARADA_GRACIA="${SUPERVISAR_GRACIA:-90}"

# Ciclo mínimo que se considera sano. Ver la cabecera: en macOS una vuelta sana
# incluye el arranque de la VM.
SV_MIN_CICLO=90

usage() {
    cat >&2 <<'EOF'
Uso: supervisar-macos.sh --slot N [opciones]

  --slot N            Slot que gobierna este proceso (obligatorio). La VM, el
                      runner en GitHub y el fichero de latido se llaman
                      <cluster>-<host>-N.

  --conf RUTA         Fichero de configuración tipo .env (por defecto ./.env).
                      El entorno ya presente GANA sobre lo que diga el fichero.
  --ciclos N          Cuántas vueltas dar y salir (por defecto 0 = sin límite).
  --una-vez           Atajo de --ciclos 1.
  --limite-job DUR    Watchdog por vuelta: 5400, 90min, 2h (por defecto 90min;
                      0 lo desactiva).
  --golden NOMBRE     VM golden de la que se clona (por defecto gh-runner-golden).
  --montaje RUTA      Directorio del despliegue que se monta como `gh-runner`
                      (trae entrypoint-macos.sh, mint.sh, latido.sh, el tarball
                      del agente y el access_token). Por defecto, el actual.
  --latidos RUTA      Directorio compartido de latidos (por defecto ./latidos).
  --estado RUTA       Raíz del estado por slot (por defecto ./estado).
  --cluster NOMBRE    Identidad del cluster (por defecto, el directorio actual).
  --cpu N             Vira la VM clonada a N CPUs.
  --memoria MB        Vira la VM clonada a MB de memoria.
  -h, --help          Esta ayuda
EOF
    exit "${1:-0}"
}

# ---- Parseo de argumentos ---------------------------------------------------
while [ "$#" -gt 0 ]; do
    case "$1" in
        --slot)        SLOT="${2:?falta el número tras --slot}"; shift 2 ;;
        --conf)        CONF="${2:?falta la ruta tras --conf}"; shift 2 ;;
        --ciclos)      CICLOS="${2:?falta el número tras --ciclos}"; shift 2 ;;
        --una-vez)     CICLOS=1; shift ;;
        --limite-job)  LIMITE_JOB="${2:?falta la duración tras --limite-job}"; shift 2 ;;
        --golden)      GOLDEN="${2:?falta el nombre tras --golden}"; shift 2 ;;
        --montaje)     MONTAJE="${2:?falta la ruta tras --montaje}"; shift 2 ;;
        --latidos)     LATIDOS_DIR="${2:?falta la ruta tras --latidos}"; shift 2 ;;
        --estado)      ESTADO_BASE="${2:?falta la ruta tras --estado}"; shift 2 ;;
        --cluster)     CLUSTER="${2:?falta el nombre tras --cluster}"; shift 2 ;;
        --cpu)         CPU="${2:?falta el número tras --cpu}"; shift 2 ;;
        --memoria)     MEMORIA="${2:?falta el número tras --memoria}"; shift 2 ;;
        -h|--help)     usage 0 ;;
        *) err "opción desconocida: $1 (usa --help)" ;;
    esac
done

case "$SLOT" in
    ''|*[!0-9]*) err "--slot es obligatorio y tiene que ser un número (recibí '${SLOT}')." ;;
esac
case "$CICLOS" in ''|*[!0-9]*) err "--ciclos debe ser un número (0 = sin límite)." ;; esac
case "${CPU:-0}" in *[!0-9]*) err "--cpu debe ser un número." ;; esac
case "${MEMORIA:-0}" in *[!0-9]*) err "--memoria debe ser un número (MB)." ;; esac

# Duración a segundos, mismo criterio que `a_segundos` de deploy.sh.
a_segundos() {
    case "$1" in
        *[!0-9smhin]*) err "--limite-job: '$1' no es una duración válida (5400, 90min, 2h)" ;;
    esac
    _sv_n="$(printf '%s' "$1" | tr -cd '0-9')"
    [ -n "$_sv_n" ] || err "--limite-job: falta el número en '$1'"
    case "$1" in
        *h)      printf '%s' "$(( _sv_n * 3600 ))" ;;
        *min|*m) printf '%s' "$(( _sv_n * 60 ))" ;;
        *)       printf '%s' "$_sv_n" ;;
    esac
}
LIMITE_JOB="$(a_segundos "$LIMITE_JOB")"

# ---- Configuración del .env del despliegue ---------------------------------
# Mismo contrato que entrypoint-macos.sh: el ENTORNO YA PRESENTE GANA, para que
# un .env viejo no pise lo que puso el LaunchAgent. Sin indirección `${!k}` (eso
# es bash), así que la comprobación de «ya definida» va por `eval` con la clave
# validada antes contra [A-Za-z0-9_]: sin esa validación, una línea torcida del
# fichero se ejecutaría como código.
cargar_conf() {
    [ -f "$1" ] || return 0
    # El `|| [ -n "$_sv_linea" ]` rescata la última línea si el fichero no
    # termina en salto de línea; sin él se pierde en silencio.
    while IFS= read -r _sv_linea || [ -n "$_sv_linea" ]; do
        _sv_linea="$(printf '%s' "$_sv_linea" | tr -d '\r')"
        case "$_sv_linea" in ''|'#'*) continue ;; esac
        _sv_linea="${_sv_linea#export }"
        case "$_sv_linea" in *=*) : ;; *) continue ;; esac
        _sv_clave="${_sv_linea%%=*}"
        _sv_valor="${_sv_linea#*=}"
        case "$_sv_clave" in ''|*[!A-Za-z0-9_]*) continue ;; esac
        case "$_sv_valor" in
            \"*\") _sv_valor="${_sv_valor#\"}"; _sv_valor="${_sv_valor%\"}" ;;
            \'*\') _sv_valor="${_sv_valor#\'}"; _sv_valor="${_sv_valor%\'}" ;;
        esac
        if eval "[ -n \"\${${_sv_clave}:-}\" ]"; then continue; fi
        export "${_sv_clave}=${_sv_valor}"
    done < "$1"
}
cargar_conf "$CONF"

: "${REPO_USER:?Falta REPO_USER (owner del repositorio); ponlo en el .env o en el entorno}"
: "${REPO_NAME:?Falta REPO_NAME (nombre del repositorio); ponlo en el .env o en el entorno}"

# ---- Identidad: cluster, host y el ÚNICO nombre ----------------------------
# Idéntico saneado al de deploy.sh, porque el nombre que sale de aquí tiene que
# poder coincidir con el que ese script pone en el censo del vigía.
if [ -z "$CLUSTER" ]; then
    CLUSTER="${RUNNER_PREFIX:-}"
fi
if [ -z "$CLUSTER" ]; then
    CLUSTER="$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-')"
    CLUSTER="${CLUSTER%-}"
fi
[ -n "$CLUSTER" ] || CLUSTER="gh"

if [ -z "$HOST" ]; then
    HOST="$(hostname 2>/dev/null || echo runner)"
    HOST="${HOST%%.*}"
    HOST="$(printf '%s' "$HOST" | tr -c 'A-Za-z0-9_-' '-')"
fi
[ -n "$HOST" ] || HOST="runner"

VM="${CLUSTER}-${HOST}-${SLOT}"
RUNNER_NAME="$VM"

# El nombre del fichero de latido se sanea con el MISMO `tr` y el MISMO locale
# que latido.sh y que el vigía: el `tr` de BSD bajo un locale UTF-8 razona por
# caracteres y el de Linux por bytes, así que un nombre con acento daría dos
# ficheros distintos y el vigía daría por caído a un slot que late.
SV_LATIDO_NOMBRE="$(printf '%s' "$RUNNER_NAME" | LC_ALL=C tr -c 'A-Za-z0-9_.-' '-')"

SV_ESTADO="${ESTADO_BASE}/runner-${SLOT}"
SV_PID_FILE="${SV_ESTADO}/supervisor.pid"
SV_MONTAJE_SLOT="${SV_ESTADO}/montaje"

# Marcadores del backoff: MISMOS NOMBRES que en entrypoint.sh a propósito, para
# que quien conozca el camino de Linux reconozca el de macOS sin releer nada.
SV_OK="${SV_ESTADO}/.gh_runner_ok"
SV_STAMP="${SV_ESTADO}/.gh_runner_last"
SV_FAILS="${SV_ESTADO}/.gh_runner_fails"

mkdir -p "$SV_ESTADO" "$LATIDOS_DIR"

# ---- mint.sh: token y base de la API ---------------------------------------
# Se sourcea en vez de reimplementarse: lo delicado es el manejo de
# 429/403/Retry-After, y duplicado se arregla en un sitio y se queda viejo en el
# otro (ver la cabecera de mint.sh). De ahí sale también `API`, que consume
# desregistrar_por_api.
# shellcheck source=mint.sh
if [ -r "${MONTAJE}/mint.sh" ]; then
    . "${MONTAJE}/mint.sh"
else
    info "AVISO: no encuentro '${MONTAJE}/mint.sh'; sigo, pero sin él no puedo limpiar runners fantasma."
    API="${API:-${GITHUB_API_URL:-https://api.github.com}}"
fi

# El PAT: del entorno, de ACCESS_TOKEN_FILE o del access_token del montaje, en
# ese orden. Solo se usa para hablar con la API desde el host; el invitado lee el
# suyo del montaje por su cuenta.
if [ -z "${ACCESS_TOKEN:-}" ]; then
    _sv_tok_file="${ACCESS_TOKEN_FILE:-${MONTAJE}/access_token}"
    if [ -r "$_sv_tok_file" ]; then
        ACCESS_TOKEN="$(tr -d '\r\n' < "$_sv_tok_file")"
        export ACCESS_TOKEN
    fi
fi

# ---- Estado del proceso ----------------------------------------------------
SV_PARANDO=0        # 1 tras la primera señal: el bucle no relanza
SV_TART_PID=""      # PID del `tart run` en curso ('' = no hay VM viva)
SV_VM_VIVA=0        # 1 entre el `tart clone` y el `tart delete`

# ---- Latido ----------------------------------------------------------------
# Disco del directorio de Tart, que es el que de verdad se llena: los clones
# viven ahí y son decenas de GB cada uno. El latido del INVITADO mide el disco de
# la VM, que se destruye tras cada job y nunca llega al umbral, así que este es
# el único momento en que alguien mira el disco que importa.
_sv_disco() {
    _sv_d="$(df -P "${TART_HOME:-$HOME/.tart}" 2>/dev/null || df -P "$HOME" 2>/dev/null || true)"
    _sv_d="$(printf '%s' "$_sv_d" | awk 'NR==2 { gsub(/%/, "", $5); print $5 }')"
    case "$_sv_d" in ''|*[!0-9]*) printf '%s' '-' ;; *) printf '%s' "$_sv_d" ;; esac
}

# Campo 5 de la línea anterior: «cuándo tomó este slot su último job». Se arrastra
# igual que en latido.sh para que rotar la VM no lo borre; si se perdiera, un slot
# mal etiquetado al que nadie manda trabajo dejaría de ser distinguible de uno sano.
_sv_ultimo_job_previo() {
    _sv_u="$(awk '{ print $5 }' "${LATIDOS_DIR}/${SV_LATIDO_NOMBRE}" 2>/dev/null || true)"
    case "$_sv_u" in ''|*[!0-9]*) printf '%s' '-' ;; *) printf '%s' "$_sv_u" ;; esac
}

# _sv_latir <motivo> — publica «arrancando · libre» en el hueco sin VM.
# Escritura atómica con `mv` dentro del mismo directorio, igual que latido.sh: el
# vigía lee cuando quiere y nunca debe pillar media línea. NO hay lock ni hace
# falta (ver la cabecera): mientras esto escribe, no hay invitado que escriba.
_sv_latir() {
    _sv_lat_tmp="${LATIDOS_DIR}/.tmp.${SV_LATIDO_NOMBRE}.$$"
    # El paréntesis mete la redirección dentro del alcance silenciado: si falla,
    # el mensaje lo emite el shell y un 2>/dev/null pegado al printf no lo taparía.
    if ! ( printf '%s %s %s %s %s %s\n' \
             "$(date -u +%s)" arrancando libre "$(_sv_disco)" \
             "$(_sv_ultimo_job_previo)" "$1" > "$_sv_lat_tmp" ) 2>/dev/null; then
        rm -f "$_sv_lat_tmp" 2>/dev/null || true
        return 0
    fi
    mv -f "$_sv_lat_tmp" "${LATIDOS_DIR}/${SV_LATIDO_NOMBRE}" 2>/dev/null \
        || rm -f "$_sv_lat_tmp" 2>/dev/null || true
}

# _sv_dormir <segundos> <motivo> — espera latiendo.
# En tramos de 30 s y no de una sentada porque el backoff llega a 300 s y
# VIGIA_RANCIO son 120: un `sleep 300` a secas dejaría el latido rancio y el
# vigía daría por caído justo al slot que se está recuperando, que es el peor
# momento para una falsa alarma.
_sv_dormir() {
    _sv_resta="$1"
    while [ "$_sv_resta" -gt 0 ]; do
        if [ "$_sv_resta" -gt 30 ]; then _sv_paso=30; else _sv_paso="$_sv_resta"; fi
        _sv_latir "$2"
        sleep "$_sv_paso"
        _sv_resta=$(( _sv_resta - _sv_paso ))
    done
    _sv_latir "$2"
}

# ---- Limpieza de runners fantasma en GitHub --------------------------------
# LA NOVEDAD FRENTE AL CAMINO DE LINUX. Un runner efímero se desregistra solo al
# acabar su job, y entrypoint-macos.sh llama a deregister() si le paran antes.
# Pero si la VM murió colgada —pánico, watchdog, `tart delete` a la fuerza— el
# invitado no llegó a hacer ninguna de las dos cosas y queda un runner `offline`
# en Settings -> Runners con ESTE nombre. El nombre se reusa en la vuelta
# siguiente, así que `--replace` lo taparía... salvo que el slot no vuelva a
# arrancar, que es justo el caso en que el vigía tiene que avisar: entonces el
# fantasma se queda ahí PARA SIEMPRE y el fleet cuenta un runner caído que no
# existe. Lo limpia el host, que es el único que sigue vivo.
#
# Idempotente por construcción: si no aparece en la lista, no hay nada que hacer
# y se sale con 0. No está en mint.sh porque mint.sh cubre los dos endpoints de
# token, que son los que comparten los tres consumidores; esto solo lo necesita
# el supervisor. De mint.sh se reusa `API`.
desregistrar_por_api() {
    _sv_nombre="$1"
    [ -n "${ACCESS_TOKEN:-}" ] || { info "Sin PAT: no puedo comprobar si quedó un runner fantasma '${_sv_nombre}'."; return 0; }
    command -v curl >/dev/null 2>&1 || return 0
    command -v jq >/dev/null 2>&1 || return 0

    _sv_lst="$(curl -sSL --max-time 30 \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "${API}/repos/${REPO_USER}/${REPO_NAME}/actions/runners?per_page=100" 2>/dev/null || true)"

    _sv_id="$(printf '%s' "$_sv_lst" | jq -r --arg n "$_sv_nombre" \
        '.runners[]? | select(.name==$n) | .id' 2>/dev/null | head -n1)"
    case "${_sv_id:-}" in
        ''|*[!0-9]*) return 0 ;;   # no está registrado: nada que limpiar
    esac

    info "Queda un runner '${_sv_nombre}' (id ${_sv_id}) registrado en GitHub; lo borro para que no cuente como caído."
    curl -sSL --max-time 30 -o /dev/null -X DELETE \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "${API}/repos/${REPO_USER}/${REPO_NAME}/actions/runners/${_sv_id}" 2>/dev/null \
        || info "AVISO: no pude borrar el runner fantasma '${_sv_nombre}'."
    return 0
}

# ---- Huérfanas -------------------------------------------------------------
# ¿Tiene esa VM un supervisor vivo? El dueño de un slot deja su PID en
# estado/runner-<i>/supervisor.pid. Si el fichero no está o el proceso ya no
# existe, la VM no es de nadie.
_sv_dueno_vivo() {
    _sv_pf="${ESTADO_BASE}/runner-${1}/supervisor.pid"
    [ -f "$_sv_pf" ] || return 1
    _sv_pid="$(cat "$_sv_pf" 2>/dev/null || true)"
    case "${_sv_pid:-}" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$_sv_pid" 2>/dev/null || return 1
    return 0
}

recoger_huerfanas() {
    # El here-doc y no una tubería: `tart list | while read` corre el bucle en
    # una subshell, y ahí cualquier estado que se toque se pierde al salir. Mismo
    # motivo por el que latido.sh lo hace así.
    while IFS= read -r _sv_vm; do
        [ -n "$_sv_vm" ] || continue
        case "$_sv_vm" in
            "${CLUSTER}-${HOST}-"*) : ;;
            *) continue ;;
        esac
        _sv_slot="${_sv_vm##*-}"
        case "$_sv_slot" in ''|*[!0-9]*) continue ;; esac
        if _sv_dueno_vivo "$_sv_slot"; then continue; fi
        info "VM huérfana '${_sv_vm}': su supervisor no está vivo. La borro (son decenas de GB y un slot bloqueado)."
        tart delete "$_sv_vm" >/dev/null 2>&1 \
            || info "AVISO: no pude borrar la VM huérfana '${_sv_vm}'; libéralo a mano con 'tart delete ${_sv_vm}'."
    done <<EOF
$(tart list 2>/dev/null | awk 'NR>1 { print $2 }')
EOF
}

# ---- Montaje por slot ------------------------------------------------------
# El invitado lee su configuración de "${MONTAJE}/.env", y RUNNER_NAME cambia por
# slot: si todos los slots montaran el MISMO directorio, todas las VMs se
# registrarían con el mismo nombre y, como config.sh usa --replace, se robarían
# el registro unas a otras en bucle (el mismo fallo que documenta deploy.sh sobre
# el prefijo). Así que cada slot monta su propia copia.
#
# `ln` antes que `cp`: el tarball del agente son ~300 MB y esto corre en cada
# vuelta; un enlace duro no gasta disco ni tiempo. `cp` es el respaldo para
# cuando el estado vive en otro sistema de ficheros que el despliegue.
preparar_montaje() {
    mkdir -p "$SV_MONTAJE_SLOT"
    for _sv_f in "$MONTAJE"/*; do
        [ -f "$_sv_f" ] || continue
        case "$(basename "$_sv_f")" in .env) continue ;; esac
        _sv_dst="${SV_MONTAJE_SLOT}/$(basename "$_sv_f")"
        # Sin `-ef` (no existe en POSIX sh): basta comparar rutas para el caso en
        # que alguien apunte --montaje al propio directorio del slot.
        [ "$_sv_f" = "$_sv_dst" ] && continue
        rm -f "$_sv_dst"
        ln "$_sv_f" "$_sv_dst" 2>/dev/null || cp -f "$_sv_f" "$_sv_dst" 2>/dev/null || true
    done
    # RUNNER_NAME va PRIMERO: cargar_env() del invitado exporta según lee y no
    # pisa lo ya definido, así que la primera aparición gana y un RUNNER_NAME
    # heredado del .env del despliegue no puede colarse por debajo.
    {
        printf 'RUNNER_NAME=%s\n' "$RUNNER_NAME"
        [ -f "${MONTAJE}/.env" ] && cat "${MONTAJE}/.env"
    } > "${SV_MONTAJE_SLOT}/.env" 2>/dev/null || true
    chmod 0600 "${SV_MONTAJE_SLOT}/.env" 2>/dev/null || true
}

# ---- Derribo ---------------------------------------------------------------
# `tart delete` SIEMPRE, pase lo que pase antes. Es la línea que no se puede
# perder: una VM que se queda son decenas de GB de un disco de menos de 500 y un
# slot que no vuelve a arrancar porque `tart clone` falla por nombre duplicado.
# Por eso el `stop` va con `|| true` (fallar ahí no puede saltarse el delete) y
# el `delete` también (para que el bucle siga aunque Tart tenga un mal día).
derribar() {
    [ "$SV_VM_VIVA" -eq 1 ] || return 0
    tart stop "$VM" >/dev/null 2>&1 || true
    tart delete "$VM" >/dev/null 2>&1 \
        || info "AVISO: 'tart delete ${VM}' falló; la vuelta siguiente no podrá clonar hasta que se borre."
    SV_VM_VIVA=0
    SV_TART_PID=""
}

# ---- Parada elegante -------------------------------------------------------
# Todo esto tiene que caber en el ExitTimeOut del plist (120 s), o launchd manda
# SIGKILL y volvemos al caso que recoger_huerfanas tiene que limpiar.
parar() {
    [ "$SV_PARANDO" -eq 0 ] || return 0
    SV_PARANDO=1
    info "Señal recibida: parando el slot ${SLOT}."

    if [ "$SV_VM_VIVA" -eq 1 ]; then
        # Se le pide al INVITADO que termine, no se apaga la VM de golpe: matar
        # el `tart run` a mitad de job lo deja a medias y sin desregistrar. El
        # pkill dispara el trap de entrypoint-macos.sh, que drena run.sh, llama a
        # su deregister() y apaga la VM — con lo que `tart run` retorna solo.
        _sv_ip="$(tart ip "$VM" 2>/dev/null || true)"
        if [ -n "$_sv_ip" ]; then
            info "Pidiendo al invitado que drene su job (${_sv_ip})..."
            _sv_ssh "$_sv_ip" 'pkill -TERM -f entrypoint-macos.sh' >/dev/null 2>&1 || true
        else
            info "AVISO: la VM '${VM}' no da IP; no puedo pedirle que drene."
        fi

        # Espera acotada a que `tart run` retorne por su cuenta.
        _sv_esperado=0
        while [ "$_sv_esperado" -lt "$PARADA_GRACIA" ]; do
            [ -n "$SV_TART_PID" ] || break
            kill -0 "$SV_TART_PID" 2>/dev/null || break
            sleep 1
            _sv_esperado=$(( _sv_esperado + 1 ))
        done
        derribar
    fi

    # SIEMPRE, y aquí está la razón de ser de esta función: si la VM murió
    # colgada, el invitado nunca se desregistró y el fantasma se quedaría en la
    # lista de GitHub contando como caído para siempre.
    desregistrar_por_api "$RUNNER_NAME"

    rm -f "$SV_PID_FILE" 2>/dev/null || true
    info "Slot ${SLOT} parado limpiamente."
    exit 0
}

# ssh contra el invitado. Credenciales de fábrica de las imágenes de Cirrus Labs
# (admin/admin, documentadas por ellos y ya usadas por hornear-macos.sh), con
# sshpass solo si está: si la golden lleva clave pública, el ssh pelado basta.
# NUNCA se le pasa el PAT: lo que viaja es un `pkill`, y el token del invitado ya
# está dentro de la VM por el montaje.
_sv_ssh() {
    _sv_ssh_ip="$1"; shift
    if command -v sshpass >/dev/null 2>&1; then
        sshpass -p "${SUPERVISAR_SSH_PASS:-admin}" ssh \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 -o BatchMode=no \
            "${SUPERVISAR_SSH_USER:-admin}@${_sv_ssh_ip}" "$@"
    else
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 -o BatchMode=yes \
            "${SUPERVISAR_SSH_USER:-admin}@${_sv_ssh_ip}" "$@"
    fi
}

trap parar INT TERM

# ---- Backoff anti crash-loop -----------------------------------------------
# Misma lógica y mismos nombres de fichero que entrypoint.sh; lo que cambia es
# dónde viven (host, no invitado), el umbral (SV_MIN_CICLO) y el jitter.
backoff() {
    _sv_ahora="$(date +%s)"
    if [ -f "$SV_OK" ]; then
        rm -f "$SV_OK" "$SV_FAILS"          # la vuelta anterior fue sana
    elif [ -f "$SV_STAMP" ]; then
        _sv_last="$(cat "$SV_STAMP" 2>/dev/null || echo 0)"
        case "$_sv_last" in ''|*[!0-9]*) _sv_last=0 ;; esac
        _sv_delta=$(( _sv_ahora - _sv_last ))
        if [ "$_sv_delta" -ge 0 ] && [ "$_sv_delta" -lt "$SV_MIN_CICLO" ]; then
            _sv_n="$(cat "$SV_FAILS" 2>/dev/null || echo 0)"
            case "$_sv_n" in ''|*[!0-9]*) _sv_n=0 ;; esac
            _sv_n=$(( _sv_n + 1 )); echo "$_sv_n" > "$SV_FAILS"
            if [ "$_sv_n" -ge 5 ]; then _sv_back=300; else _sv_back=$(( 15 * (1 << (_sv_n - 1)) )); fi
            # `$RANDOM` es de bash y este script es POSIX sh: ahí valdría cadena
            # vacía y el jitter desaparecería en silencio, dejando a todos los
            # slots reintentando a la vez contra la API.
            _sv_back=$(( _sv_back + ( _sv_ahora % 10 ) ))
            info "Fallo rápido (#${_sv_n}, vuelta previa ${_sv_delta}s < ${SV_MIN_CICLO}s); esperando ${_sv_back}s para no exceder el rate limit de GitHub..."
            _sv_dormir "$_sv_back" "backoff tras ${_sv_n} fallo(s)"
        fi
    fi
    date +%s > "$SV_STAMP"
}

# ---- Una vuelta ------------------------------------------------------------
clonar() {
    _sv_latir "clonando ${VM} de ${GOLDEN}"
    tart clone "$GOLDEN" "$VM" >/dev/null 2>&1 || return 1
    SV_VM_VIVA=1
    return 0
}

ajustar() {
    [ -n "$CPU" ] || [ -n "$MEMORIA" ] || return 0
    # Un solo `tart set`: dos llamadas dejarían la VM medio virada si la segunda
    # falla, y no hay forma de saber cuál se aplicó.
    if [ -n "$CPU" ] && [ -n "$MEMORIA" ]; then
        tart set "$VM" --cpu "$CPU" --memory "$MEMORIA" >/dev/null 2>&1 || return 1
    elif [ -n "$CPU" ]; then
        tart set "$VM" --cpu "$CPU" >/dev/null 2>&1 || return 1
    else
        tart set "$VM" --memory "$MEMORIA" >/dev/null 2>&1 || return 1
    fi
    return 0
}

arrancar() {
    _sv_latir "arrancando la VM ${VM}"
    # --no-graphics: no hay nadie delante, y con ventana `tart run` exige sesión
    # gráfica del host. Los dos montajes son el contrato con entrypoint-macos.sh:
    # gh-runner en SOLO LECTURA (un job de un PR de terceros no puede reescribir
    # el entrypoint del ciclo siguiente) y latidos en lectura/escritura.
    tart run --no-graphics \
        "--dir=gh-runner:${SV_MONTAJE_SLOT}:ro" \
        "--dir=latidos:${LATIDOS_DIR}" \
        "$VM" >/dev/null 2>&1 &
    SV_TART_PID=$!
}

# Espera a que `tart run` retorne, con watchdog. Devuelve el código de salida;
# 124 (el de `timeout`) si lo cortó el watchdog.
esperar_fin() {
    _sv_wd=""
    rm -f "${SV_ESTADO}/.watchdog"
    if [ "$LIMITE_JOB" -gt 0 ]; then
        # Un job colgado no hace que `tart run` retorne NUNCA: sin esto, el slot
        # se queda ocupado para siempre y el vigía solo ve un runner «sano ·
        # ocupado» eternamente, que es indistinguible de uno trabajando.
        (
            sleep "$LIMITE_JOB"
            kill -0 "$SV_TART_PID" 2>/dev/null || exit 0
            : > "${SV_ESTADO}/.watchdog"
            printf 'AVISO: la vuelta pasó de %ss; corto la VM %s.\n' "$LIMITE_JOB" "$VM" >&2
            tart stop "$VM" >/dev/null 2>&1 || true
        ) &
        _sv_wd=$!
    fi

    _sv_rc=0
    wait "$SV_TART_PID" 2>/dev/null || _sv_rc=$?

    # El `sleep` del watchdog queda huérfano y se apaga solo al vencer; matar al
    # grupo entero desde POSIX sh no es portable y no compensa por un sleep.
    [ -n "$_sv_wd" ] && kill "$_sv_wd" 2>/dev/null
    if [ -f "${SV_ESTADO}/.watchdog" ]; then
        rm -f "${SV_ESTADO}/.watchdog"
        return 124
    fi
    return "$_sv_rc"
}

# Marca la vuelta como sana solo si además de salir bien DURÓ lo suficiente. Ver
# la cabecera: desde el host, `tart run` rc=0 significa «la VM se apagó», y se
# apaga igual si el invitado murió en el primer segundo.
marcar_ok() {
    if [ "$1" -eq 0 ] && [ "$2" -ge "$SV_MIN_CICLO" ]; then
        : > "$SV_OK" 2>/dev/null || true
    fi
}

una_vuelta() {
    backoff
    [ "$SV_PARANDO" -eq 0 ] || return 0

    preparar_montaje
    _sv_t0="$(date +%s)"

    if ! clonar; then
        info "AVISO: 'tart clone ${GOLDEN} ${VM}' falló; la vuelta cuenta como fallo."
        derribar
        return 0
    fi
    if ! ajustar; then
        info "AVISO: 'tart set' falló sobre '${VM}'; derribo y reintento."
        derribar
        return 0
    fi

    arrancar
    _sv_rc=0
    esperar_fin || _sv_rc=$?
    _sv_dur=$(( $(date +%s) - _sv_t0 ))

    derribar
    _sv_latir "vuelta terminada (${_sv_dur}s, rc=${_sv_rc})"

    if [ "$_sv_rc" -eq 124 ]; then
        info "La VM '${VM}' pasó del límite de ${LIMITE_JOB}s y se cortó."
    elif [ "$_sv_rc" -ne 0 ]; then
        info "'tart run ${VM}' salió con ${_sv_rc} tras ${_sv_dur}s."
    fi

    # Solo cuando la VM se murió mal: ahí es donde nacen los fantasmas, porque el
    # invitado no llegó a desregistrarse. En la vuelta sana no se llama, que sería
    # una petición a la API por job y la cuota del PAT es el recurso escaso.
    if [ "$_sv_rc" -ne 0 ]; then
        desregistrar_por_api "$RUNNER_NAME"
    fi

    marcar_ok "$_sv_rc" "$_sv_dur"
    return 0
}

# ---- Bucle -----------------------------------------------------------------
command -v tart >/dev/null 2>&1 \
    || err "falta 'tart'. Instálalo con: brew install cirruslabs/cli/tart"

# El barrido va ANTES de publicar nuestro PID: si lo escribiéramos primero, la VM
# residual de nuestro propio slot se vería con dueño vivo (nosotros) y sobreviviría
# — que es exactamente el caso que este barrido existe para limpiar.
recoger_huerfanas
printf '%s\n' "$$" > "$SV_PID_FILE"

info "Supervisor del slot ${SLOT} en marcha: VM y runner '${VM}', golden '${GOLDEN}'."

SV_VUELTA=0
while :; do
    [ "$SV_PARANDO" -eq 0 ] || break
    una_vuelta
    SV_VUELTA=$(( SV_VUELTA + 1 ))
    [ "$CICLOS" -gt 0 ] && [ "$SV_VUELTA" -ge "$CICLOS" ] && break
done

rm -f "$SV_PID_FILE" 2>/dev/null || true
exit 0
