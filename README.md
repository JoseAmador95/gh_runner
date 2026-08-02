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
| `--vigilar` | Instala el vigía del host: avisa si un runner se cae o se **atasca** (ver §9) | — |
| `--vigilar-cada N` | Cadencia del vigía (def. `5min`) | — |
| `--vigilar-minimo N` | Runners sanos por debajo de los cuales el estado pasa de `parcial` a `degradado` (def. `1`) | — |
| `--no-host-label` | No añadir la etiqueta `host:<hostname>` | — |
| `-h`, `--help` | Ayuda | — |

> GitHub añade **automáticamente** las etiquetas `self-hosted`, `Linux` y la arquitectura (`X64`/`ARM64`). `--labels` es solo para etiquetas **extra** (p.ej. `gpu`, `mi-proyecto`).

> **Etiqueta `host:<hostname>`** (automática, quítala con `--no-host-label`): dice en **qué máquina** vive cada runner. Antes el único rastro era el **nombre** (`prefijo-host-N`) y parsearlo no es fiable, porque el saneado del hostname conserva guiones y el prefijo es libre: en `mi-prefijo-mi-host-3` no hay forma de saber dónde acaba uno y empieza el otro. Es **aditiva** — se suma a `--labels` (y al default), así que un `runs-on` que ya funcionaba sigue casando.

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

---

## 7. Auto-reinicio y aviso sobre reinicios de la máquina

El compose usa `restart: always`: si un contenedor se cae, el motor lo recrea, **genera un token nuevo** y se re-registra en segundos.

⚠️ **`restart: always` no cubre el runner *atascado*.** Solo actúa cuando el proceso **muere**. Un runner que pierde la conexión con GitHub entra en `Retrying until reconnected` con el proceso **vivo**: el contenedor figura `Up`, no toma un solo job y nadie se entera. Para eso está el vigía — **§9**.

⚠️ `restart: always` tampoco actúa si el **motor de contenedores** no está corriendo. Para que los runners vuelvan tras **reiniciar la máquina**:

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

## 9. Vigilancia: enterarte cuando un runner se cae (opt-in)

`restart: always` no cubre el peor fallo. Un runner puede quedarse **atascado sin poder hablar con GitHub** —entra en `Retrying until reconnected`, un bucle del que no sale— y como el proceso sigue vivo, el contenedor figura **`Up`** y **no toma un solo job**. En `podman compose ps` todo se ve bien.

Caso real que motivó esto: el reloj del host iba **32 minutos atrasado**, así que el runner renovaba su credencial tarde siempre y GitHub la rechazaba. Los jobs se quedaron **en cola durante horas** sin que nadie se enterara: no hay factura que se dispare ni corrida en rojo que lo delate.

```bash
… deploy.sh … --vigilar          # instálalo al desplegar (o vuelve a ejecutarlo con --vigilar)
```

Eso deja cuatro piezas, **todas dentro del compose**:

| Pieza | Dónde | Qué hace |
|---|---|---|
| `healthcheck.sh` | en cada **runner** | Lee el log del propio runner y decide si está atascado |
| `latido.sh` | en cada **runner**, en segundo plano | Publica su estado cada 30 s en un volumen compartido |
| `vigilar.sh` | en el servicio **`vigia`** | Cada 5 min lee los latidos y compone un informe |
| Hooks | `./vigia/hooks.d` | Deciden **cómo** te avisan. Reciben el informe completo |

El vigía **no repara nada**: diagnostica y avisa.

**Corre como un contenedor y no en el host, y eso es la decisión de fondo.** Así el agendado lo hace el motor de contenedores, que es la única capa idéntica en Linux, macOS y Windows: no hay `systemd`, ni `launchd`, ni tarea programada que mantener. Sube y baja con el cluster (`up -d` / `down`).

**No monta el socket del motor.** Cada runner publica su propio estado en un volumen compartido y el vigía lo lee. El socket habría atado el diseño a cada sistema operativo —en macOS vive dentro de la VM de podman— y es una API completa: quien la alcanza puede arrancar un contenedor privilegiado, y estaría al lado de runners que ejecutan PRs de terceros.

**Y si el host se apaga, el vigía cae con él** — de eso avisa healthchecks.io por ausencia de latido, que es el mismo mecanismo que cubre un corte de red o el motor parado.

### Varios clusters en la misma máquina

Cada despliegue vive en su directorio, así que **cada cluster tiene su propio vigía, su propia configuración (`./vigia`) y su propio check**. El nombre del cluster sale del directorio y encabeza cada aviso, así que sabes cuál está caído sin mirar la máquina.

Por el mismo motivo el **prefijo por defecto de los runners es el nombre del cluster** y no un literal fijo: con un prefijo común, dos clusters registraban runners homónimos y —como el runner se registra con `--replace`— se robaban el registro en bucle.

### Qué mide

Además del estado de cada runner, el informe lleva dos cifras que **no se ven mirando los runners**
—todos dicen «sano» mientras pasan— y una tercera que ya estaba:

| Métrica | Por qué está | Qué hace |
|---|---|---|
| **Disco** (`%` de `_work`) | Se llena y los jobs empiezan a fallar con errores que no señalan la causa | A partir de `--disco-max` (90 %) el estado pasa a **`parcial`** |
| **Último job** por runner | Un runner con la etiqueta equivocada se queda **`sano · libre` para siempre** y nadie le manda trabajo | Solo informa: sale `sin jobs aún` junto a hermanos que sí trabajaron |
| **Reloj** vs GitHub | La causa raíz del incidente que originó todo esto | A partir de `VIGIA_DESFASE_MAX` (60 s), **`degradado`** |

El último job **no alarma solo**, y es deliberado: en un fleet tranquilo (noche, fin de semana) que
nadie tome jobs es lo normal, así que un umbral absoluto daría falsos avisos. Lo que canta es
**`sin jobs aún` al lado de hermanos que sí trabajaron**, y eso lo ve quien lee.

### Qué detecta

| Fallo | Cómo se detecta | Latencia |
|---|---|---|
| Runner **atascado** (sigue `Up`, no toma jobs) | `HEALTHCHECK` → timer | ≤ 6 min |
| Contenedor **ausente** o parado | El timer no lo encuentra | ≤ 5 min |
| **Reloj desfasado** (la causa raíz del caso de arriba) | Se compara con la hora de GitHub | ≤ 5 min |
| **Máquina apagada o sin internet** | Por **ausencia de latido** (ver abajo) | el umbral que pongas |

El informe se ve en cualquier momento sin esperar al timer:

```bash
./vigilar.sh --informe
```

```text
Fleet mmJA — 5/7 en línea

DEGRADADO
  sherman-mmJA-2   atascado   atascado reconectando con GitHub
  sherman-mmJA-4   ausente    no hay contenedor

EN LÍNEA
  sherman-mmJA-1   sano       ocupado
  sherman-mmJA-3   sano       libre

Reloj: +2 s vs GitHub
Comprobado: 2026-08-01 15:04:12Z
```

### Los hooks: tú decides cómo te avisa

`vigilar.sh` **no habla con ningún servicio**. Ejecuta todo lo que sea ejecutable en el directorio de hooks (convención *run-parts*, la de `cron.d` y los hooks de git), en orden alfabético, y les pasa:

- el **informe completo** por **stdin**;
- `VIGILAR_ESTADO` (`sano` / `parcial` / `degradado`), `VIGILAR_CAMBIO` (`si` / `no`, ¿cambió respecto a la ronda anterior?), `VIGILAR_PRIMERA` (`si` en la primera ronda tras instalar), `VIGILAR_CAIDOS`, `VIGILAR_CLUSTER`, `VIGILAR_HOST`, `VIGILAR_ONLINE`, `VIGILAR_ESPERADOS`.

`VIGILAR_PRIMERA` existe porque la primera ronda y una recuperación llegan **idénticas** —estado sano, cambio sí—, y sin distinguirlas el primer aviso tras instalar diría «runners de vuelta» sin que se hubiera ido nadie. Justo el mensaje que miras para comprobar que el montaje funciona.

Los hooks corren en **cada** ronda; cada uno decide si le importa el cambio. Así el anti-spam vive en un solo sitio y los hooks son de tres líneas. Un hook que falle o se cuelgue **no impide** a los demás ni rompe el timer.

> **Ningún secreto vive en `vigilar.sh`.** Cada hook guarda el suyo, en su fichero, con sus permisos (`chmod 700`). Es deliberado: el `.env` se inyecta en contenedores que ejecutan **código arbitrario de CI**, y cualquier job puede leer su propio entorno. Un token de bot ahí sería una fuga.

`--vigilar` deja dos ejemplos listos. Se activan copiándolos **sin** el sufijo `.ejemplo` y rellenando sus datos:

```bash
cd ./vigia/hooks.d
cp 10-healthchecks.sh.ejemplo 10-healthchecks.sh && chmod 700 10-healthchecks.sh
cp 20-telegram.sh.ejemplo     20-telegram.sh     && chmod 700 20-telegram.sh
$EDITOR 10-healthchecks.sh 20-telegram.sh        # pon la URL de ping y el token del bot
```

**Para no editarlos en cada máquina**, los dos ejemplos leen antes un fichero opcional,
`./vigia/avisos.conf` (ruta configurable con `VIGILAR_CONF`), y solo caen a su valor
inline si no existe:

```sh
# ./vigia/avisos.conf   -- chmod 600: lleva credenciales
HC_URL='https://hc-ping.com/tu-uuid'
TG_TOKEN='123456:ABC-DEF'
TG_CHAT='-1001234567890'
TG_THREAD=''            # opcional
```

Con eso, aprovisionar otro host es copiar **un fichero** (`scp avisos.conf otro:~/despliegue/vigia/`)
y los hooks quedan tal cual salen del ejemplo. El fichero se **ejecuta** (`.`) desde el hook, así que
va con `chmod 600` y solo debe escribirlo su dueño — el mismo nivel de confianza que el propio hook.

### Con healthchecks.io: una ping key para todo el fleet

El hook acepta **la URL de un check** (`HC_URL`, lo de siempre) o **la ping key del proyecto**
(`HC_PING_KEY`). Con la ping key:

```sh
# ./vigia/avisos.conf — el MISMO fichero sirve para todas las máquinas
HC_PING_KEY='tu-ping-key'     # Settings del proyecto -> «Ping key»
HC_API_KEY='tu-api-key'       # opcional, pero léete el aviso de abajo
```

- El check se identifica por **cluster + máquina** (`sherman-mmja`), y `?create=1` lo **crea en el
  primer ping**. Montar un cluster nuevo no exige entrar al panel, y el `avisos.conf` deja de ser por
  máquina. Las **dos** partes del nombre hacen falta: el cluster sale del directorio del despliegue,
  que no es único entre máquinas —si todos siguen el README, todas usan el mismo—, y sin la máquina
  dos hosts compartirían check: el latido sano de uno lo mantendría verde con el otro muerto.
- **Con `HC_API_KEY` el vigía configura su propio check** (periodo, margen, nombre, descripción y
  etiquetas `host:` / `cluster:`) mediante un *upsert* idempotente. El periodo y el margen **se
  derivan de la cadencia de la ronda**: periodo = 2 rondas (tolera un ping perdido), margen = 1 ronda.
  Con la cadencia por defecto eso avisa **entre los 10 y los 15 minutos**, y se reajusta solo si
  cambias `--vigilar-cada`.

> ⚠️ **Sin `HC_API_KEY`, el check autocreado nace con periodo de 1 DÍA y margen de 1 hora.** Es el
> valor por defecto de healthchecks.io, y para un vigía que late cada 5 minutos significa que **un
> host caído tardaría un día en avisar**: parecería vigilado sin estarlo. O das la API key, o ajustas
> periodo y margen a mano **una vez** por check.

La API key es más poderosa que la ping key —lee y modifica todos los checks del proyecto—, así que es
opcional a propósito: quien no la quiera en la máquina se queda con el ajuste manual.

**Tres niveles.** healthchecks.io no tiene un estado intermedio, pero sí tres finales de URL:

| Estado del fleet | Ping | Efecto |
|---|---|---|
| `sano` | *(sin sufijo)* | Verde, y reinicia la cuenta atrás del aviso por ausencia |
| `parcial` | `/fail`, o `/log` con `HC_SUFIJO_PARCIAL='/log'` | Con `/log`: queda registrado **sin** encender la alarma |
| `degradado` | `/fail` | Enciende la alarma |

`parcial` manda `/fail` **por defecto**, y es deliberado: que `/log` no reinicie la cuenta atrás —y
que por tanto un degradado sostenido acabe cayendo solo— está **deducido** de la documentación, no
escrito en ella. Compruébalo con un check de usar y tirar (manda `/log`, espera a que pase periodo +
margen, mira si cae) antes de fiarte; si cae, pon `HC_SUFIJO_PARCIAL='/log'` y tendrás el nivel
intermedio.

### Un solo canal: healthchecks.io lo reenvía a donde quieras

`deploy.sh --vigilar` instala **un** hook, `10-healthchecks.sh`, y es suficiente. Cubre el fallo que
la máquina no puede contar por sí misma —**que esté apagada o sin internet**—: nadie manda un aviso
desde un host muerto, así que la vuelta es un **latido invertido**, y es el servicio quien avisa
cuando el ping **deja de llegar**. Por eso ignora `VIGILAR_CAMBIO` a propósito: tiene que mandarse
siempre.

**Y el informe llega igual a Telegram.** healthchecks.io reenvía el cuerpo del ping en su
notificación, envuelto en `<pre>` —monospace, columnas alineadas—, más el nombre del check, el
proyecto, las etiquetas y **el estado de los demás checks** («The following checks are also down»),
que con varios clusters es justo lo que quieres saber. El enrutado (Telegram, correo, Slack…) se
configura **en su web**, sin tocar ninguna máquina.

> El cuerpo se recorta a **1000 caracteres** en Telegram. El informe son ~290 con 3 runners y ~940
> con 20, así que cabe; por encima de eso se corta el final.

`hooks/20-telegram.sh.ejemplo` sigue en el repo, pero **ya no se instala por defecto**: mandaba el
mismo informe al mismo chat, con un segundo secreto que mantener en cada máquina. Actívalo solo si
quieres un canal **independiente del proveedor** — el precio es dos mensajes por evento.

### Ver el estado y ajustar

```bash
podman compose logs -f vigia                                   # el informe de cada ronda
podman compose exec vigia /home/runner/vigilar.sh --informe     # una lectura ahora mismo
podman compose restart vigia                                    # aplicar un cambio de configuración
```

- **Igual en los tres sistemas.** No hace falta `loginctl enable-linger` para el vigía: no depende de los *healthchecks* de podman, porque cada runner publica su estado desde dentro. (El `HEALTHCHECK` de la imagen sigue ahí para `podman ps`, pero el camino de vigilancia ya no depende de él.)
- **Tres niveles, no dos.** `sano`, `parcial` (alguno caído pero **la CI sigue corriendo**) y `degradado`. El umbral es `--vigilar-minimo N`, por defecto 1. Colapsarlo a binario obliga a elegir entre gritar por un runner de tres o callar cuando ya no queda ninguno.
- **Latido rancio = caído.** Si un runner deja de publicar durante más de `VIGIA_RANCIO` (120 s), se da por caído: cubre el contenedor parado, borrado o congelado. No distingue entre ellos, y operativamente es la misma alerta.
- **Umbral del reloj:** avisa a partir de 60 s de desfase (`VIGIA_DESFASE_MAX`). Se mide **desde dentro del contenedor**, que es el reloj que los runners usan de verdad; en macOS ese es el de la VM de podman, que es la que se desincroniza al suspender.
- **Windows:** el bit de ejecución puede no sobrevivir al *bind mount* de `./vigia`. Si el informe dice «Hooks ignorados», corre `podman compose exec vigia chmod +x /etc/gh-runner/vigia/hooks.d/*.sh`.

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
| `RUNNER_HOST_LABEL` | no | Etiqueta de máquina (`host:mi-equipo`), la pone `deploy.sh`. Va **aparte** de `RUNNER_LABELS` a propósito: si fuera dentro, borraría el default de arriba en los despliegues sin `--labels` y un `runs-on: [self-hosted, ubuntu-24.04]` dejaría de casar. El entrypoint la **suma** a lo que haya. |
| `RUNNER_GROUP` | no | Runner group |
| `RUNNER_DISABLE_UPDATE` | no | Desactiva el auto-update del runner dentro del contenedor (def. `yes`). Un self-update a mitad de job cancela el job y, al ser efímero, puede dejarlo en crash-loop; la imagen ya trae la última versión (rebuild diario). Pon `no` (o `0`) para reactivar el self-update. |
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

- **CI:** `ci.yml` corre `shellcheck` (scripts), `hadolint` (Containerfile) y un *smoke test* de la generación del compose en cada push/PR. `build-image.yml` reconstruye y publica diariamente con la última versión de `actions/runner`.
- **Licencia:** [MIT](LICENSE).
