#!/bin/sh
# ============================================================================
# mint.sh — habla con la API de GitHub para pedir y devolver tokens de runner.
# NO se ejecuta: se SOURCEA (`. /ruta/mint.sh`) y aporta dos funciones,
# mint_token() y deregister().
#
# POR QUÉ ES UN FICHERO APARTE: porque hay tres sitios que necesitan lo mismo —
# el entrypoint de Linux, el de dentro de la VM de macOS y el supervisor que la
# crea y destruye en el host— y la parte que comparten es justo la delicada. No
# es "pide un token": es qué hacer cuando GitHub responde 429, cuando responde
# 403 porque el rate limit llegó a cero, cuando manda Retry-After, cuando manda
# x-ratelimit-reset en vez de Retry-After, y cuándo NO hay que reintentar
# (un 404 no mejora reintentando; solo gasta cuota).
#
# Copiado en dos entrypoints, eso se desincroniza: se arregla un caso en uno y
# el otro se queda con la versión vieja. Y el síntoma no es un error, es un
# fleet que agota el rate limit del PAT y deja de registrar runners — que es lo
# que este manejo existe para evitar. Un solo fichero significa que arreglarlo
# una vez lo arregla en los tres.
#
# POSIX sh a propósito, sin `local`: lo sourcean shells distintos. entrypoint.sh
# es bash; los de macOS son sh, y macOS trae bash 3.2, así que aquí no puede
# entrar nada de bash 4+ (`declare -A`, `${x^^}`) ni `local`, que con shebang
# #!/bin/sh dispara SC3043 en shellcheck.
#
# Como sin `local` las variables son globales del que sourcea, todas las
# internas van con prefijo `_mt_`: sin él, un `max` o un `body` de aquí pisaría
# el del script anfitrión en silencio.
#
# Variables de entorno que espera de quien lo sourcea:
#   ACCESS_TOKEN  -> PAT con Administration:R/W sobre el repo
#   REPO_USER / REPO_NAME -> owner y nombre del repo
#   API           -> base de la API (p. ej. https://api.github.com)
# ============================================================================

# ---------------------------------------------------------------------------
# mint_token <registration-token|remove-token> [max_reintentos]
# Genera un token corto usando el PAT. Imprime SOLO el token por stdout; los
# errores van por stderr. No filtra el PAT ni el cuerpo completo a los logs.
# ---------------------------------------------------------------------------
mint_token() {
    _mt_kind="$1"; _mt_max="${2:-4}"; _mt_attempt=0
    # Inicializadas aquí porque sin `local` sobreviven a la llamada anterior:
    # arrastrar el `retry` de un rate limit previo daría una espera fantasma.
    _mt_http=''; _mt_body=''; _mt_token=''; _mt_tmp=''; _mt_hdr=''
    _mt_retry=''; _mt_reset=''; _mt_remain=''; _mt_wait_s=''
    while :; do
        # mktemp CON plantilla: el `mktemp` a secas de BSD (macOS) exige -t o
        # una plantilla y falla sin ella. Esta forma vale en GNU y en BSD.
        _mt_tmp="$(mktemp "${TMPDIR:-/tmp}/gh-runner.XXXXXX")"
        _mt_hdr="$(mktemp "${TMPDIR:-/tmp}/gh-runner.XXXXXX")"
        _mt_http="$(curl -sSL -D "$_mt_hdr" -o "$_mt_tmp" -w '%{http_code}' \
            -X POST \
            -H "Accept: application/vnd.github+json" \
            -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "${API}/repos/${REPO_USER}/${REPO_NAME}/actions/runners/${_mt_kind}" \
            2>/dev/null || true)"
        _mt_body="$(cat "$_mt_tmp")"

        if [ "$_mt_http" = "201" ] || [ "$_mt_http" = "200" ]; then
            _mt_token="$(printf '%s' "$_mt_body" | jq -r '.token // empty')"
            rm -f "$_mt_tmp" "$_mt_hdr"
            if [ -z "$_mt_token" ]; then echo "ERROR: sin token en la respuesta de ${_mt_kind}." >&2; return 1; fi
            printf '%s' "$_mt_token"; return 0
        fi

        # ¿Rate limit? 429, o 403 con x-ratelimit-remaining:0 o con Retry-After.
        _mt_remain="$(grep -i '^x-ratelimit-remaining:' "$_mt_hdr" | tail -1 | tr -dc '0-9')"
        if [ "$_mt_http" = "429" ] \
           || { [ "$_mt_http" = "403" ] && [ "${_mt_remain:-1}" = "0" ]; } \
           || { [ "$_mt_http" = "403" ] && grep -qi '^retry-after:' "$_mt_hdr"; }; then
            _mt_retry="$(grep -i '^retry-after:' "$_mt_hdr" | tail -1 | tr -dc '0-9')"
            if [ -z "$_mt_retry" ]; then
                _mt_reset="$(grep -i '^x-ratelimit-reset:' "$_mt_hdr" | tail -1 | tr -dc '0-9')"
                [ -n "$_mt_reset" ] && _mt_retry=$(( _mt_reset - $(date +%s) ))
            fi
            case "$_mt_retry" in ''|*[!0-9]*) _mt_retry=$(( (_mt_attempt + 1) * 15 )) ;; esac
            [ "$_mt_retry" -lt 1 ] && _mt_retry=15
            [ "$_mt_retry" -gt 300 ] && _mt_retry=300
            rm -f "$_mt_tmp" "$_mt_hdr"
            if [ "$_mt_attempt" -ge "$_mt_max" ]; then
                echo "ERROR: rate limit de GitHub persistente en ${_mt_kind}; me rindo tras ${_mt_attempt} reintento(s)." >&2
                return 1
            fi
            _mt_attempt=$(( _mt_attempt + 1 ))
            echo "Rate limit de GitHub (HTTP ${_mt_http}); reintento ${_mt_attempt}/${_mt_max} en ${_mt_retry}s..." >&2
            sleep "$_mt_retry"
            continue
        fi

        # 5xx o fallo de red/DNS/TLS (http=000/vacío): transitorio → reintentar
        # in-process en vez de salir y depender del restart (evita churn del
        # contenedor por un blip); mantiene 401/403-perm/404 como fail-fast abajo.
        case "${_mt_http:-000}" in
            5[0-9][0-9]|000)
                rm -f "$_mt_tmp" "$_mt_hdr"
                if [ "$_mt_attempt" -ge "$_mt_max" ]; then
                    echo "ERROR: ${_mt_kind} falló por error transitorio (HTTP ${_mt_http:-000}) tras ${_mt_attempt} reintento(s)." >&2
                    return 1
                fi
                _mt_attempt=$(( _mt_attempt + 1 ))
                _mt_wait_s=$(( _mt_attempt * 5 ))
                echo "Error transitorio de GitHub (HTTP ${_mt_http:-000}); reintento ${_mt_attempt}/${_mt_max} en ${_mt_wait_s}s..." >&2
                sleep "$_mt_wait_s"
                continue
                ;;
        esac

        # Error real (no rate limit): no reintentar.
        echo "ERROR: la API de GitHub (${_mt_kind}) devolvió HTTP ${_mt_http:-000}." >&2
        echo "  $(printf '%s' "$_mt_body" | jq -r '.message // "sin mensaje"' 2>/dev/null)" >&2
        rm -f "$_mt_tmp" "$_mt_hdr"
        return 1
    done
}

# ---------------------------------------------------------------------------
# deregister — quita el runner del lado de GitHub si sigue registrado.
# Se ejecuta desde el directorio del agente (donde vive config.sh).
# ---------------------------------------------------------------------------
deregister() {
    echo "Desregistrando el runner (si sigue registrado)..." >&2
    if [ -n "${ACCESS_TOKEN:-}" ]; then
        _mt_rt="$(mint_token remove-token 0 2>/dev/null || true)"   # sin reintentos: no demorar el stop
        [ -n "$_mt_rt" ] && ./config.sh remove --token "$_mt_rt" >/dev/null 2>&1 || true
    else
        # Con RUNNER_TOKEN legacy no se puede mintear un remove-token; se intenta
        # con el mismo token (funciona solo si aún no ha caducado).
        ./config.sh remove --token "${REG_TOKEN}" >/dev/null 2>&1 || true
    fi
}
