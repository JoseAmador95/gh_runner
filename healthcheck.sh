#!/bin/sh
# ============================================================================
# healthcheck.sh — corre DENTRO del contenedor (HEALTHCHECK del Containerfile).
#
# Responde a UNA sola pregunta: ¿este runner está atascado sin poder hablar con
# GitHub? Es el fallo que `restart: always` NO cubre, porque el proceso sigue
# vivo: el runner entra en "Retrying until reconnected" —un bucle del que no
# sale nunca— y el contenedor figura "Up" sin tomar un solo job.
#
# Caso real que motiva esto: el reloj del host iba 32 minutos atrasado, así que
# el runner renovaba su credencial tarde SIEMPRE, GitHub la rechazaba y el
# contenedor se quedó "Up" e inútil durante horas sin que nadie se enterase.
#
# Salida: 0 = sano · 1 = atascado (el motor lo marca `unhealthy`). Lo que
# imprima se guarda en `.State.Health.Log`, así que el motivo viaja hasta el
# informe del host: `vigilar.sh` lo lee de ahí y lo pone en el mensaje.
#
# PRINCIPIO DE DISEÑO: solo busca EVIDENCIA POSITIVA DE FALLO. NO exige ver
# "Listening for Jobs", porque un runner ejecutando un job está sano y no está
# escuchando. Fallar en abierto es lo correcto: un falso `unhealthy` despierta a
# alguien de madrugada para nada, y eso quema la alerta entera.
# ============================================================================
set -u

DIAG="${RUNNER_DIAG_DIR:-/home/runner/_diag}"

# Ventana de observación en minutos. Solo cuentan las líneas escritas dentro de
# ella: un error superado hace rato NO puede dejar el contenedor en rojo para
# siempre. `entrypoint.sh` vacía _diag en cada arranque, así que el log ya es
# del ciclo actual; esto acota además dentro del propio ciclo.
VENTANA_MIN="${RUNNER_HEALTH_VENTANA_MIN:-5}"

# El log más reciente del Listener. Los Worker_*.log (un job en curso) se
# excluyen a propósito: ahí viven los fallos DEL JOB, que no son cosa nuestra.
log="$(ls -1t "$DIAG"/Runner_*.log 2>/dev/null | head -n1)"

# Sin log todavía = arranque en curso (o backoff anti crash-loop, que puede
# durar minutos). Sano: --start-period cubre este hueco.
[ -n "$log" ] || exit 0

# Corte de la ventana en el MISMO formato que el prefijo del log
# ("[2026-08-01 11:16:01Z INFO Listener] ..."), para poder comparar como texto:
# el formato ISO ordena lexicográficamente. Si `date -d` no existe, se compara
# sin ventana (peor: más sensible; nunca menos).
corte="$(date -u -d "-${VENTANA_MIN} minutes" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '')"

motivo="$(
    tail -n 500 "$log" 2>/dev/null | awk -v corte="$corte" '
        # Sello de tiempo = los 19 caracteres tras el "[" inicial.
        substr($0, 1, 1) == "[" {
            ts = substr($0, 2, 19)
            fuera = (corte != "" && ts < corte)
        }
        fuera { next }
        # Orden a propósito: el último que casa gana, y en la línea del fallo
        # real casan varios a la vez. "Retrying until reconnected" es la firma
        # del atasco (el bucle sin salida), así que va la última.
        /Access denied|Not authorized/ { m = "GitHub rechaza la credencial" }
        /Runner connect error/         { m = "no conecta con GitHub" }
        /Retrying until reconnected/   { m = "atascado reconectando con GitHub" }
        END { if (m != "") print m }
    '
)"

if [ -n "$motivo" ]; then
    # Este texto acaba en el informe del host; que se lea como una frase.
    printf '%s\n' "$motivo"
    exit 1
fi

exit 0
