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
# Auto-update del runner DESACTIVADO por defecto: un self-update a mitad de job
# cancela el job y, al ser efímero, deja config local huérfana → crash-loop (ver
# el bloque de idempotencia más abajo). La versión se mantiene al día con el
# rebuild diario de la imagen + pull, no con self-update en caliente. Reactívalo
# con RUNNER_DISABLE_UPDATE=no si de verdad lo necesitas (ver README).
RUNNER_DISABLE_UPDATE="${RUNNER_DISABLE_UPDATE:-yes}"

cd /home/runner

# Limpia los logs _diag del ciclo anterior (ya capturados por `podman logs`);
# así no se acumulan en la capa del contenedor entre recreates.
rm -rf /home/runner/_diag/* 2>/dev/null || true

# Asegura que los mountpoints de volúmenes pertenezcan a runner. Un volumen
# nombrado recién creado sobre un dir que NO existía en la imagen se monta como
# root; basta un chown no-recursivo del mountpoint (lo que escriba runner
# después ya nace con el dueño correcto). _work y .cache ya vienen con dueño
# runner desde la imagen, así que se saltan. CACHE_DIRS lo puebla deploy.sh.
for _d in /home/runner/_work /home/runner/.cache ${CACHE_DIRS:-}; do
    [ -d "$_d" ] || continue
    [ -O "$_d" ] && continue
    sudo chown runner:runner "$_d" 2>/dev/null \
        || echo "AVISO: no se pudo ajustar el dueño de ${_d}; podría causar errores de permisos en el job." >&2
done

# ---- Backoff anti crash-loop (protege el rate limit de GitHub) -------------
# Cada arranque mintea un registration-token. Si el contenedor falla y
# restart:always lo relanza al instante, eso martillearía la API de GitHub y
# dispararía el rate limit. Distinguimos un ciclo SANO (marca .ok al terminar)
# de un crash-loop (fallo rápido sin .ok) y, en éste, esperamos con backoff
# exponencial. Los ficheros persisten entre restarts del mismo contenedor.
_ok="/home/runner/.gh_runner_ok"
_stamp="/home/runner/.gh_runner_last"
_fails="/home/runner/.gh_runner_fails"
_min_cycle=20
_now="$(date +%s)"
if [ -f "$_ok" ]; then
    rm -f "$_ok" "$_fails"          # el ciclo anterior terminó sano
elif [ -f "$_stamp" ]; then
    _last="$(cat "$_stamp" 2>/dev/null || echo 0)"
    case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
    _delta=$(( _now - _last ))
    if [ "$_delta" -ge 0 ] && [ "$_delta" -lt "$_min_cycle" ]; then
        _n="$(cat "$_fails" 2>/dev/null || echo 0)"
        case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
        _n=$(( _n + 1 )); echo "$_n" > "$_fails"
        if [ "$_n" -ge 5 ]; then _back=300; else _back=$(( 15 * (1 << (_n - 1)) )); fi
        _back=$(( _back + (RANDOM % 10) ))
        echo "Fallo rápido (#${_n}, ciclo previo ${_delta}s); esperando ${_back}s para no exceder el rate limit de GitHub..." >&2
        sleep "$_back"
    fi
fi
date +%s > "$_stamp"

# ---------------------------------------------------------------------------
# mint_token <registration-token|remove-token> [max_reintentos]
# Genera un token corto usando el PAT. Imprime SOLO el token por stdout; los
# errores van por stderr. No filtra el PAT ni el cuerpo completo a los logs.
# ---------------------------------------------------------------------------
mint_token() {
    local kind="$1" max="${2:-4}" attempt=0 http body token tmp hdr retry reset remain wait_s
    while :; do
        tmp="$(mktemp)"; hdr="$(mktemp)"
        http="$(curl -sSL -D "$hdr" -o "$tmp" -w '%{http_code}' \
            -X POST \
            -H "Accept: application/vnd.github+json" \
            -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "${API}/repos/${REPO_USER}/${REPO_NAME}/actions/runners/${kind}" \
            2>/dev/null || true)"
        body="$(cat "$tmp")"

        if [ "$http" = "201" ] || [ "$http" = "200" ]; then
            token="$(printf '%s' "$body" | jq -r '.token // empty')"
            rm -f "$tmp" "$hdr"
            if [ -z "$token" ]; then echo "ERROR: sin token en la respuesta de ${kind}." >&2; return 1; fi
            printf '%s' "$token"; return 0
        fi

        # ¿Rate limit? 429, o 403 con x-ratelimit-remaining:0 o con Retry-After.
        remain="$(grep -i '^x-ratelimit-remaining:' "$hdr" | tail -1 | tr -dc '0-9')"
        if [ "$http" = "429" ] \
           || { [ "$http" = "403" ] && [ "${remain:-1}" = "0" ]; } \
           || { [ "$http" = "403" ] && grep -qi '^retry-after:' "$hdr"; }; then
            retry="$(grep -i '^retry-after:' "$hdr" | tail -1 | tr -dc '0-9')"
            if [ -z "$retry" ]; then
                reset="$(grep -i '^x-ratelimit-reset:' "$hdr" | tail -1 | tr -dc '0-9')"
                [ -n "$reset" ] && retry=$(( reset - $(date +%s) ))
            fi
            case "$retry" in ''|*[!0-9]*) retry=$(( (attempt + 1) * 15 )) ;; esac
            [ "$retry" -lt 1 ] && retry=15
            [ "$retry" -gt 300 ] && retry=300
            rm -f "$tmp" "$hdr"
            if [ "$attempt" -ge "$max" ]; then
                echo "ERROR: rate limit de GitHub persistente en ${kind}; me rindo tras ${attempt} reintento(s)." >&2
                return 1
            fi
            attempt=$(( attempt + 1 ))
            echo "Rate limit de GitHub (HTTP ${http}); reintento ${attempt}/${max} en ${retry}s..." >&2
            sleep "$retry"
            continue
        fi

        # 5xx o fallo de red/DNS/TLS (http=000/vacío): transitorio → reintentar
        # in-process en vez de salir y depender del restart (evita churn del
        # contenedor por un blip); mantiene 401/403-perm/404 como fail-fast abajo.
        case "${http:-000}" in
            5[0-9][0-9]|000)
                rm -f "$tmp" "$hdr"
                if [ "$attempt" -ge "$max" ]; then
                    echo "ERROR: ${kind} falló por error transitorio (HTTP ${http:-000}) tras ${attempt} reintento(s)." >&2
                    return 1
                fi
                attempt=$(( attempt + 1 ))
                wait_s=$(( attempt * 5 ))
                echo "Error transitorio de GitHub (HTTP ${http:-000}); reintento ${attempt}/${max} en ${wait_s}s..." >&2
                sleep "$wait_s"
                continue
                ;;
        esac

        # Error real (no rate limit): no reintentar.
        echo "ERROR: la API de GitHub (${kind}) devolvió HTTP ${http:-000}." >&2
        echo "  $(printf '%s' "$body" | jq -r '.message // "sin mensaje"' 2>/dev/null)" >&2
        rm -f "$tmp" "$hdr"
        return 1
    done
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
        rt="$(mint_token remove-token 0 2>/dev/null || true)"   # sin reintentos: no demorar el stop
        [ -n "$rt" ] && ./config.sh remove --token "$rt" >/dev/null 2>&1 || true
    else
        # Con RUNNER_TOKEN legacy no se puede mintear un remove-token; se intenta
        # con el mismo token (funciona solo si aún no ha caducado).
        ./config.sh remove --token "${REG_TOKEN}" >/dev/null 2>&1 || true
    fi
}

# ---- Reset de config local efímera huérfana --------------------------------
# Normalmente un runner --ephemeral borra su config local (.runner/.credentials)
# al terminar el job. Pero si algo corta el ciclo antes (un self-update que
# cancela el job, un crash, o "registration deleted"), run.sh sale SIN ese
# cleanup y la config rancia se queda. Como restart:always REUSA el mismo
# filesystem, el siguiente arranque la vería y config.sh abortaría con "already
# configured" → crash-loop perpetuo. Borramos SOLO los ficheros de registro del
# runner (NUNCA los marcadores .gh_runner_* del backoff); el lado servidor lo
# reconcilia --replace (mismo RUNNER_NAME) sin gastar una llamada extra a la API.
# rm -f es no-op en el primer arranque.
if [ -f /home/runner/.runner ] || [ -f /home/runner/.credentials ] || [ -f /home/runner/.credentials_rsaparams ]; then
    echo "Config local de un runner previo detectada; reseteándola para un registro limpio..." >&2
    rm -f /home/runner/.runner /home/runner/.credentials /home/runner/.credentials_rsaparams
fi

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
# Desactiva el auto-update del runner salvo opt-in explícito (no|0|false|off).
case "${RUNNER_DISABLE_UPDATE}" in
    0|no|false|off) : ;;
    *) config_args+=(--disableupdate) ;;
esac

./config.sh "${config_args[@]}"

# Si nos pidieron parar durante config.sh (el trap se difiere mientras config.sh
# corre en primer plano), no arranques un job: desregistra y sal limpio.
[ "$_terminating" = "1" ] && { deregister; exit 0; }

# run.sh en segundo plano para poder reenviarle la señal en un `podman stop`.
export RUNNER_MANUALLY_TRAP_SIG=1
./run.sh &
RUNNER_PID=$!

# `wait` retorna al recibir una señal (el trap ya la reenvió a run.sh), así que
# reintentamos hasta que run.sh termine de verdad, capturando su código de salida.
run_rc=0
wait "$RUNNER_PID" 2>/dev/null || run_rc=$?
while kill -0 "$RUNNER_PID" 2>/dev/null; do
    run_rc=0
    wait "$RUNNER_PID" 2>/dev/null || run_rc=$?
done

if [ "$_terminating" = "1" ]; then
    # Nos pararon (idle o drenando un job): desregistrar. No se marca .ok.
    deregister
elif [ "$run_rc" -eq 0 ]; then
    # Ciclo SANO: run.sh completó su job y salió 0 → el siguiente arranque no
    # aplicará backoff. (Un job de workflow que falla igual sale con 0.)
    : > "$_ok" 2>/dev/null || true
fi
# Si run.sh falló (run_rc != 0) sin parada: NO se marca .ok, para que el backoff
# throttlee un crash-loop en la etapa run.sh (sesión rechazada, "registration
# deleted", runner bajo el mínimo, 5xx) y evite una tormenta de tokens.
exit 0
