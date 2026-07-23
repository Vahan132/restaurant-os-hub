<#
  EDGE-PKG-2-WIN / EDGE-PKG-5-WIN - Start the Restaurant OS Edge Hub.

  Ensures the Docker engine is running (launching Docker Desktop and waiting for it
  if needed), then brings the stack up. Safe to run repeatedly - if the hub is
  already up this is a no-op. This is what the logon Scheduled Task runs after a
  power-cut so the hub returns with no human action.

  MUST run as the INTERACTIVE (auto-login) user, NOT SYSTEM. Docker Desktop is a
  per-user application: its engine pipe and context live in that user's profile, so
  SYSTEM (or any other account) can never reach it. enable-boot-on-power.ps1
  registers this task -AtLogOn under that user; this script hard-checks that and
  fails loudly (with a log line) rather than looping forever if it's ever run as
  SYSTEM. Progress is logged to <InstallDir>\start-hub.log for unattended diagnosis.
#>
[CmdletBinding()]
param(
  [string]$InstallDir = 'C:\RestaurantOS',
  [int]$TimeoutSeconds = 240
)

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

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$script:LogFile = Join-Path $InstallDir 'start-hub.log'

function Write-Log {
  param([string]$Message)
  $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
  Write-Host $line
  try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 } catch { }
}

$script:DockerBinDirs = @(
  (Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin'),
  'C:\Program Files\Docker\Docker\resources\bin'
) | Select-Object -Unique
$script:DockerDesktopExe = @(
  (Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'),
  'C:\Program Files\Docker\Docker\Docker Desktop.exe'
) | Select-Object -Unique

function Update-SessionPath {
  # A logon task starts with the environment as it was at sign-in, which may predate
  # Docker's PATH entry. Re-read the live Machine + User PATH so `docker` resolves.
  $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
  $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

function Resolve-DockerCli {
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

function Test-DockerReady {
  # $true only if the Docker engine is installed AND responding in THIS session.
  # Uses `docker info` (daemon reachable), not `docker --version` (CLI present).
  if (-not (Resolve-DockerCli)) { return $false }
  # Judge readiness by exit code only; `docker info` writes a harmless warning to
  # stderr that would otherwise throw under 'Stop' and be misread as "not ready"
  # (an infinite wait / silent boot-on-power failure). See Invoke-Native.
  return (Invoke-Native 'docker info')
}

# ---- Guard: this MUST be the interactive user, not SYSTEM -------------------
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if ($identity.IsSystem) {
  Write-Log "ERROR: start-hub.ps1 is running as SYSTEM ($($identity.Name))."
  Write-Log "Docker Desktop is per-user and is NOT reachable from SYSTEM, so the hub"
  Write-Log "cannot be started here. Fix the boot-on-power task to run as the"
  Write-Log "interactive auto-login user (re-run enable-boot-on-power.ps1), then reboot."
  exit 1
}
Write-Log "start-hub: running as $($identity.Name); InstallDir=$InstallDir"

Set-Location $InstallDir

if (-not (Test-DockerReady)) {
  # Launch Docker Desktop if it isn't already coming up.
  $dd = $script:DockerDesktopExe | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
  if ($dd) {
    if (-not (Get-Process 'Docker Desktop' -ErrorAction SilentlyContinue)) {
      Write-Log "Launching Docker Desktop..."
      Start-Process $dd | Out-Null
    }
  } else {
    Write-Log "WARNING: Docker Desktop.exe not found in the usual location; waiting anyway."
  }
  Write-Log "Waiting up to $TimeoutSeconds s for the Docker engine to become ready..."
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while (-not (Test-DockerReady)) {
    if ((Get-Date) -gt $deadline) {
      Write-Log "ERROR: Docker engine did not become ready within $TimeoutSeconds s. The hub was not started."
      exit 2
    }
    Start-Sleep -Seconds 5
  }
}

Write-Log "Docker engine ready. Bringing the hub up..."
# compose writes normal progress to stderr; under 'Stop' that would throw. Route
# through Invoke-Native (exit-code only) so a benign stderr line can't abort the
# unattended boot-on-power path.
if (-not (Invoke-Native 'docker compose -f docker-compose.edge.yml --env-file .env.edge up -d')) {
  Write-Log "ERROR: 'docker compose up -d' failed. The hub may not be running; check Docker Desktop and re-run start-hub.ps1."
  exit 3
}
Write-Log "Hub is up."
Write-Host "Hub is up."
