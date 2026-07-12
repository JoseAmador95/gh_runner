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

Siempre es un **contenedor Linux** (Ubuntu 24.04). El host solo necesita un motor de contenedores:

| Host | Motor | Notas |
|------|-------|-------|
| **Mac mini (Apple Silicon, arm64)** | Podman | `brew install podman docker-compose && podman machine init && podman machine start`. Usa la imagen arm64. |
| **Fedora (x86_64)** | Podman (o Docker) | `sudo dnf install podman podman-compose`. Nativo amd64. |
| **Windows (x86_64)** | Podman Desktop o Docker Desktop | Backend **WSL2**. Ejecuta `deploy.sh` en **Git Bash**/**WSL2**, o `deploy.ps1` en **PowerShell**. Corre la imagen amd64 como contenedor Linux. |

`deploy.sh` es un script POSIX `sh`; necesita `curl` en el host (y `jq` opcional, solo para un mensaje de error más claro al validar el token).

> **Podman no incluye `compose`**: necesita un proveedor externo — `podman-compose` (`pip3 install podman-compose` o el paquete de tu distro) o el binario `docker-compose` (`brew install docker-compose`; en Windows suele venir con Docker Desktop). Si ves `falta un proveedor de compose para podman`, instala uno. `deploy.sh`/`deploy.ps1` autodetectan el motor: prefieren Podman con compose y, si Podman no tiene proveedor, **caen a Docker**; puedes forzarlo con `--engine`/`-Engine podman|docker`.
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
- Mismos flags que `deploy.sh` pero con guion simple: `-Count`, `-Prefix`, `-Labels`, `-Secret`, `-Cpus`, `-Memory`, `-Engine`, `-Force`, `-NoUp`, `-Help`, etc.
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
| `--cpus N` | Límite de CPU por runner (p.ej. `2`, `1.5`) | `RUNNER_CPUS` |
| `--memory SIZE` | Límite de memoria por runner (p.ej. `2g`, `512m`) | `RUNNER_MEMORY` |
| `--pull-always` | Añade `pull_policy: always` al compose | — |
| `--file PATH` | Ruta del compose a generar (def. `compose.yaml`) | — |
| `--secret` | Guarda el PAT como file-secret en vez de en `.env` (ver §8) | — |
| `--token-in-env` | Fuerza el modo por defecto (PAT en `.env`) | — |
| `--up` / `--no-up` | Levantar o no el stack tras generar | — |
| `--skip-validation` | No validar el token contra la API | — |
| `--force` | Sobreescribe `compose.yaml`/`.env`/`access_token` ajenos | — |
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

El workflow `build-image.yml` reconstruye y publica `:latest` **semanalmente** (con la última versión de `actions/runner`). Pero los hosts **no** la adoptan solos:

- El ciclo efímero es un **restart** (el job termina → `restart: always` reinicia el contenedor **con la misma imagen** con la que se creó). **Un restart nunca hace `pull`**, así que el runner sigue con la imagen vieja job tras job. `pull_policy: always` tampoco lo cambia: solo actúa al **recrear** (`up`), no en un restart.

Para adoptar la imagen nueva hay que **recrear** los contenedores:

```bash
podman compose pull      # baja el :latest nuevo de GHCR
podman compose up -d     # recrea los contenedores con la imagen nueva
```

(Con `--pull-always` al generar el compose, basta `podman compose up -d`.)

> ⚠️ `up -d` recrea **todos** los contenedores; si uno está a mitad de un job, ese job se **cancela** (el runner drena por la parada elegante, pero el job en curso se pierde). Como los jobs efímeros son cortos la ventana es pequeña — aun así, hazlo en horas tranquilas. Hacerlo cada semana (tras el rebuild) mantiene el fleet al día.

**Limpiar del todo:**

```bash
podman compose down -v          # para, desregistra y borra los volúmenes (cache)
rm -f .env compose.yaml         # borra los ficheros generados
```

### ⚠️ Esto es normal: los contenedores se reinician

Como los runners son **efímeros**, cada uno procesa **un job y su contenedor se reinicia** (por `restart: always`) para re-registrarse limpio. Así que en `podman compose ps` los verás ciclar tras cada job, y en la UI de GitHub el runner desaparece un instante y reaparece. **No es un error** — es el ciclo efímero. En reposo (sin jobs) están `Up` esperando.

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
| `GITHUB_API_URL` | no | Base de la API (def. `https://api.github.com`; útil en GHES) |
| `RUNNER_TOKEN` | no | **Legacy**: token de registro directo (caduca ~1 h; rompe el auto-reinicio). Solo si no hay `ACCESS_TOKEN`. |

\* `ACCESS_TOKEN` es obligatorio salvo que lo pases como fichero (`ACCESS_TOKEN_FILE`/`--secret`) o uses el modo legacy `RUNNER_TOKEN`.

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

- **CI:** `ci.yml` corre `shellcheck` (scripts), `hadolint` (Containerfile) y un *smoke test* de la generación del compose en cada push/PR. `build-image.yml` reconstruye y publica semanalmente con la última versión de `actions/runner`.
- **Licencia:** [MIT](LICENSE).
