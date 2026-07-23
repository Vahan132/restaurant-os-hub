<#
  EDGE-PKG-2-WIN - Update the Restaurant OS Edge Hub to a newer image.

  Pulls the newer public image and restarts. The hub keeps serving locally during
  the update, applies any new database migrations on start, and preserves its
  pairing + data on the named volumes. Safe to run during service.

  To move to a specific release, pass -Tag (writes EDGE_IMAGE_TAG into .env.edge):
    .\update-hub.ps1 -Tag edge-v0.2.0
#>
[CmdletBinding()]
param(
  [string]$InstallDir = 'C:\RestaurantOS',
  [string]$Tag
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Native {
  # Run a native command WITHOUT letting its stderr become a terminating error.
  # PowerShell 5.1 + $ErrorActionPreference='Stop' turns a native command's stderr
  # into a THROW even when the command exits 0 (docker compose prints progress to
  # stderr). Success is judged by EXIT CODE only. The string / Invoke-Expression
  # form is deliberate: a [scriptblock] parameter trips Set-StrictMode -Version
  # Latest ("variable not set"), so keep the string form.
  param([Parameter(Mandatory)][string]$CommandLine)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    Invoke-Expression "$CommandLine 2>`$null 1>`$null"
    return ($LASTEXITCODE -eq 0)
  } finally { $ErrorActionPreference = $prev }
}

Set-Location $InstallDir
$envFile = Join-Path $InstallDir '.env.edge'

if ($Tag) {
  $line = "EDGE_IMAGE_TAG=$Tag"
  if ((Get-Content $envFile) -match '^\s*EDGE_IMAGE_TAG=') {
    (Get-Content $envFile) -replace '^\s*EDGE_IMAGE_TAG=.*', $line | Set-Content $envFile -Encoding UTF8
  } else {
    Add-Content -Path $envFile -Value $line -Encoding UTF8
  }
  Write-Host "Pinned EDGE_IMAGE_TAG=$Tag"
}

# pull/up write normal progress to stderr; under 'Stop' that would throw. Route
# them through Invoke-Native and judge success by exit code.
if (-not (Invoke-Native 'docker compose -f docker-compose.edge.yml --env-file .env.edge pull')) {
  Write-Warning "docker compose pull reported a problem; continuing to 'up' (an already-present image will still be used)."
}
if (-not (Invoke-Native 'docker compose -f docker-compose.edge.yml --env-file .env.edge up -d')) {
  Write-Warning "docker compose up failed. Run it manually in $InstallDir to see the error."
  exit 1
}

# `ps` is a status readout the operator is meant to SEE, so keep its output visible;
# only neutralize the stderr-throw by dropping to 'Continue' for this one call.
$prev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try { docker compose -f docker-compose.edge.yml --env-file .env.edge ps } finally { $ErrorActionPreference = $prev }

Write-Host "Update complete."
