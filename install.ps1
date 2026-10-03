# Installs testard-agent on Windows, which reports this server's health to Testard.
# Run in an elevated PowerShell (Run as administrator):
#
#   [Net.ServicePointManager]::SecurityProtocol = 'Tls12'; & ([scriptblock]::Create((irm https://raw.githubusercontent.com/federicolia-coder/testard-agent/main/install.ps1))) -Key tsk_... -Url https://platform.testardstudios.it
#
# Read testard-agent.ps1 first if you like: it's a short script that only
# sends numbers and never runs commands from Testard.

param(
  [Parameter(Mandatory = $true)][string]$Key,
  [Parameter(Mandatory = $true)][string]$Url
)

$ErrorActionPreference = 'Stop'
$RepoRaw = 'https://raw.githubusercontent.com/federicolia-coder/testard-agent/main'
$TaskName = 'Testard agent'

function Fail([string]$Message) {
  [Console]::Error.WriteLine("install: $Message")
  # `exit` would close the window when run through `& ([scriptblock]::Create(...))`.
  throw "install: $Message"
}

if ($env:OS -ne 'Windows_NT') { Fail 'this installer is for Windows; on Linux use install.sh' }
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Fail 'run PowerShell as administrator'
}
if ($Key -notmatch '^tsk_[A-Za-z0-9_-]{43}$') { Fail 'pass the key from Testard with -Key tsk_...' }
$Url = $Url.TrimEnd('/')
if ($Url -notmatch '^https://[A-Za-z0-9.:-]+$' -and $Url -notmatch '^http://(localhost|127\.0\.0\.1)(:\d+)?$') {
  Fail "pass Testard's address with -Url https://..., e.g. https://platform.testardstudios.it"
}

Write-Output 'Installing testard-agent...'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$InstallDir = Join-Path $env:ProgramFiles 'TestardAgent'
$DataDir = Join-Path $env:ProgramData 'TestardAgent'
$StateDir = Join-Path $DataDir 'state'
$Script = Join-Path $InstallDir 'testard-agent.ps1'

# The agent itself, in Program Files so only administrators can change it.
# TESTARD_AGENT_SOURCE lets a local copy be used for testing.
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
if ($env:TESTARD_AGENT_SOURCE) {
  Copy-Item -LiteralPath $env:TESTARD_AGENT_SOURCE -Destination $Script -Force
} else {
  $agent = (Invoke-WebRequest -Uri "$RepoRaw/testard-agent.ps1" -UseBasicParsing).Content
  if ($agent -notmatch '^# testard-agent for Windows') { Fail "downloaded file doesn't look like testard-agent.ps1" }
  Set-Content -LiteralPath $Script -Value $agent -Encoding UTF8
}

# The agent runs as LOCAL SERVICE, a built-in account without admin rights.
# Names differ by Windows language, so accounts are given by SID.
$LocalService = ([Security.Principal.SecurityIdentifier]'S-1-5-19').Translate([Security.Principal.NTAccount]).Value

# Configuration and key: readable by LOCAL SERVICE, SYSTEM and administrators only.
New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
& icacls.exe $DataDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-19:(OI)(CI)RX' | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "couldn't set permissions on $DataDir" }
# The agent writes its last result and network counters here.
& icacls.exe $StateDir /grant:r '*S-1-5-19:(OI)(CI)M' | Out-Null
Set-Content -LiteralPath (Join-Path $DataDir 'agent.conf') -Value "TESTARD_URL=$Url" -Encoding ASCII
Set-Content -LiteralPath (Join-Path $DataDir 'key') -Value $Key -Encoding ASCII

# A scheduled task runs the agent every minute, from now on and after every restart.
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Script`" run"
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
$trigger.Repetition.Duration = '' # repeat indefinitely
$principal = New-ScheduledTaskPrincipal -UserId $LocalService -LogonType ServiceAccount
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew -StartWhenAvailable `
  -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden
Register-ScheduledTask -TaskName $TaskName -TaskPath '\' -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
  -Description 'Reports this server''s health to Testard every minute. Sends numbers only; never runs commands.' -Force | Out-Null

# First report right away, as LOCAL SERVICE, so the server shows up in Testard now.
$lastFile = Join-Path $StateDir 'last'
Remove-Item -LiteralPath $lastFile -Force -ErrorAction SilentlyContinue
Start-ScheduledTask -TaskName $TaskName
$deadline = (Get-Date).AddSeconds(45)
while (-not (Test-Path -LiteralPath $lastFile) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }

$last = if (Test-Path -LiteralPath $lastFile) { (Get-Content -LiteralPath $lastFile -Raw).Trim() } else { '' }
if ($last -match ' (202|429)$') {
  Write-Output 'Done. This server now reports to Testard every minute (scheduled task "Testard agent").'
  Write-Output "Check it with: & '$Script' status    Remove it with: & '$Script' uninstall"
} elseif ($last) {
  Fail "installed, but the first report failed: $last. It will retry every minute."
} else {
  Fail "installed, but the first report didn't run within 45 seconds. Check the task with: & '$Script' status"
}
