#!/bin/sh
# ============================================================================
# vigilar.sh — mira los runners de SU cluster y entrega un informe a los hooks.
#
# Corre DENTRO de un contenedor (el servicio `vigia` del compose), no en el host.
# Esa es la decisión de fondo, y el motivo es que el agendado lo haga el motor de
# contenedores: es la única capa idéntica en Linux, macOS y Windows. La versión
# anterior vivía en el host y obligaba a mantener systemd, launchd y Scheduled
# Task en paralelo — de ahí salieron sus dos últimos fallos.
#
# CÓMO VE A LOS RUNNERS: leyendo los ficheros de latido que cada runner escribe
# en un volumen compartido (ver latido.sh). NO habla con el motor de contenedores
# y no necesita su socket, que además de atarnos a cada sistema operativo sería
# una API completa al lado de runners que ejecutan PRs de terceros.
#
# Qué mira, en una ronda:
#   1. Latidos que faltan o están rancios  (contenedor parado, borrado o muerto)
#   2. Latidos que dicen «atascado»        (el runner colgado; ver healthcheck.sh)
#   3. Desfase del reloj contra GitHub     (la causa raíz del incidente del 1-ago)
#
# El desfase se mide DESDE AQUÍ a propósito: este es el reloj que los runners
# usan de verdad. En macOS es el de la VM de podman, que es la que se desincroniza
# al suspender — medirlo desde el host habría mirado el reloj equivocado.
#
# Qué NO hace: reparar. Diagnostica y avisa; decidir es de quien lee.
#
# Y QUÉ PASA SI ESTE CONTENEDOR MUERE: que deja de latir hacia fuera, y de eso
# avisa el servicio de heartbeat por ausencia de señal. Es el mismo mecanismo que
# cubre el host apagado, y por eso no hace falta nadie vigilando al vigía.
#
# CÓMO AVISA: no lo decide este script. Ejecuta todo lo que sea ejecutable en el
# directorio de hooks (convención run-parts) y les pasa el INFORME COMPLETO por
# stdin más unas variables de entorno. Así este script NO maneja ni un secreto:
# cada hook guarda el suyo.
#
# Uso:
#   ./vigilar.sh --bucle     # como corre en el contenedor: una ronda cada VIGIA_CADA
#   ./vigilar.sh             # una ronda y sale
#   ./vigilar.sh --informe   # solo imprime el informe (no toca hooks ni estado)
# ============================================================================
set -eu

err()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*" >&2; }

# ---- Configuración ---------------------------------------------------------
LATIDOS_DIR="${VIGIA_LATIDOS:-/var/lib/gh-runner/latidos}"
HOOKS_DIR="${VIGIA_HOOKS:-/etc/gh-runner/vigia/hooks.d}"
ESTADO_FILE="${VIGIA_ESTADO_FILE:-/var/lib/gh-runner/estado/vigilar.estado}"

# Censo: los nombres de runner que DEBEN estar. Lo escribe deploy.sh en el
# compose. Es una lista explícita y no un descubrimiento porque «no hay latido»
# solo significa algo si sabes a quién esperabas.
RUNNERS="${VIGIA_RUNNERS:-}"

# Identidad del cluster: encabeza el informe y viaja a los hooks. Es lo que
# permite que dos clusters de la misma máquina manden avisos distinguibles.
CLUSTER="${VIGIA_CLUSTER:-}"

# Un latido más viejo que esto = ese runner está caído. 4x el intervalo de
# latido (30 s) deja margen para una ronda perdida sin dar falsas alarmas.
RANCIO="${VIGIA_RANCIO:-120}"

# Cuántos runners sanos hacen falta para que la CI siga corriendo. Por debajo de
# esto el estado es `degradado` (alarma); por encima, con alguno caído, es
# `parcial` (se registra, no despierta a nadie).
MINIMO="${VIGIA_MINIMO:-1}"

# Cadencia del modo bucle.
CADA="${VIGIA_CADA:-300}"

# Umbral de desfase de reloj (segundos) que ya cuenta como degradado. El token de
# registro vive ~10 min, así que un desfase de minutos rompe el runner; 60 s está
# muy por encima de lo que deja cualquier NTP sano, así que no da falsos avisos.
DESFASE_MAX="${VIGIA_DESFASE_MAX:-60}"

# Ocupación de disco (%) a partir de la cual se avisa. 90 deja margen para
# reaccionar: a partir de ahí una cache o un checkout grande ya puede no caber.
DISCO_MAX="${VIGIA_DISCO_MAX:-90}"

# Ruta cuyo disco mide el VIGÍA por su cuenta, además de lo que reporten los
# runners. Vacía = solo lo reportado, que es lo de siempre.
#
# Existe porque el latido mide el disco DESDE DENTRO del runner, y hay un caso en
# que ese no es el disco que se llena: con runners en VM efímera (macOS + Tart),
# el invitado se destruye tras cada job —su ocupación no llega nunca al umbral—
# mientras las imágenes en ~/.tart se comen el disco del host a decenas de GB por
# VM. Nadie lo reportaría y la primera señal sería un job fallando por «no space
# left» que no señala la causa. En Linux vale igual para apuntar al volumen de
# caches, que tampoco vive dentro del contenedor.
DISCO_RUTA="${VIGIA_DISCO_RUTA:-}"

SOLO_INFORME="no"
BUCLE="no"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --latidos)      LATIDOS_DIR="${2:?falta la ruta tras --latidos}"; shift 2 ;;
        --hooks)        HOOKS_DIR="${2:?falta la ruta tras --hooks}"; shift 2 ;;
        --estado)       ESTADO_FILE="${2:?falta la ruta tras --estado}"; shift 2 ;;
        --runners)      RUNNERS="${2:?falta la lista tras --runners}"; shift 2 ;;
        --cluster)      CLUSTER="${2:?falta el nombre tras --cluster}"; shift 2 ;;
        --rancio)       RANCIO="${2:?falta el valor tras --rancio}"; shift 2 ;;
        --minimo)       MINIMO="${2:?falta el valor tras --minimo}"; shift 2 ;;
        --cada)         CADA="${2:?falta el valor tras --cada}"; shift 2 ;;
        --desfase-max)  DESFASE_MAX="${2:?falta el valor tras --desfase-max}"; shift 2 ;;
        --disco-max)    DISCO_MAX="${2:?falta el valor tras --disco-max}"; shift 2 ;;
        --disco-ruta)   DISCO_RUTA="${2:?falta la ruta tras --disco-ruta}"; shift 2 ;;
        --informe)      SOLO_INFORME="yes"; shift ;;
        --bucle)        BUCLE="yes"; shift ;;
        -h|--help)
            sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//' >&2
            exit 0 ;;
        *) err "opción desconocida: $1 (usa --help)" ;;
    esac
done

[ -n "$RUNNERS" ] || err "no sé a qué runners vigilar.
       Pasa --runners 'nombre-1 nombre-2' o define VIGIA_RUNNERS (lo hace deploy.sh)."

# El host llega por entorno desde deploy.sh, que sí corre en el host. Dentro de
# un contenedor `hostname` devuelve su ID —cambia en cada recreate—, así que solo
# vale como último recurso (ejecución suelta fuera del compose).
HOSTNAME_CORTO="${VIGIA_HOST:-}"
if [ -z "$HOSTNAME_CORTO" ]; then
    HOSTNAME_CORTO="$(hostname 2>/dev/null || echo host)"
    HOSTNAME_CORTO="${HOSTNAME_CORTO%%.*}"
fi
[ -n "$CLUSTER" ] || CLUSTER="$HOSTNAME_CORTO"

# El mismo saneado que aplica latido.sh al componer el nombre del fichero: si no
# coincidiera, el vigía buscaría un fichero que nadie escribe y daría por caído a
# un runner sano.
# `LC_ALL=C` no es adorno, y por eso va aquí igual que en `col()`: el `tr` de BSD
# (macOS) bajo un locale UTF-8 razona por CARACTERES, así que un nombre con
# acento se convierte en un número de guiones distinto al que produce el `tr` del
# contenedor Linux que escribe el latido. El vigía buscaría entonces un fichero
# que nadie escribe y daría por caído a un runner sano.
sanear() { printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9_.-' '-'; }

# Rellena $1 hasta $2 CARACTERES. No se usa `printf '%-*s'` porque cuenta BYTES:
# con «caído» o «sin señal» (multibyte en UTF-8) la columna sale corta y la tabla
# se desalinea justo en las filas que avisan de un problema. Contar caracteres
# quitando los bytes de continuación UTF-8 (0x80-0xBF) funciona sea cual sea el
# locale del contenedor, que `wc -m` no garantiza.
col() {
    _txt="$1"; _w="$2"
    _n="$(printf '%s' "$_txt" | LC_ALL=C tr -d '\200-\277' | wc -c | tr -dc '0-9')"
    printf '%s' "$_txt"
    _i=$(( _w - _n ))
    while [ "$_i" -gt 0 ]; do printf ' '; _i=$(( _i - 1 )); done
}

# Una fila de la tabla: nombre, estado y detalle.
fila() { printf '  %s %s %s' "$(col "$1" "$ANCHO")" "$(col "$2" 11)" "$3"; }

# «hace 2 h» a partir de un epoch. Un runner puede estar `sano · libre` PARA
# SIEMPRE porque se registró con la etiqueta equivocada y nadie le manda trabajo:
# desde fuera es indistinguible de uno sano. Esto lo delata sin inventar una
# alarma, porque en un fleet tranquilo (noche, fin de semana) que nadie tome
# jobs es lo normal; lo que canta es «nunca» al lado de hermanos que sí
# trabajaron.
cuando() {
    # Con un job EN CURSO la antigüedad sobra: es ahora mismo.
    [ "${3:-}" = "ocupado" ] && return 0
    [ -n "$1" ] || { printf ' · sin jobs aún'; return 0; }
    _s=$(( $2 - $1 ))
    [ "$_s" -lt 0 ] && _s=0
    if   [ "$_s" -lt 90 ];    then printf ' · job hace %ss' "$_s"
    elif [ "$_s" -lt 5400 ];  then printf ' · job hace %s min' "$(( _s / 60 ))"
    elif [ "$_s" -lt 172800 ]; then printf ' · job hace %s h' "$(( _s / 3600 ))"
    else printf ' · job hace %s d' "$(( _s / 86400 ))"
    fi
}

# ---- Desfase del reloj contra GitHub ---------------------------------------
a_epoch() {
    date -u -d "$1" +%s 2>/dev/null && return 0                                   # GNU
    date -j -u -f '%a, %d %b %Y %H:%M:%S %Z' "$1" +%s 2>/dev/null && return 0     # BSD/macOS
    return 1
}

medir_desfase() {
    command -v curl >/dev/null 2>&1 || return 0
    # GET con el cuerpo tirado (-o /dev/null -D -), no HEAD: algunos proxies
    # corporativos responden 400 a HEAD o le quitan las cabeceras.
    _fecha_gh="$(curl -sS -o /dev/null -D - -m 10 https://api.github.com 2>/dev/null \
        | grep -i '^date:' | head -n1 | sed 's/^[Dd][Aa][Tt][Ee]:[[:space:]]*//' | tr -d '\r')"
    [ -n "$_fecha_gh" ] || return 0
    _epoch_gh="$(a_epoch "$_fecha_gh")" || return 0
    DESFASE=$(( $(date -u +%s) - _epoch_gh ))
}

# `timeout` de repuesto, en shell puro: corre "$@" y lo mata si pasa de $1
# segundos. Devuelve el código del hook, o 143 (SIGTERM) si hubo que matarlo, que
# es lo mismo que devuelve `timeout` y basta para que la ronda lo nombre.
#
# El `exec 3<&0` + `<&3` NO es equivalente a dejarlo tal cual: en un shell POSIX
# sin control de trabajos (dash, el /bin/sh del contenedor), un proceso lanzado en
# segundo plano recibe /dev/null como entrada salvo redirección EXPLÍCITA. Medido:
# sin esto el hook arranca, no falla y manda un aviso VACÍO — el informe se pierde
# por el camino. `<&0` tampoco vale: la asignación a /dev/null ya ocurrió.
con_limite() {
    _lim="$1"; shift
    exec 3<&0
    "$@" <&3 &
    _hijo=$!
    # El vigilante duerme de segundo en segundo en vez de `sleep $_lim` de una vez
    # para poder rendirse en cuanto el hook termina: si no, cada ronda arrastraría
    # el límite entero aunque todos los hooks contesten al instante.
    (
        _t=0
        while [ "$_t" -lt "$_lim" ]; do
            kill -0 "$_hijo" 2>/dev/null || exit 0
            sleep 1
            _t=$(( _t + 1 ))
        done
        # TERM primero y KILL después: a un hook colgado en una petición HTTP se
        # le da ocasión de cerrar, pero no derecho a ignorarnos.
        kill -TERM "$_hijo" 2>/dev/null || true
        sleep 2
        kill -KILL "$_hijo" 2>/dev/null || true
    ) &
    _vigilante=$!
    _rc=0
    wait "$_hijo" || _rc=$?
    kill "$_vigilante" 2>/dev/null || true
    wait "$_vigilante" 2>/dev/null || true
    return "$_rc"
}

# ---- Una ronda -------------------------------------------------------------
ronda() {
    DEGRADADOS=""   # líneas ya formateadas
    SANOS=""
    CAIDOS=""       # nombres, separados por espacio (va a los hooks)
    HUELLA=""       # firma canónica del estado, para detectar cambios entre rondas
    ONLINE=0
    ESPERADOS=0
    DESFASE=""      # vacío = no medido
    DISCO_PICO=""   # el mayor de los runners: en la práctica, el del host

    medir_desfase

    _ahora="$(date -u +%s)"

    # El ancho de la columna de nombres se calcula del contenido: con nombres
    # largos una anchura fija parte la tabla, y la tabla alineada es medio valor
    # del aviso.
    ANCHO="$(printf '%s\n' $RUNNERS \
        | awk '{ if (length($0) > m) m = length($0) } END { print (m < 12 ? 12 : m) + 2 }')"

    for _nombre in $RUNNERS; do
        ESPERADOS=$(( ESPERADOS + 1 ))
        _f="${LATIDOS_DIR}/$(sanear "$_nombre")"

        if [ ! -f "$_f" ]; then
            DEGRADADOS="${DEGRADADOS}$(fila "$_nombre" "sin señal" "nunca ha latido")
"
            CAIDOS="$CAIDOS $_nombre"
            HUELLA="$HUELLA$_nombre=sin-senal;"
            continue
        fi

        # Formato: <epoch> <estado> <ocupado|libre> <disco%|-> <ultimo_job|-> <motivo…>
        _linea="$(cat "$_f" 2>/dev/null || true)"
        _sello="${_linea%% *}"; _resto="${_linea#* }"
        _est="${_resto%% *}";   _resto="${_resto#* }"
        _act="${_resto%% *}";   _resto="${_resto#* }"
        _disco="${_resto%% *}"; _resto="${_resto#* }"
        _ult="${_resto%% *}"
        _motivo="${_resto#* }"
        [ "$_motivo" = "$_ult" ] && _motivo=""
        case "$_sello" in ''|*[!0-9]*) _sello=0 ;; esac
        case "$_disco" in ''|*[!0-9]*) _disco="" ;; esac
        case "$_ult"   in ''|*[!0-9]*) _ult="" ;; esac

        # El disco es del sistema de ficheros, así que en la práctica es del HOST:
        # todos los runners de una máquina devuelven lo mismo. Se queda el mayor y
        # se reporta UNA vez, en vez de repetir la misma cifra en cada fila.
        if [ -n "$_disco" ] && [ "$_disco" -gt "${DISCO_PICO:-0}" ]; then
            DISCO_PICO="$_disco"
        fi

        _edad=$(( _ahora - _sello ))
        if [ "$_edad" -gt "$RANCIO" ]; then
            # Nadie ha actualizado el fichero: el contenedor está parado, borrado
            # o colgado. No podemos distinguir cuál, y operativamente da igual.
            DEGRADADOS="${DEGRADADOS}$(fila "$_nombre" "caído" "sin latido desde hace ${_edad}s")
"
            CAIDOS="$CAIDOS $_nombre"
            HUELLA="$HUELLA$_nombre=caido;"
            continue
        fi

        case "$_est" in
            sano)
                SANOS="${SANOS}$(fila "$_nombre" "sano" "$_act$(cuando "$_ult" "$_ahora" "$_act")")
"
                ONLINE=$(( ONLINE + 1 ))
                HUELLA="$HUELLA$_nombre=ok;"
                ;;
            arrancando)
                # Estado normal y transitorio (backoff anti crash-loop, config.sh
                # en curso). No cuenta como caído: no hay nada que arreglar.
                SANOS="${SANOS}$(fila "$_nombre" "arrancando" "todavía no toma jobs")
"
                HUELLA="$HUELLA$_nombre=arrancando;"
                ;;
            *)
                [ -n "$_motivo" ] || _motivo="el runner reporta '$_est'"
                DEGRADADOS="${DEGRADADOS}$(fila "$_nombre" "atascado" "$_motivo")
"
                CAIDOS="$CAIDOS $_nombre"
                HUELLA="$HUELLA$_nombre=atascado;"
                ;;
        esac
    done

    CAIDOS="${CAIDOS# }"

    # El disco que el vigía mide por su cuenta (ver DISCO_RUTA). Se queda el PEOR
    # de los dos, no el suyo: si un runner reporta más ocupación que el host, ese
    # es el que va a reventar, y quedarse con el último medido lo taparía.
    # `df -P` fuerza el formato POSIX en una línea, igual que en latido.sh: sin
    # -P, un punto de montaje largo se parte en dos y el porcentaje cae en otra
    # columna.
    if [ -n "$DISCO_RUTA" ]; then
        _dh="$(df -P "$DISCO_RUTA" 2>/dev/null | awk 'NR==2 { gsub(/%/, "", $5); print $5 }')"
        case "$_dh" in ''|*[!0-9]*) _dh="" ;; esac
        if [ -n "$_dh" ] && [ "$_dh" -gt "${DISCO_PICO:-0}" ]; then
            DISCO_PICO="$_dh"
        fi
    fi

    # Latidos huérfanos: al bajar de 5 runners a 3, los dos ficheros que sobran
    # no deben alarmar ni ensuciar. Manda el censo.
    for _f in "$LATIDOS_DIR"/*; do
        [ -f "$_f" ] || continue
        _b="$(basename "$_f")"
        case "$_b" in .*) continue ;; esac
        _conocido="no"
        for _nombre in $RUNNERS; do
            [ "$_b" = "$(sanear "$_nombre")" ] && { _conocido="si"; break; }
        done
        [ "$_conocido" = "no" ] && rm -f "$_f" 2>/dev/null
    done

    # ---- Estado global -----------------------------------------------------
    # Tres niveles, y el criterio no es cuántos fallan sino si la CI sigue
    # corriendo: con un runner sano los jobs salen, más lentos. Colapsar eso a
    # binario obliga a elegir entre gritar por nada o callar cuando importa.
    ESTADO="sano"
    if [ -n "$CAIDOS" ]; then
        if [ "$ONLINE" -ge "$MINIMO" ]; then ESTADO="parcial"; else ESTADO="degradado"; fi
    fi

    AVISO_RELOJ=""
    if [ -n "$DESFASE" ]; then
        _abs="$DESFASE"; [ "$_abs" -lt 0 ] && _abs=$(( -_abs ))
        if [ "$_abs" -gt "$DESFASE_MAX" ]; then
            # A rojo directo aunque los runners se declaren sanos: es el fallo del
            # 1 de agosto, donde todo figuraba «Up» y nada tomaba jobs.
            ESTADO="degradado"
            AVISO_RELOJ="  DESFASADO ${_abs}s: el runner renovará su credencial fuera de plazo y GitHub la rechazará."
            HUELLA="${HUELLA}reloj=desfasado;"
        fi
    fi

    # Disco: como el reloj, es un fallo que NO se ve mirando los runners —todos
    # dicen «sano» hasta que un job revienta con un error que no señala la causa—.
    # Empuja a `parcial` y no a `degradado`: la CI aún corre, pero hay que actuar
    # antes de que deje de hacerlo.
    AVISO_DISCO=""
    if [ -n "$DISCO_PICO" ] && [ "$DISCO_PICO" -ge "$DISCO_MAX" ]; then
        [ "$ESTADO" = "degradado" ] || ESTADO="parcial"
        AVISO_DISCO="  DISCO AL ${DISCO_PICO}%: los jobs empezarán a fallar con errores que no lo señalan."
        HUELLA="${HUELLA}disco=lleno;"
    fi

    # Un hook sin permiso de ejecución se ignoraría en silencio y creerías tener
    # avisos que no tienes. Se nombra en el informe. Pasa de verdad: el bit de
    # ejecución puede no sobrevivir a un bind mount desde Windows.
    SIN_PERMISO=""
    if [ -d "$HOOKS_DIR" ]; then
        for _h in "$HOOKS_DIR"/*; do
            [ -f "$_h" ] || continue
            case "$_h" in *.ejemplo) continue ;; esac
            [ -x "$_h" ] || SIN_PERMISO="$SIN_PERMISO $(basename "$_h")"
        done
    fi

    # ---- Informe -----------------------------------------------------------
    INFORME="$(
        printf 'Fleet %s — %s/%s en línea\n' "$CLUSTER" "$ONLINE" "$ESPERADOS"
        [ -n "$DEGRADADOS" ] && printf '\nDEGRADADO\n%s' "$DEGRADADOS"
        [ -n "$SANOS" ]      && printf '\nEN LÍNEA\n%s' "$SANOS"
        printf '\n'
        if [ -n "$DESFASE" ]; then
            printf 'Reloj: %+d s vs GitHub\n' "$DESFASE"
            [ -n "$AVISO_RELOJ" ] && printf '%s\n' "$AVISO_RELOJ"
        else
            printf 'Reloj: no medido (sin red o sin `date` compatible)\n'
        fi
        if [ -n "$DISCO_PICO" ]; then
            printf 'Disco: %s%% usado\n' "$DISCO_PICO"
            [ -n "$AVISO_DISCO" ] && printf '%s\n' "$AVISO_DISCO"
        fi
        [ -n "$SIN_PERMISO" ] && printf 'Hooks ignorados (sin permiso de ejecución):%s\n' "$SIN_PERMISO"
        printf 'Máquina: %s · Comprobado: %s\n' "$HOSTNAME_CORTO" "$(date -u '+%Y-%m-%d %H:%M:%SZ')"
    )"

    # A stdout SIEMPRE: en un contenedor stdout es el registro, así que
    # `podman compose logs vigia` da el historial sin montar nada más.
    printf '%s\n' "$INFORME"

    [ "$SOLO_INFORME" = "yes" ] && return 0

    # ---- ¿Cambió algo desde la ronda anterior? -----------------------------
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

    # ---- Hooks -------------------------------------------------------------
    export VIGILAR_ESTADO="$ESTADO"          # sano | parcial | degradado
    export VIGILAR_CAMBIO="$CAMBIO"
    # Distingue "es la primera ronda" de "se ha recuperado". Sin esto un hook no
    # puede saberlo —las dos llegan con estado sano y cambio si—, y el primer aviso
    # tras instalar diría "runners de vuelta" sin que se hubiera ido nadie.
    export VIGILAR_PRIMERA="$PRIMERA"
    export VIGILAR_CAIDOS="$CAIDOS"
    export VIGILAR_HOST="$HOSTNAME_CORTO"
    export VIGILAR_CLUSTER="$CLUSTER"
    export VIGILAR_ONLINE="$ONLINE"
    export VIGILAR_ESPERADOS="$ESPERADOS"
    # La cadencia viaja a los hooks para que puedan derivar sus propios umbrales
    # de ella (el de healthchecks.io calcula así el periodo y el margen del check)
    # en vez de llevar constantes que se desincronizan al cambiar --vigilar-cada.
    export VIGILAR_CADA="$CADA"

    if [ ! -d "$HOOKS_DIR" ]; then
        info "No hay directorio de hooks ($HOOKS_DIR); nadie recibirá el informe."
        return 0
    fi

    # `timeout` evita que un hook colgado (una API que no responde) atasque la
    # ronda siguiente. Nunca se corre sin límite: en macOS no hay `timeout` en el
    # sistema base —la elegancia del `command -v` dejaba el guard cumplido y los
    # hooks sueltos—, así que se busca también el `gtimeout` de coreutils y, sin
    # ninguno de los dos, lo impone `con_limite`.
    TIMEOUT="con_limite 15"
    if command -v timeout >/dev/null 2>&1; then
        TIMEOUT="timeout 15"
    elif command -v gtimeout >/dev/null 2>&1; then
        TIMEOUT="gtimeout 15"
    fi

    # Orden lexicográfico: el prefijo numérico decide quién habla primero. El
    # latido va con 10- a propósito, para que un hook roto más abajo no retrase la
    # señal de vida. Un hook que falla NO impide los siguientes.
    _alguno="no"
    for _hook in "$HOOKS_DIR"/*; do
        [ -f "$_hook" ] && [ -x "$_hook" ] || continue
        _alguno="yes"
        _rc=0
        # shellcheck disable=SC2086
        printf '%s\n' "$INFORME" | $TIMEOUT "$_hook" >/dev/null 2>&1 || _rc=$?
        [ "$_rc" -eq 0 ] || info "AVISO: el hook '$(basename "$_hook")' falló (rc=$_rc); sigo con los demás."
    done

    # Los hooks presentes pero sin `+x` ya se nombran en el informe (SIN_PERMISO,
    # más arriba). Este mensaje cubre el caso distinto y peor: que el directorio
    # se vea VACÍO desde el contenedor. En Linux con SELinux, un bind mount sin
    # `:z` deja al contenedor sin poder leerlo, y entonces no hay ni ficheros que
    # nombrar. Por eso se dice la ruta: es lo que permite comprobarlo con
    # `podman compose exec vigia ls -la <ruta>`.
    [ "$_alguno" = "no" ] && info "No hay hooks ejecutables en $HOOKS_DIR; nadie recibirá el informe."
    return 0
}

if [ "$BUCLE" = "yes" ]; then
    # Una ronda que falle no puede matar al vigía: sería quedarse sin vigilancia
    # justo cuando algo va mal.
    while : ; do
        ronda || info "AVISO: la ronda falló; reintento en ${CADA}s."
        sleep "$CADA"
    done
else
    ronda
fi

# Verde siempre: un fleet degradado no es un fallo de la vigilancia; avisar de él
# ES su trabajo.
exit 0
