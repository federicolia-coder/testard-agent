# testard-agent for Windows: reports this server's health to Testard once a minute.
#
# What it sends: hostname, Windows version, CPU count, memory and disk size,
# uptime, and CPU / memory / disk usage and network throughput. Nothing else.
# What it never does: receive or run commands. Testard can't control this
# server through the agent; the key only lets it submit reports.
#
# Usage (from an elevated PowerShell for uninstall):
#   testard-agent.ps1 run         collect and send one report (the scheduled task does this)
#   testard-agent.ps1 collect     print the report that would be sent
#   testard-agent.ps1 status      show the configuration and the last result
#   testard-agent.ps1 uninstall   remove the agent, its scheduled task and its files
#   testard-agent.ps1 version
#
# Works with Windows PowerShell 5.1 (built into Windows 10 and Server 2016 and later) and PowerShell 7.

param([string]$Command = 'run')

$ErrorActionPreference = 'Stop'
$Version = '1.0.0'
$TaskName = 'Testard agent'
$DataDir = if ($env:TESTARD_AGENT_DATA) { $env:TESTARD_AGENT_DATA } else { Join-Path $env:ProgramData 'TestardAgent' }
$InstallDir = if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'TestardAgent' } else { $PSScriptRoot }
$StateDir = Join-Path $DataDir 'state'

function Fail([string]$Message) {
  [Console]::Error.WriteLine("testard-agent: $Message")
  exit 1
}

# Reads KEY=value lines without executing the file.
function Get-ConfValue([string]$Name) {
  $path = Join-Path $DataDir 'agent.conf'
  if (-not (Test-Path -LiteralPath $path)) { return '' }
  foreach ($line in Get-Content -LiteralPath $path) {
    if ($line -match "^$Name=(.*)$") { return $Matches[1].Trim() }
  }
  return ''
}

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Network adapters that are up, excluding loopback.
function Get-ActiveAdapters {
  [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
    Where-Object { $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -ne 'Loopback' }
}

function Get-PrivateIp {
  foreach ($nic in Get-ActiveAdapters) {
    $props = $nic.GetIPProperties()
    if ($props.GatewayAddresses.Count -eq 0) { continue }
    foreach ($a in $props.UnicastAddresses) {
      if ($a.Address.AddressFamily -eq 'InterNetwork') { return $a.Address.ToString() }
    }
  }
  return $null
}

function Get-Percent([double]$Part, [double]$Whole) {
  if ($Whole -le 0) { return 0 }
  return [math]::Round([math]::Min(100.0, [math]::Max(0.0, $Part / $Whole * 100)), 1)
}

function Get-Report {
  $os = Get-CimInstance -ClassName Win32_OperatingSystem
  $loads = @(Get-CimInstance -ClassName Win32_Processor | ForEach-Object { $_.LoadPercentage } | Where-Object { $null -ne $_ })
  $cpu = 0
  if ($loads.Count -gt 0) { $cpu = [math]::Round([double](($loads | Measure-Object -Average).Average), 1) }

  $drive = if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' }
  $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$drive'"
  $memTotal = [double]$os.TotalVisibleMemorySize * 1024
  $memFree = [double]$os.FreePhysicalMemory * 1024
  $diskTotal = [double]$disk.Size
  $diskUsed = $diskTotal - [double]$disk.FreeSpace

  # Network throughput since the previous run.
  $rx = [double]0; $tx = [double]0
  foreach ($nic in Get-ActiveAdapters) {
    $s = $nic.GetIPStatistics()
    $rx += $s.BytesReceived; $tx += $s.BytesSent
  }
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $rxRate = 0; $txRate = 0
  $netFile = Join-Path $StateDir 'net'
  if (Test-Path -LiteralPath $netFile) {
    $prev = (Get-Content -LiteralPath $netFile -Raw).Trim() -split '\s+'
    if ($prev.Count -eq 3 -and $now -gt [double]$prev[0]) {
      $secs = $now - [double]$prev[0]
      $rxRate = [math]::Max(0.0, [math]::Round(($rx - [double]$prev[1]) / $secs))
      $txRate = [math]::Max(0.0, [math]::Round(($tx - [double]$prev[2]) / $secs))
    }
  }
  if (Test-Path -LiteralPath $StateDir) { Set-Content -LiteralPath $netFile -Value "$now $rx $tx" -Encoding ASCII }

  $arch = switch ($env:PROCESSOR_ARCHITECTURE) { 'AMD64' { 'x86_64' } 'ARM64' { 'aarch64' } 'x86' { 'i686' } default { "$env:PROCESSOR_ARCHITECTURE" } }

  $report = [ordered]@{
    version           = 1
    agentVersion      = "$Version windows"
    hostname          = [System.Net.Dns]::GetHostName()
    os                = "$($os.Caption)".Trim()
    kernel            = "$($os.Version)"
    arch              = $arch
    cpus              = [Environment]::ProcessorCount
    memoryBytes       = [int64]$memTotal
    diskBytes         = [int64]$diskTotal
    uptimeSeconds     = [int64][math]::Max(0.0, ((Get-Date) - $os.LastBootUpTime).TotalSeconds)
    cpuPercent        = [math]::Min(100.0, [math]::Max(0.0, $cpu))
    memoryPercent     = Get-Percent ($memTotal - $memFree) $memTotal
    diskPercent       = Get-Percent $diskUsed $diskTotal
    netInBytesPerSec  = [int64]$rxRate
    netOutBytesPerSec = [int64]$txRate
  }
  $ip = Get-PrivateIp
  if ($ip) { $report.privateIp = $ip }
  return ($report | ConvertTo-Json -Compress)
}

function Invoke-Run {
  $url = Get-ConfValue 'TESTARD_URL'
  if (-not $url) { Fail "no TESTARD_URL in $(Join-Path $DataDir 'agent.conf')" }
  $keyFile = Join-Path $DataDir 'key'
  if (-not (Test-Path -LiteralPath $keyFile)) { Fail "can't read $keyFile" }
  $key = (Get-Content -LiteralPath $keyFile -Raw).Trim()
  if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }

  # Older Windows PowerShell defaults to TLS 1.0.
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $body = [Text.Encoding]::UTF8.GetBytes((Get-Report))
  $code = 0; $detail = ''
  try {
    $res = Invoke-WebRequest -Uri "$url/api/agent/v1/report" -Method Post -UseBasicParsing -TimeoutSec 20 `
      -ContentType 'application/json' -UserAgent "testard-agent/$Version (windows)" `
      -Headers @{ Authorization = "Bearer $key" } -Body $body
    $code = [int]$res.StatusCode
  } catch {
    if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
    $detail = $_.Exception.Message
  }
  $stamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
  Set-Content -LiteralPath (Join-Path $StateDir 'last') -Value ("$stamp $code $detail".Trim()) -Encoding UTF8
  # 429: reported less than 20 seconds ago; harmless.
  if ($code -ne 202 -and $code -ne 429) { Fail "report failed: $code $detail" }
}

function Show-Status {
  Write-Output "testard-agent $Version (windows)"
  Write-Output "reports to: $(Get-ConfValue 'TESTARD_URL')"
  $last = Join-Path $StateDir 'last'
  if (Test-Path -LiteralPath $last) { Write-Output "last run:   $((Get-Content -LiteralPath $last -Raw).Trim())" } else { Write-Output 'last run:   never' }
  try { Write-Output "task:       $((Get-ScheduledTask -TaskName $TaskName).State)" } catch { Write-Output 'task:       not found' }
}

function Invoke-Uninstall {
  if (-not (Test-Admin)) { Fail 'run uninstall from an elevated PowerShell (Run as administrator)' }
  try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false } catch { }
  Remove-Item -LiteralPath $DataDir -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
  Write-Output 'testard-agent removed. Delete the server in Testard to remove its history too.'
}

switch ($Command) {
  'run' { Invoke-Run }
  'collect' { Get-Report }
  'status' { Show-Status }
  'uninstall' { Invoke-Uninstall }
  'version' { Write-Output $Version }
  default { Fail "unknown command: $Command (use run, collect, status, uninstall or version)" }
}
