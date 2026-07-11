# Runner de GitHub Actions autohospedado sobre Ubuntu 24.04
# Pensado para Apple Silicon (arm64) ejecutado con Podman rootless.
#
# Build (desde la Mac, arm64 nativo):
#   podman build -t gh-runner:u24 .
#
# Si algún día necesitas la MISMA arquitectura que ubuntu-24.04 de GitHub (x86_64),
# construye con:  podman build --platform linux/amd64 -t gh-runner:u24-amd64 .
# (requiere una podman machine x86_64 o emulación; es mucho más lento).

FROM ubuntu:24.04

# Versión del agente runner. Mínimo exigido por GitHub (enforcement 2026): 2.329.0
# Última al momento de escribir: 2.334.0. Revisa https://github.com/actions/runner/releases
ARG RUNNER_VERSION=2.334.0
ARG TARGETARCH=arm64

ENV DEBIAN_FRONTEND=noninteractive

# Dependencias base + las que el propio runner necesita en tiempo de ejecución.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl jq git sudo unzip zip tar gzip \
        build-essential libssl3 libicu74 \
    && rm -rf /var/lib/apt/lists/*

# El runner se NIEGA a ejecutarse como root, así que creamos un usuario dedicado.
RUN useradd -m -s /bin/bash runner \
    && usermod -aG sudo runner \
    && echo "runner ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/99-runner \
    && chmod 0440 /etc/sudoers.d/99-runner

USER runner
WORKDIR /home/runner

# Descarga y descompresión del agente según la arquitectura de destino.
RUN set -eux; \
    case "${TARGETARCH}" in \
        arm64) ARCH=arm64 ;; \
        amd64) ARCH=x64 ;; \
        *) echo "Arquitectura no soportada: ${TARGETARCH}" && exit 1 ;; \
    esac; \
    curl -fsSL -o runner.tar.gz \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${ARCH}-${RUNNER_VERSION}.tar.gz"; \
    tar xzf runner.tar.gz; \
    rm runner.tar.gz

# installdependencies.sh necesita root (apt). Lo ejecutamos y volvemos a runner.
USER root
RUN /home/runner/bin/installdependencies.sh
USER runner

COPY --chown=runner:runner entrypoint.sh /home/runner/entrypoint.sh
RUN chmod +x /home/runner/entrypoint.sh

ENTRYPOINT ["/home/runner/entrypoint.sh"]
