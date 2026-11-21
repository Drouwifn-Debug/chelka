# ============================================================
#  System load sampler (own runspace): CPU, RAM, GPU, VRAM.
#  Works only while $sync.SysOn is true (the "Система" tab is open), so it costs nothing the rest of the time.
#  Result: a fresh hashtable in $sync.Sys once per second.
# ============================================================
$ErrorActionPreference = 'SilentlyContinue'
function SLog($m) { try { $sync.Log.Enqueue("sys: $m") } catch {} }

# ---- static info (read once) ----
$cpuName = ''
try { $cpuName = ([string](Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0').ProcessorNameString).Trim() } catch {}
$threads = [Environment]::ProcessorCount

$gpuName = ''
$vramTotal = 0.0     # GB
try {
  $best = -1.0
  $root = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11cd-be10-08002be10318}'
  foreach ($k in (Get-ChildItem $root -ErrorAction SilentlyContinue)) {
    if ($k.PSChildName -notmatch '^\d{4}$') { continue }
    $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
    if (-not $p -or -not $p.DriverDesc) { continue }
    $mem = 0.0
    $raw = $p.'HardwareInformation.qwMemorySize'
    if ($null -eq $raw) { $raw = $p.'HardwareInformation.MemorySize' }
    if ($raw -is [byte[]]) {
      $b = New-Object byte[] 8
      [Array]::Copy($raw, $b, [Math]::Min(8, $raw.Length))
      $mem = [double][BitConverter]::ToUInt64($b, 0)
    } elseif ($null -ne $raw) { $mem = [double]$raw }
    $score = $mem
    if ($p.DriverDesc -match 'Microsoft Basic|Remote Display|Virtual') { $score = -2.0 }
    if ($score -gt $best) { $best = $score; $gpuName = [string]$p.DriverDesc; $vramTotal = $mem / 1GB }
  }
} catch { SLog "gpu info: $($_.Exception.Message)" }

$gpuOk = $true

function Get-GpuLoad {
  # Task Manager logic: sum over processes per engine, then the busiest engine
  $r = @{ load = -1.0; vram = -1.0 }
  if (-not $script:gpuOk) { return $r }
  try {
    $args1 = @{ ClassName = 'Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine'; ErrorAction = 'Stop' }
    $rows = Get-CimInstance @args1
    $by = @{}
    foreach ($x in $rows) {
      $key = ([string]$x.Name) -replace '^pid_\d+_', ''
      if ($by.ContainsKey($key)) { $by[$key] += [double]$x.UtilizationPercentage } else { $by[$key] = [double]$x.UtilizationPercentage }
    }
    $mx = 0.0
    foreach ($v in $by.Values) { if ($v -gt $mx) { $mx = $v } }
    $r.load = [Math]::Min(100.0, $mx)
  } catch {
    $script:gpuOk = $false
    SLog "gpu counters unavailable: $($_.Exception.Message)"
    return $r
  }
  try {
    $args2 = @{ ClassName = 'Win32_PerfFormattedData_GPUPerformanceCounters_GPUAdapterMemory'; ErrorAction = 'Stop' }
    $best = 0.0
    foreach ($x in (Get-CimInstance @args2)) {
      $d = [double]$x.DedicatedUsage
      if ($d -gt $best) { $best = $d }
    }
    $r.vram = $best / 1GB
  } catch {}
  return $r
}

# ---- network speed (all active non-loopback adapters) ----
$netPrevT = $null; $netPrevRx = 0.0; $netPrevTx = 0.0
function Get-NetSpeed {
  $rx = 0.0; $tx = 0.0
  try {
    foreach ($n in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
      if ($n.OperationalStatus -ne 'Up') { continue }
      if ($n.NetworkInterfaceType -eq 'Loopback' -or $n.NetworkInterfaceType -eq 'Tunnel') { continue }
      $st = $n.GetIPv4Statistics()
      $rx += [double]$st.BytesReceived; $tx += [double]$st.BytesSent
    }
  } catch { return @{ down = -1.0; up = -1.0 } }
  $now = [Diagnostics.Stopwatch]::GetTimestamp()
  $r = @{ down = 0.0; up = 0.0 }
  if ($null -ne $script:netPrevT) {
    $dt = ($now - $script:netPrevT) / [Diagnostics.Stopwatch]::Frequency
    if ($dt -gt 0.05) {
      $d = ($rx - $script:netPrevRx) / $dt; $u = ($tx - $script:netPrevTx) / $dt
      if ($d -lt 0) { $d = 0.0 }; if ($u -lt 0) { $u = 0.0 }
      $r.down = $d; $r.up = $u
    }
  }
  $script:netPrevT = $now; $script:netPrevRx = $rx; $script:netPrevTx = $tx
  return $r
}

# ---- temperatures (best effort, refreshed every few seconds) ----
$tempAt = 0; $cpuTemp = -1.0; $gpuTemp = -1.0
$nvsmi = $null
try { $nvsmi = (Get-Command 'nvidia-smi.exe' -ErrorAction SilentlyContinue).Source } catch {}
if (-not $nvsmi) {
  foreach ($c in @("$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe", "$env:SystemRoot\System32\nvidia-smi.exe")) { if (Test-Path $c) { $nvsmi = $c; break } }
}
function Get-Temps {
  $ct = -1.0; $gt = -1.0
  try {
    $z = Get-CimInstance -ClassName Win32_PerfFormattedData_Counters_ThermalZoneInformation -ErrorAction Stop
    $mx = -1.0
    foreach ($x in $z) { $k = [double]$x.Temperature - 273.15; if ($k -gt $mx -and $k -lt 130) { $mx = $k } }
    $ct = $mx
  } catch {}
  if ($ct -lt 0) {
    try {
      $z = Get-CimInstance -Namespace 'root/wmi' -ClassName MSAcpi_ThermalZone -ErrorAction Stop
      $mx = -1.0
      foreach ($x in $z) { $k = ([double]$x.CurrentTemperature) / 10.0 - 273.15; if ($k -gt $mx -and $k -lt 130) { $mx = $k } }
      $ct = $mx
    } catch {}
  }
  if ($script:nvsmi) {
    try {
      $o = & $script:nvsmi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>$null
      $f = ([string]($o | Select-Object -First 1)).Trim()
      $v = 0.0
      if ([double]::TryParse($f, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v)) { $gt = $v }
    } catch {}
  }
  return @{ cpu = $ct; gpu = $gt }
}

$wasOn = $false
while ($sync.Running) {
  if (-not $sync.SysOn) { $wasOn = $false; Start-Sleep -Milliseconds 250; continue }
  $t0 = [Diagnostics.Stopwatch]::StartNew()
  if (-not $wasOn) {
    # the CPU counter works on deltas: take a first reading, wait a moment, then report
    $wasOn = $true
    $netPrevT = $null; $tempAt = 0
    [void][DI.Sys]::Cpu()
    [void](Get-NetSpeed)
    Start-Sleep -Milliseconds 350
  }
  $cpu = [DI.Sys]::Cpu()
  $used = 0.0; $tot = 0.0; $pct = 0.0
  $okMem = [DI.Sys]::Mem([ref]$used, [ref]$tot, [ref]$pct)
  $g = Get-GpuLoad
  $nt = Get-NetSpeed
  if (([Environment]::TickCount - $tempAt) -gt 4000 -or $tempAt -eq 0) {
    $tp = Get-Temps; $cpuTemp = $tp.cpu; $gpuTemp = $tp.gpu; $tempAt = [Environment]::TickCount
  }
  $sync.Sys = @{
    netDown = $nt.down; netUp = $nt.up; cpuTemp = $cpuTemp; gpuTemp = $gpuTemp
    cpu = $cpu
    ram = $(if ($okMem) { $pct } else { -1.0 }); ramUsed = $used; ramTotal = $tot
    gpu = $g.load; vram = $g.vram; vramTotal = $vramTotal
    cpuName = $cpuName; threads = $threads; gpuName = $gpuName
  }
  $left = 1000 - [int]$t0.ElapsedMilliseconds
  if ($left -gt 30) { Start-Sleep -Milliseconds $left } else { Start-Sleep -Milliseconds 30 }
}
