<#
  EDGE-PKG-2-WIN - make the hub return after a power cut with NO human action.

  The compose restart policy (restart: unless-stopped) already brings the
  CONTAINER back whenever the Docker engine is running. The only Windows-specific
  gap is that the Docker engine (Docker Desktop) starts on user LOGIN, not on
  power-on. A mini-PC that power-cycles unattended never logs in, so nothing
  starts. This script closes that gap with three pieces:

    1. Docker Desktop launches at login   (Startup-folder shortcut)
    2. The stack is brought up at login    (logon Scheduled Task -> start-hub.ps1)
    3. Windows logs in automatically       (auto-login, so 1+2 actually fire)

  SECURITY NOTE (auto-login): enabling auto-login stores the account password so
  Windows signs in without a prompt. This is standard for a locked, single-purpose
  back-office box, but anyone with physical access is effectively logged in. Skip
  -EnableAutoLogin if the box is not physically secured; the hub will then come
  back only after someone logs in once. For a more secure auto-login that encrypts
  the password via LSA, use Sysinternals Autologon instead of the registry method.

  Run elevated (Administrator).
    .\enable-boot-on-power.ps1                          # steps 1 + 2 only
    .\enable-boot-on-power.ps1 -EnableAutoLogin -Username "hub"
#>
[CmdletBinding()]
param(
  [string]$InstallDir = 'C:\RestaurantOS',
  [switch]$EnableAutoLogin,
  [string]$Username = $env:USERNAME,
  [string]$TaskName = 'RestaurantOS-Hub'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    throw 'Please run this as Administrator.'
  }
}
Assert-Admin

# ---- 1. Docker Desktop starts at login (Startup-folder shortcut) ------------
$dd = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
if (Test-Path $dd) {
  $startup = [Environment]::GetFolderPath('Startup')
  $lnk = Join-Path $startup 'Docker Desktop.lnk'
  $ws = New-Object -ComObject WScript.Shell
  $s = $ws.CreateShortcut($lnk)
  $s.TargetPath = $dd
  $s.Save()
  Write-Host "1/3  Docker Desktop will start at login."
} else {
  Write-Warning "Docker Desktop not found at $dd - install it first, then re-run."
}

# ---- 2. Bring the stack up at login (Scheduled Task) ------------------------
$startScript = Join-Path $InstallDir 'start-hub.ps1'
if (-not (Test-Path $startScript)) {
  # Fall back to the copy next to this script if the hub folder doesn't have it.
  $alt = Join-Path $PSScriptRoot 'start-hub.ps1'
  if (Test-Path $alt) { Copy-Item $alt $startScript -Force }
}
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
             -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$startScript`" -InstallDir `"$InstallDir`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
  -RunLevel Highest -Force | Out-Null
Write-Host "2/3  Logon task '$TaskName' will bring the hub up."

# ---- 3. Auto-login (optional; see SECURITY NOTE above) ----------------------
if ($EnableAutoLogin) {
  $sec = Read-Host "Password for '$Username' (stored for auto-login)" -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
  $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
  [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

  $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
  Set-ItemProperty $key -Name 'AutoAdminLogon'   -Value '1'
  Set-ItemProperty $key -Name 'DefaultUserName'  -Value $Username
  Set-ItemProperty $key -Name 'DefaultDomainName' -Value $env:COMPUTERNAME
  Set-ItemProperty $key -Name 'DefaultPassword'  -Value $plain
  $plain = $null
  Write-Host "3/3  Windows auto-login enabled for '$Username'."
  Write-Warning "Auto-login stores the password in the registry. Keep this box physically secured."
} else {
  Write-Host "3/3  Auto-login SKIPPED. The hub will return only after someone logs in once."
  Write-Host "     Re-run with -EnableAutoLogin for fully unattended power-cycles."
}

Write-Host ""
Write-Host "Boot-on-power configured. Test it: reboot, wait ~2 minutes, then open" -ForegroundColor Green
Write-Host "the hub's /setup page with no login or commands - it should be back up."
