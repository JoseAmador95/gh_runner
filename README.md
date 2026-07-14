# gh_runner

Runners **self-hosted de GitHub Actions** en contenedores (Podman/Docker), pensados para desplegar **uno o varios por máquina** en varias computadoras con **un solo comando**.

Características:

- **Efímeros:** cada runner procesa **un job** y se re-registra limpio para el siguiente → aislamiento entre jobs.
- **Auto-registro por PAT:** el contenedor genera un token de registro fresco en **cada arranque** vía la API de GitHub, así que **sobreviven caídas y reinicios** indefinidamente (los tokens de registro sueltos caducan en ~1 h; por eso no se usan directamente).
- **Cache persistente:** cada runner conserva su clone (`.git` en `_work`) y sus caches → `actions/checkout` hace *fetch* incremental en vez de clonar desde cero.
- **Multi-arch:** imagen `linux/arm64` + `linux/amd64` publicada en GHCR.
- **Compose declarativo:** `deploy.sh` genera un `compose.yaml` con `restart: always` para N runners.

---

## Requisitos por sistema operativo

Siempre es un **contenedor Linux** (Ubuntu 24.04). **`deploy.sh`/`deploy.ps1` hacen el bootstrap del entorno**: si falta `podman`, el proveedor de compose o (en macOS/Windows) la *machine*, los instalan/crean automáticamente. Opt-out con `--no-bootstrap` / `-NoBootstrap` si prefieres gestionarlo tú.

| Host | Gestor | Qué instala/crea el bootstrap |
|------|--------|-------------------------------|
| **macOS** (Apple Silicon / Intel) | Homebrew | `brew install podman docker-compose` + `podman machine init --now`. Requiere [Homebrew](https://brew.sh). |
| **Fedora** | dnf | `sudo dnf install -y podman podman-compose`. Nativo. |
| **Debian / Ubuntu / Raspberry Pi OS** | apt | `sudo apt-get install -y podman podman-compose`. Nativo. |
| **Windows** | winget | `deploy.ps1`: `winget install RedHat.Podman` + `podman machine init --now` (WSL2). O usa `deploy.sh` en Git Bash/WSL2. |

> ⚠️ **Raspberry Pi debe correr un SO de 64 bits** (arm64): la imagen es multi-arch `arm64`+`amd64`, no hay build de 32 bits (armhf/armv7). `deploy.sh` aborta si detecta un host de 32 bits.
>
> El bootstrap usa `sudo` en Linux (instala paquetes en el host) y es idempotente (no-op si ya tienes todo). `deploy.sh` es POSIX `sh`; necesita `curl` (obligatorio para validar el token, salvo `--skip-validation`) y `jq` opcional.

> **Podman no incluye `compose`** (necesita un proveedor externo). El bootstrap lo instala; con `--no-bootstrap` instálalo tú: `podman-compose` (paquete de tu distro / `pip3 install podman-compose`) o `docker-compose` (`brew install docker-compose`; en Windows suele venir con Docker Desktop). `deploy.sh`/`deploy.ps1` autodetectan el motor: prefieren Podman con compose y, si no, **caen a Docker**; fuérzalo con `--engine`/`-Engine podman|docker`. Nota: `podman-compose`/`docker-compose` v1 tienen soporte **parcial** de `secrets:`/`deploy:` — para todo, usa `podman compose` o `docker compose` (plugin v2).
>
> Cuando Podman usa un proveedor externo imprime un aviso `>>>> Executing external compose provider … <<<<` (a stderr, **inofensivo**). Para silenciarlo, en tu `containers.conf` (`~/.config/containers/containers.conf` en Linux, `%APPDATA%\containers\containers.conf` en Windows) pon:
> ```ini
> [engine]
> compose_warning_logs=false
> ```

### Windows con Git Bash

`deploy.sh` corre en **Git Bash** tal cual: el CLI `docker.exe`/`podman.exe` (Docker/Podman Desktop, backend WSL2) se invoca desde Git Bash sin problema, y el script ya desactiva la conversión de rutas de MSYS2. Ten en cuenta:

- **Comandos con rutas absolutas del contenedor** (p.ej. `exec … /run/secrets/…` o `/home/runner/…`): Git Bash intenta convertir esas rutas a rutas de Windows. Antepón `MSYS_NO_PATHCONV=1` o usa doble barra (`//run/secrets/…`):
  ```bash
  MSYS_NO_PATHCONV=1 docker compose exec runner-1 cat /run/secrets/access_token
  ```
- **Permisos:** `chmod 600` sobre `.env`/`access_token` es *best-effort* en NTFS (Windows usa ACLs), así que la protección de fichero es más débil que en Linux/macOS. Restringe el acceso a la carpeta si te preocupa.
- **jq** no viene con Git Bash; no es necesario (`deploy.sh` funciona sin él).

### Windows con PowerShell

Si prefieres PowerShell nativo (sin Git Bash ni WSL2 en la shell), usa **`deploy.ps1`** — el equivalente de `deploy.sh` con parámetros al estilo PowerShell (`-Repo`, `-Token`, …). Funciona en Windows PowerShell 5.1 y PowerShell 7, con Docker Desktop (trae `docker compose`) o Podman con un proveedor de compose.

Un comando (permite pasar parámetros, sin tocar la Execution Policy):

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/JoseAmador95/gh_runner/main/deploy.ps1))) -Repo OWNER/REPO -Token <PAT> -Count 3 -Up
```

O descargar y ejecutar:

```powershell
irm https://raw.githubusercontent.com/JoseAmador95/gh_runner/main/deploy.ps1 -OutFile deploy.ps1
.\deploy.ps1 -Repo OWNER/REPO -Token <PAT> -Count 3 -Up
```

- Sin `-Token`, toma el PAT de `$env:ACCESS_TOKEN`, luego de `gh auth token`, y si no lo pide (oculto).
- Mismos flags que `deploy.sh` pero con guion simple: `-Count`, `-Prefix`, `-Labels`, `-Secret`, `-Cpus`, `-Memory`, `-Engine`, `-Force`, `-NoBootstrap`, `-NoUp`, `-Help`, etc.
- Si `.\deploy.ps1` queda bloqueado por la Execution Policy, usa `pwsh -ExecutionPolicy Bypass -File .\deploy.ps1 …` o `Unblock-File .\deploy.ps1`.
- **Permisos:** en NTFS restringe `.env`/`access_token` con `icacls` (best-effort), igual que en Git Bash.

---

## 1. Obtener el token

El contenedor llama a `POST /repos/{owner}/{repo}/actions/runners/{registration,remove}-token`, que requiere permiso de **administración** sobre el repo. Tres formas de conseguirlo:

### A) Fine-grained PAT (recomendado — mínimo privilegio)
`GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token`:

- **Resource owner:** tu cuenta.
- **Repository access:** *Only select repositories* → el repo objetivo.
- **Permissions → Repository → Administration:** **Read and write**. (Nada más.)
- **Expiration:** la que controles (p.ej. 90 días) y rota.

Copia el token (`github_pat_…`) y pásalo con `--token`.

### B) Classic PAT
`Tokens (classic) → Generate new token (classic)`, scope **`repo`**. Cubre admin de runners en repos que administras, pero es menos granular.

### C) Con la GitHub CLI (`gh`)
GitHub **no permite crear un PAT** por API/CLI (solo en la web, opciones A/B). Pero `gh` ofrece un atajo:

```bash
gh auth status            # comprueba que tienes scope 'repo'
gh auth refresh -s repo   # si te falta el scope
```

Si `gh` está autenticado con scope `repo` y eres admin del repo, **`deploy.sh` toma el token automáticamente** (`gh auth token`) cuando **no** pasas `--token`. Ojo: ese token tiene scopes más amplios y está atado a tu sesión de `gh`.

---

## 2. Instalación de un comando

**Idioma recomendado** (la terminal sigue conectada → funcionan los *prompts* interactivos **y** los argumentos):

```bash
sh -c "$(curl -fsSL https://raw.githubusercontent.com/JoseAmador95/gh_runner/main/deploy.sh)" -- \
    --repo JoseAmador95/mi-repo \
    --token github_pat_XXXX \
    --count 3 \
    --prefix ci \
    --up
```

**Modo interactivo** (sin argumentos → te pregunta lo que falte, el PAT con eco oculto):

```bash
sh -c "$(curl -fsSL https://raw.githubusercontent.com/JoseAmador95/gh_runner/main/deploy.sh)"
```

**Por tubería** (⚠️ `curl … | sh` consume STDIN → **sin** prompts; usa solo args/env):

```bash
curl -fsSL https://raw.githubusercontent.com/JoseAmador95/gh_runner/main/deploy.sh \
  | sh -s -- --repo JoseAmador95/mi-repo --token github_pat_XXXX --count 3
```

**Con variables de entorno** (útil en scripts / si usas `gh`):

```bash
export ACCESS_TOKEN=github_pat_XXXX   # o deja que deploy.sh use `gh auth token`
export REPO_USER=JoseAmador95 REPO_NAME=mi-repo
sh -c "$(curl -fsSL https://raw.githubusercontent.com/JoseAmador95/gh_runner/main/deploy.sh)" -- --count 3 --up
```

`deploy.sh` genera dos ficheros **en el directorio actual**:

- **`.env`** (permisos `600`, en `.gitignore`) — contiene el PAT y la config compartida.
- **`compose.yaml`** — el compose con N servicios. Se llama así (nombre estándar) para que puedas usar `podman compose …` **sin `-f`**.

> 💡 **Corre `deploy.sh` en un directorio dedicado** (p.ej. `mkdir ~/gh-runner && cd ~/gh-runner`), porque escribe `compose.yaml` y `.env` ahí. Si ya existe un `compose.yaml`/`.env` que **no** generó `deploy.sh`, se niega a pisarlo (usa `--force` para forzar).

---

## 3. Opciones de `deploy.sh`

| Flag | Descripción | Fallback (env) |
|------|-------------|----------------|
| `--repo OWNER/REPO` | Repositorio objetivo | — |
| `--owner` / `--name` | Alternativa a `--repo` | `REPO_USER` / `REPO_NAME` |
| `--token PAT` | Personal Access Token | `ACCESS_TOKEN` → `gh auth token` → prompt |
| `--count N` | Número de runners (def. 1) | `RUNNER_COUNT` |
| `--prefix P` | Prefijo del nombre (def. `gh`) | `RUNNER_PREFIX` |
| `--labels L` | Etiquetas extra (coma) | `RUNNER_LABELS` |
| `--group G` | Runner group | `RUNNER_GROUP` |
| `--image REF` | Imagen (def. `ghcr.io/joseamador95/gh_runner:latest`) | `IMAGE` |
| `--engine E` | Fuerza el motor: `podman` o `docker` (def. autodetecta) | — |
| `--cache-dirs A,B` | Dirs extra de cache por runner (p.ej. `.npm,.cargo`) | — |
| `--mount SRC:DST[:ro]` | Volumen/bind extra en **cada** runner (repetible). `SRC` = volumen nombrado (compartido) o ruta host (bind) | — |
| `--network NAME[:external]` | Red extra en **cada** runner (repetible; para redes externas ya existentes) | — |
| `--compose-extra FILE` | Override de compose a encadenar (autodetecta `compose.override.yaml`) | — |
| `--cpus N` | Límite de CPU por runner (p.ej. `2`, `1.5`) | `RUNNER_CPUS` |
| `--memory SIZE` | Límite de memoria por runner (p.ej. `2g`, `512m`) | `RUNNER_MEMORY` |
| `--pull-always` | *(default)* `pull_policy: always`: cada `up -d` re-baja `:latest` | — |
| `--no-pull-always` | Desactiva `pull_policy: always` (fija la imagen local cacheada) | — |
| `--file PATH` | Ruta del compose a generar (def. `compose.yaml`) | — |
| `--secret` | Guarda el PAT como file-secret en vez de en `.env` (ver §8) | — |
| `--token-in-env` | Fuerza el modo por defecto (PAT en `.env`) | — |
| `--up` / `--no-up` | Levantar o no el stack tras generar | — |
| `--skip-validation` | No validar el token contra la API | — |
| `--force` | Sobreescribe `compose.yaml`/`.env`/`access_token` ajenos | — |
| `--no-bootstrap` | No instalar podman/compose ni crear la machine | — |
| `-h`, `--help` | Ayuda | — |

> GitHub añade **automáticamente** las etiquetas `self-hosted`, `Linux` y la arquitectura (`X64`/`ARM64`). `--labels` es solo para etiquetas **extra** (p.ej. `gpu`, `mi-proyecto`).

---

## 4. Operación diaria (interactuar con los runners)

`deploy.sh` es solo el arranque. Después interactúas con **compose** desde el directorio donde están `compose.yaml` y `.env`.

**Usarlos** (el objetivo real): no "entras" a los runners; los apuntas desde tus workflows y los ves en **repo → Settings → Actions → Runners**.

```yaml
jobs:
  build:
    runs-on: [self-hosted, linux, ARM64]   # o las labels que definiste
```

**Comandos** (con `compose.yaml` no hace falta `-f`):

| Acción | Comando |
|--------|---------|
| Levantar / aplicar cambios | `podman compose up -d` |
| Estado | `podman compose ps` |
| Logs de un runner | `podman compose logs -f runner-1` |
| Reiniciar uno | `podman compose restart runner-1` |
| Entrar a un contenedor | `podman exec -it <nombre> bash` |
| Parar todo (desregistra) | `podman compose down` |
| Parar + borrar cache | `podman compose down -v` |

> Con Docker sustituye `podman` por `docker`. Si usaste `--file otro.yaml`, añade `-f otro.yaml`.

**Escalar** (más/menos runners): vuelve a correr `deploy.sh` con otro `--count` (regenera el `compose.yaml`) y aplica:

```bash
podman compose up -d --remove-orphans   # --remove-orphans quita los que redujiste
```

**Actualizar la imagen (importante — leer):**

El workflow `build-image.yml` reconstruye y publica `:latest` **diariamente** (con la última versión de `actions/runner`). `deploy.sh` genera el compose con **`pull_policy: always` por defecto**, así que adoptar la imagen nueva es un solo comando:

```bash
podman compose up -d     # re-baja :latest (pull_policy: always) y recrea los contenedores
```

- ⚠️ Un **restart** (el ciclo efímero, por `restart: always`) **nunca hace `pull`**: reusa la imagen con la que se creó el contenedor. Solo un **recrear** (`up -d`) adopta la imagen nueva — y con `pull_policy: always` ese `up -d` primero re-baja `:latest`. Este default es justo lo que evita quedarte con una imagen vieja cacheada (incluida una de arquitectura equivocada).
- Si generaste el compose con `--no-pull-always`, actualiza en dos pasos: `podman compose pull && podman compose up -d`.
- ¿Sospechas de una imagen local vieja/rota? Fuérzala: `podman compose down && podman rmi -f ghcr.io/joseamador95/gh_runner:latest && podman compose pull && podman compose up -d`.

> El runner **no** se auto-actualiza dentro del contenedor (`--disableupdate`, activado por defecto): un self-update a mitad de job cancelaría el job y, al ser efímero, podría dejar el contenedor en un crash-loop. La versión se mantiene al día con el **rebuild diario + `pull`+recreate**. Contrapartida: si GitHub sube el **mínimo** de versión de runner entre rebuilds, un runner sin actualizar podría ser rechazado hasta el siguiente `pull`+recreate (o reactívalo temporalmente con `RUNNER_DISABLE_UPDATE=no`).

> ⚠️ `up -d` recrea **todos** los contenedores; si uno está a mitad de un job, ese job se **cancela** (el runner drena por la parada elegante, pero el job en curso se pierde). Como los jobs efímeros son cortos la ventana es pequeña — aun así, hazlo en horas tranquilas. Hacerlo cada día (tras el rebuild) mantiene el fleet al día.

**Limpiar del todo:**

```bash
podman compose down -v          # para, desregistra y borra los volúmenes (cache)
rm -f .env compose.yaml         # borra los ficheros generados
```

### ⚠️ Esto es normal: los contenedores se reinician

Como los runners son **efímeros**, cada uno procesa **un job y su contenedor se reinicia** (por `restart: always`) para re-registrarse limpio. Así que en `podman compose ps` los verás ciclar tras cada job, y en la UI de GitHub el runner desaparece un instante y reaparece. **No es un error** — es el ciclo efímero. En reposo (sin jobs) están `Up` esperando.

El runner **no** se auto-actualiza (la versión viene de la imagen; se refresca con `pull`+recreate), y el entrypoint **se auto-repara**: si al arrancar encuentra la config local de un ciclo anterior que no se limpió (p.ej. tras un corte a mitad de job), la resetea y se re-registra en vez de quedarse en `Cannot configure… already configured`.

---

## 5. Varios runners y varias máquinas

- **Varios por máquina:** `--count N` crea N servicios, cada uno con su **propio** volumen de cache. Los nombres son `PREFIX-HOSTNAME-i` (únicos por índice).
- **Varias máquinas:** corre el mismo comando en cada host. El `hostname` mantiene los nombres únicos entre máquinas. Puedes usar el mismo PAT en todas, o uno por máquina (recomendado a gran escala por los *rate limits*).

Verifica en el repo: **Settings → Actions → Runners** (aparecen como *idle*).

---

## 6. Cache

Cada runner monta volúmenes **propios** (no compartidos, para evitar corrupción entre contenedores concurrentes):

- `runner-i-work` → `/home/runner/_work`: conserva el clone del repo (`.git`) y el *tool-cache* de las actions `setup-*`. `actions/checkout` reutiliza el `.git` (*fetch* incremental) pero limpia el árbol de trabajo (`clean: true`), así que el **código** sigue limpio cada job.
- `runner-i-cache` → `/home/runner/.cache`: cache genérico (XDG; p.ej. `pip`).
- Dirs extra opcionales con `--cache-dirs .npm,.cargo` → un volumen por dir por runner (el contenedor arregla su *ownership* al arrancar).

Para **limpiar** el cache: `… down -v` (borra los volúmenes).

### Acelerar descargas (clone, `pnpm install`, "post")

El cuello de botella suele ser la red de los jobs, no el runner. Cómo aprovechar los volúmenes persistentes:

- **`pnpm install` (el gran lever):** en **tu imagen derivada** (o el workflow) fija `npm_config_store_dir=/home/runner/_work/.pnpm-store` — gh_runner **no** lo hornea, por ser genérico (ver [Extender gh_runner](#extender-gh_runner-para-un-proyecto-imagen-derivada)). Al quedar **dentro de `_work`** el store persiste entre jobs **y** está en el **mismo filesystem** que `node_modules` (`_work/<repo>`), así que pnpm instala por **hard-links, sin descargar**. (En otro volumen pnpm *copiaría* en vez de enlazar — por eso va en `_work`, no en `.cache`.) Instala con `pnpm install --frozen-lockfile --prefer-offline`.
- **Quita `actions/cache` (y `setup-node` con `cache: pnpm`):** en self-hosted esos pasos suben/bajan el store al *cache service* de GitHub (Azure) — lento y **redundante** con el store local. Ese es el paso **"post"** que ves; al quitarlo, desaparece.
- **Clone:** el `.git` persiste en `_work` → `actions/checkout` hace *fetch* incremental (solo el 1er job por runner clona en frío). Mantén `fetch-depth` bajo.
- **npm / yarn:** el base **no** redirige estos caches (por ser genérico). Persístelos con `--cache-dirs .npm` (npm usa `~/.npm`) o fija `npm_config_cache=/home/runner/.cache/npm` en tu imagen derivada.
- **Opcional — registry local (Verdaccio):** un proxy *pull-through* compartido por los runners del host baja de npmjs **una vez** y cachea; acelera el arranque en frío y comparte cache entre runners sin el riesgo de corromper un store compartido. Corre Verdaccio en el host y apunta los jobs con `npm_config_registry=http://<host>:4873`.

> El store en `_work` crece con el tiempo; acótalo con `pnpm store prune` (p.ej. dentro del `refresh.sh` periódico) o un `down -v` ocasional.

---

## 7. Auto-reinicio y aviso sobre reinicios de la máquina

El compose usa `restart: always`: si un contenedor se cae, el motor lo recrea, **genera un token nuevo** y se re-registra en segundos.

⚠️ `restart: always` solo actúa **mientras el motor de contenedores está corriendo**. Para que los runners vuelvan tras **reiniciar la máquina**:

- **macOS:** la `podman machine` debe arrancar sola. Configúrala como *login item* o arráncala al iniciar sesión (`podman machine start`).
- **Linux (Podman rootless):**
  ```bash
  systemctl --user enable --now podman-restart.service
  loginctl enable-linger "$USER"
  ```
- **Windows:** activa *"Start on login"* en Podman/Docker Desktop y asegúrate de que la distro WSL2 arranque.

> Actualizar la imagen, escalar y hacer teardown se explican en **§4 Operación diaria**.

### Mantener el runner al día (importante con `--disableupdate`)

Los runners **no** se auto-actualizan (variable `RUNNER_DISABLE_UPDATE`), y el ciclo efímero es un **restart** que **no** hace `pull`. Pero GitHub **exige** que el runner esté dentro de los ~30 días de la última versión, y el **mínimo de ejecución avanza** con el tiempo (enforcement en github.com desde ~sep-2026): un runner que nunca se recrea acabará **rechazado** (deja de tomar jobs).

Solución: **recrea periódicamente** para adoptar la imagen del rebuild diario. El repo trae **`refresh.sh`** (hace `pull` + `up -d` en el directorio del despliegue); agéndalo, p.ej. semanal:

- **Linux (systemd user timer):** un `gh-runner-refresh.service` (`ExecStart=/ruta/refresh.sh`, `WorkingDirectory=/ruta/deploy`) + `.timer` (`OnCalendar=weekly`, `Persistent=true`), y:
  ```bash
  systemctl --user enable --now gh-runner-refresh.timer
  loginctl enable-linger "$USER"
  ```
- **Linux / macOS (cron):** `0 5 * * 1 cd /ruta/deploy && /ruta/refresh.sh >> refresh.log 2>&1`
- **macOS (launchd):** un agente con `StartCalendarInterval` que corra `refresh.sh` en el dir del despliegue.
- **Windows (Task Scheduler):** una tarea semanal `pwsh -File refresh` — o en PowerShell puro, en el dir del despliegue: `podman compose pull; podman compose up -d`.

> Alternativa: si prefieres no agendar nada, reactiva el auto-update con `RUNNER_DISABLE_UPDATE=no` en `.env` — pero entonces un update a mitad de job puede cancelarlo (por eso el default es desactivarlo).

---

## 8. Parada elegante, límites de recursos y secrets

### Parada elegante
`podman compose stop`/`down` envía SIGTERM; el contenedor lo **reenvía a `run.sh`** (que con `RUNNER_MANUALLY_TRAP_SIG=1` — puesto automáticamente — hace un apagado limpio de `Runner.Listener`) y, si el runner estaba *idle*, lo **desregistra** de GitHub antes de salir. Si un job puede estar corriendo, usa un timeout amplio: `podman compose stop -t 30`. Sin esto, un `stop` normal mataría el runner a lo bruto y quedaría *offline* en GitHub hasta que GitHub lo recolecte.

### Límites de recursos (`--cpus`, `--memory`)
Se escriben en el compose como `deploy.resources.limits`. Recomendado cuando corres **varios runners por máquina**, para que un job pesado no ahogue a los demás:
```bash
… deploy.sh … --count 4 --cpus 2 --memory 2g
```
Caveat: los honran `podman compose` (nativo), `docker compose` y un `podman-compose` **reciente**; las versiones viejas de `podman-compose` ignoran el bloque `deploy:`.

### PAT como secret (`--secret`, opt-in)
Por defecto el PAT va en `.env` (chmod 600, gitignored). Con **`--secret`**, `deploy.sh` lo guarda en `./access_token` (chmod 600, gitignored) y el compose lo monta como *file-secret* en `/run/secrets/access_token`:
- **Beneficio:** el PAT **no** aparece en `podman inspect … .Config.Env` (con `.env` sí). Sigue en disco (`./access_token`), misma exposición que `.env`.
- **Es opt-in a propósito:** Docker Compose ≥ 2.34 monta los file-secrets como `root:root 0400`, ilegibles por el usuario no-root `runner`; el contenedor los lee con `sudo cat` (tiene sudo sin contraseña). `podman-compose` tiene soporte parcial. Si tu proveedor de compose no soporta `secrets:`, quédate con el default (`.env`).

---

## Referencia: variables del contenedor

Estas las inyecta el `.env` / compose; normalmente no las tocas a mano:

| Variable | Obligatoria | Descripción |
|----------|:-----------:|-------------|
| `ACCESS_TOKEN` | sí* | PAT para generar tokens de registro |
| `ACCESS_TOKEN_FILE` | no | Ruta a un fichero con el PAT (def. `/run/secrets/access_token` en modo `--secret`) |
| `REPO_USER` | sí | Owner del repo |
| `REPO_NAME` | sí | Nombre del repo |
| `RUNNER_NAME` | no | Nombre del runner (def. `hostname-owner-repo`) |
| `RUNNER_LABELS` | no | Etiquetas extra (def. `self-hosted,ubuntu-24.04`) |
| `RUNNER_GROUP` | no | Runner group |
| `RUNNER_DISABLE_UPDATE` | no | Desactiva el auto-update del runner dentro del contenedor (def. `yes`). Un self-update a mitad de job cancela el job y, al ser efímero, puede dejarlo en crash-loop; la imagen ya trae la última versión (rebuild diario). Pon `no` (o `0`) para reactivar el self-update. |
| `GITHUB_API_URL` | no | Base de la API (def. `https://api.github.com`; útil en GHES) |
| `RUNNER_TOKEN` | no | **Legacy**: token de registro directo (caduca ~1 h; rompe el auto-reinicio). Solo si no hay `ACCESS_TOKEN`. |

\* `ACCESS_TOKEN` es obligatorio salvo que lo pases como fichero (`ACCESS_TOKEN_FILE`/`--secret`) o uses el modo legacy `RUNNER_TOKEN`.

---

## Extender gh_runner para un proyecto (imagen derivada)

`gh_runner` es un deployer **genérico**. Lo específico de un proyecto (toolchain, `ENV`, servicios sidecar, volúmenes/redes a medida) va en una **capa aparte**, sin tocar el base. Dos ejes:

**1. Binarios/tooling → imagen derivada (`FROM`).** Crea un repo con un `Containerfile` que herede del base y añada lo tuyo:

```dockerfile
FROM ghcr.io/joseamador95/gh_runner:latest
USER root
RUN apt-get update && apt-get install -y --no-install-recommends nodejs npm \
    && corepack enable && rm -rf /var/lib/apt/lists/*
USER runner
# El store de pnpm DEBE ir dentro de _work (mismo filesystem que node_modules →
# instala por hard-links, sin descargar; ver §6). Esto NO va en el base genérico.
ENV npm_config_store_dir=/home/runner/_work/.pnpm-store \
    npm_config_cache=/home/runner/.cache/npm
```

Publícala en GHCR (multi-arch, como el base; con un `schedule` diario para heredar los arreglos del base) y despliega con `--image`:

```bash
sh deploy.sh --repo OWNER/REPO --image ghcr.io/OWNER/mi-runner:latest \
    --labels mi-proyecto --count 3 --up
```

**2. Servicios/volúmenes/redes → `compose.override.yaml` + flags.**

- **Sidecars (Verdaccio, Postgres…):** decláralos en un `compose.override.yaml` en el directorio del despliegue. `deploy.sh` (y `refresh.sh`) lo **autodetectan** y lo **encadenan** (`-f compose.yaml -f compose.override.yaml`); no lo generan ni lo pisan (lo posee tu proyecto). La **red por defecto** hace a los sidecars alcanzables **por nombre** desde los runners (`verdaccio:4873`), sin necesitar `--network`:

  ```yaml
  # compose.override.yaml
  services:
    verdaccio:
      image: verdaccio/verdaccio:5
      ports: ["4873:4873"]
      volumes: [verdaccio-storage:/verdaccio/storage]
  volumes:
    verdaccio-storage: {}
  ```

- **Un volumen/bind en cada runner → `--mount SRC:DST[:ro]`** (repetible). Un `SRC` sin `/` es un **volumen nombrado compartido** entre todos los runners (útil para un cache read-mostly; para un store con escritura fuerte usa el `_work` por-runner, no un mount compartido); un `SRC` con ruta es un **bind**.
- **Una red externa ya existente → `--network NAME[:external]`** (repetible). Solo para redes **fuera** del proyecto; los sidecars del propio override no la necesitan.

```bash
sh deploy.sh --repo OWNER/REPO --image ghcr.io/OWNER/mi-runner:latest \
    --mount shared-cache:/opt/cache --network db-net:external --up
```

> `refresh.sh` (el recreate periódico que mantiene el runner al día) también encadena el `compose.override.yaml`, así que los sidecars/mounts sobreviven al recreate.

---

## Build local de la imagen (opcional)

Normalmente usas la imagen de GHCR. Si quieres construirla tú:

```bash
podman build --tag gh-runner:local .
# multi-arch / cruzada:
podman build --platform linux/amd64 --tag gh-runner:local-amd64 .
```

Y luego despliega con `--image gh-runner:local`.

---

## Modo legacy (un solo contenedor, token de registro directo)

Sin PAT ni compose, para pruebas rápidas. ⚠️ El token caduca en ~1 h, así que el auto-reinicio dejará de funcionar:

```bash
podman run -d --name gh-runner --restart=always \
    -e REPO_USER=USER -e REPO_NAME=NAME \
    -e RUNNER_TOKEN=TOKEN \
    ghcr.io/joseamador95/gh_runner:latest
```

---

## Desarrollo y licencia

- **CI:** `ci.yml` corre `shellcheck` (scripts), `hadolint` (Containerfile) y un *smoke test* de la generación del compose en cada push/PR. `build-image.yml` reconstruye y publica diariamente con la última versión de `actions/runner`.
- **Licencia:** [MIT](LICENSE).
