#!/usr/bin/env bash
set -euo pipefail

# Variables de entorno esperadas (se pasan con -e al arrancar el contenedor):
#   REPO_URL     -> https://github.com/TU_USUARIO/TU_REPO
#   RUNNER_TOKEN -> token de registro (Settings > Actions > Runners > New self-hosted runner)
#   RUNNER_NAME  -> nombre opcional (por defecto: hostname del contenedor)
#   RUNNER_LABELS-> etiquetas opcionales separadas por comas (ej: self-hosted,mac-mini,arm64)

: "${REPO_USER:?Falta REPO_USER (Owner del repositorio)}"
: "${REPO_NAME:?Falta REPO_NAME (Nombre del repositorio)}"
: "${RUNNER_TOKEN:?Falta RUNNER_TOKEN (token de registro del repo)}"

REPO_URL="https://github.com/${REPO_USER}/${REPO_NAME}"
RUNNER_NAME="${RUNNER_NAME:-$(hostname)}-${REPO_USER}-${REPO_NAME}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,mac-mini,arm64,ubuntu-24.04}"

cd /home/runner

# Al usar --ephemeral el runner procesa UN solo job y luego se apaga.
# Como el contenedor arranca limpio cada vez, esto da aislamiento real entre jobs.
cleanup() {
    echo "Eliminando el registro del runner..."
    ./config.sh remove --token "${RUNNER_TOKEN}" || true
}
trap 'cleanup; exit 0' INT TERM

./config.sh \
    --url "${REPO_URL}" \
    --token "${RUNNER_TOKEN}" \
    --name "${RUNNER_NAME}" \
    --labels "${RUNNER_LABELS}" \
    --work "_work" \
    --unattended \
    --replace \
    --ephemeral

# run.sh gestiona la conexión y la ejecución del job.
./run.sh
