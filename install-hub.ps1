<#
  EDGE-PKG-2-WIN / EDGE-PKG-5-WIN - Restaurant OS Edge Hub installer (Windows)

  Runs AS THE INTERACTIVE USER. Docker Desktop is a PER-USER application (its engine
  pipe and `.docker` context live in the logged-in user's profile), so all Docker
  work - `docker info`, `docker compose pull/up` - MUST run in that user's session.
  This script therefore does NOT self-elevate. It elevates only the few genuinely
  privileged steps (firewall rule, winget/wsl install), each briefly and on its own,
  then drops back to the user context.

  One command to install and start the hub on a Windows mini-PC:
    * makes sure Docker is installed AND running (installs Docker Desktop for you
      if it's missing - Ubuntu parity - and starts it if it's just not running),
    * downloads the public compose + env template from the PUBLIC hub repo
      (raw.githubusercontent.com/Vahan132/restaurant-os-hub) - no auth, no login,
    * generates the required auth secrets into .env.edge (nothing to hand-edit),
    * opens the LAN port in Windows Firewall (elevates just for that),
    * pulls the public image and brings the stack up.

  No registry credentials are ever needed (the image is public). The hub's
  identity + keys arrive later, when you pair it at /setup.

  IMPORTANT: run this NORMALLY (double-click install-hub.bat). Do NOT "Run as
  administrator" - that can start it under a different Windows account than the one
  running Docker Desktop, and Docker would be unreachable.

  Examples:
    .\install-hub.ps1                       # uses defaults below
    .\install-hub.ps1 -Tag edge-v0.1.0 -Port 3001 -ConfigureBootOnPower

  Exit codes (so a wrapper / scheduled task can react):
    0  success - hub is starting
    2  Docker was just installed and the machine must REBOOT; re-run afterwards
    3  winget is unavailable - Docker must be installed by hand (URL printed)
    4  Docker is installed but the engine did not become ready in time
    5  the automatic Docker install failed / was declined (details + URL printed)
    6  running elevated and Docker is unreachable - re-run WITHOUT administrator
#>
[CmdletBinding()]
param(
  [string]$Tag = 'edge-v0.1.0',                       # image release to PIN (EDGE_IMAGE_TAG)
  [string]$Repo = 'Vahan132/restaurant-os-hub',      # PUBLIC repo holding the dist files
  [string]$Branch = 'main',                           # branch to fetch the raw dist files from
  [int]$Port = 3001,                                  # LAN port the hub serves on
  [string]$InstallDir = 'C:\RestaurantOS',            # where the hub files live
  [string]$CloudUrl = '',                             # optional: your platform base URL
  [int]$DockerStartTimeoutSeconds = 180,              # how long to wait for the engine
  [switch]$SkipDockerAutoInstall                       # detect only; never auto-install
)
# NOTE: -ConfigureBootOnPower was intentionally removed here. Boot-on-power setup
# (enable-boot-on-power.ps1) genuinely needs admin and is run separately, so this
# non-elevated installer no longer chains into it.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Native {
  # Run a native command WITHOUT letting its stderr become a terminating error.
  # PowerShell 5.1 + $ErrorActionPreference='Stop' turns a native command's stderr
  # into a THROW even when the command exits 0 (e.g. `docker info` prints a benign
  # "WARNING: No blkio throttle.read_bps_device support" to stderr). Success is
  # judged by EXIT CODE only. The string / Invoke-Expression form is deliberate: a
  # [scriptblock] parameter trips Set-StrictMode -Version Latest ("variable not
  # set"), so keep the string form (or an equivalent that survives StrictMode).
  param([Parameter(Mandatory)][string]$CommandLine)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    Invoke-Expression "$CommandLine 2>`$null 1>`$null"
    return ($LASTEXITCODE -eq 0)
  } finally { $ErrorActionPreference = $prev }
}

# Known-good Docker locations, used when PATH still doesn't resolve `docker`.
$script:DockerBinDirs = @(
  (Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin'),
  'C:\Program Files\Docker\Docker\resources\bin'
) | Select-Object -Unique
$script:DockerDesktopExe = @(
  (Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'),
  'C:\Program Files\Docker\Docker\Docker Desktop.exe'
) | Select-Object -Unique

function Test-IsElevated {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
    [Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Invoke-Privileged {
  # Run ONE privileged command. If we're already elevated, run it in-process (no
  # extra prompt). Otherwise spawn a single elevated PowerShell for just this
  # command - a brief UAC prompt - then return to the user context.
  # Returns $true on success, $false if the user declined UAC or the command failed.
  param([string[]]$PowerShellArgs)
  if (Test-IsElevated) {
    try {
      & powershell.exe -NoProfile -ExecutionPolicy Bypass @PowerShellArgs
      return ($LASTEXITCODE -eq 0)
    } catch { return $false }
  }
  try {
    $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList (
      @('-NoProfile','-ExecutionPolicy','Bypass') + $PowerShellArgs)
    return ($p.ExitCode -eq 0)
  } catch {
    return $false   # user declined the UAC prompt
  }
}

function Update-SessionPath {
  # From EDGE-PKG-4-WIN: an inherited environment block can predate Docker's PATH
  # entry. Re-read the live Machine + User PATH so `docker` resolves.
  $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
  $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

function Resolve-DockerCli {
  # Returns $true if `docker` is callable after refreshing PATH (and, if needed,
  # after adding a known Docker bin folder to this session's PATH).
  Update-SessionPath
  if (Get-Command docker -ErrorAction SilentlyContinue) { return $true }
  foreach ($dir in $script:DockerBinDirs) {
    if ($dir -and (Test-Path (Join-Path $dir 'docker.exe'))) {
      $env:Path = "$dir;$env:Path"
      return $true
    }
  }
  return $false
}

function Get-DockerState {
  # Three distinct states, never conflated:
  #   NotInstalled - the CLI cannot be found anywhere (system PATH, so account-agnostic).
  #   DaemonDown   - the CLI exists but the engine (Docker Desktop) isn't answering
  #                  in THIS session (down, or unreachable because we're a different user).
  #   Ready        - `docker info` succeeds; the engine is up and reachable here.
  if (-not (Resolve-DockerCli)) { return 'NotInstalled' }
  # `docker info` prints a harmless warning to stderr; judge by exit code only
  # (see Invoke-Native) so a stderr line can't be mistaken for the daemon being down.
  if (Invoke-Native 'docker info') { return 'Ready' } else { return 'DaemonDown' }
}

function Start-DockerDesktop {
  foreach ($exe in $script:DockerDesktopExe) {
    if ($exe -and (Test-Path $exe)) {
      if (-not (Get-Process 'Docker Desktop' -ErrorAction SilentlyContinue)) {
        Start-Process $exe | Out-Null
      }
      return $true
    }
  }
  return $false
}

function Wait-DockerReady {
  param([int]$TimeoutSeconds)
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ($true) {
    if ((Get-DockerState) -eq 'Ready') { return $true }
    if ((Get-Date) -gt $deadline) { return $false }
    Write-Host "  ...waiting for Docker to start"
    Start-Sleep -Seconds 5
  }
}

function Show-ElevationHelp {
  Write-Warning @"
Docker is not reachable from this session.

This almost always means the installer is running as a DIFFERENT Windows account
than the one running Docker Desktop - usually because it was started with
"Run as administrator" and Windows switched to an admin account.

  1. Close this window.
  2. Double-click install-hub.bat NORMALLY (do NOT "Run as administrator").

The installer only needs admin for a couple of small steps and will ask for it
just for those.
"@
}

function Install-DockerDesktop {
  # Ubuntu parity: the .sh runs `get.docker.com`; here we use winget - but the
  # install (winget + WSL2) is the one part that needs admin, so it runs in a single
  # elevated child. Returns: NoWinget | Installed | RebootRequired | Failed.
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { return 'NoWinget' }

  # Elevated helper script: enable WSL2 if needed, then winget-install Docker Desktop.
  # Exit codes are read back by the (non-elevated) parent: 0 ok, 10 reboot, 12 failed.
  $elevated = @'
$ErrorActionPreference = "Continue"
$reboot = $false
$wslReady = $false
try { wsl.exe --status *> $null; if ($LASTEXITCODE -eq 0) { $wslReady = $true } } catch {}
if (-not $wslReady) {
  wsl.exe --install --no-distribution *> $null
  if ($LASTEXITCODE -ne 0) { wsl.exe --install *> $null }
  $reboot = $true
}
winget install -e --id Docker.DockerDesktop --accept-package-agreements --accept-source-agreements --silent | Out-Host
$code = $LASTEXITCODE
$present = Test-Path "C:\Program Files\Docker\Docker\resources\bin\docker.exe"
if (-not $present -and $code -ne 0) { exit 12 }
if ($reboot) { exit 10 }
exit 0
'@
  $tmp = Join-Path $env:TEMP ("edge-docker-install-{0}.ps1" -f ([guid]::NewGuid().ToString('N')))
  Set-Content -Path $tmp -Value $elevated -Encoding UTF8

  Write-Host "  installing Docker Desktop (this needs admin once, and can take several minutes)..."
  $exit = $null
  if (Test-IsElevated) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp
    $exit = $LASTEXITCODE
  } else {
    try {
      $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File', $tmp)
      $exit = $p.ExitCode
    } catch {
      Remove-Item $tmp -ErrorAction SilentlyContinue
      return 'Failed'   # user declined the UAC prompt
    }
  }
  Remove-Item $tmp -ErrorAction SilentlyContinue

  switch ($exit) {
    0       { return 'Installed' }
    10      { return 'RebootRequired' }
    12      { return 'Failed' }
    default { if (Resolve-DockerCli) { return 'Installed' } else { return 'Failed' } }
  }
}

function Show-ManualDockerHelp {
  Write-Warning @"
Couldn't install Docker automatically on this machine.

  1. Install Docker Desktop by hand (keep the WSL 2 option ticked):
       https://www.docker.com/products/docker-desktop/
  2. Restart the computer if it asks.
  3. Open Docker Desktop once and wait until it says "Engine running."
  4. Run install-hub.bat again (normally, not as administrator).
"@
}

function Ensure-DockerReady {
  # Guarantees the engine is up and reachable in THIS (user) session before we touch
  # compose - or exits with a clear, jargon-light message and a distinct code.
  $state = Get-DockerState

  if ($state -eq 'Ready') {
    Write-Host "Docker is installed and running." -ForegroundColor Green
    return
  }

  if ($state -eq 'DaemonDown') {
    # CLI is present but `docker info` failed. If we're elevated, the overwhelmingly
    # likely cause is a different-account session, not a stopped engine - so say so
    # immediately instead of waiting out the whole timeout (EDGE-PKG-5 2.3).
    if (Test-IsElevated) {
      Show-ElevationHelp
      exit 6
    }
    Write-Host "Docker is installed but not running yet. Starting Docker Desktop..." -ForegroundColor Cyan
    if (-not (Start-DockerDesktop)) {
      Write-Warning @"
Docker is installed but I couldn't find "Docker Desktop.exe" to start it.
  1. Open Docker Desktop from the Start menu and wait for "Engine running."
  2. Then run install-hub.bat again.
"@
      exit 4
    }
    if (Wait-DockerReady -TimeoutSeconds $DockerStartTimeoutSeconds) {
      Write-Host "Docker engine is now running." -ForegroundColor Green
      return
    }
    Write-Warning @"
Docker didn't finish starting within $DockerStartTimeoutSeconds seconds.
  1. Open Docker Desktop and wait until it says "Engine running."
  2. Then run install-hub.bat again.
"@
    exit 4
  }

  # state -eq 'NotInstalled'
  if ($SkipDockerAutoInstall) {
    Write-Warning @"
Docker Desktop isn't installed and auto-install was skipped (-SkipDockerAutoInstall).
Install it, then run install-hub.bat again:
  https://www.docker.com/products/docker-desktop/
"@
    exit 3
  }

  Write-Host "Docker Desktop isn't installed. Installing it for you..." -ForegroundColor Cyan
  switch (Install-DockerDesktop) {
    'NoWinget' {
      Write-Warning @"
This computer doesn't have 'winget' (the Windows app installer), so I can't
install Docker automatically.
"@
      Show-ManualDockerHelp
      exit 3
    }
    'Failed' {
      Show-ManualDockerHelp
      exit 5
    }
    'RebootRequired' {
      Write-Host ""
      Write-Host "Docker Desktop was installed, but Windows needs to RESTART to finish" -ForegroundColor Yellow
      Write-Host "turning on WSL2 (the piece Docker runs on)." -ForegroundColor Yellow
      Write-Host "  1. Restart this computer." -ForegroundColor Yellow
      Write-Host "  2. After it comes back, run install-hub.bat again - it will continue." -ForegroundColor Yellow
      exit 2
    }
    'Installed' {
      Write-Host "Docker Desktop installed. Starting it..." -ForegroundColor Cyan
      Start-DockerDesktop | Out-Null
      if (Wait-DockerReady -TimeoutSeconds $DockerStartTimeoutSeconds) {
        Write-Host "Docker engine is now running." -ForegroundColor Green
        return
      }
      Write-Host ""
      Write-Host "Docker Desktop was installed but the engine didn't come up yet - this" -ForegroundColor Yellow
      Write-Host "usually means Windows needs one RESTART to finish setup." -ForegroundColor Yellow
      Write-Host "  1. Restart this computer." -ForegroundColor Yellow
      Write-Host "  2. After it comes back, run install-hub.bat again." -ForegroundColor Yellow
      exit 2
    }
  }
}

function New-Secret {
  # 24 random bytes -> 48 hex chars (well above the 16-char minimum).
  $bytes = New-Object 'System.Byte[]' 24
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

function Set-EnvValue {
  param([string]$Path, [string]$Key, [string]$Value)
  $line = "$Key=$Value"
  if (Test-Path $Path) {
    $content = Get-Content $Path
    if ($content -match "^\s*$([regex]::Escape($Key))=") {
      (Get-Content $Path) -replace "^\s*$([regex]::Escape($Key))=.*", $line | Set-Content $Path -Encoding UTF8
      return
    }
  }
  Add-Content -Path $Path -Value $line -Encoding UTF8
}

function Get-DistFile {
  # Fetch a dist file from the PUBLIC hub repo by its RAW URL. Raw URLs need no
  # auth (public repo), serve the file under its real name (so `.env.edge.example`
  # is NOT renamed to `default.env.edge.example` the way a Release asset download
  # would be), and don't depend on a Release existing. The image version is pinned
  # separately via -Tag (EDGE_IMAGE_TAG), not by this path.
  param([string]$Name, [string]$OutFile)
  $url = "https://raw.githubusercontent.com/$Repo/$Branch/$Name"
  Write-Host "  downloading $Name ..."
  Invoke-WebRequest -Uri $url -OutFile $OutFile -UseBasicParsing
}

function Set-HubFirewallRule {
  # Opening a LAN port genuinely needs admin - elevate JUST this, idempotently.
  # If the user declines, the hub still runs; only remote (tablet/phone) access is
  # affected, so warn and continue (EDGE-PKG-5 2.2).
  param([int]$Port)
  $ruleName = "RestaurantOS Hub $Port"
  $exists = $false
  try { if (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue) { $exists = $true } } catch { }
  if ($exists) { Write-Host "Firewall already allows TCP $Port."; return }

  $cmd = "if (-not (Get-NetFirewallRule -DisplayName '$ruleName' -ErrorAction SilentlyContinue)) { " +
         "New-NetFirewallRule -DisplayName '$ruleName' -Direction Inbound -Action Allow " +
         "-Protocol TCP -LocalPort $Port -Profile Any | Out-Null }"
  if (Invoke-Privileged -PowerShellArgs @('-Command', $cmd)) {
    Write-Host "Opened inbound TCP $Port in Windows Firewall."
  } else {
    Write-Warning @"
Skipped opening the firewall port (you may have declined the prompt).
The hub still runs - but LAN devices (tablets/phones) may not reach it until TCP
$Port is allowed. You can re-run install-hub.bat later to open it.
"@
  }
}

# ---- 1. Preconditions -------------------------------------------------------
# NOTE (EDGE-PKG-5): no Assert-Admin here. This script runs as the interactive user
# on purpose; admin is requested per-step only.

Write-Host "Restaurant OS Edge Hub installer" -ForegroundColor Cyan
Write-Host "  release : $Tag"
Write-Host "  folder  : $InstallDir"
Write-Host "  port    : $Port"
if (Test-IsElevated) {
  Write-Warning "This window is running as administrator. Docker work must run as your normal user; if Docker turns out to be unreachable, close this and run install-hub.bat WITHOUT 'Run as administrator'."
}
Write-Host ""

# Robust Docker detection + auto-install/-start, all in the USER context. Returns
# only when the engine is ready; otherwise it printed guidance and exited above.
Ensure-DockerReady

# ---- 2. Files ---------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Set-Location $InstallDir

Get-DistFile -Name 'docker-compose.edge.yml' -OutFile (Join-Path $InstallDir 'docker-compose.edge.yml')
if (-not (Test-Path (Join-Path $InstallDir '.env.edge.example'))) {
  Get-DistFile -Name '.env.edge.example' -OutFile (Join-Path $InstallDir '.env.edge.example')
}

# ---- 3. Environment + secrets ----------------------------------------------
$envFile = Join-Path $InstallDir '.env.edge'
if (-not (Test-Path $envFile)) {
  Copy-Item (Join-Path $InstallDir '.env.edge.example') $envFile
  Write-Host "Generating auth secrets into .env.edge ..."
  foreach ($k in 'JWT_ACCESS_SECRET','JWT_REFRESH_SECRET','CONSUMER_JWT_ACCESS_SECRET','CONSUMER_JWT_REFRESH_SECRET') {
    Set-EnvValue -Path $envFile -Key $k -Value (New-Secret)
  }
  Set-EnvValue -Path $envFile -Key 'EDGE_IMAGE_TAG' -Value $Tag
  if ($CloudUrl) { Set-EnvValue -Path $envFile -Key 'CLOUD_URL' -Value $CloudUrl }
  Set-EnvValue -Path $envFile -Key 'PORT' -Value $Port
} else {
  Write-Host ".env.edge already exists - keeping your settings (not regenerating secrets)."
}

# ---- 4. Firewall (LAN access from tablets/phones) - elevates just this step ---
Set-HubFirewallRule -Port $Port
# EDGE-OFFLINE-UI: the bundled proxy serves POS/KDS/Admin on :80 over the LAN,
# so open that too (offline screens reach the apps here, not just the API).
Set-HubFirewallRule -Port 80

# ---- 5. Bring the stack up (as the USER - Docker lives in this profile) -------
Write-Host "Pulling the public image and starting the hub ..." -ForegroundColor Cyan
# Both compose calls write normal progress to stderr; under $ErrorActionPreference
# 'Stop' that stderr would throw mid-pull, so route them through Invoke-Native and
# judge success by exit code.
if (-not (Invoke-Native 'docker compose -f docker-compose.edge.yml --env-file .env.edge pull')) {
  Write-Warning "docker compose pull reported a problem; continuing to 'up' (an already-present image will still be used)."
}
if (-not (Invoke-Native 'docker compose -f docker-compose.edge.yml --env-file .env.edge up -d')) {
  Write-Warning "docker compose up failed. Run it manually in $InstallDir to see the error:"
  Write-Warning "  docker compose -f docker-compose.edge.yml --env-file .env.edge up -d"
  exit 1
}

# ---- 6. Where to go next ----------------------------------------------------
$lan = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' } |
        Select-Object -First 1 -ExpandProperty IPAddress)
Write-Host ""
Write-Host "Done. The hub is starting." -ForegroundColor Green
Write-Host "  On this machine : http://localhost:$Port/setup"
if ($lan) { Write-Host "  From a tablet   : http://$lan`:$Port/setup" }
Write-Host ""
if ($lan) { Write-Host "  POS/KDS/Admin   : http://$lan/res/pos  |  http://$lan/res/kds  |  http://$lan/res/admin" }
Write-Host ""
Write-Host "Open that page, enter your pairing code, and the hub takes over from there."
Write-Host ""
Write-Host "To make the hub restart by itself after a power cut, right-click"
Write-Host "enable-boot-on-power.ps1 -> Run with PowerShell (that step needs admin)."
