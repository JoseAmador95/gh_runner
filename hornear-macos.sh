#!/bin/sh
# ============================================================================
# hornear-macos.sh — construye y refresca la VM "golden" de Tart que usan los
# runners efímeros de macOS, y por separado el tarball del agente en el host.
#
# Corre EN EL HOST macOS (no dentro de una VM). El ciclo de un job, que lo
# gobierna un supervisor aparte, es: `tart clone` de la golden -> `tart run` ->
# job -> `tart delete`. Los clones son copy-on-write y casi gratis; lo caro es
# la golden, y este script es lo único que la toca.
#
# Dos modos independientes, y la razón de partirlos en dos es de disco y de
# cadencia, no de comodidad:
#
#   --completo   Rehace la golden entera: clona la base, la arranca, la
#                aprovisiona por ssh y la para. Cadencia esperada: SEMANAL
#                (solo cuando cambia Xcode o el toolchain).
#   --runner     Refresca SOLO el tarball de actions/runner en el directorio
#                del despliegue, en el HOST. NO toca la golden. Cadencia
#                esperada: DIARIA.
#
# Por qué el agente vive en el host y no horneado en la golden: GitHub exige
# una versión mínima del agente y la sube a menudo (igual que documenta el
# README para el runner de Linux). Si el binario viviera DENTRO de la golden,
# cada bump de versión obligaría a re-hornear 60-80 GB para cambiar un
# ejecutable de ~300 MB. Viviendo en el host, el invitado lo desempaqueta en
# segundos al arrancar (ver entrypoint-macos.sh) y la golden solo se re-hornea
# cuando de verdad cambia algo caro: el sistema o el toolchain.
#
# --provisionar RUTA_O_URL es el gancho de extensibilidad, y es la pieza que
# hace que este script sirva para cualquier proyecto sin forkearlo: es el
# equivalente exacto de un `FROM ghcr.io/joseamador95/gh_runner:latest` en un
# Containerfile derivado. Un consumidor (p. ej. sherman-svelte-runner, que
# necesita Node 22 + pnpm) pasa su propio script y este lo copia/descarga
# dentro de la VM y lo ejecuta por ssh. Este script NO sabe qué instala.
#
# PRESUPUESTO DE DISCO (el requisito duro; Mac mini M2, <500 GB libres):
#   caché OCI de la imagen base .... 50-60 GB  (se libera con `tart prune`)
#   VM golden aprovisionada ........ 60-80 GB
#   clon efímero de un job ......... 15-30 GB  (fuera del alcance de este script)
# Por eso --completo COMPRUEBA el espacio libre ANTES de clonar (fallar a
# mitad de un clon de 60 GB deja el disco peor que antes de empezar) y podA la
# caché OCI de la base al terminar (ya no hace falta: la golden es una copia
# completa, no depende de esa caché).
#
# BASE ELEGIDA: ghcr.io/cirruslabs/macos-sequoia-xcode:16.4 — un solo Xcode.
# NO uses macos-runner:tahoe: trae tres versiones de Xcode, ronda los 100 GB
# y este proyecto no cambia de versión de Xcode entre jobs.
#
# CREDENCIALES DE LA IMAGEN DE CIRRUS: usuario "admin", contraseña "admin".
# Son las credenciales de fábrica de CUALQUIER imagen de este catálogo (documen-
# tadas por Cirrus Labs), no un secreto de este despliegue, así que van en este
# comentario y no en un fichero protegido. Overrideables por env solo para
# pruebas (HORNEAR_SSH_USER / HORNEAR_SSH_PASS).
#
# Uso:
#   hornear-macos.sh --completo [--base REF] [--golden NOMBRE] \
#                     [--provisionar RUTA_O_URL] [--force]
#   hornear-macos.sh --runner
#
# Requisitos en el host: tart (brew install cirruslabs/cli/tart), curl, jq,
# shasum o sha256sum y, solo para --completo, sshpass (no está en homebrew-core
# por licencia; brew install hudochenkov/sshpass/sshpass).
# ============================================================================
set -eu

err()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*" >&2; }

# ---- Valores por defecto ----------------------------------------------------
BASE="ghcr.io/cirruslabs/macos-sequoia-xcode:16.4"
GOLDEN="gh-runner-golden"
PROVISIONAR=""
COMPLETO="no"
RUNNER="no"
FORCE="no"

# Credenciales de fábrica de la imagen (ver cabecera). Overrideables SOLO para
# pruebas con un arnés de ssh/sshpass falsos.
ADMIN_USER="${HORNEAR_SSH_USER:-admin}"
ADMIN_PASS="${HORNEAR_SSH_PASS:-admin}"

# Directorio del despliegue donde vive el tarball del agente en el HOST (lo
# lee entrypoint-macos.sh dentro de la VM, montado o copiado por el
# supervisor). Por defecto el directorio actual, igual que deploy.sh escribe
# compose.yaml/.env en el directorio desde el que se ejecuta.
RUNNER_DIR="${HORNEAR_RUNNER_DIR:-.}"

# Presupuesto de disco (GB) de la tabla de la cabecera, con margen sobre el
# techo de cada franja: 80 GB de golden aprovisionada + 10 de margen; 60 GB de
# caché OCI de la base (solo cuenta si la base AÚN NO está en caché local).
DISCO_GOLDEN_GB="${HORNEAR_DISCO_GOLDEN_GB:-90}"
DISCO_BASE_GB="${HORNEAR_DISCO_BASE_GB:-60}"

# `tart ip` falla hasta que la VM tiene red; el arranque tarda ~30-45 s. 40
# intentos * 5 s = 200 s, con margen sobre eso.
IP_INTENTOS="${HORNEAR_IP_INTENTOS:-40}"
IP_ESPERA_S="${HORNEAR_IP_ESPERA_S:-5}"

GH_API="${GH_API:-https://api.github.com}"
GH_RUNNER_REPO="actions/runner"

usage() {
    cat >&2 <<'EOF'
Uso: hornear-macos.sh [opciones]

Modos (al menos uno; se pueden combinar, --runner corre primero):
  --completo              Rehace la golden: clone -> run -> aprovisionar -> stop -> prune
  --runner                Refresca solo el tarball de actions/runner en el host

Opciones de --completo:
  --base REF              Imagen base OCI (por defecto ghcr.io/cirruslabs/macos-sequoia-xcode:16.4)
  --golden NOMBRE         Nombre de la VM golden en Tart (por defecto gh-runner-golden)
  --provisionar RUTA|URL  Script a ejecutar DENTRO de la golden por ssh (fichero local o URL)
  --force                 Rehace la golden aunque ya exista (si no, aborta)

  -h, --help              Esta ayuda

Variables de entorno:
  HORNEAR_SSH_USER / HORNEAR_SSH_PASS   Credenciales ssh (por defecto admin/admin)
  HORNEAR_RUNNER_DIR                    Directorio del tarball del agente (por defecto .)
  HORNEAR_DISCO_GOLDEN_GB / _BASE_GB    Umbrales de espacio libre requerido
  HORNEAR_IP_INTENTOS / _ESPERA_S       Reintentos de `tart ip` tras `tart run`
  GH_API                                Base de la API de GitHub (pruebas)
  GITHUB_TOKEN / GH_TOKEN               Si están, se usan para consultar la API (rate limit mayor)
EOF
    exit "${1:-0}"
}

# ---- Parseo de argumentos ---------------------------------------------------
while [ "$#" -gt 0 ]; do
    case "$1" in
        --base)          BASE="${2:?}"; shift 2 ;;
        --golden)        GOLDEN="${2:?}"; shift 2 ;;
        --provisionar)   PROVISIONAR="${2:?}"; shift 2 ;;
        --completo)      COMPLETO="yes"; shift ;;
        --runner)        RUNNER="yes"; shift ;;
        --force)         FORCE="yes"; shift ;;
        -h|--help)       usage 0 ;;
        *) err "opción desconocida: $1 (usa --help)" ;;
    esac
done

[ "$COMPLETO" = "yes" ] || [ "$RUNNER" = "yes" ] || usage 1

# Anti-inyección: estos valores acaban en comandos ssh/scp y en el nombre de
# la VM; nada de saltos de línea ni caracteres de control (mismo criterio que
# assert_clean en deploy.sh).
assert_sin_control() {
    _hm_ctrl="$(printf '%s' "$2" | LC_ALL=C tr -cd '[:cntrl:]' | wc -c | tr -dc '0-9')"
    if [ "${_hm_ctrl:-0}" -gt 0 ]; then
        err "valor inválido para $1: contiene saltos de línea o caracteres de control."
    fi
}
assert_sin_control base "$BASE"
assert_sin_control golden "$GOLDEN"
assert_sin_control provisionar "$PROVISIONAR"

if [ -n "$PROVISIONAR" ] && [ "$COMPLETO" != "yes" ]; then
    info "aviso: --provisionar se ignora sin --completo (no toca la golden)."
fi

# ---- Espacio en disco --------------------------------------------------------
# Directorio de Tart: ahí viven la caché OCI y las VMs (golden + clones), así
# que es el volumen que hay que medir. Si aún no existe (primera vez), se mide
# $HOME: df necesita una ruta que exista.
TART_DIR="${TART_HOME:-$HOME/.tart}"
[ -d "$TART_DIR" ] || TART_DIR="$HOME"

# Best-effort: si la base OCI ya aparece en `tart list`, ya está en caché
# local y clonar no vuelve a bajarla, así que no cuenta en el presupuesto. Si
# el formato de `tart list` cambiara y esto no la detectara, el resultado es
# solo pedir más margen del estrictamente necesario, nunca menos.
base_en_cache() {
    tart list 2>/dev/null | grep -F -- "$BASE" >/dev/null 2>&1
}

comprobar_espacio() {
    if base_en_cache; then
        _hm_req_gb="$DISCO_GOLDEN_GB"
        _hm_extra=""
    else
        _hm_req_gb=$(( DISCO_BASE_GB + DISCO_GOLDEN_GB ))
        _hm_extra=" (incluye ${DISCO_BASE_GB} GB de caché de la base, aún no descargada)"
    fi
    _hm_req_kb=$(( _hm_req_gb * 1024 * 1024 ))
    # `df -Pk` es la forma POSIX portable (Linux y BSD/macOS coinciden en ella);
    # NR==2 toma la fila de datos, $4 es "Available" en KB con -P -k.
    _hm_disp_kb="$(df -Pk "$TART_DIR" 2>/dev/null | awk 'NR==2{print $4}')"
    case "${_hm_disp_kb:-}" in
        ''|*[!0-9]*) err "no pude leer el espacio libre en '$TART_DIR' (df no devolvió un número)." ;;
    esac
    if [ "$_hm_disp_kb" -lt "$_hm_req_kb" ]; then
        _hm_disp_gb=$(( _hm_disp_kb / 1024 / 1024 ))
        err "espacio insuficiente en '$TART_DIR': hay ${_hm_disp_gb} GB libres y hacen falta al menos ${_hm_req_gb} GB para clonar y aprovisionar la golden${_hm_extra}. Libera espacio (revisa 'tart list' y borra clones o goldens viejas) antes de reintentar."
    fi
    info "Espacio libre en '$TART_DIR': $(( _hm_disp_kb / 1024 / 1024 )) GB (hacen falta ${_hm_req_gb} GB). OK."
}

# ---- Golden: existencia y espera de IP --------------------------------------
# Best-effort igual que base_en_cache: si el formato de `tart list` cambiara y
# esto NO detectara una golden existente, `tart clone` fallará solo por el
# nombre duplicado, así que el peor caso es un error menos claro, no un borrado
# silencioso.
golden_existe() {
    tart list 2>/dev/null | awk -v n="$GOLDEN" 'NR>1 && $2==n {f=1} END{exit !f}'
}

esperar_ip() {
    _hm_i=0
    while [ "$_hm_i" -lt "$IP_INTENTOS" ]; do
        _hm_ip="$(tart ip "$GOLDEN" 2>/dev/null || true)"
        if [ -n "$_hm_ip" ]; then printf '%s\n' "$_hm_ip"; return 0; fi
        _hm_i=$(( _hm_i + 1 ))
        sleep "$IP_ESPERA_S"
    done
    return 1
}

# ---- Aprovisionamiento por ssh ----------------------------------------------
ssh_run() {
    sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 "${ADMIN_USER}@${IP}" "$@"
}
scp_copy() {
    sshpass -p "$ADMIN_PASS" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 "$1" "${ADMIN_USER}@${IP}:$2"
}

provisionar_via_ssh() {
    _hm_origen="$1"
    case "$_hm_origen" in
        http://*|https://*)
            info "Aprovisionando desde URL: $_hm_origen"
            ssh_run "curl -fsSL '${_hm_origen}' -o /tmp/hornear-provisionar.sh && chmod +x /tmp/hornear-provisionar.sh && /tmp/hornear-provisionar.sh"
            ;;
        *)
            [ -f "$_hm_origen" ] || err "no encuentro el script de aprovisionamiento local: $_hm_origen"
            info "Aprovisionando desde fichero local: $_hm_origen"
            scp_copy "$_hm_origen" /tmp/hornear-provisionar.sh
            ssh_run "chmod +x /tmp/hornear-provisionar.sh && /tmp/hornear-provisionar.sh"
            ;;
    esac
}

# ---- Modo --completo: rehace la golden --------------------------------------
hornear_completo() {
    command -v tart >/dev/null 2>&1 \
        || err "falta 'tart'. Instálalo con: brew install cirruslabs/cli/tart"
    if [ -n "$PROVISIONAR" ]; then
        command -v sshpass >/dev/null 2>&1 \
            || err "falta 'sshpass' (hace falta para aprovisionar por ssh). Instálalo con: brew install hudochenkov/sshpass/sshpass"
    else
        info "aviso: sin --provisionar la golden queda solo con la imagen base (sin Node/pnpm ni ningún otro aprovisionamiento)."
    fi

    if golden_existe; then
        if [ "$FORCE" = "yes" ]; then
            info "la golden '$GOLDEN' ya existe; --force -> se rehace."
            tart delete "$GOLDEN" 2>/dev/null || true
        else
            err "la golden '$GOLDEN' ya existe (tart list). Usa --force para rehacerla, o --golden NOMBRE para crear otra."
        fi
    fi

    comprobar_espacio

    info "Clonando '$BASE' -> '$GOLDEN'..."
    tart clone "$BASE" "$GOLDEN"

    if [ -n "$PROVISIONAR" ]; then
        info "Arrancando '$GOLDEN' en segundo plano para aprovisionar..."
        tart run "$GOLDEN" --no-graphics &
        _hm_run_pid=$!

        if ! IP="$(esperar_ip)"; then
            kill "$_hm_run_pid" 2>/dev/null || true
            err "'$GOLDEN' no obtuvo IP tras $(( IP_INTENTOS * IP_ESPERA_S ))s. Revisa que 'tart run' haya arrancado y la red compartida de Tart (bridged/NAT)."
        fi
        info "IP de '$GOLDEN': $IP"

        provisionar_via_ssh "$PROVISIONAR"

        info "Deteniendo '$GOLDEN'..."
        tart stop "$GOLDEN"
        wait "$_hm_run_pid" 2>/dev/null || true
    fi

    # La caché OCI de la base ya no hace falta: la golden es una copia
    # completa e independiente. Son 50-60 GB en un disco de <500; no esperamos
    # a que Tart la pode solo por falta de espacio (umbral por defecto 100 GB
    # en `tart clone --prune-limit`), la liberamos ya.
    info "Podando la caché OCI de imágenes base (tart prune)..."
    tart prune

    info "Golden '$GOLDEN' lista."
}

# ---- Modo --runner: refresca el tarball del agente en el host --------------
refrescar_runner() {
    command -v curl >/dev/null 2>&1 || err "falta 'curl'."
    command -v jq >/dev/null 2>&1 || err "falta 'jq'. Instálalo con: brew install jq"
    if command -v shasum >/dev/null 2>&1; then
        SHA_BIN="shasum"; SHA_ARGS="-a 256"
    elif command -v sha256sum >/dev/null 2>&1; then
        SHA_BIN="sha256sum"; SHA_ARGS=""
    else
        err "falta 'shasum' o 'sha256sum' para verificar el tarball descargado."
    fi

    mkdir -p "$RUNNER_DIR"

    info "Consultando la última versión de ${GH_RUNNER_REPO}..."
    _hm_auth="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
    if [ -n "$_hm_auth" ]; then
        _hm_json="$(curl -fsSL -H "Accept: application/vnd.github+json" -H "Authorization: Bearer ${_hm_auth}" \
            "${GH_API}/repos/${GH_RUNNER_REPO}/releases/latest")" \
            || err "no pude consultar ${GH_API}/repos/${GH_RUNNER_REPO}/releases/latest"
    else
        _hm_json="$(curl -fsSL -H "Accept: application/vnd.github+json" \
            "${GH_API}/repos/${GH_RUNNER_REPO}/releases/latest")" \
            || err "no pude consultar ${GH_API}/repos/${GH_RUNNER_REPO}/releases/latest"
    fi

    _hm_version="$(printf '%s' "$_hm_json" | jq -r '.tag_name // empty' | sed 's/^v//')"
    [ -n "$_hm_version" ] || err "la respuesta de la API de GitHub no trae 'tag_name'."

    _hm_asset="actions-runner-osx-arm64-${_hm_version}.tar.gz"
    _hm_url="$(printf '%s' "$_hm_json" | jq -r --arg n "$_hm_asset" '.assets[]? | select(.name==$n) | .browser_download_url // empty')"
    [ -n "$_hm_url" ] || err "la release ${_hm_version} no trae el asset '${_hm_asset}' (¿cambió el nombre de la plataforma en actions/runner?)."

    # Fuente preferida del checksum: el campo "digest" del asset en la propia
    # API (GitHub lo publica como "sha256:<hex>"). Si esa release no lo trae
    # (versiones antiguas), se cae al bloque de checksums de las notas de la
    # versión: son texto libre, así que se busca el hex de 64 caracteres que
    # aparece junto al nombre del asset, sin asumir tabla ni formato exacto.
    _hm_hash="$(printf '%s' "$_hm_json" | jq -r --arg n "$_hm_asset" '.assets[]? | select(.name==$n) | (.digest // empty)' | sed -n 's/^sha256://p')"
    if [ -z "$_hm_hash" ]; then
        _hm_hash="$(printf '%s' "$_hm_json" | jq -r '.body // empty' | grep -A1 -F -- "$_hm_asset" | grep -Eo '[0-9a-fA-F]{64}' | head -n1)"
    fi
    [ -n "$_hm_hash" ] || err "no encontré el checksum SHA-256 de '${_hm_asset}' (ni en 'digest' ni en las notas de la versión ${_hm_version}); aborto sin descargar algo que no puedo verificar."
    _hm_hash="$(printf '%s' "$_hm_hash" | tr 'A-F' 'a-f')"

    if [ -f "${RUNNER_DIR}/${_hm_asset}" ]; then
        info "'${_hm_asset}' ya está en '${RUNNER_DIR}'; nada que hacer."
        return 0
    fi

    info "Descargando ${_hm_asset}..."
    _hm_tmp="$(mktemp "${RUNNER_DIR}/.actions-runner-download.XXXXXX")"
    if ! curl -fsSL -o "$_hm_tmp" "$_hm_url"; then
        rm -f "$_hm_tmp"
        err "la descarga de ${_hm_url} falló."
    fi

    # shellcheck disable=SC2086  # SHA_ARGS puede ir vacío (sha256sum no lo lleva)
    _hm_real="$("$SHA_BIN" $SHA_ARGS "$_hm_tmp" | awk '{print $1}' | tr 'A-F' 'a-f')"
    if [ "$_hm_real" != "$_hm_hash" ]; then
        rm -f "$_hm_tmp"
        err "el checksum de '${_hm_asset}' no coincide (esperado ${_hm_hash}, obtenido ${_hm_real}); descarté el fichero descargado."
    fi

    mv "$_hm_tmp" "${RUNNER_DIR}/${_hm_asset}"
    printf '%s\n' "$_hm_version" > "${RUNNER_DIR}/actions-runner-osx-arm64.version"

    # El disco es el recurso escaso de esta máquina (ver cabecera): no dejar
    # tarballs de versiones anteriores acumulándose en cada refresco diario.
    # ANTES de crear el symlink "-latest": es un fichero real que hace `ln -sf`
    # (no un enlace simbólico visto por `-e` como inexistente) y matchea el
    # mismo glob, así que crearlo primero lo dejaría borrado por su propio bucle.
    for _hm_viejo in "${RUNNER_DIR}"/actions-runner-osx-arm64-*.tar.gz; do
        [ -e "$_hm_viejo" ] || continue
        case "$_hm_viejo" in
            "${RUNNER_DIR}/${_hm_asset}") continue ;;
        esac
        info "Borrando tarball de versión anterior: $_hm_viejo"
        rm -f "$_hm_viejo"
    done

    ln -sf "$_hm_asset" "${RUNNER_DIR}/actions-runner-osx-arm64-latest.tar.gz"

    info "Listo: '${_hm_asset}' (checksum verificado) en '${RUNNER_DIR}'."
}

# ---- Orden de ejecución ------------------------------------------------------
# --runner primero: es la operación diaria y barata; --completo es la semanal
# y cara. Si se piden las dos a la vez, tiene sentido dejar el agente listo
# antes de gastar tiempo en la golden.
[ "$RUNNER" = "yes" ] && refrescar_runner
[ "$COMPLETO" = "yes" ] && hornear_completo

exit 0
