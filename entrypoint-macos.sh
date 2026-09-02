#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# entrypoint-macos.sh — arranca un runner de GitHub Actions EFÍMERO DENTRO de
# una VM de macOS (Tart) que se clona de una golden, hace un job y se destruye.
#
# El ciclo completo lo gobierna un supervisor en el HOST:
#
#   tart clone golden vm-N → tart run → [ESTE SCRIPT] → job → shutdown -h now
#   → `tart run` retorna → tart delete vm-N → repetir
#
# --- CÓMO ARRANCA ESTE SCRIPT, Y POR QUÉ NO POR SSH ------------------------
# Lo lanza un LaunchAgent horneado en la golden, dentro de la sesión GRÁFICA
# (inicio de sesión automático), con:
#
#     exec "/Volumes/My Shared Files/gh-runner/entrypoint-macos.sh"
#
# NO se lanza por `ssh`, y no es una preferencia de estilo. El workflow
# `movil-release.yml` de la app hace `security create-keychain`,
# `security set-key-partition-list` y `codesign`. Un proceso lanzado por ssh no
# pertenece a la sesión Aqua, y ahí el acceso al llavero se comporta distinto:
# `codesign` falla con `errSecInternalComponent`, o peor, abre un diálogo de
# autorización que en una VM sin nadie delante NADIE CONTESTA. El job no falla:
# se queda colgado hasta el timeout del workflow, que es el peor modo de fallo
# posible — gasta minutos de CI, ocupa la VM y no dice por qué.
#
# Si alguien "simplifica" esto a un `ssh vm ./entrypoint-macos.sh`, la firma de
# la app deja de funcionar. Es la razón de que exista el LaunchAgent.
#
# --- MONTAJES ---------------------------------------------------------------
# El supervisor pasa dos directorios del host con `tart run --dir=`:
#   gh-runner : SOLO LECTURA (`:ro`). Trae este script, mint.sh, latido.sh,
#               healthcheck.sh, el tarball actions-runner-osx-arm64-<ver>.tar.gz
#               y el fichero access_token (0600 en el host).
#   latidos   : lectura y escritura, donde latido.sh publica el estado.
# virtiofs los expone bajo /Volumes/My Shared Files/<nombre>.
#
# --- LO QUE A PROPÓSITO NO ESTÁ AQUÍ ---------------------------------------
# * `installdependencies.sh`: no existe en el tarball osx-arm64; es de Linux.
# * El backoff anti crash-loop de entrypoint.sh (.gh_runner_ok/_last/_fails):
#   se apoya en que el filesystem sobrevive al reinicio, y aquí la VM se
#   DESTRUYE cada ciclo. Esos marcadores morirían con ella y el backoff nunca
#   frenaría nada. Ese throttling vive en el host, en el supervisor, que es
#   quien sí persiste entre ciclos.
# * El reset de config huérfana (.runner/.credentials): una VM recién clonada
#   de la golden no puede tener config rancia de un ciclo anterior.
# * `sudo cat` del secret: no hay file-secrets de compose; el PAT llega por el
#   montaje y lo lee el propio usuario.
#
# Variables de entorno (del LaunchAgent o del .env del montaje; mismos nombres
# que entrypoint.sh, que son el contrato del repo):
#   ACCESS_TOKEN / ACCESS_TOKEN_FILE, REPO_USER, REPO_NAME, RUNNER_NAME,
#   RUNNER_LABELS, RUNNER_GROUP, GITHUB_API_URL, RUNNER_DISABLE_UPDATE.
#
# bash 3.2 a propósito: es el que trae macOS. Nada de `declare -A` ni de
# `${x,,}`/`${x^^}` (bash 4+); los arrays indexados sí existen en 3.2.
# ============================================================================

# Directorios del montaje. Variables sobreescribibles porque son el único
# gancho para probar este script fuera de una VM (el CI corre en Linux).
MONTAJE="${GH_RUNNER_MONTAJE:-/Volumes/My Shared Files/gh-runner}"
MONTAJE_LATIDOS="${GH_RUNNER_LATIDOS:-/Volumes/My Shared Files/latidos}"

# ---- Configuración del .env del montaje ------------------------------------
# El LaunchAgent puede pasar el entorno completo, pero editar un plist para
# cambiar una etiqueta es incómodo: se admite además un .env en el montaje de
# solo lectura, que el supervisor reescribe en el host sin tocar la golden.
# EL ENTORNO YA PRESENTE GANA: si el LaunchAgent (o el supervisor vía
# `tart run`) fijó una variable, un .env viejo del montaje no debe pisarla.
cargar_env() {
    local fichero="$1" linea clave valor
    [ -f "$fichero" ] || return 0
    # El `|| [ -n "$linea" ]` rescata la última línea si el fichero no termina
    # en salto de línea; sin él, esa línea se pierde en silencio.
    while IFS= read -r linea || [ -n "$linea" ]; do
        linea="${linea%$'\r'}"                       # tolera CRLF
        case "$linea" in ''|'#'*) continue ;; esac
        linea="${linea#export }"
        case "$linea" in *=*) : ;; *) continue ;; esac
        clave="${linea%%=*}"
        valor="${linea#*=}"
        case "$clave" in ''|*[!A-Za-z0-9_]*) continue ;; esac
        case "$valor" in
            \"*\") valor="${valor#\"}"; valor="${valor%\"}" ;;
            \'*\') valor="${valor#\'}"; valor="${valor%\'}" ;;
        esac
        if [ -n "${!clave:-}" ]; then continue; fi
        export "$clave=$valor"
    done < "$fichero"
}
cargar_env "${MONTAJE}/.env"

: "${REPO_USER:?Falta REPO_USER (owner del repositorio)}"
: "${REPO_NAME:?Falta REPO_NAME (nombre del repositorio)}"

REPO_URL="https://github.com/${REPO_USER}/${REPO_NAME}"
RUNNER_NAME="${RUNNER_NAME:-$(hostname)-${REPO_USER}-${REPO_NAME}}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,macOS,ARM64}"
# Igual que en Linux: la etiqueta de host viaja APARTE para que solo pueda
# sumar. Dentro de RUNNER_LABELS borraría el default de arriba y un `runs-on`
# que casaba dejaría de casar.
[ -n "${RUNNER_HOST_LABEL:-}" ] && RUNNER_LABELS="${RUNNER_LABELS},${RUNNER_HOST_LABEL}"
RUNNER_GROUP="${RUNNER_GROUP:-}"
# Auto-update desactivado por defecto: un self-update a mitad de job lo cancela.
# Aquí la versión la fija la golden (hornear-macos.sh), no un update en caliente.
RUNNER_DISABLE_UPDATE="${RUNNER_DISABLE_UPDATE:-yes}"

# $HOME, NO /home/runner: en la golden el usuario es `admin` y su casa es
# /Users/admin. Una ruta de Linux aquí daría "no such file or directory" en el
# primer `cd` y la VM se apagaría sin haber tomado un job.
RUNNER_DIR="${RUNNER_DIR:-${HOME}/actions-runner}"

# ---- PAT ------------------------------------------------------------------
if [ -z "${ACCESS_TOKEN:-}" ]; then
    _tok_file="${ACCESS_TOKEN_FILE:-${MONTAJE}/access_token}"
    if [ -r "$_tok_file" ]; then
        ACCESS_TOKEN="$(tr -d '\r\n' < "$_tok_file")"
        export ACCESS_TOKEN
        echo "PAT leído de ${_tok_file}."
    fi
fi

# ---- Token de registro y desregistro (mint.sh, compartido) ----------------
# mint_token()/deregister() se sourcean del montaje en vez de copiarse aquí: lo
# delicado es el manejo de 429/403/Retry-After, y duplicado se desincroniza (ver
# la cabecera de mint.sh). Se sourcea DESPUÉS de fijar API/REPO_*, que es lo que
# esas funciones leen.
# shellcheck source=mint.sh
. "${MONTAJE}/mint.sh"

if [ -n "${ACCESS_TOKEN:-}" ]; then
    echo "Generando un token de registro fresco vía PAT..."
    REG_TOKEN="$(mint_token registration-token)"
elif [ -n "${RUNNER_TOKEN:-}" ]; then
    echo "AVISO: usando RUNNER_TOKEN directo (caduca ~1h)." >&2
    REG_TOKEN="${RUNNER_TOKEN}"
else
    echo "ERROR: define ACCESS_TOKEN, ACCESS_TOKEN_FILE o un access_token en ${MONTAJE}." >&2
    exit 1
fi

# ---- Apagado de la VM = fin del ciclo -------------------------------------
# Que `tart run` RETORNE es la única señal de «ciclo terminado» que tiene el
# supervisor del host: es lo que le deja hacer `tart delete` y clonar la VM
# siguiente. Si este script sale sin apagar, `tart run` se queda corriendo con
# una VM encendida y ociosa para siempre, y el supervisor no lanza el relevo:
# el fleet se para sin que falle nada. Por eso el apagado va en una trampa EXIT
# y no al final del flujo feliz — un `set -e` disparado a mitad también tiene
# que apagar.
apagar_vm() {
    echo "Ciclo terminado; apagando la VM para que 'tart run' retorne..." >&2
    sudo shutdown -h now || \
        echo "AVISO: 'shutdown' falló; el supervisor tendrá que forzar el ciclo." >&2
}
trap apagar_vm EXIT

# ---- Desempaquetar el agente ----------------------------------------------
# El tarball viaja en el montaje de solo lectura (no dentro de la golden) para
# poder subir de versión sin re-hornear la imagen de 40 GB.
mkdir -p "$RUNNER_DIR"
_tarball=""
for _t in "${MONTAJE}"/actions-runner-osx-arm64-*.tar.gz; do
    [ -f "$_t" ] && _tarball="$_t"
done
if [ -n "$_tarball" ]; then
    echo "Desempaquetando $(basename "$_tarball") en ${RUNNER_DIR}..."
    tar -xzf "$_tarball" -C "$RUNNER_DIR"
elif [ ! -f "${RUNNER_DIR}/config.sh" ]; then
    echo "ERROR: no hay tarball osx-arm64 en ${MONTAJE} ni un agente ya horneado en ${RUNNER_DIR}." >&2
    exit 1
fi
# NADA de ./bin/installdependencies.sh: ese script no existe en el paquete
# osx-arm64 (es del de Linux) y llamarlo aborta el arranque.

cd "$RUNNER_DIR"

# ---- Gatekeeper: quitar la cuarentena -------------------------------------
# Todo lo que llega de un tarball descargado y de un montaje virtiofs arrastra
# el atributo extendido com.apple.quarantine. Con él, Gatekeeper mata
# Runner.Listener en cuanto arranca, y el mensaje no señala la causa: en el log
# del job solo se ve que el runner "se murió" sin traza. Recursivo y ANTES de
# config.sh, porque config.sh ya ejecuta binarios del propio agente: hacerlo
# después es hacerlo tarde.
xattr -dr com.apple.quarantine . 2>/dev/null || \
    echo "AVISO: no se pudo limpiar com.apple.quarantine; Gatekeeper podría matar al runner." >&2

# ---- Latido para el vigía --------------------------------------------------
# Escribe en el montaje de lectura/escritura, que es el que el host comparte con
# el vigía. Va antes de config.sh para que el estado «arrancando» exista mientras
# se registra; si el montaje no está, latido.sh avisa una vez y sigue sin dañar.
if [ -x "${MONTAJE}/latido.sh" ]; then
    LATIDO_DIR="${MONTAJE_LATIDOS}" \
    LATIDO_HEALTHCHECK="${MONTAJE}/healthcheck.sh" \
    LATIDO_MARCA_CONFIG="${RUNNER_DIR}/.runner" \
    LATIDO_TRABAJO="${RUNNER_DIR}/_work" \
    RUNNER_NAME="${RUNNER_NAME}" \
        "${MONTAJE}/latido.sh" &
fi

# ---- Parada elegante -------------------------------------------------------
# Un runner --ephemeral se auto-desregistra al completar su job; deregister()
# solo hace falta si nos paran antes (idle o drenando). Con
# RUNNER_MANUALLY_TRAP_SIG=1, run.sh instala su propio trap y convierte
# SIGTERM->SIGINT hacia Runner.Listener (drenaje ordenado); sin esa variable no
# reenvía nada y el runner muere sin desregistrarse, dejando un fantasma en la
# lista de GitHub que --replace solo limpiaría si el nombre se repite.
RUNNER_PID=""
_terminating=0

forward_signal() {
    _terminating=1
    echo "Señal recibida: reenviando a run.sh para un apagado ordenado..." >&2
    [ -n "$RUNNER_PID" ] && kill -TERM "$RUNNER_PID" 2>/dev/null || true
}
trap forward_signal INT TERM

# ---- Configurar (efímero: un job por registro) -----------------------------
config_args=(
    --url "${REPO_URL}"
    --token "${REG_TOKEN}"
    --name "${RUNNER_NAME}"
    --labels "${RUNNER_LABELS}"
    --work "_work"
    --unattended
    --replace
    --ephemeral
)
[ -n "${RUNNER_GROUP}" ] && config_args+=(--runnergroup "${RUNNER_GROUP}")
case "${RUNNER_DISABLE_UPDATE}" in
    0|no|false|off) : ;;
    *) config_args+=(--disableupdate) ;;
esac

./config.sh "${config_args[@]}"

# Si nos pidieron parar durante config.sh (el trap se difiere mientras corre en
# primer plano), no arranques un job: desregistra y sal — el trap EXIT apaga.
[ "$_terminating" = "1" ] && { deregister; exit 0; }

# run.sh en segundo plano para poder reenviarle la señal.
export RUNNER_MANUALLY_TRAP_SIG=1
./run.sh &
RUNNER_PID=$!

# `wait` retorna al recibir una señal (el trap ya la reenvió), así que se
# reintenta hasta que run.sh termine de verdad.
run_rc=0
wait "$RUNNER_PID" 2>/dev/null || run_rc=$?
while kill -0 "$RUNNER_PID" 2>/dev/null; do
    run_rc=0
    wait "$RUNNER_PID" 2>/dev/null || run_rc=$?
done

if [ "$_terminating" = "1" ]; then
    deregister
fi

echo "run.sh terminó con código ${run_rc}."
# La VM se apaga en el trap EXIT: aquí no hay nada más que hacer. El estado del
# ciclo (sano o fallido) lo juzga el supervisor del host, que es quien persiste.
exit 0
