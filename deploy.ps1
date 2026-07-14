<#
.SYNOPSIS
  Despliega uno o varios GitHub self-hosted runners (efímeros, con auto-reinicio
  y cache persistente) usando Podman/Docker Compose. Equivalente a deploy.sh
  para Windows PowerShell (sin necesitar Git Bash ni WSL2 en la shell).

.DESCRIPTION
  Genera .env (o un file-secret) y compose.yaml en el directorio actual, y
  opcionalmente levanta el stack. Requiere un motor de contenedores con
  proveedor de compose (Docker Desktop trae 'docker compose'; para Podman
  instala 'podman-compose' o 'docker-compose').

.EXAMPLE
  .\deploy.ps1 -Repo OWNER/REPO -Token <PAT> -Count 3 -Prefix ci -Up

.EXAMPLE
  # Un comando desde internet (permite pasar parámetros):
  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/JoseAmador95/gh_runner/main/deploy.ps1))) -Repo OWNER/REPO -Token <PAT> -Count 3 -Up

.EXAMPLE
  # O descargar y ejecutar (modo interactivo si faltan datos):
  irm https://raw.githubusercontent.com/JoseAmador95/gh_runner/main/deploy.ps1 -OutFile deploy.ps1
  .\deploy.ps1
#>
[CmdletBinding()]
param(
    [string]$Repo,
    [string]$Owner,
    [string]$Name,
    [string]$Token,
    [int]$Count = 0,
    [string]$Prefix,
    [string]$Labels,
    [string]$Group,
    [string]$Image,
    [ValidateSet('podman', 'docker')][string]$Engine,
    [string]$CacheDirs,
    [string[]]$Mount,
    [string[]]$Network,
    [string]$ComposeExtra,
    [string]$Cpus,
    [string]$Memory,
    [switch]$PullAlways,
    [switch]$NoPullAlways,
    [string]$File = 'compose.yaml',
    [switch]$Secret,
    [switch]$Up,
    [switch]$NoUp,
    [switch]$SkipValidation,
    [switch]$Force,
    [switch]$NoBootstrap,
    [switch]$Help
)

# NO usar 'Stop': los comandos nativos (podman/docker compose) escriben avisos a
# stderr (p.ej. "Executing external compose provider"), y bajo 'Stop' Windows
# PowerShell los convierte en un error TERMINANTE (NativeCommandError). Con
# 'Continue' esos stderr son inofensivos; los errores de cmdlets que sí nos
# importan se capturan con try/catch + -ErrorAction Stop puntual.
$ErrorActionPreference = 'Continue'
# Tampoco hacer throw por el código de salida de comandos nativos (PS 7.3+).
$PSNativeCommandUseErrorActionPreference = $false

$Marker     = '# GENERADO por deploy'   # prefijo común con deploy.sh
$SecretFile = 'access_token'
$ImageDefault = 'ghcr.io/joseamador95/gh_runner:latest'

function Die($m)  { [Console]::Error.WriteLine("ERROR: $m"); exit 1 }
function Info($m) { [Console]::Error.WriteLine($m) }
function Have($n) { [bool](Get-Command $n -ErrorAction SilentlyContinue) }

# Rechaza valores con saltos de línea / caracteres de control (anti-inyección YAML/.env).
function Assert-Clean($name, $val) {
    if ($val -and $val -match '[\x00-\x1F\x7F]') {
        Die "valor inválido para ${name}: contiene saltos de línea o caracteres de control (posible inyección)."
    }
}

function Show-Usage {
    @"
Uso: deploy.ps1 [parámetros]

Repositorio y credenciales:
  -Repo OWNER/REPO       Repositorio objetivo (o usar -Owner y -Name)
  -Owner OWNER           Owner del repo
  -Name  REPO            Nombre del repo
  -Token PAT             Personal Access Token (Administration: Read and write).
                         Si se omite: env ACCESS_TOKEN -> 'gh auth token' -> prompt.

Despliegue:
  -Count N               Número de runners (por defecto 1)
  -Prefix P              Prefijo del nombre de runner (por defecto 'gh')
  -Labels L              Etiquetas extra separadas por comas
  -Group G               Runner group (opcional)
  -Image REF             Imagen (por defecto $ImageDefault)
  -Engine podman|docker  Fuerza el motor (por defecto autodetecta)
  -CacheDirs A,B         Dirs extra de cache por runner (p.ej. .npm,.cargo)
  -Mount a:/x,b:/y       Volumen/bind extra en CADA runner (lista por comas). SRC
                         nombre de volumen (compartido; se declara) o ruta (bind).
  -Network n1,n2         Red extra en CADA runner (lista por comas; n:external para
                         una red externa ya existente). Los sidecars del override
                         ya son alcanzables por nombre vía la red por defecto.
  -ComposeExtra FILE     Override de compose a encadenar (autodetecta compose.override.yaml)
  -Cpus N                Límite de CPU por runner (p.ej. 2)
  -Memory SIZE           Límite de memoria por runner (p.ej. 2g)
  -PullAlways            (default) pull_policy: always: cada 'up -d' re-baja :latest
  -NoPullAlways          Quita pull_policy: always (fija la imagen local cacheada)
  -File PATH             Ruta del compose a generar (por defecto compose.yaml)

Seguridad:
  -Secret                Guarda el PAT como file-secret (.\access_token) en vez de en .env

Ejecución:
  -Up / -NoUp            Levantar o no el stack tras generar
  -SkipValidation        No validar el token contra la API
  -Force                 Sobreescribe compose.yaml/.env/access_token ajenos
  -NoBootstrap           No instalar podman/compose ni crear la machine (gestionas el entorno tú)
  -Help                  Esta ayuda

Variables de entorno usadas como fallback:
  ACCESS_TOKEN, REPO_USER, REPO_NAME, RUNNER_PREFIX, RUNNER_COUNT,
  RUNNER_LABELS, RUNNER_GROUP, IMAGE, RUNNER_CPUS, RUNNER_MEMORY
"@ | Write-Output
}

if ($Help) { Show-Usage; exit 0 }

$Interactive = [Environment]::UserInteractive

# ---- Resolución de campos (flag -> env -> prompt) --------------------------
if ($Repo) {
    if ($Repo -notmatch '/') { Die "-Repo debe ser OWNER/REPO" }
    $Owner = $Repo.Split('/')[0]
    $Name  = $Repo.Split('/', 2)[1]
}
if (-not $Owner) { $Owner = $env:REPO_USER }
if (-not $Name)  { $Name  = $env:REPO_NAME }
if (-not $Owner) { if ($Interactive) { $Owner = (Read-Host 'Owner del repo (OWNER)').Trim() } else { Die "falta OWNER (-Owner/-Repo o REPO_USER)" } }
if (-not $Name)  { if ($Interactive) { $Name  = (Read-Host 'Nombre del repo (REPO)').Trim() } else { Die "falta NAME (-Name/-Repo o REPO_NAME)" } }
if (-not $Owner -or -not $Name) { Die "faltan owner y/o name del repositorio" }

if (-not $Prefix) { $Prefix = if ($env:RUNNER_PREFIX) { $env:RUNNER_PREFIX } else { 'gh' } }
if ($PSBoundParameters.ContainsKey('Count')) {
    if ($Count -lt 1) { Die "-Count debe ser >= 1" }
}
elseif ($env:RUNNER_COUNT) {
    if ($env:RUNNER_COUNT -notmatch '^\d+$') { Die "RUNNER_COUNT debe ser un entero positivo" }
    $Count = [int]$env:RUNNER_COUNT
    if ($Count -lt 1) { Die "RUNNER_COUNT debe ser >= 1" }
}
else { $Count = 1 }
if (-not $Labels) { $Labels = $env:RUNNER_LABELS }
if (-not $Group)  { $Group  = $env:RUNNER_GROUP }
if (-not $Image)  { $Image  = if ($env:IMAGE) { $env:IMAGE } else { $ImageDefault } }
if (-not $Cpus)   { $Cpus   = $env:RUNNER_CPUS }
if (-not $Memory) { $Memory = $env:RUNNER_MEMORY }

# Anti-inyección: nada que llegue al compose/.env con saltos de línea o control.
Assert-Clean owner  $Owner
Assert-Clean name   $Name
Assert-Clean prefix $Prefix
Assert-Clean labels $Labels
Assert-Clean group  $Group
Assert-Clean image  $Image
Assert-Clean cpus   $Cpus
Assert-Clean memory $Memory
Assert-Clean 'cache-dirs' $CacheDirs
if ($PullAlways -and $NoPullAlways) { Die "no combines -PullAlways y -NoPullAlways" }

# ---- Token: flag -> ACCESS_TOKEN -> 'gh auth token' -> prompt --------------
$tokenSrc = 'flag -Token'
if (-not $Token) {
    if ($env:ACCESS_TOKEN) {
        $Token = $env:ACCESS_TOKEN; $tokenSrc = 'env ACCESS_TOKEN'
    }
    elseif (Have 'gh') {
        $t = & gh auth token 2>$null
        if ($LASTEXITCODE -eq 0 -and $t) { $Token = ("$t").Trim(); $tokenSrc = 'gh auth token' }
    }
    if (-not $Token) {
        if ($Interactive) {
            $sec = Read-Host -AsSecureString 'PAT (Administration R/W)'
            $Token = [System.Net.NetworkCredential]::new('', $sec).Password
            $tokenSrc = 'prompt'
        }
        else { Die "falta el token (-Token / ACCESS_TOKEN / gh)" }
    }
}
if (-not $Token) { Die "el token está vacío" }

# ---- Detección de motor y compose -----------------------------------------
function Get-ComposeFor($eng) {
    switch ($eng) {
        'podman' {
            if (Have 'podman') {
                # 2>&1 | Out-Null descarta stdout Y stderr (podman avisa por stderr
                # aunque el proveedor funcione); $LASTEXITCODE da el resultado real.
                & podman compose version 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { return , @('podman', 'compose') }
                if (Have 'podman-compose') { return , @('podman-compose') }
            }
        }
        'docker' {
            if (Have 'docker') {
                & docker compose version 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { return , @('docker', 'compose') }
                if (Have 'docker-compose') { return , @('docker-compose') }
            }
        }
    }
    return $null
}

# ---- Bootstrap del entorno (podman + compose + machine) -------------------
# Windows: winget para podman; podman machine (WSL2) si no existe. -NoBootstrap
# lo salta. No-op si ya está todo.
function Ensure-Podman {
    if (Have 'podman') { return }
    if (-not (Have 'winget')) { Die "falta podman y no hay winget. Instala Podman Desktop (https://podman-desktop.io) o usa -NoBootstrap." }
    Info "podman no está instalado; instalando con winget (RedHat.Podman)..."
    & winget install -e --id RedHat.Podman --accept-source-agreements --accept-package-agreements
    if (-not (Have 'podman')) { Die "la instalación no dejó 'podman' en el PATH; reinicia la shell y reintenta (o usa -NoBootstrap)." }
}
function Ensure-Compose {
    if (Get-ComposeFor 'podman') { return }
    if ((Have 'docker') -and (Get-ComposeFor 'docker')) { return }
    if (Have 'winget') {
        Info "Falta un proveedor de compose; instalando docker-compose con winget..."
        & winget install -e --id Docker.DockerCompose --accept-source-agreements --accept-package-agreements
    }
    if (Get-ComposeFor 'podman') { return }
    if ((Have 'docker') -and (Get-ComposeFor 'docker')) { return }
    Die "sigo sin un proveedor de compose. Instala 'docker compose' (Docker/Podman Desktop) o usa -NoBootstrap."
}
function Ensure-Machine {
    if (-not (Have 'podman')) { return }
    $names = & podman machine list --format '{{.Name}}' 2>$null
    if (-not $names) {
        Info "No hay podman machine; creándola (init --now)..."
        & podman machine init --now
    }
    else {
        & podman info *> $null
        if ($LASTEXITCODE -ne 0) { Info "Arrancando la podman machine..."; & podman machine start *> $null }
    }
}
if (-not $NoBootstrap) {
    Ensure-Podman
    Ensure-Compose
    Ensure-Machine
}

$engines = if ($Engine) { , $Engine } else { @('podman', 'docker') }
$ComposeCmd = $null
$EngineName = $null
foreach ($e in $engines) {
    if (-not (Have $e)) { continue }
    $c = Get-ComposeFor $e
    if ($c) { $ComposeCmd = $c; $EngineName = $e; break }
}
if (-not $ComposeCmd) {
    if ($Engine -and -not (Have $Engine)) { Die "-Engine $($Engine): no se encontró '$Engine' en el PATH" }
    if ((Have 'podman') -or (Have 'docker')) {
        Die @"
hay motor de contenedores pero falta un proveedor de compose. Instala uno:
  - Podman (no trae compose): 'pip3 install podman-compose', o instala Docker Desktop
    (que incluye 'docker compose'), o el binario docker-compose.
  - Docker: Docker Desktop ya incluye 'docker compose'.
  Verifica con 'podman compose version' o 'docker compose version'.
"@
    }
    else { Die "no se encontró 'podman' ni 'docker' en el PATH" }
}

# Aviso de capacidad: proveedores "legacy" con soporte parcial del compose.
if ($ComposeCmd.Count -eq 1 -and $ComposeCmd[0] -in @('podman-compose', 'docker-compose')) {
    Info "AVISO: '$($ComposeCmd[0])' puede no soportar del todo 'secrets:'/'deploy:'/merge YAML. Si 'up' falla, usa 'podman compose' o 'docker compose' (plugin v2)."
}

# ---- Validación del token contra la API (fail-fast) -----------------------
if (-not $SkipValidation) {
    Info "Validando el token contra la API de GitHub..."
    try {
        $headers = @{
            Authorization          = "Bearer $Token"
            Accept                 = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2022-11-28'
            'User-Agent'           = 'gh_runner-deploy'
        }
        $resp = Invoke-RestMethod -Method Post -Headers $headers -ErrorAction Stop `
            -Uri "https://api.github.com/repos/$Owner/$Name/actions/runners/registration-token"
        if (-not $resp.token) { throw "respuesta sin token" }
        Info "Token válido."
    }
    catch {
        Die "el token no puede registrar runners en $Owner/$Name. Necesita Administration:R/W sobre el repo. Detalle: $($_.Exception.Message). Usa -SkipValidation para omitir."
    }
}

# ---- Nombre de host corto y saneado ---------------------------------------
$hostShort = $env:COMPUTERNAME
if (-not $hostShort) { $hostShort = 'runner' }
$hostShort = ($hostShort -replace '[^A-Za-z0-9_-]', '-')
if (-not $hostShort) { $hostShort = 'runner' }

# ---- Helpers de escritura (UTF-8 sin BOM, saltos LF) ----------------------
function Write-TextLf($path, $text) {
    $full = if ([System.IO.Path]::IsPathRooted($path)) { $path } else { Join-Path (Get-Location).ProviderPath $path }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($full, $text, $enc)
}
function Protect-File($path) {
    # Best-effort en NTFS: quita herencia y da acceso solo al usuario actual.
    try {
        $full = (Resolve-Path -LiteralPath $path).ProviderPath
        & icacls $full /inheritance:r /grant:r "$($env:USERNAME):(F)" *> $null
        if ($LASTEXITCODE -ne 0) { Info "AVISO: no se pudieron restringir los permisos de ${path} (icacls). Protégelo a mano si el host es compartido." }
    }
    catch { Info "AVISO: no se pudieron restringir los permisos de ${path}." }
}
function Test-Ours($path) {
    if (-not (Test-Path -LiteralPath $path)) { return $true }
    $first = Get-Content -LiteralPath $path -TotalCount 1 -ErrorAction SilentlyContinue
    return ($first -and $first.StartsWith($Marker))
}
function Guard-Overwrite($path) {
    if (Test-Ours $path) { return }
    if ($Force) { return }
    Die "ya existe '$path' y no lo generó deploy. Corre en un directorio DEDICADO, usa -File OTRO.yaml, o -Force para sobreescribir."
}
function Guard-Secret($path) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    if ($Force) { return }
    Die "ya existe '$path' (fichero del secret). Bórralo o usa -Force para sobreescribir."
}

# ---- No pisar ficheros ajenos ---------------------------------------------
Guard-Overwrite '.env'
Guard-Overwrite $File
if ($Secret) { Guard-Secret $SecretFile }

# ---- (opcional) PAT como file-secret --------------------------------------
if ($Secret) {
    Write-TextLf $SecretFile $Token   # verbatim, sin newline
    Protect-File $SecretFile
    Info "Escrito $SecretFile con el PAT (montado como secret)."
}

# ---- Escribir .env ---------------------------------------------------------
$envText = "$Marker (líneas # son comentarios)`n"
if (-not $Secret) { $envText += "ACCESS_TOKEN=$Token`n" }
$envText += "REPO_USER=$Owner`n"
$envText += "REPO_NAME=$Name`n"
if ($Labels) { $envText += "RUNNER_LABELS=$Labels`n" }
if ($Group) { $envText += "RUNNER_GROUP=$Group`n" }
Write-TextLf '.env' $envText
Protect-File '.env'
Info "Escrito .env."

# ---- Dirs de cache extra ---------------------------------------------------
$cacheList = @()
if ($CacheDirs) {
    foreach ($d in ($CacheDirs -split ',')) {
        $d = $d.Trim()
        if (-not $d) { continue }
        $full = if ($d.StartsWith('/')) { $d } else { "/home/runner/$d" }
        $sfx = ($d -replace '[^A-Za-z0-9]', '')
        $cacheList += , @($full, $sfx)
    }
}

# ---- Puntos de extensión: -Mount / -Network (mismos en cada runner) --------
foreach ($m in $Mount) { Assert-Clean mount $m }
foreach ($n in $Network) { Assert-Clean network $n }

# Volúmenes NOMBRADOS de -Mount → se declaran una vez a top-level (compartidos).
# Bind si empieza por ruta (unix / . ~ \) o unidad Windows 'X:\' / 'X:/'.
$namedVols = [System.Collections.Generic.List[string]]::new()
foreach ($m in $Mount) {
    if (-not $m) { continue }
    if ($m -match '^[A-Za-z]:[\\/]' -or $m -match '^[\\/.~]') { continue }
    $src = $m.Split(':')[0]
    if ($src -and -not $namedVols.Contains($src)) { $namedVols.Add($src) }
}

# Redes de -Network → dedup por NOMBRE (1er campo), conservando el sufijo :external.
$netUniq = [System.Collections.Generic.List[string]]::new()
$seenNet = [System.Collections.Generic.HashSet[string]]::new()
foreach ($n in $Network) {
    if (-not $n) { continue }
    if ($seenNet.Add($n.Split(':')[0])) { $netUniq.Add($n) }
}

# ---- Generar el compose ----------------------------------------------------
$c = "$Marker — no editar a mano.`n"
$c += "# Runners: {0} | repo: {1}/{2} | imagen: {3}`n`n" -f $Count, $Owner, $Name, $Image
$c += "x-runner-common: &runner-common`n"
$c += "  image: $Image`n"
$c += "  restart: always`n"
if (-not $NoPullAlways) { $c += "  pull_policy: always`n" }   # default: always (opt-out con -NoPullAlways)
$c += "  env_file: [.env]`n"
if ($Secret) { $c += "  secrets:`n    - access_token`n" }
if ($Cpus -or $Memory) {
    $c += "  deploy:`n    resources:`n      limits:`n"
    if ($Cpus) { $c += "        cpus: `"$Cpus`"`n" }
    if ($Memory) { $c += "        memory: $Memory`n" }
}
$c += "`nservices:`n"
for ($i = 1; $i -le $Count; $i++) {
    $c += "  runner-{0}:`n" -f $i
    $c += "    <<: *runner-common`n"
    $c += "    environment:`n"
    $c += "      RUNNER_NAME: `"{0}-{1}-{2}`"`n" -f $Prefix, $hostShort, $i
    if ($cacheList.Count -gt 0) {
        $dirs = ($cacheList | ForEach-Object { $_[0] }) -join ' '
        $c += "      CACHE_DIRS: `"{0}`"`n" -f $dirs
    }
    $c += "    volumes:`n"
    $c += "      - runner-{0}-work:/home/runner/_work`n" -f $i
    $c += "      - runner-{0}-cache:/home/runner/.cache`n" -f $i
    foreach ($cd in $cacheList) {
        $c += "      - runner-{0}-{1}:{2}`n" -f $i, $cd[1], $cd[0]
    }
    foreach ($m in $Mount) { if ($m) { $c += "      - {0}`n" -f $m } }
    if ($netUniq.Count -gt 0) {
        $c += "    networks:`n      - default`n"
        foreach ($n in $netUniq) { $c += "      - {0}`n" -f ($n.Split(':')[0]) }
    }
}
$c += "`nvolumes:`n"
for ($i = 1; $i -le $Count; $i++) {
    $c += "  runner-{0}-work: {{}}`n" -f $i
    $c += "  runner-{0}-cache: {{}}`n" -f $i
    foreach ($cd in $cacheList) {
        $c += "  runner-{0}-{1}: {{}}`n" -f $i, $cd[1]
    }
}
# Volúmenes nombrados de -Mount (una vez, compartidos entre runners).
foreach ($v in $namedVols) { $c += "  {0}: {{}}`n" -f $v }
# Redes de -Network (top-level). 'default' explícito para conservar la red por
# defecto del proyecto (sidecars alcanzables por nombre).
if ($netUniq.Count -gt 0) {
    $c += "`nnetworks:`n  default: {}`n"
    foreach ($n in $netUniq) {
        $nm = $n.Split(':')[0]
        if ($n -like '*:external') { $c += "  {0}:`n    external: true`n" -f $nm }
        else { $c += "  {0}: {{}}`n" -f $nm }
    }
}
if ($Secret) {
    $c += "`nsecrets:`n  access_token:`n    file: ./access_token`n"
}
Write-TextLf $File $c
Info "Escrito $File con $Count runner(s)."

# ---- Override del proyecto (compose.override.yaml) -------------------------
# -ComposeExtra FILE, o autodetecta .\compose.override.yaml. No se genera ni pisa.
if (-not $ComposeExtra -and (Test-Path 'compose.override.yaml')) { $ComposeExtra = 'compose.override.yaml' }
if ($ComposeExtra -and -not (Test-Path $ComposeExtra)) { Die "-ComposeExtra: no encuentro '$ComposeExtra'" }

# ---- Comandos de control ---------------------------------------------------
# Pasar cualquier -f desactiva el autoload del base, así que con override se
# encadenan AMBOS (-f base -f override).
$auto = @('compose.yaml', 'compose.yml', 'docker-compose.yaml', 'docker-compose.yml')
if ($ComposeExtra) {
    $fileArgs = @('-f', $File, '-f', $ComposeExtra)
    $ctlFiles = "-f $File -f $ComposeExtra"
}
elseif ($auto -notcontains $File) {
    $fileArgs = @('-f', $File); $ctlFiles = "-f $File"
}
else {
    $fileArgs = @(); $ctlFiles = ''
}
$composeDisplay = ($ComposeCmd -join ' ')
$ctl = if ($ctlFiles) { "$composeDisplay $ctlFiles" } else { $composeDisplay }

function Invoke-Compose {
    $exe = $ComposeCmd[0]
    $pre = @()
    if ($ComposeCmd.Count -gt 1) { $pre = $ComposeCmd[1..($ComposeCmd.Count - 1)] }
    & $exe @pre @args
}

# ---- Resumen ---------------------------------------------------------------
Info ""
Info "Resumen:"
Info "  Repo    : $Owner/$Name"
Info "  Runners : $Count (nombres: $Prefix-$hostShort-1..$Count)"
Info "  Imagen  : $Image"
Info "  Token   : $tokenSrc"
if ($Secret) { Info "  PAT     : file-secret (.\$SecretFile)" } else { Info "  PAT     : en .env" }
if ($Cpus -or $Memory) { Info "  Límites : cpus=$(if($Cpus){$Cpus}else{'—'}) memoria=$(if($Memory){$Memory}else{'—'})" }
Info "  Motor   : $EngineName ($composeDisplay)"
if ($ComposeExtra) { Info "  Override: $ComposeExtra" }

# ---- Levantar el stack -----------------------------------------------------
$doUp = if ($NoUp) { $false } elseif ($Up) { $true } else { $Interactive }

if ($doUp) {
    Info ""
    Info "Levantando: $ctl up -d"
    Invoke-Compose @fileArgs up -d
    Info ""
    Info "Listo. Comprueba con: $ctl ps"
}
else {
    Info ""
    Info "Para levantar los runners:"
    Info "  $ctl up -d"
}

Info ""
Info "Comandos útiles (desde este directorio):"
Info "  $ctl ps                 # estado"
Info "  $ctl logs -f runner-1   # logs de un runner"
Info "  $ctl down               # parar y desregistrar"
Info "  $ctl down -v            # + borrar el cache (volúmenes)"
