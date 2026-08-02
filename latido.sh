#!/bin/sh
# ============================================================================
# latido.sh — corre DENTRO de cada runner, en segundo plano, y publica su estado
# en un volumen compartido para que el contenedor `vigia` lo lea.
#
# POR QUÉ ASÍ Y NO CONSULTANDO AL MOTOR: la alternativa era montar el socket de
# podman/docker en el vigía. Se descartó por dos motivos. (1) Deja de ser
# agnóstico: con podman en macOS el socket vive DENTRO de la VM y montarlo desde
# el host es frágil. (2) El socket es una API completa —quien lo alcanza puede
# arrancar un contenedor privilegiado y tomar el host— y estaría al lado de
# runners que ejecutan PRs de terceros.
#
# A cambio, el runner reporta cosas que desde fuera solo se deducen: si tiene un
# job en curso, en qué punto del arranque está, y el motivo exacto del atasco.
# Lo único que se pierde: distinguir «contenedor parado» de «nunca creado».
# Operativamente es la misma alerta — ese runner no reporta.
#
# Formato de la línea (una sola, reescrita cada ronda):
#
#     <epoch> <estado> <ocupado|libre> <disco%|-> <ultimo_job|-> <motivo…>
#
# Estados: arrancando · sano · atascado. La FRESCURA del fichero es la señal de
# vida: si el contenedor muere, deja de actualizarse y el vigía lo da por caído
# al pasar VIGIA_RANCIO. Por eso no hace falta ningún «adiós» al terminar.
#
# El motivo va SIEMPRE el último y es «todo lo que queda»: es el único campo de
# texto libre, así que cualquier campo nuevo se añade antes que él sin tocar el
# recorte de los demás.
# ============================================================================
set -u

DIR="${LATIDO_DIR:-/var/lib/gh-runner/latidos}"
CADA="${LATIDO_CADA:-30}"
CHECK="${LATIDO_HEALTHCHECK:-/home/runner/healthcheck.sh}"

# El fichero que config.sh deja al registrar el runner. Su ausencia es la señal
# de «todavía arrancando». Configurable para poder probarlo fuera del contenedor.
MARCA_CONFIG="${LATIDO_MARCA_CONFIG:-/home/runner/.runner}"

# El nombre del fichero es el que ve GitHub: es el que aparece en Settings ->
# Runners y el que reconoce quien lee el aviso. Se sanea porque acaba siendo un
# nombre de fichero.
NOMBRE="$(printf '%s' "${RUNNER_NAME:-runner}" | tr -c 'A-Za-z0-9_.-' '-')"

# ¿Hay un job corriendo? Sustituye al `podman top | grep Runner.Worker` que hacía
# el vigía desde el host. Se lee /proc directamente en vez de usar pgrep porque
# la imagen NO instala procps: el runner no lo necesita y no vamos a engordarla
# por esto.
ocupado() {
    for _c in /proc/[0-9]*/cmdline; do
        # Solo argv[0] (el ejecutable), no la línea entera: buscando en toda la
        # línea, cualquier proceso que MENCIONE la cadena —un script, el propio
        # grep— contaría como job en curso. Los campos van separados por NUL.
        case "$(tr '\0' '\n' < "$_c" 2>/dev/null | head -n1)" in
            */Runner.Worker|Runner.Worker) return 0 ;;
        esac
    done
    return 1
}

# Ocupación del disco donde vive _work, en porcentaje entero. Es el asesino
# silencioso de la CI: el volumen se llena, los jobs empiezan a fallar con
# errores que no señalan la causa, y desde fuera el runner sigue «sano».
# `df -P` fuerza el formato POSIX en una sola línea (sin -P, un punto de montaje
# largo se parte en dos y el porcentaje cae en otra columna).
TRABAJO="${LATIDO_TRABAJO:-/home/runner/_work}"
disco() {
    _d="$(df -P "$TRABAJO" 2>/dev/null | awk 'NR==2 { gsub(/%/, "", $5); print $5 }')"
    case "$_d" in ''|*[!0-9]*) printf '%s' '-' ;; *) printf '%s' "$_d" ;; esac
}

# Cuándo tomó este runner su último job. Se arrastra de la línea anterior en vez
# de guardarse aparte: así el dato vive donde vive el latido y no hay un segundo
# fichero que limpiar. Un runner «sano · libre» PARA SIEMPRE suele ser uno que se
# registró con la etiqueta equivocada y al que nadie le manda trabajo — desde
# fuera es indistinguible de uno sano, y este campo es lo que lo delata.
ultimo_job_previo() {
    _l="$(cat "${DIR}/${NOMBRE}" 2>/dev/null || true)"
    # Campo 5; si la línea es de un formato anterior, sale vacío o no numérico.
    _u="$(printf '%s' "$_l" | awk '{ print $5 }')"
    case "$_u" in ''|*[!0-9]*) printf '%s' '-' ;; *) printf '%s' "$_u" ;; esac
}

# Escritura atómica: el vigía puede leer en cualquier momento y nunca debe pillar
# media línea. `mv` dentro del mismo directorio (mismo sistema de ficheros) lo
# garantiza; un `>` directo, no.
_aviso_dado=0
escribir() {
    _tmp="${DIR}/.tmp.${NOMBRE}.$$"
    # El paréntesis NO es decorativo: si la redirección falla, el mensaje lo emite
    # el shell, no printf, así que un `2>/dev/null` pegado al printf no lo tapa y
    # el error se repetiría en cada ronda. La subshell mete la redirección dentro
    # del alcance silenciado, dejando un único aviso nuestro y legible.
    if ! ( printf '%s %s %s %s %s %s\n' "$(date -u +%s)" "$1" "$2" "$3" "$4" "${5:-}" > "$_tmp" ) 2>/dev/null; then
        # El caso real que esto delata: el volumen se montó con dueño root y el
        # usuario `runner` no puede escribir. Sin este aviso, el vigía diría que
        # TODOS los runners están caídos y nadie sabría por qué. Se avisa una vez
        # (va a `podman logs`), no en cada ronda.
        if [ "$_aviso_dado" -eq 0 ]; then
            echo "AVISO: no puedo escribir el latido en ${DIR}. El vigía dará este runner por caído." >&2
            _aviso_dado=1
        fi
        rm -f "$_tmp" 2>/dev/null || true
        return 0
    fi
    _aviso_dado=0
    mv -f "$_tmp" "${DIR}/${NOMBRE}" 2>/dev/null || rm -f "$_tmp" 2>/dev/null || true
}

while : ; do
    if [ ! -f "$MARCA_CONFIG" ]; then
        # Todavía sin configurar: backoff anti crash-loop (que puede durar hasta
        # 300 s) o config.sh en curso. Es un estado NORMAL y transitorio; sin
        # nombrarlo, un runner arrancando parecería uno muerto.
        escribir arrancando libre "$(disco)" "$(ultimo_job_previo)" ''
    else
        # healthcheck.sh es la fuente única del veredicto: se reutiliza tal cual
        # (0 = sano, 1 = atascado y el motivo por stdout) en vez de duplicar aquí
        # su lógica, que ya está probada en CI contra el fallo del 1 de agosto.
        _motivo="$("$CHECK" 2>/dev/null)" && _estado="sano" || _estado="atascado"
        if ocupado; then
            _oc="ocupado"
            _ult="$(date -u +%s)"     # hay job AHORA: este es el último
        else
            _oc="libre"
            _ult="$(ultimo_job_previo)"
        fi
        escribir "$_estado" "$_oc" "$(disco)" "$_ult" "$_motivo"
    fi
    sleep "$CADA"
done
