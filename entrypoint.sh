#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# entrypoint.sh — arranca un runner de GitHub Actions autohospedado y EFÍMERO.
#
# Variables de entorno esperadas (se inyectan con -e / env_file al arrancar):
#   ACCESS_TOKEN  -> (recomendado) PAT con permiso Administration:R/W sobre el
#                    repo. El contenedor lo usa para generar un token de
#                    registro FRESCO en cada arranque vía la API de GitHub, de
#                    modo que el auto-reinicio funciona indefinidamente.
#   REPO_USER     -> owner del repositorio (obligatorio)
#   REPO_NAME     -> nombre del repositorio (obligatorio)
#   RUNNER_NAME   -> nombre del runner (opcional; por defecto hostname-owner-repo)
#   RUNNER_LABELS -> etiquetas extra separadas por comas (opcional). GitHub ya
#                    añade solo: self-hosted, Linux y la arquitectura (X64/ARM64).
#   RUNNER_GROUP  -> grupo del runner (opcional)
#   GITHUB_API_URL-> base de la API (opcional; por defecto https://api.github.com)
#
#   RUNNER_TOKEN  -> (LEGACY) token de registro directo. Solo se usa si NO hay
#                    ACCESS_TOKEN. Caduca en ~1h, así que el auto-reinicio se
#                    rompe pasada una hora. Preferir siempre ACCESS_TOKEN.
# ============================================================================

: "${REPO_USER:?Falta REPO_USER (owner del repositorio)}"
: "${REPO_NAME:?Falta REPO_NAME (nombre del repositorio)}"

API="${GITHUB_API_URL:-https://api.github.com}"
REPO_URL="https://github.com/${REPO_USER}/${REPO_NAME}"
# RUNNER_NAME se usa TAL CUAL si viene dado (deploy.sh ya pasa el nombre final).
# Solo cuando no se proporciona se genera un default único por host + repo.
RUNNER_NAME="${RUNNER_NAME:-$(hostname)-${REPO_USER}-${REPO_NAME}}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,ubuntu-24.04}"
RUNNER_GROUP="${RUNNER_GROUP:-}"

cd /home/runner

# Asegura que los mountpoints de volúmenes pertenezcan a runner. Un volumen
# nombrado recién creado sobre un dir que NO existía en la imagen se monta como
# root; basta un chown no-recursivo del mountpoint (lo que escriba runner
# después ya nace con el dueño correcto). _work y .cache ya vienen con dueño
# runner desde la imagen, así que se saltan. CACHE_DIRS lo puebla deploy.sh.
for _d in /home/runner/_work /home/runner/.cache ${CACHE_DIRS:-}; do
    [ -d "$_d" ] || continue
    [ -O "$_d" ] || sudo chown runner:runner "$_d" 2>/dev/null || true
done

# ---------------------------------------------------------------------------
# mint_token <registration-token|remove-token>
# Genera un token corto usando el PAT. Imprime SOLO el token por stdout; los
# errores van por stderr. No filtra el PAT ni el cuerpo completo a los logs.
# ---------------------------------------------------------------------------
mint_token() {
    local kind="$1" http body token tmp
    tmp="$(mktemp)"
    http="$(curl -sSL -o "$tmp" -w '%{http_code}' \
        -X POST \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "${API}/repos/${REPO_USER}/${REPO_NAME}/actions/runners/${kind}" \
        2>/dev/null || true)"
    body="$(cat "$tmp")"; rm -f "$tmp"
    if [ "$http" != "201" ] && [ "$http" != "200" ]; then
        echo "ERROR: la API de GitHub (${kind}) devolvió HTTP ${http:-000}." >&2
        echo "  $(printf '%s' "$body" | jq -r '.message // "sin mensaje"' 2>/dev/null)" >&2
        return 1
    fi
    token="$(printf '%s' "$body" | jq -r '.token // empty')"
    if [ -z "$token" ]; then
        echo "ERROR: no vino ningún token en la respuesta de ${kind}." >&2
        return 1
    fi
    printf '%s' "$token"
}

# ---- Leer un secret de fichero con fallback a sudo -------------------------
# Los file-secrets de compose se montan root:root 0400; el usuario 'runner' no
# puede leerlos, así que recurrimos al sudo sin contraseña de la imagen.
read_secret_file() {
    local f="$1"
    [ -f "$f" ] || return 1
    if [ -r "$f" ]; then cat "$f"; else sudo cat "$f"; fi
}

# Si no hay ACCESS_TOKEN explícito, intentar leerlo de un fichero:
# ACCESS_TOKEN_FILE o el secret por defecto /run/secrets/access_token.
if [ -z "${ACCESS_TOKEN:-}" ]; then
    _tok_file="${ACCESS_TOKEN_FILE:-/run/secrets/access_token}"
    if _tok="$(read_secret_file "$_tok_file" 2>/dev/null)"; then
        ACCESS_TOKEN="$(printf '%s' "$_tok" | tr -d '\r\n')"
        export ACCESS_TOKEN
        echo "PAT leído del secret ${_tok_file}."
    fi
fi

# ---- Resolver el token de registro ----------------------------------------
if [ -n "${ACCESS_TOKEN:-}" ]; then
    echo "Generando un token de registro fresco vía PAT..."
    REG_TOKEN="$(mint_token registration-token)"
elif [ -n "${RUNNER_TOKEN:-}" ]; then
    echo "AVISO: usando RUNNER_TOKEN directo (caduca ~1h; el auto-reinicio se romperá)." >&2
    REG_TOKEN="${RUNNER_TOKEN}"
else
    echo "ERROR: define ACCESS_TOKEN, ACCESS_TOKEN_FILE, un secret access_token o RUNNER_TOKEN (legacy)." >&2
    exit 1
fi

# ---- Parada elegante + cleanup --------------------------------------------
# Un runner --ephemeral se auto-desregistra al completar su job: en ese caso
# run.sh sale con 0 y NO hay que borrar nada. deregister() solo aplica si nos
# paran estando idle/registrado. Para que `podman stop` sea limpio reenviamos la
# señal a run.sh en segundo plano; con RUNNER_MANUALLY_TRAP_SIG=1, run.sh instala
# su propio trap y convierte SIGTERM->SIGINT hacia Runner.Listener (drenaje
# ordenado). Sin esa variable run.sh NO reenvía la señal y el runner muere por
# SIGKILL sin desregistrarse.
RUNNER_PID=""
_terminating=0

forward_signal() {
    _terminating=1
    echo "Señal recibida: reenviando a run.sh para un apagado ordenado..." >&2
    [ -n "$RUNNER_PID" ] && kill -TERM "$RUNNER_PID" 2>/dev/null || true
}
trap forward_signal INT TERM

deregister() {
    echo "Desregistrando el runner (si sigue registrado)..." >&2
    if [ -n "${ACCESS_TOKEN:-}" ]; then
        local rt
        rt="$(mint_token remove-token 2>/dev/null || true)"
        [ -n "$rt" ] && ./config.sh remove --token "$rt" >/dev/null 2>&1 || true
    else
        # Con RUNNER_TOKEN legacy no se puede mintear un remove-token; se intenta
        # con el mismo token (funciona solo si aún no ha caducado).
        ./config.sh remove --token "${REG_TOKEN}" >/dev/null 2>&1 || true
    fi
}

# ---- Configurar (efímero: un job por registro) ----------------------------
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

./config.sh "${config_args[@]}"

# run.sh en segundo plano para poder reenviarle la señal en un `podman stop`.
export RUNNER_MANUALLY_TRAP_SIG=1
./run.sh &
RUNNER_PID=$!

# `wait` retorna al recibir una señal (el trap ya la reenvió a run.sh), así que
# reintentamos hasta que run.sh termine de verdad.
wait "$RUNNER_PID" 2>/dev/null || true
while kill -0 "$RUNNER_PID" 2>/dev/null; do
    wait "$RUNNER_PID" 2>/dev/null || true
done

# Solo desregistramos si nos pararon estando idle. En el camino efímero normal
# run.sh ya salió (el runner se auto-desregistró) y esto no se ejecuta.
[ "$_terminating" = "1" ] && deregister
exit 0
