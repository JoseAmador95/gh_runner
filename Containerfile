# Runner de GitHub Actions autohospedado sobre Ubuntu 24.04.
# Se publica multi-arch (linux/arm64 + linux/amd64) en GHCR vía
# .github/workflows/build-image.yml; normalmente NO necesitas construirla a mano.
#
# Build local (arm64 nativo en la Mac):
#   podman build -t gh-runner:local .
# Build cruzada a x86_64:
#   podman build --platform linux/amd64 -t gh-runner:local-amd64 .
#   (requiere una podman machine x86_64 o emulación; es más lento).

FROM ubuntu:24.04

# Enlaza el package publicado en GHCR con este repositorio (visibilidad/procedencia).
LABEL org.opencontainers.image.source="https://github.com/JoseAmador95/gh_runner"

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
# Además pre-creamos _work y .cache con dueño runner: al montar volúmenes
# nombrados (Podman rootless) el mountpoint conserva ese dueño en vez de root,
# lo que evita que actions/checkout falle por permisos.
USER root
RUN /home/runner/bin/installdependencies.sh \
    && mkdir -p /home/runner/_work /home/runner/.cache \
    && chown -R runner:runner /home/runner/_work /home/runner/.cache
USER runner

COPY --chown=runner:runner entrypoint.sh /home/runner/entrypoint.sh
RUN chmod +x /home/runner/entrypoint.sh

ENTRYPOINT ["/home/runner/entrypoint.sh"]
