# Runner de GitHub Actions autohospedado sobre Ubuntu 24.04.
# Se publica multi-arch (linux/arm64 + linux/amd64) en GHCR vía
# .github/workflows/build-image.yml; normalmente NO necesitas construirla a mano.
#
# Build local (detecta la arch del host automáticamente con uname -m):
#   podman build -t gh-runner:local .
# Cross-build a otra arch (requiere emulación binfmt/qemu; más lento):
#   podman build --platform linux/amd64 -t gh-runner:local-amd64 .

FROM ubuntu:24.04

# Enlaza el package publicado en GHCR con este repositorio (visibilidad/procedencia).
LABEL org.opencontainers.image.source="https://github.com/JoseAmador95/gh_runner"

# Versión del agente runner. Mínimo exigido por GitHub (enforcement 2026): 2.329.0
# Última al momento de escribir: 2.334.0. Revisa https://github.com/actions/runner/releases
ARG RUNNER_VERSION=2.334.0

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

# Descarga y descompresión del agente según la arquitectura REAL del build.
# Usamos `uname -m` (no un ARG con default) para no descargar nunca el binario
# de la arch equivocada: en un build multi-arch de buildx cada plataforma corre
# bajo su propia emulación, así que uname refleja la arch de destino correcta.
RUN set -eux; \
    case "$(uname -m)" in \
        x86_64 | amd64)   ARCH=x64 ;; \
        aarch64 | arm64)  ARCH=arm64 ;; \
        *) echo "Arquitectura no soportada: $(uname -m)" >&2 && exit 1 ;; \
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

# Cache de paquetes para acelerar los jobs (ver README §6 "Acelerar descargas").
# - pnpm: el store va DENTRO de _work para (1) persistir entre ciclos efímeros y
#   (2) estar en el MISMO filesystem que node_modules (_work/<repo>) → instala por
#   hard-links, sin volver a descargar. (Cross-FS pnpm copiaría en vez de enlazar.)
# - npm: su cache va al volumen persistente .cache (copy-based, cross-FS OK).
# Ambas son overridables por el workflow.
ENV npm_config_store_dir=/home/runner/_work/.pnpm-store \
    npm_config_cache=/home/runner/.cache/npm

COPY --chown=runner:runner entrypoint.sh /home/runner/entrypoint.sh
RUN chmod +x /home/runner/entrypoint.sh

ENTRYPOINT ["/home/runner/entrypoint.sh"]
