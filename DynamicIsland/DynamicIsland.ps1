# ============================================================
#  Dynamic Island for Windows  v2.5   (PowerShell 5.1 + WPF, no dependencies)
#  Liquid Glass pill: blurred snapshot of the screen behind it, clipped to the
#  pill shape, spring morphing, music + lyrics / to-do + calendar / weather /
#  system load / sound mixer / clipboard / sites / file shelf / timer + pomodoro.
# ============================================================
param([switch]$Console)

$ErrorActionPreference = 'Stop'
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$DataDir = Join-Path $env:LOCALAPPDATA 'DynamicIsland'
[void](New-Item -ItemType Directory -Force -Path $DataDir)
$LogFile = Join-Path $DataDir 'island.log'
try { if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 300KB)) { Remove-Item $LogFile -Force } } catch {}
$script:logCount = 0
function Log([string]$m) {
  if ($script:logCount -gt 400) { return }
  $script:logCount++
  $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') $m"
  try { [IO.File]::AppendAllText($LogFile, $line + "`r`n", (New-Object Text.UTF8Encoding($true))) } catch {}
  if ($Console) { Write-Host $line }
}
trap {
  Log ("FATAL: " + $_.Exception.ToString() + "`r`n" + $_.InvocationInfo.PositionMessage)
  if ($Console) { Write-Host "Нажми Enter, чтобы закрыть..."; [void](Read-Host) }
  exit 1
}
Log "=== start v2.5  PS $($PSVersionTable.PSVersion)  dir=$ScriptDir"

# ---- single instance ----
$script:mutex = New-Object System.Threading.Mutex($false, 'Global\DynamicIslandPS_v2')
if (-not $script:mutex.WaitOne(0)) { Log 'already running, exit'; exit }

# ---- native helpers (acrylic, regions, volume ...) ----
if (-not ('DI.Native' -as [type])) {
  Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $ScriptDir 'src\Native.cs'), [Text.Encoding]::UTF8)) -Language CSharp
}
[void][DI.Native]::SetProcessDPIAware()   # crisp rendering + real pixel coordinates

Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ============================================================
#  Settings  (%LOCALAPPDATA%\DynamicIsland\settings.json)
# ============================================================
$SetFile = Join-Path $DataDir 'settings.json'
$cfg = @{
  accent = '242,242,242'; eq = $true; charge = $true; glass = $true; glassAlpha = 55
  hideFull = $true; hoverClock = $true; city = ''; favicons = $true
  theme = 'auto'; hotkey = 'Ctrl+Alt+I'; icsUrl = ''
  pillMusic = 'title'; pillIdle = 'hover'; shotDir = ''
  cities = @(); cityIdx = -1; pins = @(); shelf = @(); todos = @(); events = @()
  sites = @(
    @{ n = 'YouTube'; u = 'https://www.youtube.com' }
    @{ n = 'GitHub'; u = 'https://github.com' }
    @{ n = 'Google'; u = 'https://www.google.com' }
    @{ n = 'Telegram'; u = 'https://web.telegram.org' }
  )
}
function Load-Settings {
  try {
    if (Test-Path $SetFile) {
      $j = Get-Content $SetFile -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($k in @($cfg.Keys)) {
        $v = $j.$k
        if ($null -ne $v) { $cfg[$k] = $v }
      }
    }
  } catch { Log "settings load failed: $($_.Exception.Message)" }
  $cfg.glassAlpha = [int][Math]::Min(100, [Math]::Max(0, [int]$cfg.glassAlpha))
  # lists come back from JSON as objects: normalise them to plain hashtables / strings
  $list = @()
  foreach ($x in @($cfg.sites)) {
    try { if ($x.u) { $list += , @{ n = [string]$x.n; u = [string]$x.u } } } catch {}
  }
  $cfg.sites = $list
  $cities = @()
  foreach ($x in @($cfg.cities)) {
    try {
      if ($x.n) {
        $la = $null; $lo = $null
        if ($null -ne $x.lat -and $null -ne $x.lon) { $la = [double]$x.lat; $lo = [double]$x.lon }
        $cities += , @{ n = [string]$x.n; lat = $la; lon = $lo }
      }
    } catch {}
  }
  # an old single "city" setting becomes the first saved city
  if ($cities.Count -eq 0 -and $cfg.city) { $cities += , @{ n = [string]$cfg.city; lat = $null; lon = $null } }
  $cfg.cities = $cities
  $cfg.cityIdx = [int]$cfg.cityIdx
  if ($cfg.cityIdx -ge $cities.Count) { $cfg.cityIdx = -1 }
  $cfg.pins = @(@($cfg.pins) | Where-Object { $_ } | ForEach-Object { [string]$_ })
  $cfg.shelf = @(@($cfg.shelf) | Where-Object { $_ } | ForEach-Object { [string]$_ })
  $td = @()
  foreach ($x in @($cfg.todos)) { try { if ($x.t) { $td += , @{ id = [string]$x.id; t = [string]$x.t; d = [bool]$x.d } } } catch {} }
  $cfg.todos = $td
  $ev = @()
  foreach ($x in @($cfg.events)) { try { if ($x.t -and $x.n) { $ev += , @{ t = [string]$x.t; n = [string]$x.n } } } catch {} }
  $cfg.events = $ev
  $cfg.theme = [string]$cfg.theme
  $cfg.hotkey = [string]$cfg.hotkey
  $cfg.icsUrl = [string]$cfg.icsUrl
  $cfg.pillMusic = [string]$cfg.pillMusic
  if (@('title', 'artist', 'both') -notcontains $cfg.pillMusic) { $cfg.pillMusic = 'title' }
  $cfg.pillIdle = [string]$cfg.pillIdle
  if (@('hover', 'clock', 'date') -notcontains $cfg.pillIdle) { $cfg.pillIdle = 'hover' }
  $cfg.shotDir = [string]$cfg.shotDir
}
function Save-Settings {
  try { ($cfg | ConvertTo-Json -Depth 6) | Set-Content -Path $SetFile -Encoding UTF8 }
  catch { Log "settings save failed: $($_.Exception.Message)" }
}
Load-Settings
if (-not (Test-Path $SetFile)) { Save-Settings }   # so the user can find and edit it (e.g. "city")

# Windows build (only for the log). The glass is drawn by the island itself, so it works everywhere.
$build = 0
try { $build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber } catch {}
$glassCapable = $true
Log "build=$build"

# ============================================================
#  Worker runspace  (src\Worker.ps1)
# ============================================================
$sync = [hashtable]::Synchronized(@{
  Running = $true; State = $null; Clip = $null
  ClipWrite = ''; ClipClear = $false; Seek = -1.0; Cmd = ''
  SysOn = $false; Sys = $null
  WxReq = $null; WxRes = [hashtable]::Synchronized(@{}); CityQ = $null; CityRes = $null
  LyrReq = $null; Lyr = $null; IcsReq = $null; Ics = $null
  Log = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]')
})
$workerText = [IO.File]::ReadAllText((Join-Path $ScriptDir 'src\Worker.ps1'), [Text.Encoding]::UTF8)
$rs = [runspacefactory]::CreateRunspace()
$rs.Open()
$rs.SessionStateProxy.SetVariable('sync', $sync)
$workerPs = [powershell]::Create()
$workerPs.Runspace = $rs
$null = $workerPs.AddScript($workerText)
$null = $workerPs.BeginInvoke()

# internet workers: lyrics / weather + calendar / city search, each in its own runspace
# (a slow weather request must never delay lyrics or the city search, and none of them may block the media session)
$netText = ''
try { $netText = [IO.File]::ReadAllText((Join-Path $ScriptDir 'src\Net.ps1'), [Text.Encoding]::UTF8) } catch { Log "net script: $($_.Exception.Message)" }
$script:netPool = @()
foreach ($netRole in @('lyr', 'wx', 'city')) {
  try {
    $nrs = [runspacefactory]::CreateRunspace()
    $nrs.Open()
    $nrs.SessionStateProxy.SetVariable('sync', $sync)
    $nrs.SessionStateProxy.SetVariable('role', $netRole)
    $nps = [powershell]::Create()
    $nps.Runspace = $nrs
    $null = $nps.AddScript($netText)
    $null = $nps.BeginInvoke()
    $script:netPool += , $nps
  } catch { Log "net runspace ($netRole) failed: $($_.Exception.Message)" }
}

# system load sampler (CPU / RAM / GPU): its own runspace, only works while the "Система" tab is open
$sysText = [IO.File]::ReadAllText((Join-Path $ScriptDir 'src\Sys.ps1'), [Text.Encoding]::UTF8)
$sysRs = [runspacefactory]::CreateRunspace()
$sysRs.Open()
$sysRs.SessionStateProxy.SetVariable('sync', $sync)
$sysPs = [powershell]::Create()
$sysPs.Runspace = $sysRs
$null = $sysPs.AddScript($sysText)
$null = $sysPs.BeginInvoke()

# ============================================================
#  UI  (src\Island.xaml)
# ============================================================
$xamlText = [IO.File]::ReadAllText((Join-Path $ScriptDir 'src\Island.xaml'), [Text.Encoding]::UTF8)
$window = [Windows.Markup.XamlReader]::Parse($xamlText)

$E = @{}
# names declared inside <Window.Resources> belong to control templates and cannot be found from the window
$skip = @('bg', 'bgc', 'root', 'hov', 'track', 'knob', 'PART_Track', 'PART_ContentHost', 'fbg', 'ring', 'sel')
$resEnd = $xamlText.IndexOf('</Window.Resources>')
if ($resEnd -lt 0) { $resEnd = 0 }
foreach ($m in [regex]::Matches($xamlText.Substring($resEnd), 'x:Name="(\w+)"')) {
  $n = $m.Groups[1].Value
  if ($skip -notcontains $n) { $E[$n] = $window.FindName($n) }
}
# a few non-element objects: fall back to walking the tree if FindName could not resolve them
if (-not $E.islandClip)  { $E.islandClip  = $E.Island.Clip }
if (-not $E.shadowHole)  { $E.shadowHole  = $E.ShadowWrap.Clip.Geometry2 }
if (-not $E.shadowFx)    { $E.shadowFx    = $E.ShadowShape.Effect }
if (-not $E.expT)        { $E.expT        = $E.ExpandedLayer.RenderTransform }
if (-not $E.sweepX)      { $E.sweepX      = $E.sweepLight.Children[0].RenderTransform.Children[1] }
if (-not $E.washC0)      { $E.washC0      = $E.WashLayer.Children[0].Background.GradientStops[0] }
if (-not $E.washC1)      { $E.washC1      = $E.WashLayer.Children[0].Background.GradientStops[1] }
if (-not $E.washD0)      { $E.washD0      = $E.WashLayer.Children[1].Background.GradientStops[0] }
if (-not $E.washD1)      { $E.washD1      = $E.WashLayer.Children[1].Background.GradientStops[1] }
$miss = @($E.Keys | Where-Object { -not $E[$_] })
if ($miss.Count -gt 0) { throw ("XAML elements not found: " + ($miss -join ', ')) }
Log "xaml ok, $($E.Count) named objects"

$app = New-Object System.Windows.Application
$app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$app.add_DispatcherUnhandledException([System.Windows.Threading.DispatcherUnhandledExceptionEventHandler]{
  param($snd, $ev)
  $pos = ''
  try { $pos = $ev.Exception.ErrorRecord.InvocationInfo.PositionMessage } catch {}
  Log ("UI error: " + $ev.Exception.Message + "`r`n" + $pos)
  $ev.Handled = $true
})

# ============================================================
#  Window: layered, transparent, never steals focus. No second window: the glass is part of the island.
# ============================================================
$wih = New-Object System.Windows.Interop.WindowInteropHelper $window
$mainHwnd = $wih.EnsureHandle()
[DI.Native]::ToolNoActivate($mainHwnd, $false)

# ============================================================
#  Geometry, spring physics, glass (blurred backdrop), sliders
# ============================================================
$WIN_W = 780.0; $WIN_H = 640.0; $TOP = 10.0
$SIZES = @{
  idle      = @(116.0, 34.0, 17.0)
  idleHover = @(152.0, 34.0, 17.0)
  music     = @(248.0, 34.0, 17.0)
  timer     = @(176.0, 34.0, 17.0)
  charge    = @(150.0, 34.0, 17.0)
  done      = @(210.0, 34.0, 17.0)
  event     = @(260.0, 34.0, 17.0)
  vol       = @(220.0, 34.0, 17.0)
  panel     = @(660.0, 520.0, 36.0)
}
$clock = [Diagnostics.Stopwatch]::StartNew()
function Now-Ms { return $clock.Elapsed.TotalMilliseconds }

# spring state (w/h/r = current, v* = velocity, t* = target)
$sp = @{ w = 34.0; h = 14.0; r = 7.0; vw = 0.0; vh = 0.0; vr = 0.0; tw = 116.0; th = 34.0; tr = 17.0; k = 224.0; c = 23.0; active = $false; last = 0.0 }

$ui = @{
  mode = 'idle'; sizeKey = 'idle'; expanded = $false; hover = $false; pressed = $false
  compactPanel = $null; tab = 'music'
  timerLeft = 0; timerTotal = 0; timerPaused = $false; doneUntil = 0.0
  volUntil = 0.0; chargeUntil = 0.0; chargeLow = $false; lastCharging = $false; battInit = $false; lowShown = $false
  volInit = $false; lastVol = -1.0; lastMute = $false; suppressVol = $false
  hidden = $false; glassOn = $false; bdReady = $false
  scale = 1.0; winX = 0; winY = 0; screenKey = ''
  waveStarted = $false; wavePaused = $false
  optPlaying = $true; optUntil = 0.0; shownPlaying = $null
  lastTitle = ''; lastArtKey = '#'; lastPos = 0.0; len = 0.0; seekPos = 0.0; seekAt = 0.0; seekHold = 0.0
  tint = $null; accent = [System.Windows.Media.Color]::FromRgb(242, 242, 242)
  closing = $false; reduceMotion = $false
  kbd = $false; prevFg = [IntPtr]::Zero; sitesEdit = $false; sysRef = $null; volErrLogged = $false
  lastLeft = $false; wxRef = $null; renderErr = 0
  evtUntil = 0.0; evtText = ''; pomo = $false; pomoPhase = 'work'; pomoRound = 0
  pillSig = ''; idleShown = $false; zeroHits = 0; posTitle = ''
}
try { $ui.reduceMotion = -not [System.Windows.SystemParameters]::ClientAreaAnimation } catch {}
try {
  $rgb = ([string]$cfg.accent) -split ','
  if ($rgb.Count -eq 3) { $ui.accent = [System.Windows.Media.Color]::FromRgb([byte][int]$rgb[0], [byte][int]$rgb[1], [byte][int]$rgb[2]) }
} catch {}

$saveTimer = New-Object System.Windows.Threading.DispatcherTimer
$saveTimer.Interval = [TimeSpan]::FromMilliseconds(600)
$saveTimer.Add_Tick({ $saveTimer.Stop(); Save-Settings })
function Request-Save { $saveTimer.Stop(); $saveTimer.Start() }

function Reposition {
  $wa = [System.Windows.SystemParameters]::WorkArea
  $window.Left = $wa.Left + ($wa.Width - $WIN_W) / 2.0
  $window.Top = $wa.Top
  $sw = [double][System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width
  $ui.scale = $sw / [System.Windows.SystemParameters]::PrimaryScreenWidth
  $rc = New-Object DI.RECT
  [void][DI.Native]::GetWindowRect($mainHwnd, [ref]$rc)
  $ui.winX = $rc.Left; $ui.winY = $rc.Top
  $ui.screenKey = "$($wa.Left),$($wa.Top),$($wa.Width),$($wa.Height),$sw"
}

# Glass backdrop. The island grabs the screen behind its panel ONCE when it opens (the island is a layered
# window, so the grab does not contain it), blurs it and paints it INSIDE the island under the tint. There is no
# second window, so the glass follows the spring frame-perfectly and has no edges that could stick out.
$BD_W = 660.0; $BD_H = 520.0
$script:bdT = $E.bdImg.RenderTransform
function Capture-Backdrop([bool]$windowHidden = $false) {
  $ui.bdReady = $false
  if (-not $ui.glassOn) { return }
  try {
    $sc = $ui.scale
    $x0 = [int][Math]::Round($ui.winX + (($WIN_W - $BD_W) / 2.0) * $sc)
    $y0 = [int][Math]::Round($ui.winY + $TOP * $sc)
    $w = [int][Math]::Round($BD_W * $sc); $h = [int][Math]::Round($BD_H * $sc)
    $pw = [int][Math]::Round($sp.w * $sc) + 6
    $ph = [int][Math]::Round($sp.h * $sc) + 4
    $ix = [int][Math]::Round((($BD_W - $sp.w) / 2.0) * $sc) - 3
    if ($windowHidden) { $pw = 0; $ph = 0 }   # the island was hidden for the grab: nothing to paint over
    $down = [int][Math]::Max(2, [Math]::Round(4.0 * $sc))
    $ow = 0; $oh = 0
    $buf = [DI.Backdrop]::Snap($x0, $y0, $w, $h, $down, 4, [float]1.55, $ix, 0, $pw, $ph, [ref]$ow, [ref]$oh)
    if (-not $buf) { Log ("backdrop failed: " + [DI.Backdrop]::LastError); return }
    $bs = [System.Windows.Media.Imaging.BitmapSource]::Create($ow, $oh, 96.0, 96.0, [System.Windows.Media.PixelFormats]::Bgra32, $null, $buf, $ow * 4)
    $bs.Freeze()
    $E.bdImg.Source = $bs
    $ui.bdReady = $true
  } catch { Log "backdrop: $($_.Exception.Message)" }
}

function Apply-Geo {
  $w = $sp.w; $h = $sp.h
  if ($w -lt 4) { $w = 4.0 }
  if ($h -lt 4) { $h = 4.0 }
  $r = [Math]::Min($sp.r, [Math]::Min($w, $h) / 2.0)
  if ($r -lt 1) { $r = 1.0 }
  $left = ($WIN_W - $w) / 2.0
  $I = $E.Island
  [System.Windows.Controls.Canvas]::SetLeft($I, $left)
  $I.Width = $w; $I.Height = $h
  $ic = $E.islandClip
  $ic.Rect = [System.Windows.Rect]::new(0.0, 0.0, $w, $h); $ic.RadiusX = $r; $ic.RadiusY = $r
  $script:bdT.X = ($w - $BD_W) / 2.0
  $cr = [System.Windows.CornerRadius]::new($r)
  $E.Rim.CornerRadius = $cr; $E.RimGlow.CornerRadius = $cr
  $ss = $E.ShadowShape
  [System.Windows.Controls.Canvas]::SetLeft($ss, $left)
  $ss.Width = $w; $ss.Height = $h; $ss.CornerRadius = $cr
  $sh = $E.shadowHole
  $sh.Rect = [System.Windows.Rect]::new($left, $TOP, $w, $h); $sh.RadiusX = $r; $sh.RadiusY = $r
}

function Step-Spring([double]$dt) {
  $n = [Math]::Max(1, [int][Math]::Ceiling($dt / 0.004))
  $h = $dt / $n
  for ($i = 0; $i -lt $n; $i++) {
    $sp.vw += (-$sp.k * ($sp.w - $sp.tw) - $sp.c * $sp.vw) * $h; $sp.w += $sp.vw * $h
    $sp.vh += (-$sp.k * ($sp.h - $sp.th) - $sp.c * $sp.vh) * $h; $sp.h += $sp.vh * $h
    $sp.vr += (-$sp.k * ($sp.r - $sp.tr) - $sp.c * $sp.vr) * $h; $sp.r += $sp.vr * $h
  }
}

$script:onRender = [System.EventHandler]{
  param($snd, $ev)
  try {
    $t = $clock.Elapsed.TotalSeconds
    $dt = $t - $sp.last
    if ($dt -lt 0.001) { return }
    if ($dt -gt 0.05) { $dt = 0.05 }
    $sp.last = $t
    Step-Spring $dt
    $settled = ([Math]::Abs($sp.w - $sp.tw) -lt 0.15) -and ([Math]::Abs($sp.h - $sp.th) -lt 0.15) -and
               ([Math]::Abs($sp.r - $sp.tr) -lt 0.15) -and ([Math]::Abs($sp.vw) -lt 1.2) -and
               ([Math]::Abs($sp.vh) -lt 1.2) -and ([Math]::Abs($sp.vr) -lt 1.2)
    if ($settled) {
      $sp.w = $sp.tw; $sp.h = $sp.th; $sp.r = $sp.tr; $sp.vw = 0.0; $sp.vh = 0.0; $sp.vr = 0.0
      Stop-Anim
    }
    Apply-Geo
  } catch {
    $ui.renderErr++
    if ($ui.renderErr -lt 4) { Log "render: $($_.Exception.Message)" }
    if ($ui.renderErr -gt 20) { Stop-Anim }
  }
}
function Start-Anim {
  if (-not $sp.active) {
    $sp.active = $true
    $sp.last = $clock.Elapsed.TotalSeconds
    [System.Windows.Media.CompositionTarget]::add_Rendering($script:onRender)
  }
}
function Stop-Anim {
  if ($sp.active) {
    $sp.active = $false
    [System.Windows.Media.CompositionTarget]::remove_Rendering($script:onRender)
  }
}

# aim the spring at the size that belongs to the current state (+ hover / press feedback)
function Retarget([double]$resp = 0.40, [double]$zeta = 0.78) {
  $key = $ui.sizeKey
  if ($key -eq 'idle' -and $ui.hover -and $cfg.hoverClock -and -not $ui.expanded) { $key = 'idleHover' }
  $s = $SIZES[$key]
  $w = [double]$s[0]; $h = [double]$s[1]; $r = [double]$s[2]
  if (-not $ui.expanded) {
    if ($ui.pressed) { $w = $w * 0.93; $h = $h * 0.88 }
    elseif ($ui.hover -and $key -ne 'idleHover') { $w += 8.0; $h += 2.0 }
    $r = $h / 2.0
  }
  if ($ui.reduceMotion) { $resp = 0.18; $zeta = 1.0 }
  $om = 2.0 * [Math]::PI / $resp
  $sp.k = $om * $om; $sp.c = 2.0 * $zeta * $om
  $sp.tw = $w; $sp.th = $h; $sp.tr = $r
  Start-Anim
}

# ============================================================
#  Glass material: tint, album wash, backdrop
# ============================================================
$script:tintBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(176, 14, 14, 18))
$E.TintLayer.Background = $script:tintBrush
$script:accBrush = New-Object System.Windows.Media.SolidColorBrush $ui.accent
# glass themes: tint colour of the panel ('auto' = follows the album cover, or the accent colour)
$THEMES = [ordered]@{
  auto     = @('Авто', $null)
  graphite = @('Графит', @(170, 170, 184))
  ocean    = @('Океан', @(20, 120, 255))
  sunset   = @('Закат', @(255, 110, 50))
  forest   = @('Лес', @(40, 190, 105))
  violet   = @('Фиалка', @(150, 85, 245))
  rose     = @('Роза', @(255, 60, 125))
}
# the colour that tints the glass right now: theme > album cover > nothing (accent decides)
function Get-BaseTint {
  $th = $THEMES[[string]$cfg.theme]
  if ($th -and $th[1]) { return $th[1] }
  if ($ui.tint -and $ui.mode -eq 'music') { return $ui.tint }
  if ($ui.tint -and $ui.expanded) { return $ui.tint }
  return $null
}
function Set-PillTint([int]$ms = 320, [bool]$solid = $false) {
  $bt = Get-BaseTint
  if ($bt) {
    $mr = [double]$bt[0]; $mg = [double]$bt[1]; $mb = [double]$bt[2]; $k = 0.30
  } else {
    $a = $ui.accent
    $mr = [double]$a.R; $mg = [double]$a.G; $mb = [double]$a.B
    $sat = ([Math]::Max($mr, [Math]::Max($mg, $mb)) - [Math]::Min($mr, [Math]::Min($mg, $mb))) / 255.0
    $k = 0.03 + 0.24 * $sat
  }
  if (-not $ui.glassOn) { $k = $k * 0.6 }
  $r = [int][Math]::Min(255, 11 + $mr * $k)
  $g = [int][Math]::Min(255, 11 + $mg * $k)
  $b = [int][Math]::Min(255, 15 + $mb * $k)
  if (-not $ui.glassOn) { $al = 255 }
  elseif ($ui.bdReady -and $ui.expanded -and (-not $ui.closing) -and (-not $solid)) {
    $al = 250 - 1.5 * [double]$cfg.glassAlpha
    $al = [int][Math]::Max(80, [Math]::Min(246, $al))
  } else { $al = 234 }
  $col = [System.Windows.Media.Color]::FromArgb([byte]$al, [byte]$r, [byte]$g, [byte]$b)
  $ca = New-Object System.Windows.Media.Animation.ColorAnimation
  $ca.To = $col
  $ca.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds($ms))
  $ca.EasingFunction = $script:easeOut
  $script:tintBrush.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $ca)
}
# the colour wash: two soft glows (top-left, bottom-right) so the WHOLE panel carries the colour
function Set-Wash {
  $bt = Get-BaseTint
  $show = ($bt -and $ui.glassOn -and ($ui.expanded -or $ui.mode -eq 'music'))
  if ($show) {
    $r = [byte]$bt[0]; $g = [byte]$bt[1]; $b = [byte]$bt[2]
    $E.washC0.Color = [System.Windows.Media.Color]::FromArgb(150, $r, $g, $b)
    $E.washC1.Color = [System.Windows.Media.Color]::FromArgb(0, $r, $g, $b)
    $E.washD0.Color = [System.Windows.Media.Color]::FromArgb(125, $r, $g, $b)
    $E.washD1.Color = [System.Windows.Media.Color]::FromArgb(0, $r, $g, $b)
    FadeTo $E.WashLayer $(if ($ui.expanded) { 0.72 } else { 0.6 }) 420
  } else { FadeTo $E.WashLayer 0.0 300 }
}
function Update-Glass {
  $ui.glassOn = ([bool]$cfg.glass -and $glassCapable)
  if ($ui.glassOn -and $ui.expanded -and (-not $ui.closing) -and (-not $ui.bdReady)) {
    # turned on while the panel is open: hide the island for a blink so the grab is clean
    try {
      [DI.Native]::Visible($mainHwnd, $false)
      Start-Sleep -Milliseconds 90
      Capture-Backdrop $true
    } finally { [DI.Native]::Visible($mainHwnd, (-not $ui.hidden)) }
    if ($ui.bdReady) { Set-Op $E.BdCanvas 0.0; FadeTo $E.BdCanvas 1.0 260 }
  }
  if (-not $ui.glassOn) { $ui.bdReady = $false; FadeTo $E.BdCanvas 0.0 160 }
  $E.RimGlow.Visibility = if ($ui.glassOn) { 'Visible' } else { 'Collapsed' }
  $E.Spec.Opacity = if ($ui.glassOn) { 1.0 } else { 0.5 }
  $E.alHit.IsEnabled = $ui.glassOn
  $E.alHit.Opacity = if ($ui.glassOn) { 1.0 } else { 0.4 }
  Set-PillTint 260 $false
  Set-Wash
}
function Set-Hidden([bool]$h) {
  if ($ui.hidden -eq $h) { return }
  $ui.hidden = $h
  [DI.Native]::Visible($mainHwnd, (-not $h))
  Log "hidden=$h"
}
function Apply-Accent([System.Windows.Media.Color]$c) {
  $ui.accent = $c
  $ca = New-Object System.Windows.Media.Animation.ColorAnimation
  $ca.To = $c
  $ca.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(320))
  $ca.EasingFunction = $script:easeOut
  $script:accBrush.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $ca)
  foreach ($d in $E.dotsHost.Children) {
    $dc = ([System.Windows.Media.SolidColorBrush]$d.Background).Color
    $d.Tag = $(if ($dc -eq $c) { 'sel' } else { $null })
  }
  Set-PillTint
  $cfg.accent = "$($c.R),$($c.G),$($c.B)"
  Request-Save
}

# ============================================================
#  Animation helpers
# ============================================================
$script:easeOut = New-Object System.Windows.Media.Animation.CubicEase
$script:easeOut.EasingMode = 'EaseOut'
function PP([string]$p) { return (New-Object System.Windows.PropertyPath $p) }
function FadeTo($el, [double]$to, [int]$ms) {
  $a = New-Object System.Windows.Media.Animation.DoubleAnimation
  $a.To = $to
  $a.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds($ms))
  $el.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $a)
}
function Set-Op($el, [double]$v) {
  $el.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
  $el.Opacity = $v
}
function SwapPanel($from, $to, [int]$ms) {
  if ($from -and $from -ne $to) { $from.Visibility = 'Hidden' }
  if ($to) {
    $to.Opacity = 0
    $to.Visibility = 'Visible'
    $sb = New-Object System.Windows.Media.Animation.Storyboard
    $d = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds($ms))
    $a1 = New-Object System.Windows.Media.Animation.DoubleAnimation
    $a1.From = 0; $a1.To = 1; $a1.Duration = $d
    [System.Windows.Media.Animation.Storyboard]::SetTarget($a1, $to)
    [System.Windows.Media.Animation.Storyboard]::SetTargetProperty($a1, (PP 'Opacity'))
    $sb.Children.Add($a1) | Out-Null
    foreach ($pp in @('(UIElement.RenderTransform).(ScaleTransform.ScaleX)', '(UIElement.RenderTransform).(ScaleTransform.ScaleY)')) {
      $a = New-Object System.Windows.Media.Animation.DoubleAnimation
      $a.From = 0.88; $a.To = 1; $a.Duration = $d
      $a.EasingFunction = $script:easeOut
      [System.Windows.Media.Animation.Storyboard]::SetTarget($a, $to)
      [System.Windows.Media.Animation.Storyboard]::SetTargetProperty($a, (PP $pp))
      $sb.Children.Add($a) | Out-Null
    }
    $sb.Begin($to)
  }
}


# colour of a brush glides to another colour
function Anim-Color($brush, [System.Windows.Media.Color]$to, [int]$ms = 240) {
  $ca = New-Object System.Windows.Media.Animation.ColorAnimation
  $ca.To = $to
  $ca.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds($ms))
  $ca.EasingFunction = $script:easeOut
  $brush.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $ca)
}
# run a script block once, a little later (UI thread)
function Later([int]$ms, [scriptblock]$sb) {
  $tm = New-Object System.Windows.Threading.DispatcherTimer
  $tm.Interval = [TimeSpan]::FromMilliseconds($ms)
  $tm.Tag = $sb
  $tm.Add_Tick({
    param($snd, $ev)
    $snd.Stop()
    try { & $snd.Tag } catch { Log "later: $($_.Exception.Message)" }
  })
  $tm.Start()
}
# a row / tile / card slides up a few pixels while it fades in (the i-th item of a list is a bit later)
function Pop-In($el, [int]$i = 0, [double]$dy = 9.0) {
  if ($ui.reduceMotion) { return }
  try {
    $tt = $el.RenderTransform
    if (-not ($tt -is [System.Windows.Media.TranslateTransform])) {
      $tt = New-Object System.Windows.Media.TranslateTransform
      $el.RenderTransform = $tt
    }
    $d = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(320))
    $bt = [TimeSpan]::FromMilliseconds([Math]::Min(420, 34 * $i))
    $el.Opacity = 0.0
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation
    $a.From = 0.0; $a.To = 1.0; $a.Duration = $d; $a.BeginTime = $bt
    $el.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $a)
    $b = New-Object System.Windows.Media.Animation.DoubleAnimation
    $b.From = $dy; $b.To = 0.0; $b.Duration = $d; $b.BeginTime = $bt; $b.EasingFunction = $script:easeOut
    $tt.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $b)
  } catch {}
}
# the element shrinks and fades before it is removed
function Pop-Out($el, [int]$ms = 170) {
  try {
    FadeTo $el 0.0 $ms
    $tt = $el.RenderTransform
    if ($tt -is [System.Windows.Media.TranslateTransform]) { Anim-To $tt ([System.Windows.Media.TranslateTransform]::XProperty) 14.0 $ms }
  } catch {}
}

# --- equalizer bars ---
$waveSb = New-Object System.Windows.Media.Animation.Storyboard
$wi = 0
foreach ($n in 'w1', 'w2', 'w3', 'w4', 'w5') {
  $a = New-Object System.Windows.Media.Animation.DoubleAnimation
  $a.From = 3.5; $a.To = 14
  $a.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(500 + 90 * $wi))
  $a.AutoReverse = $true
  $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
  $a.BeginTime = [TimeSpan]::FromMilliseconds(70 * $wi)
  [System.Windows.Media.Animation.Storyboard]::SetTarget($a, $E[$n])
  [System.Windows.Media.Animation.Storyboard]::SetTargetProperty($a, (PP 'Height'))
  $waveSb.Children.Add($a) | Out-Null
  $wi++
}
foreach ($n in 'w1', 'w2', 'w3', 'w4', 'w5') { $E[$n].Fill = $script:accBrush }
$E.progFill.Background = $script:accBrush
$E.colPrev.Background = $script:accBrush
function WaveStart  { try { $waveSb.Begin($E.wavePanel, $true) } catch {} }
function WaveStop   { try { $waveSb.Stop($E.wavePanel) } catch {} }
function WavePause  { try { $waveSb.Pause($E.wavePanel) } catch {} }
function WaveResume { try { $waveSb.Resume($E.wavePanel) } catch {} }

$script:easeBack = New-Object System.Windows.Media.Animation.BackEase
$script:easeBack.EasingMode = 'EaseOut'
$script:easeBack.Amplitude = 0.6
function Anim-To($target, $dp, [double]$to, [int]$ms, $ease = $null) {
  $a = New-Object System.Windows.Media.Animation.DoubleAnimation
  $a.To = $to
  $a.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds($ms))
  $a.EasingFunction = $(if ($ease) { $ease } else { $script:easeOut })
  $target.BeginAnimation($dp, $a)
}

# ============================================================
#  Slider component (track progress / volume / glass transparency).
#  Plain mouse handling instead of the WPF Slider: press = jump there, drag = follow, release = commit.
# ============================================================
$SL = @{}
function Slider-FracAt($s, [double]$x) {
  if ($s.w -lt 1) { return 0.0 }
  return [Math]::Max(0.0, [Math]::Min(1.0, $x / $s.w))
}
function Slider-Set([string]$id, [double]$f, [bool]$anim = $false) {
  $s = $SL[$id]
  if ($f -lt 0) { $f = 0.0 }
  if ($f -gt 1) { $f = 1.0 }
  $s.frac = $f
  $fw = $s.w * $f
  $kx = [Math]::Max(0.0, [Math]::Min($s.w - 14.0, $fw - 7.0))
  if ($anim) {
    Anim-To $s.fill ([System.Windows.FrameworkElement]::WidthProperty) $fw 170
    Anim-To $s.kt ([System.Windows.Media.TranslateTransform]::XProperty) $kx 170
  } else {
    $s.fill.BeginAnimation([System.Windows.FrameworkElement]::WidthProperty, $null)
    $s.fill.Width = $fw
    $s.kt.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $null)
    $s.kt.X = $kx
  }
}
# hover / drag look: the bar thickens, the knob pops in, the bubble shows
function Slider-Look([string]$id) {
  $s = $SL[$id]
  $on = ($s.hover -or $s.drag)
  $hp = [System.Windows.FrameworkElement]::HeightProperty
  $th = $(if ($on) { 10.0 } else { 6.0 })
  Anim-To $s.track $hp $th 170
  Anim-To $s.fill $hp $th 170
  Anim-To $s.knob ([System.Windows.UIElement]::OpacityProperty) $(if ($on) { 1.0 } else { 0.0 }) 150
  $ks = $(if ($s.drag) { 1.18 } elseif ($on) { 1.0 } else { 0.5 })
  Anim-To $s.ks ([System.Windows.Media.ScaleTransform]::ScaleXProperty) $ks 200 $(if ($on) { $script:easeBack } else { $null })
  Anim-To $s.ks ([System.Windows.Media.ScaleTransform]::ScaleYProperty) $ks 200 $(if ($on) { $script:easeBack } else { $null })
  $showTip = ($s.drag -or ($s.hover -and $s.preview))
  Anim-To $s.tip ([System.Windows.UIElement]::OpacityProperty) $(if ($showTip) { 1.0 } else { 0.0 }) 130
}
function Slider-Tip([string]$id, [double]$f, [double]$x) {
  $s = $SL[$id]
  if (-not ($s.drag -or $s.preview)) { return }
  $txt = [string](& $s.fmt $f)
  $s.tipTxt.Text = $(if ($txt) { $txt } else { '–:––' })
  $s.tt.X = [Math]::Max(0.0, [Math]::Min($s.w - 50.0, $x - 25.0))
}
function Add-Slider([string]$id, [scriptblock]$onMove, [scriptblock]$onCommit, [scriptblock]$fmt, [bool]$preview = $false, [double]$wheel = 0.0) {
  $hit = $E["${id}Hit"]
  $knob = $E["${id}Knob"]
  $SL[$id] = @{
    id = $id; hit = $hit; w = [double]$hit.Width
    fill = $E["${id}Fill"]; track = $E["${id}Track"]; knob = $knob
    tip = $E["${id}Tip"]; tipTxt = $E["${id}TipTxt"]
    ks = $knob.RenderTransform.Children[0]; kt = $knob.RenderTransform.Children[1]
    tt = $E["${id}Tip"].RenderTransform
    frac = 0.0; drag = $false; hover = $false; preview = $preview; wheel = $wheel
    onMove = $onMove; onCommit = $onCommit; fmt = $fmt
  }
  $hit.Add_MouseEnter({
    param($snd, $ev)
    $id2 = $snd.Name -replace 'Hit$', ''
    $SL[$id2].hover = $true
    Slider-Look $id2
  })
  $hit.Add_MouseLeave({
    param($snd, $ev)
    $id2 = $snd.Name -replace 'Hit$', ''
    $SL[$id2].hover = $false
    Slider-Look $id2
  })
  $hit.Add_MouseLeftButtonDown({
    param($snd, $ev)
    $id2 = $snd.Name -replace 'Hit$', ''
    $s2 = $SL[$id2]
    $ev.Handled = $true
    [void]$snd.CaptureMouse()
    $s2.drag = $true
    $x = $ev.GetPosition($snd).X
    $f = Slider-FracAt $s2 $x
    Slider-Set $id2 $f $false
    Slider-Look $id2
    Slider-Tip $id2 $f $x
    & $s2.onMove $f $id2
  })
  $hit.Add_MouseMove({
    param($snd, $ev)
    $id2 = $snd.Name -replace 'Hit$', ''
    $s2 = $SL[$id2]
    $x = $ev.GetPosition($snd).X
    $f = Slider-FracAt $s2 $x
    if ($s2.drag) {
      Slider-Set $id2 $f $false
      & $s2.onMove $f $id2
    }
    Slider-Tip $id2 $f $x
  })
  $hit.Add_MouseLeftButtonUp({
    param($snd, $ev)
    $id2 = $snd.Name -replace 'Hit$', ''
    $s2 = $SL[$id2]
    if ($s2.drag) {
      $s2.drag = $false
      $snd.ReleaseMouseCapture()
      Slider-Look $id2
      & $s2.onCommit $s2.frac $id2
    }
    $ev.Handled = $true
  })
  $hit.Add_LostMouseCapture({
    param($snd, $ev)
    $id2 = $snd.Name -replace 'Hit$', ''
    $s2 = $SL[$id2]
    if ($s2.drag) {
      $s2.drag = $false
      Slider-Look $id2
      & $s2.onCommit $s2.frac $id2
    }
  })
  if ($wheel -gt 0) {
    $hit.Add_MouseWheel({
      param($snd, $ev)
      $id2 = $snd.Name -replace 'Hit$', ''
      $s2 = $SL[$id2]
      $nf = $s2.frac + ($ev.Delta / 120.0) * $s2.wheel
      Slider-Set $id2 $nf $true
      & $s2.onMove $s2.frac $id2
      & $s2.onCommit $s2.frac $id2
      $ev.Handled = $true
    })
  }
}

# ============================================================
#  State, navigation, expand / collapse
# ============================================================
$COMPACT_OF = @{ idle = 'cIdle'; music = 'cMusic'; timer = 'cTimer'; charge = 'cCharge'; done = 'cDone'; vol = 'cVol'; event = 'cEvent' }
$SECTIONS   = @{ music = 'mMusic'; todo = 'mTodo'; weather = 'mWeather'; sys = 'mSys'; sound = 'mSound'; clip = 'mClip'; sites = 'mSites'; shelf = 'mShelf'; view = 'mView'; more = 'mMore'; timer = 'mTimerRun' }
$TABS       = @{ music = 'tbMusic'; todo = 'tbTodo'; weather = 'tbWeather'; sys = 'tbSys'; sound = 'tbSound'; clip = 'tbClip'; sites = 'tbSites'; shelf = 'tbShelf'; view = 'tbView'; more = 'tbMore' }
$ui.musicOn = $false
$ui.vs = @{ vol = $false; mvol = $false }   # is the slider of this tab already in step with Windows volume?

$script:tabActiveBg = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(242, 242, 242)); $script:tabActiveBg.Freeze()
$script:tabActiveFg = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(14, 14, 18)); $script:tabActiveFg.Freeze()
$script:tabIdleCol   = [System.Windows.Media.Color]::FromArgb(0xA6, 0xFF, 0xFF, 0xFF)
$script:tabActiveCol = [System.Windows.Media.Color]::FromRgb(14, 14, 18)
# every tab keeps its own text brush so the colour can fade when the tab changes
$script:tabBrush = @{}
foreach ($k in $TABS.Keys) {
  $tbr = New-Object System.Windows.Media.SolidColorBrush $script:tabIdleCol
  $E[$TABS[$k]].Foreground = $tbr
  $script:tabBrush[$k] = $tbr
}

function Hide-AllCompact { foreach ($k in $COMPACT_OF.Keys) { $E[$COMPACT_OF[$k]].Visibility = 'Hidden' } }

function Set-Compact([string]$mode) {
  $name = $COMPACT_OF[$mode]
  $panel = if ($name) { $E[$name] } else { $null }
  if ($panel -ne $ui.compactPanel) {
    SwapPanel $ui.compactPanel $panel 190
    $ui.compactPanel = $panel
    if ($mode -eq 'music' -and $cfg.eq) { WaveStart; $ui.waveStarted = $true; $ui.wavePaused = $false }
    else { WaveStop; $ui.waveStarted = $false; $ui.wavePaused = $false }
  }
}

function Compute-Mode {
  $now = Now-Ms
  if ($now -lt $ui.doneUntil) { return 'done' }
  if ($now -lt $ui.evtUntil) { return 'event' }
  if ($now -lt $ui.volUntil) { return 'vol' }
  if ($now -lt $ui.chargeUntil) { return 'charge' }
  if ($ui.timerLeft -gt 0) { return 'timer' }
  if ($ui.musicOn) { return 'music' }
  return 'idle'
}
function Go-Mode([string]$mode) {
  $ui.mode = $mode
  if ($ui.expanded) { return }
  Set-Compact $mode
  $ui.sizeKey = $mode
  Retarget 0.42 0.84
  Set-Wash
}
function Update-Mode {
  $m = Compute-Mode
  if ($m -ne $ui.mode) { Go-Mode $m }
}

function Show-Section([string]$name, [bool]$animate = $true) {
  foreach ($k in $SECTIONS.Keys) {
    $sec = $E[$SECTIONS[$k]]
    if ($k -eq $name) {
      if ($sec.Visibility -ne 'Visible') {
        if ($animate) { $sec.Opacity = 0 }
        $sec.Visibility = 'Visible'
        if ($animate) {
          $sb = New-Object System.Windows.Media.Animation.Storyboard
          $d = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(240))
          $a1 = New-Object System.Windows.Media.Animation.DoubleAnimation
          $a1.From = 0; $a1.To = 1; $a1.Duration = $d
          [System.Windows.Media.Animation.Storyboard]::SetTarget($a1, $sec)
          [System.Windows.Media.Animation.Storyboard]::SetTargetProperty($a1, (PP 'Opacity'))
          $sb.Children.Add($a1) | Out-Null
          $a2 = New-Object System.Windows.Media.Animation.DoubleAnimation
          $a2.From = 10; $a2.To = 0; $a2.Duration = $d
          $a2.EasingFunction = $script:easeOut
          [System.Windows.Media.Animation.Storyboard]::SetTarget($a2, $sec)
          [System.Windows.Media.Animation.Storyboard]::SetTargetProperty($a2, (PP '(UIElement.RenderTransform).(TranslateTransform.Y)'))
          $sb.Children.Add($a2) | Out-Null
          $sb.Begin($sec)
        }
      }
    } else { $sec.Visibility = 'Hidden' }
  }
}
# the light "pill" under the active tab glides to it; the text colour fades
function Set-TabInd([string]$tab, [bool]$animate) {
  $btn = $E[$TABS[$tab]]
  if ((-not $btn) -or $E.tabBar.Visibility -ne 'Visible') { return }
  $w = $btn.ActualWidth
  if ($w -lt 5) {
    # not laid out yet: fall back to a plain highlighted button
    foreach ($k in $TABS.Keys) {
      $E[$TABS[$k]].Background = $(if ($k -eq $tab) { $script:tabActiveBg } else { [System.Windows.Media.Brushes]::Transparent })
    }
    $E.tabInd.Opacity = 0.0
    return
  }
  foreach ($k in $TABS.Keys) { $E[$TABS[$k]].Background = [System.Windows.Media.Brushes]::Transparent }
  $x = $btn.TranslatePoint((New-Object System.Windows.Point (0.0, 0.0)), $E.tabRow).X
  $t = $E.tabInd.RenderTransform
  $wp = [System.Windows.FrameworkElement]::WidthProperty
  $xp = [System.Windows.Media.TranslateTransform]::XProperty
  if ($animate -and $E.tabInd.Opacity -gt 0.5 -and (-not $ui.reduceMotion)) {
    Anim-To $E.tabInd $wp $w 340 $script:easeBack
    Anim-To $t $xp $x 340 $script:easeBack
  } else {
    $E.tabInd.BeginAnimation($wp, $null); $E.tabInd.Width = $w
    $t.BeginAnimation($xp, $null); $t.X = $x
    Set-Op $E.tabInd 1.0
  }
}
function Update-SysOn {
  $on = ($ui.expanded -and (-not $ui.closing) -and $ui.tab -eq 'sys' -and $E.tabBar.Visibility -eq 'Visible')
  if ($on -and (-not $sync.SysOn)) { Reset-SysUi }
  $sync.SysOn = $on
}
function Set-Tab([string]$tab, [bool]$animate = $true) {
  $prev = $ui.tab
  $ui.tab = $tab
  foreach ($k in $TABS.Keys) {
    $to = $(if ($k -eq $tab) { $script:tabActiveCol } else { $script:tabIdleCol })
    $br = $script:tabBrush[$k]
    if ($animate) {
      $ca = New-Object System.Windows.Media.Animation.ColorAnimation
      $ca.To = $to
      $ca.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(240))
      $br.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $ca)
    } else {
      $br.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $null)
      $br.Color = $to
    }
  }
  Set-TabInd $tab $animate
  if ($prev -eq 'sites' -and $tab -ne 'sites') { Close-SiteAdd $true; Set-SitesEdit $false }
  if ($prev -eq 'weather' -and $tab -ne 'weather') { Wx-CloseSearch $true }
  if ($ui.kbd -and (-not $ui.siteAddOpen)) { End-Kbd }
  Show-Section $tab $animate
  Update-SysOn
  try {
    if ($tab -eq 'music') { $ui.vs.vol = $false; Lyr-Sync; Music-Resume }
    elseif ($tab -eq 'todo') { Build-Events; Build-Todos $animate }
    elseif ($tab -eq 'weather') { Wx-Show }
    elseif ($tab -eq 'sound') { $ui.vs.mvol = $false; $ui.mixAt = 0.0; Mixer-Poll }
    elseif ($tab -eq 'clip') { $ui.clipRef = $null; Build-Clip $animate }
    elseif ($tab -eq 'sites') { Build-Sites }
    elseif ($tab -eq 'shelf') { Build-Shelf $animate }
    elseif ($tab -eq 'view') { Sync-Themes; Sync-PillOpts }
    elseif ($tab -eq 'more') { Sync-Hotkeys; Sync-Pomo }
  } catch { Log "tab $tab : $($_.Exception.Message)" }
}

# Opening: the screen behind the island is grabbed and blurred (the glass), the little content fades out, the shape
# springs open, and the panel content slides in once the shape is ~half open.
function Expand {
  if ($ui.expanded -or $ui.closing) { return }
  $closeTimer.Stop()
  $ui.expanded = $true; $ui.hover = $false; $ui.pressed = $false
  Capture-Backdrop
  if ($ui.bdReady) { Set-Op $E.BdCanvas 0.0; FadeTo $E.BdCanvas 1.0 340 }
  FadeTo $E.CompactLayer 0.0 90
  # start from a clean invisible state BEFORE the layer becomes visible (no flash of half-clipped content)
  Set-Op $E.ExpandedLayer 0.0
  $E.expT.Y = 14.0
  if ($ui.timerLeft -gt 0) {
    $E.tabBar.Visibility = 'Collapsed'
    Show-Section 'timer' $false
  } else {
    $E.tabBar.Visibility = 'Visible'
    Set-Tab $ui.tab $false
  }
  $E.ExpandedLayer.Visibility = 'Visible'
  try { $E.ExpandedLayer.UpdateLayout(); if ($ui.timerLeft -le 0) { Set-TabInd $ui.tab $false } } catch { Log "layout: $($_.Exception.Message)" }
  if ($ui.timerLeft -le 0 -and $ui.tab -eq 'music') { try { Music-Resume } catch { } }
  Update-SysOn
  $sb = New-Object System.Windows.Media.Animation.Storyboard
  $ao = New-Object System.Windows.Media.Animation.DoubleAnimation
  $ao.From = 0; $ao.To = 1
  $ao.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(260))
  $ao.BeginTime = [TimeSpan]::FromMilliseconds(130)
  [System.Windows.Media.Animation.Storyboard]::SetTarget($ao, $E.ExpandedLayer)
  [System.Windows.Media.Animation.Storyboard]::SetTargetProperty($ao, (PP 'Opacity'))
  $sb.Children.Add($ao) | Out-Null
  $ay = New-Object System.Windows.Media.Animation.DoubleAnimation
  $ay.From = 14; $ay.To = 0
  $ay.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(420))
  $ay.BeginTime = [TimeSpan]::FromMilliseconds(110)
  $ay.EasingFunction = $script:easeOut
  [System.Windows.Media.Animation.Storyboard]::SetTarget($ay, $E.ExpandedLayer)
  [System.Windows.Media.Animation.Storyboard]::SetTargetProperty($ay, (PP '(UIElement.RenderTransform).(TranslateTransform.Y)'))
  $sb.Children.Add($ay) | Out-Null
  $sb.Begin($E.ExpandedLayer)
  # one soft highlight gliding over the glass while it opens
  if (-not $ui.reduceMotion) {
    try {
      $swSb = New-Object System.Windows.Media.Animation.Storyboard
      $swDur = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(700))
      $ax = New-Object System.Windows.Media.Animation.DoubleAnimation
      $ax.From = -260; $ax.To = 820; $ax.Duration = $swDur
      $ax.EasingFunction = $script:easeOut
      [System.Windows.Media.Animation.Storyboard]::SetTarget($ax, $E.sweepX)
      [System.Windows.Media.Animation.Storyboard]::SetTargetProperty($ax, (PP 'X'))
      $swSb.Children.Add($ax) | Out-Null
      $so = New-Object System.Windows.Media.Animation.DoubleAnimation
      $so.From = 0.5; $so.To = 0; $so.Duration = $swDur
      [System.Windows.Media.Animation.Storyboard]::SetTarget($so, $E.sweepLight)
      [System.Windows.Media.Animation.Storyboard]::SetTargetProperty($so, (PP 'Opacity'))
      $swSb.Children.Add($so) | Out-Null
      $swSb.Begin()
    } catch {}
  }
  $ui.sizeKey = 'panel'
  Set-PillTint 320 $false
  Set-Wash
  Retarget 0.52 0.82
  $fast.Start()
}

# Closing: the content and the glass fade first while the shape holds still, then the shape springs shut.
function Collapse {
  if ((-not $ui.expanded) -or $ui.closing) { return }
  $ui.closing = $true
  $fast.Stop()
  End-Kbd
  Update-SysOn
  Set-PillTint 140 $true
  FadeTo $E.ExpandedLayer 0.0 120
  FadeTo $E.BdCanvas 0.0 160
  $closeTimer.Stop()
  $closeTimer.Start()
}
function Finish-Collapse {
  $closeTimer.Stop()
  if (-not $ui.closing) { return }
  $ui.bdReady = $false
  Set-Op $E.BdCanvas 0.0
  Close-SiteAdd $true
  Set-SitesEdit $false
  $ui.closing = $false
  $ui.expanded = $false
  $E.ExpandedLayer.Visibility = 'Hidden'
  foreach ($k in $SECTIONS.Keys) { $E[$SECTIONS[$k]].Visibility = 'Hidden' }
  Hide-AllCompact
  $ui.compactPanel = $null
  Set-Op $E.CompactLayer 1.0
  $E.CompactLayer.Visibility = 'Visible'
  $m = Compute-Mode
  $ui.mode = $m
  Set-Compact $m
  $ui.sizeKey = $m
  Set-PillTint 200 $true
  Set-Wash
  Retarget 0.40 0.88
}
$closeTimer = New-Object System.Windows.Threading.DispatcherTimer
$closeTimer.Interval = [TimeSpan]::FromMilliseconds(125)
$closeTimer.Add_Tick({ try { Finish-Collapse } catch { Log "finish-collapse: $($_.Exception.Message)" } })

# ============================================================
#  Weather icons (stroke icons, 24x24 grid)
# ============================================================
$WX_ICONS = @{
  sun     = @('M12 7a5 5 0 1 0 0 10 5 5 0 0 0 0-10z M12 1v2 M12 21v2 M4.22 4.22l1.42 1.42 M18.36 18.36l1.42 1.42 M1 12h2 M21 12h2 M4.22 19.78l1.42-1.42 M18.36 5.64l1.42-1.42', '#FFD60A')
  moon    = @('M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z', '#D8DBFF')
  pcloud  = @('M12 2v2 M4.93 4.93l1.41 1.41 M20 12h2 M19.07 4.93l-1.41 1.41 M15.947 12.65a4 4 0 0 0-5.925-4.128 M13 22H7a5 5 0 1 1 4.9-6H13a3 3 0 0 1 0 6z', '#EAF2FF')
  cloud   = @('M18 10h-1.26A8 8 0 1 0 9 20h9a5 5 0 0 0 0-10z', '#D7E3F5')
  fog     = @('M9.59 4.59A2 2 0 1 1 11 8H2 M12.59 19.41A2 2 0 1 0 14 16H2 M17.73 7.73A2.5 2.5 0 1 1 19.5 12H2', '#C9D2DC')
  drizzle = @('M8 19v2 M8 13v2 M16 19v2 M16 13v2 M12 21v2 M12 15v2 M20 16.58A5 5 0 0 0 18 7h-1.26A8 8 0 1 0 4 15.25', '#9ACBFF')
  rain    = @('M16 13v8 M8 13v8 M12 15v8 M20 16.58A5 5 0 0 0 18 7h-1.26A8 8 0 1 0 4 15.25', '#7CC4FF')
  snow    = @('M20 17.58A5 5 0 0 0 18 8h-1.26A8 8 0 1 0 4 16.25 M8 16h.01 M8 20h.01 M12 18h.01 M12 22h.01 M16 16h.01 M16 20h.01', '#E3F3FF')
  storm   = @('M19 16.9A5 5 0 0 0 18 7h-1.26a8 8 0 1 0-11.62 9 M13 11l-4 6h6l-4 6', '#FFE066')
}
function Set-WxIcon($path, [string]$key) {
  $ic = $WX_ICONS[$key]
  if (-not $ic) { $ic = $WX_ICONS['cloud'] }
  $path.Data = [System.Windows.Media.Geometry]::Parse($ic[0])
  $path.Stroke = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($ic[1]))
}
# ============================================================
#  Timer
# ============================================================
function Format-Time([double]$sec) {
  if ($sec -lt 0) { $sec = 0 }
  return ("{0}:{1:d2}" -f [int][Math]::Floor($sec / 60), [int]([Math]::Floor($sec) % 60))
}
function Update-TimerText {
  $t = Format-Time $ui.timerLeft
  $pre = ''
  if ($ui.pomo) { $pre = $(if ($ui.pomoPhase -eq 'work') { 'Фокус ' } else { 'Отдых ' }) }
  $E.cTimerTxt.Text = $pre + $t
  $E.xTimerBig.Text = $t
  if ($ui.pomo) {
    $n = ($ui.pomoRound % 4) + 1
    if ($ui.pomoPhase -eq 'work') { $E.xTimerPhase.Text = "ФОКУС · КРУГ $n ИЗ 4"; $E.xTimerPhase.Foreground = $script:brOrange }
    elseif ($ui.pomoPhase -eq 'long') { $E.xTimerPhase.Text = 'ДЛИННЫЙ ПЕРЕРЫВ'; $E.xTimerPhase.Foreground = $script:brGreen }
    else { $E.xTimerPhase.Text = 'ПЕРЕРЫВ'; $E.xTimerPhase.Foreground = $script:brGreen }
  } else { $E.xTimerPhase.Text = '' }
}
function Start-Timer([int]$sec, [bool]$pomo = $false) {
  $ui.pomo = $pomo
  $ui.timerTotal = $sec; $ui.timerLeft = $sec; $ui.timerPaused = $false
  $E.btnPause.Content = 'Пауза'
  Update-TimerText
  if ($ui.expanded) { Collapse }
  Update-Mode
}
# Pomodoro: 25 min focus -> 5 min break, every 4th break is a long one (15 min). Runs by itself until "Стоп".
function Pomo-Phase([string]$ph) {
  $ui.pomoPhase = $ph
  $secs = 1500
  if ($ph -eq 'short') { $secs = 300 } elseif ($ph -eq 'long') { $secs = 900 }
  Start-Timer $secs $true
}
function Start-Pomo { $ui.pomoRound = 0; Pomo-Phase 'work' }
# called when a timer reaches zero; returns the text for the "done" pill
function Pomo-Next {
  if (-not $ui.pomoArmed) { return }
  $ui.pomoArmed = $false
  if ($ui.timerLeft -gt 0) { return }
  Pomo-Phase $script:pomoNext
}
function Timer-Finished {
  if (-not $ui.pomo) { return 'Готово' }
  $ui.pomoArmed = $true
  if ($ui.pomoPhase -eq 'work') {
    $ui.pomoRound++
    $script:pomoNext = $(if (($ui.pomoRound % 4) -eq 0) { 'long' } else { 'short' })
    Later 2900 { Pomo-Next }
    return $(if ($script:pomoNext -eq 'long') { 'Длинный перерыв!' } else { 'Перерыв!' })
  }
  $script:pomoNext = 'work'
  Later 2900 { Pomo-Next }
  return 'Снова в фокус!'
}

# ============================================================
#  Autostart, tray, quit
# ============================================================
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$VbsPath = Join-Path $ScriptDir 'Dynamic Island.vbs'
function Get-Autostart { return ($null -ne (Get-ItemProperty -Path $RunKey -Name 'DynamicIsland' -ErrorAction SilentlyContinue)) }
function Set-Autostart([bool]$on) {
  try {
    if ($on) { Set-ItemProperty -Path $RunKey -Name 'DynamicIsland' -Value ('wscript.exe "' + $VbsPath + '"') }
    else { Remove-ItemProperty -Path $RunKey -Name 'DynamicIsland' -ErrorAction SilentlyContinue }
  } catch { Log "autostart: $($_.Exception.Message)" }
  $cur = Get-Autostart
  $E.swAuto.IsChecked = $cur
  if ($script:miAuto) { $script:miAuto.Checked = $cur }
}
function Quit-App {
  try { $sync.Running = $false } catch {}
  try { Stop-Anim } catch {}
  try { $script:ni.Visible = $false; $script:ni.Dispose() } catch {}
  try { End-Kbd } catch {}
  Log 'quit'
  try { $app.Shutdown() } catch {}
}

$bmp = New-Object System.Drawing.Bitmap 32, 32
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = 'AntiAlias'
$pillPath = New-Object System.Drawing.Drawing2D.GraphicsPath
$pillPath.AddArc(5, 9, 22, 22, 180, 180)
$pillPath.AddArc(5, 9, 22, 22, 0, 180)
$pillPath.CloseFigure()
$g.FillPath([System.Drawing.Brushes]::Black, $pillPath)
$g.FillEllipse([System.Drawing.Brushes]::SpringGreen, 21, 16, 5, 5)
$g.Dispose()
$icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())

$script:ni = New-Object System.Windows.Forms.NotifyIcon
$script:ni.Icon = $icon
$script:ni.Text = 'Dynamic Island'
$script:ni.Visible = $true
$cms = New-Object System.Windows.Forms.ContextMenuStrip
$miToggle = New-Object System.Windows.Forms.ToolStripMenuItem 'Развернуть / свернуть'
$miToggle.Add_Click({ if ($ui.expanded) { Collapse } else { Expand } })
$script:miAuto = New-Object System.Windows.Forms.ToolStripMenuItem 'Запускать при входе в Windows'
$script:miAuto.CheckOnClick = $false
$script:miAuto.Add_Click({ Set-Autostart (-not (Get-Autostart)) })
$miLog = New-Object System.Windows.Forms.ToolStripMenuItem 'Открыть папку с логами'
$miLog.Add_Click({ try { Start-Process explorer.exe $DataDir } catch {} })
$miExit = New-Object System.Windows.Forms.ToolStripMenuItem 'Выход'
$miExit.Add_Click({ Quit-App })
[void]$cms.Items.Add($miToggle)
[void]$cms.Items.Add($script:miAuto)
[void]$cms.Items.Add($miLog)
[void]$cms.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$cms.Items.Add($miExit)
$script:ni.ContextMenuStrip = $cms
$script:ni.Add_MouseClick({
  param($snd, $ev)
  if ($ev.Button -eq [System.Windows.Forms.MouseButtons]::Left) { if ($ui.expanded) { Collapse } else { Expand } }
})

# ============================================================
#  Controls
# ============================================================
$script:brGreen = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(48, 209, 88)); $script:brGreen.Freeze()
$script:brRed = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(255, 69, 58)); $script:brRed.Freeze()
$script:brOrange = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(255, 159, 10)); $script:brOrange.Freeze()
$ui.playing = $true

# accent colour dots
$ACCENTS = @(
  @(242, 242, 242), @(255, 69, 58), @(255, 159, 10), @(255, 214, 10), @(48, 209, 88),
  @(100, 210, 255), @(10, 132, 255), @(191, 90, 242), @(255, 55, 95), @(172, 142, 104), @(16, 16, 18)
)
foreach ($ac in $ACCENTS) {
  $btn = New-Object System.Windows.Controls.Button
  $btn.Style = $E.dotsHost.FindResource('DotBtn')
  $btn.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb([byte]$ac[0], [byte]$ac[1], [byte]$ac[2]))
  $btn.Add_Click([System.Windows.RoutedEventHandler]{
    param($snd, $ev)
    Apply-Accent ([System.Windows.Media.SolidColorBrush]$snd.Background).Color
  })
  $null = $E.dotsHost.Children.Add($btn)
}
$script:accBrush.Color = $ui.accent
foreach ($d in $E.dotsHost.Children) {
  $d.Tag = $(if (([System.Windows.Media.SolidColorBrush]$d.Background).Color -eq $ui.accent) { 'sel' } else { $null })
}

# initial control state (set before handlers are attached)
$E.swEq.IsChecked = [bool]$cfg.eq
$E.swCharge.IsChecked = [bool]$cfg.charge
$E.swFull.IsChecked = [bool]$cfg.hideFull
$E.swClock.IsChecked = [bool]$cfg.hoverClock
$E.swGlass.IsChecked = [bool]$cfg.glass
$E.swAuto.IsChecked = (Get-Autostart)
$script:miAuto.Checked = (Get-Autostart)
if (-not $cfg.eq) { $E.wavePanel.Visibility = 'Collapsed' }

# media
# the UI reacts at once (optimistic), the worker sends the command to the media session
$E.btnPlay.Add_Click({
  $want = (-not $ui.playing)
  $ui.optPlaying = $want
  $ui.optUntil = (Now-Ms) + 1500
  Set-PlayState $want
  $sync.Cmd = $(if ($want) { 'play' } else { 'pause' })
})
$E.btnPrev.Add_Click({ Nudge-Icon $E.icoPrev -7.0; $sync.Cmd = 'prev' })
$E.btnNext.Add_Click({ Nudge-Icon $E.icoNext 7.0; $sync.Cmd = 'next' })
# track position: press / drag shows the target time, release seeks
Add-Slider 'prog' {
  param($f)
  if ($ui.len -gt 0) {
    $tg = $f * $ui.len
    $E.mPos.Text = Format-Time $tg
    $E.mRem.Text = '-' + (Format-Time ($ui.len - $tg))
  }
} {
  param($f)
  if ($ui.len -gt 0) {
    $tg = $f * $ui.len
    $sync.Seek = [double]$tg
    $now = Now-Ms
    $ui.seekPos = $tg; $ui.seekAt = $now; $ui.seekHold = $now + 1400; $ui.lastPos = $tg
  }
} {
  param($f)
  if ($ui.len -gt 0) { Format-Time ($f * $ui.len) } else { '' }
} $true 0.0

# volume (REAL Windows master volume via Core Audio): press / drag / mouse wheel, on the Music AND the Sound tab
function Set-MasterVol([double]$f) {
  $r = [DI.Vol]::Set([float]$f)
  if ($r -ne 0) {
    if (-not $ui.volErrLogged) { $ui.volErrLogged = $true; Log ('volume set failed: ' + [DI.Vol]::LastError) }
  } elseif (-not $ui.volOkLogged) { $ui.volOkLogged = $true; Log 'volume set ok' }
  if (($f -gt 0.0) -and $ui.lastMute) { [void][DI.Vol]::SetMute($false); $ui.lastMute = $false }
  $ui.lastVol = $f
  $txt = "$([int][Math]::Round($f * 100.0))%"
  $E.volPct.Text = $txt; $E.mvolPct.Text = $txt
  foreach ($sid in 'vol', 'mvol') { if (-not $SL[$sid].drag) { Slider-Set $sid $f $false } }
}
foreach ($vid in 'vol', 'mvol') {
  Add-Slider $vid {
    param($f, $sid)
    Set-MasterVol $f
  } { param($f, $sid) } {
    param($f)
    "$([int][Math]::Round($f * 100.0))%"
  } $false 0.03
}

# glass transparency (Вид)
Add-Slider 'al' {
  param($f)
  $cfg.glassAlpha = [int][Math]::Round($f * 100.0)
  Set-PillTint 90 $false
} { param($f) Request-Save } {
  param($f)
  "$([int][Math]::Round($f * 100.0))%"
} $false 0.05
Slider-Set 'al' ([double]$cfg.glassAlpha / 100.0) $false
foreach ($mb in @($E.btnMute, $E.btnMute2)) { $mb.Add_Click({ [void][DI.Vol]::SetMute(-not $ui.lastMute) }) }

# tabs
foreach ($id in @($TABS.Values)) {
  $E[$id].Add_Click([System.Windows.RoutedEventHandler]{
    param($snd, $ev)
    Set-Tab $snd.Name.Substring(2).ToLower()
  })
}
$E.btnX.Add_Click({ Collapse })

# timer + pomodoro
foreach ($id in 't1', 't5', 't10', 't25', 't45') {
  $E[$id].Add_Click({
    param($snd, $ev)
    $secs = switch ($snd.Name) { 't1' { 60 } 't5' { 300 } 't10' { 600 } 't25' { 1500 } 't45' { 2700 } default { 300 } }
    Start-Timer $secs $false
  })
}
$E.btnPomo.Add_Click({ Start-Pomo })
$E.btnPause.Add_Click({
  $ui.timerPaused = -not $ui.timerPaused
  $E.btnPause.Content = if ($ui.timerPaused) { 'Дальше' } else { 'Пауза' }
})
$E.btnStop.Add_Click({
  $ui.timerLeft = 0; $ui.timerPaused = $false; $ui.pomo = $false; $ui.pomoArmed = $false
  Collapse; Update-Mode
})

# settings
$E.swAuto.Add_Click({ Set-Autostart ([bool]$E.swAuto.IsChecked) })
$E.swEq.Add_Click({
  $cfg.eq = [bool]$E.swEq.IsChecked
  if ($cfg.eq) { $E.wavePanel.Visibility = 'Visible'; if ($ui.mode -eq 'music') { WaveStart; $ui.waveStarted = $true; $ui.wavePaused = $false } }
  else { $E.wavePanel.Visibility = 'Collapsed'; WaveStop; $ui.waveStarted = $false; $ui.wavePaused = $false }
  Request-Save
})
$E.swCharge.Add_Click({ $cfg.charge = [bool]$E.swCharge.IsChecked; Request-Save })
$E.swFull.Add_Click({ $cfg.hideFull = [bool]$E.swFull.IsChecked; Request-Save })
$E.swClock.Add_Click({ $cfg.hoverClock = [bool]$E.swClock.IsChecked; Request-Save })
$E.swGlass.Add_Click({ $cfg.glass = [bool]$E.swGlass.IsChecked; Update-Glass; Request-Save })
$E.btnQuit.Add_Click({ Quit-App })

# ============================================================
#  Pointer: hover, press
# ============================================================
$E.Island.Add_MouseEnter({
  if ($ui.expanded) { return }
  $ui.hover = $true
  Retarget 0.30 0.80
  if ($ui.mode -eq 'idle' -and $cfg.hoverClock -and ([string]$cfg.pillIdle -eq 'hover')) {
    $E.cIdleTxt.Text = (Get-Date).ToString('HH:mm')
    FadeTo $E.cIdleTxt 1.0 220
  }
})
$E.Island.Add_MouseLeave({
  $ui.hover = $false; $ui.pressed = $false
  if ([string]$cfg.pillIdle -eq 'hover') { FadeTo $E.cIdleTxt 0.0 150 }
  if (-not $ui.expanded) { Retarget 0.34 0.86 }
})
$E.Island.Add_MouseLeftButtonDown({ if (-not $ui.expanded) { $ui.pressed = $true; Retarget 0.20 0.85 } })
$E.Island.Add_MouseLeftButtonUp({ if ((-not $ui.expanded) -and $ui.pressed) { $ui.pressed = $false; Expand } })

# ============================================================
#  Timers: 1 s clock, 80 ms outside-click, 250 ms poll, 1.5 s keep-on-top
# ============================================================
$timerDt = New-Object System.Windows.Threading.DispatcherTimer
$timerDt.Interval = [TimeSpan]::FromSeconds(1)
$timerDt.Add_Tick({
  if ($ui.timerLeft -gt 0 -and -not $ui.timerPaused) {
    $ui.timerLeft--
    Update-TimerText
    if ($ui.timerLeft -le 0) {
      $E.cDoneTxt.Text = (Timer-Finished)
      $ui.doneUntil = (Now-Ms) + 2800
      try { [System.Media.SystemSounds]::Asterisk.Play() } catch {}
      if ($ui.expanded) { Collapse }
      Update-Mode
    }
  }
  try { Check-Reminders } catch { Log "reminders: $($_.Exception.Message)" }
})

$fast = New-Object System.Windows.Threading.DispatcherTimer
$fast.Interval = [TimeSpan]::FromMilliseconds(80)
$fast.Add_Tick({
  $down = [DI.Native]::LeftDown()
  if ($down -and (-not $ui.lastLeft) -and $ui.expanded) {
    $sc = $ui.scale
    $x0 = $ui.winX + (($WIN_W - $sp.w) / 2.0) * $sc
    $y0 = $ui.winY + $TOP * $sc
    $x1 = $x0 + $sp.w * $sc; $y1 = $y0 + $sp.h * $sc
    $cx = [DI.Native]::CursorX(); $cy = [DI.Native]::CursorY()
    if ($cx -lt $x0 -or $cx -gt $x1 -or $cy -lt $y0 -or $cy -gt $y1) { Collapse }
  }
  $ui.lastLeft = $down
})

$keep = New-Object System.Windows.Threading.DispatcherTimer
$keep.Interval = [TimeSpan]::FromMilliseconds(1500)
$keep.Add_Tick({
  if (-not $ui.hidden) {
    try { [DI.Native]::KeepTopmost($mainHwnd, [IntPtr]::Zero) } catch {}
  }
  try {
    $wa2 = [System.Windows.SystemParameters]::WorkArea
    $key = "$($wa2.Left),$($wa2.Top),$($wa2.Width),$($wa2.Height),$([System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width)"
    if ($key -ne $ui.screenKey) { Log "display changed -> $key"; Reposition }
  } catch {}
})

# ============================================================
#  Keyboard input (the island window never takes focus, except while a text box is in use)
# ============================================================
$script:kbdTarget = $null
$kbdTimer = New-Object System.Windows.Threading.DispatcherTimer
$kbdTimer.Interval = [TimeSpan]::FromMilliseconds(70)
$kbdTimer.Add_Tick({
  $kbdTimer.Stop()
  try {
    $t = $script:kbdTarget
    if ($t) { [void]$t.Focus(); [void][System.Windows.Input.Keyboard]::Focus($t) }
  } catch {}
})
function Begin-Kbd($tb) {
  if (-not $ui.kbd) {
    $ui.kbd = $true
    try { $ui.prevFg = [DI.Native]::Foreground() } catch { $ui.prevFg = [IntPtr]::Zero }
    [DI.Native]::SetNoActivate($mainHwnd, $false)
    try { [void]$window.Activate() } catch {}
  }
  $script:kbdTarget = $tb
  $kbdTimer.Stop(); $kbdTimer.Start()
}
function End-Kbd {
  if (-not $ui.kbd) { return }
  $ui.kbd = $false
  $kbdTimer.Stop()
  try { [System.Windows.Input.Keyboard]::ClearFocus() } catch {}
  $wasMine = ([DI.Native]::Foreground() -eq $mainHwnd)
  [DI.Native]::SetNoActivate($mainHwnd, $true)
  # give the keyboard back to the previous window, but only if the user did not click into another one meanwhile
  if ($wasMine) { [DI.Native]::Foreground($ui.prevFg) }
  $ui.prevFg = [IntPtr]::Zero
}

# ============================================================
#  Sites: quick links
# ============================================================
$SITE_MAX = 14
$SITE_COLORS = @('#FF453A', '#FF9F0A', '#30D158', '#5AC8FA', '#0A84FF', '#BF5AF2', '#FF375F', '#AC8E68')
$script:favMap = @{}
$script:plateLight = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(244, 244, 246)); $script:plateLight.Freeze()
$script:siteCloseTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:siteCloseTimer.Interval = [TimeSpan]::FromMilliseconds(170)
$script:siteCloseTimer.Add_Tick({
  $script:siteCloseTimer.Stop()
  if (-not $ui.siteAddOpen) { $E.siteAdd.Visibility = 'Collapsed' }
})
$ui.siteAddOpen = $false

function Normalize-Url([string]$raw) {
  $t = ([string]$raw).Trim()
  if (-not $t) { return $null }
  if ($t -notmatch '^[a-zA-Z][a-zA-Z0-9+.\-]*://') { $t = 'https://' + $t }
  $u = $null
  if (-not [Uri]::TryCreate($t, [UriKind]::Absolute, [ref]$u)) { return $null }
  if ($u.Scheme -ne 'http' -and $u.Scheme -ne 'https') { return $null }
  if ((-not $u.Host) -or (($u.Host -notmatch '\.') -and ($u.Host -ne 'localhost'))) { return $null }
  return $u.AbsoluteUri
}
function Site-Name([string]$url, [string]$typed) {
  $n = ([string]$typed).Trim()
  if ($n) { return $n.Substring(0, [Math]::Min(24, $n.Length)) }
  $h = ([Uri]$url).Host -replace '^www\.', ''
  $lab = $h.Split('.')[0]
  if ($lab.Length -gt 0) { return $lab.Substring(0, 1).ToUpper() + $lab.Substring(1) }
  return $h
}

function Show-Favicon($bi) {
  $t = $script:favMap[$bi]
  if (-not $t) { return }
  $script:favMap.Remove($bi)
  try {
    if ($bi.PixelWidth -lt 2) { return }
    $t.img.Source = $bi
    $t.letter.Visibility = 'Collapsed'
    $t.plate.Background = $script:plateLight
    FadeTo $t.img 1.0 240
  } catch {}
}
function Load-Favicon($t, [string]$url) {
  if (-not $cfg.favicons) { return }
  try {
    $h = ([Uri]$url).Host
    $bi = New-Object System.Windows.Media.Imaging.BitmapImage
    $bi.BeginInit()
    $bi.UriSource = [Uri]("https://www.google.com/s2/favicons?domain=$h&sz=64")
    $bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bi.EndInit()
    $script:favMap[$bi] = $t
    if ($bi.IsDownloading) {
      $bi.add_DownloadCompleted({ param($snd, $ev) Show-Favicon $snd })
      $bi.add_DownloadFailed({ param($snd, $ev) $script:favMap.Remove($snd) })
    } else { Show-Favicon $bi }
  } catch { Log "favicon: $($_.Exception.Message)" }
}

function New-SiteTile($site, [bool]$isAdd) {
  $wrap = New-Object System.Windows.Controls.Grid
  $wrap.Width = 108.0; $wrap.Height = 88.0
  $wrap.Margin = [System.Windows.Thickness]::new(0, 0, 8, 8)
  $wrap.RenderTransformOrigin = [System.Windows.Point]::new(0.5, 0.5)
  $wrap.RenderTransform = New-Object System.Windows.Media.ScaleTransform (1.0, 1.0)

  $btn = New-Object System.Windows.Controls.Button
  $btn.Style = $E.sitesHost.FindResource('SiteTile')
  $stack = New-Object System.Windows.Controls.StackPanel
  $stack.HorizontalAlignment = 'Center'; $stack.VerticalAlignment = 'Center'
  $ico = New-Object System.Windows.Controls.Grid
  $ico.Width = 38.0; $ico.Height = 38.0
  $plate = New-Object System.Windows.Controls.Border
  $plate.CornerRadius = [System.Windows.CornerRadius]::new(11)
  $nm = New-Object System.Windows.Controls.TextBlock
  $nm.FontSize = 11.5; $nm.FontWeight = 'SemiBold'; $nm.MaxWidth = 94.0
  $nm.TextTrimming = 'CharacterEllipsis'; $nm.HorizontalAlignment = 'Center'
  $nm.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)

  if ($isAdd) {
    $plate.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(0x30, 255, 255, 255))
    $pl = New-Object System.Windows.Shapes.Path
    $pl.Data = [System.Windows.Media.Geometry]::Parse('M0 6 H12 M6 0 V12')
    $pl.Stroke = [System.Windows.Media.Brushes]::White; $pl.StrokeThickness = 2.0
    $pl.StrokeStartLineCap = 'Round'; $pl.StrokeEndLineCap = 'Round'
    $pl.Width = 14.0; $pl.Height = 14.0; $pl.Stretch = 'Uniform'
    $pl.HorizontalAlignment = 'Center'; $pl.VerticalAlignment = 'Center'
    $plate.Child = $pl
    $nm.Text = 'Добавить'
    $nm.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(0xB4, 255, 255, 255))
    $btn.Tag = 'add'
    $btn.Add_Click({ param($snd, $ev) if (-not $ui.sitesEdit) { Open-SiteAdd } })
    $img = $null; $lt = $null
  } else {
    $url = [string]$site.u
    $name = [string]$site.n
    if (-not $name) { $name = Site-Name $url '' }
    $sum = 0
    foreach ($ch in ([Uri]$url).Host.ToCharArray()) { $sum += [int]$ch }
    $colHex = $SITE_COLORS[$sum % $SITE_COLORS.Count]
    $plate.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($colHex))
    $lt = New-Object System.Windows.Controls.TextBlock
    $lt.Text = $name.Substring(0, 1).ToUpper()
    $lt.Foreground = [System.Windows.Media.Brushes]::White
    $lt.FontSize = 18.0; $lt.FontWeight = 'SemiBold'
    $lt.HorizontalAlignment = 'Center'; $lt.VerticalAlignment = 'Center'
    $plate.Child = $lt
    $img = New-Object System.Windows.Controls.Image
    $img.Width = 26.0; $img.Height = 26.0; $img.Opacity = 0.0
    $img.HorizontalAlignment = 'Center'; $img.VerticalAlignment = 'Center'
    [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($img, [System.Windows.Media.BitmapScalingMode]::HighQuality)
    $nm.Text = $name
    $nm.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(0xEE, 255, 255, 255))
    $btn.Tag = $url
    $btn.Add_Click({ param($snd, $ev) Open-Site ([string]$snd.Tag) })
  }
  [void]$ico.Children.Add($plate)
  if ($img) { [void]$ico.Children.Add($img) }
  [void]$stack.Children.Add($ico)
  [void]$stack.Children.Add($nm)
  $btn.Content = $stack
  [void]$wrap.Children.Add($btn)

  if (-not $isAdd) {
    # the round "−" badge that appears in edit mode
    $del = New-Object System.Windows.Controls.Button
    $del.Style = $E.sitesHost.FindResource('IcoBtn')
    $del.Width = 22.0; $del.Height = 22.0
    $del.Background = $script:brRed
    $del.HorizontalAlignment = 'Left'; $del.VerticalAlignment = 'Top'
    $del.Margin = [System.Windows.Thickness]::new(3, 3, 0, 0)
    $del.Opacity = 0.0; $del.IsHitTestVisible = $false
    $del.RenderTransformOrigin = [System.Windows.Point]::new(0.5, 0.5)
    $del.RenderTransform = New-Object System.Windows.Media.ScaleTransform (0.3, 0.3)
    $mp = New-Object System.Windows.Shapes.Path
    $mp.Data = [System.Windows.Media.Geometry]::Parse('M0 0 H9')
    $mp.Stroke = [System.Windows.Media.Brushes]::White; $mp.StrokeThickness = 2.2
    $mp.StrokeStartLineCap = 'Round'; $mp.StrokeEndLineCap = 'Round'
    $mp.Width = 9.0; $mp.Stretch = 'Uniform'
    $del.Content = $mp
    $del.Tag = [string]$site.u
    $del.Add_Click({ param($snd, $ev) Remove-Site ([string]$snd.Tag) })
    [void]$wrap.Children.Add($del)
    Load-Favicon @{ img = $img; plate = $plate; letter = $lt } $url
  }
  return $wrap
}

function Show-Badge($del, [bool]$on, [bool]$animate) {
  $del.IsHitTestVisible = $on
  $op = $(if ($on) { 1.0 } else { 0.0 })
  $sc = $(if ($on) { 1.0 } else { 0.3 })
  if ($animate) {
    Anim-To $del ([System.Windows.UIElement]::OpacityProperty) $op 180
    Anim-To $del.RenderTransform ([System.Windows.Media.ScaleTransform]::ScaleXProperty) $sc 260 $(if ($on) { $script:easeBack } else { $null })
    Anim-To $del.RenderTransform ([System.Windows.Media.ScaleTransform]::ScaleYProperty) $sc 260 $(if ($on) { $script:easeBack } else { $null })
  } else {
    Set-Op $del $op
    $del.RenderTransform.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $null)
    $del.RenderTransform.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $null)
    $del.RenderTransform.ScaleX = $sc; $del.RenderTransform.ScaleY = $sc
  }
}

function Build-Sites([bool]$animate = $true) {
  $sh = $E.sitesHost
  $sh.Children.Clear()
  $script:favMap.Clear()
  $i = 0
  foreach ($site in @($cfg.sites)) {
    $w = New-SiteTile $site $false
    if ($ui.sitesEdit -and $w.Children.Count -ge 2) { Show-Badge $w.Children[1] $true $false }
    [void]$sh.Children.Add($w)
    if ($animate -and (-not $ui.reduceMotion)) {
      $w.Opacity = 0.0
      $d = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(300))
      $a = New-Object System.Windows.Media.Animation.DoubleAnimation
      $a.From = 0.0; $a.To = 1.0; $a.Duration = $d; $a.BeginTime = [TimeSpan]::FromMilliseconds(40 * $i)
      $w.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $a)
      foreach ($axis in @([System.Windows.Media.ScaleTransform]::ScaleXProperty, [System.Windows.Media.ScaleTransform]::ScaleYProperty)) {
        $b = New-Object System.Windows.Media.Animation.DoubleAnimation
        $b.From = 0.86; $b.To = 1.0; $b.Duration = $d; $b.BeginTime = [TimeSpan]::FromMilliseconds(40 * $i)
        $b.EasingFunction = $script:easeBack
        $w.RenderTransform.BeginAnimation($axis, $b)
      }
    }
    $i++
  }
  if ($i -lt $SITE_MAX) {
    $w = New-SiteTile $null $true
    [void]$sh.Children.Add($w)
    if ($animate -and (-not $ui.reduceMotion)) {
      $w.Opacity = 0.0
      $a = New-Object System.Windows.Media.Animation.DoubleAnimation
      $a.From = 0.0; $a.To = 1.0
      $a.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(300))
      $a.BeginTime = [TimeSpan]::FromMilliseconds(40 * $i)
      $w.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $a)
    }
  }
}

function Set-SitesEdit([bool]$on) {
  if ($ui.sitesEdit -eq $on) { return }
  $ui.sitesEdit = $on
  $E.btnSitesEdit.Content = $(if ($on) { 'Готово' } else { 'Изменить' })
  $E.sitesLabel.Text = $(if ($on) { 'НАЖМИ НА «−», ЧТОБЫ УДАЛИТЬ' } else { 'БЫСТРЫЕ САЙТЫ · КЛИК — ОТКРЫТЬ' })
  foreach ($w in $E.sitesHost.Children) {
    if ($w.Children.Count -ge 2) { Show-Badge $w.Children[1] $on $true }
  }
}

function Open-Site([string]$url) {
  if ($ui.sitesEdit) { return }
  if ($url -notmatch '^https?://') { return }
  try { [void][System.Diagnostics.Process]::Start($url) }
  catch { Log "open site: $($_.Exception.Message)"; return }
  Collapse
}

function Remove-Site([string]$url) {
  $cfg.sites = @($cfg.sites | Where-Object { $_.u -ne $url })
  Request-Save
  Build-Sites $false
}

function Open-SiteAdd {
  if ($ui.siteAddOpen) { return }
  $ui.siteAddOpen = $true
  $script:siteCloseTimer.Stop()
  $E.siteUrl.Text = ''; $E.siteName.Text = ''
  $E.siteErr.Visibility = 'Collapsed'
  $E.siteAdd.Visibility = 'Visible'
  Set-Op $E.siteAdd 0.0
  FadeTo $E.siteAdd 1.0 200
  $cs = $E.siteCard.RenderTransform.Children[0]
  $cs.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $null); $cs.ScaleX = 0.94
  $cs.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $null); $cs.ScaleY = 0.94
  Anim-To $cs ([System.Windows.Media.ScaleTransform]::ScaleXProperty) 1.0 320 $script:easeBack
  Anim-To $cs ([System.Windows.Media.ScaleTransform]::ScaleYProperty) 1.0 320 $script:easeBack
  Begin-Kbd $E.siteUrl
}
function Close-SiteAdd([bool]$instant = $false) {
  if (-not $ui.siteAddOpen) { return }
  $ui.siteAddOpen = $false
  End-Kbd
  if ($instant) { Set-Op $E.siteAdd 0.0; $E.siteAdd.Visibility = 'Collapsed' }
  else { FadeTo $E.siteAdd 0.0 150; $script:siteCloseTimer.Stop(); $script:siteCloseTimer.Start() }
}
function Site-Error([string]$msg) {
  $E.siteErr.Text = $msg
  $E.siteErr.Visibility = 'Visible'
  # small shake of the card
  try {
    $tt = $E.siteCard.RenderTransform.Children[1]
    $ka = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
    foreach ($kv in @(@(0, 0), @(60, -7), @(130, 6), @(200, -4), @(270, 2), @(340, 0))) {
      $kt = [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds([double]$kv[0]))
      $kf = New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame ([double]$kv[1], $kt)
      [void]$ka.KeyFrames.Add($kf)
    }
    $tt.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $ka)
  } catch {}
}
function Commit-Site {
  $url = Normalize-Url $E.siteUrl.Text
  if (-not $url) { Site-Error 'Не похоже на адрес сайта. Пример: youtube.com'; return }
  if (@($cfg.sites).Count -ge $SITE_MAX) { Site-Error "Можно добавить не больше $SITE_MAX сайтов"; return }
  foreach ($x in @($cfg.sites)) { if ($x.u -eq $url) { Site-Error 'Этот сайт уже есть в списке'; return } }
  $entry = @{ n = (Site-Name $url $E.siteName.Text); u = $url }
  $cfg.sites = @($cfg.sites) + (, $entry)
  Request-Save
  Close-SiteAdd
  Build-Sites $false
}

$E.btnSitesEdit.Add_Click({ Set-SitesEdit (-not $ui.sitesEdit) })
$E.btnSiteOk.Add_Click({ Commit-Site })
$E.btnSiteCancel.Add_Click({ Close-SiteAdd })
$E.btnSitePaste.Add_Click({
  $t = ''
  try { $t = [System.Windows.Clipboard]::GetText() } catch {}
  if ($t) {
    $t = ($t -split '\s+')[0]
    $E.siteUrl.Text = $t
    $E.siteUrl.CaretIndex = $E.siteUrl.Text.Length
    $E.siteErr.Visibility = 'Collapsed'
  } else { Site-Error 'В буфере обмена нет текста' }
})
$E.siteUrl.Add_TextChanged({ $E.siteUrlHint.Visibility = $(if ($E.siteUrl.Text) { 'Collapsed' } else { 'Visible' }) })
$E.siteName.Add_TextChanged({ $E.siteNameHint.Visibility = $(if ($E.siteName.Text) { 'Collapsed' } else { 'Visible' }) })
foreach ($tbx in @($E.siteUrl, $E.siteName)) {
  $tbx.Add_KeyDown({
    param($snd, $ev)
    if ($ev.Key -eq [System.Windows.Input.Key]::Return) { Commit-Site; $ev.Handled = $true }
    elseif ($ev.Key -eq [System.Windows.Input.Key]::Escape) { Close-SiteAdd; $ev.Handled = $true }
  })
}
$E.siteAdd.Add_MouseLeftButtonDown({
  param($snd, $ev)
  if ([object]::ReferenceEquals($ev.OriginalSource, $snd)) { Close-SiteAdd }
})

# ============================================================
#  System load: CPU / GPU / RAM / network cards with a scrolling graph (samples come from src\Sys.ps1)
# ============================================================
$SYS_N = 61
$PLOT_W = 264.0; $PLOT_H = 104.0
function New-Br([string]$hex) {
  $b = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($hex))
  $b.Freeze()
  return $b
}
$script:SYS_COL = @{
  cpu = @{ line = (New-Br '#0A84FF'); area = (New-Br '#2E0A84FF') }
  gpu = @{ line = (New-Br '#30D158'); area = (New-Br '#2E30D158') }
  ram = @{ line = (New-Br '#BF5AF2'); area = (New-Br '#2EBF5AF2') }
}
$script:SYS_HOT = @{ line = (New-Br '#FF453A'); area = (New-Br '#33FF453A') }
$script:brTmpHot = New-Br '#FF6A5F'; $script:brTmpWarm = New-Br '#FFB340'; $script:brTmpOk = New-Br '#F2FFFFFF'
$ui.hist = @{}
$ui.sysHot = @{ cpu = $false; gpu = $false; ram = $false }
$ruRu = [Globalization.CultureInfo]::GetCultureInfo('ru-RU')
function Fmt1([double]$v) { return $v.ToString('0.0', $ruRu) }
function Fmt-Speed([double]$b) {
  if ($b -ge 1048576.0) { return ((Fmt1 ($b / 1048576.0)) + ' МБ/с') }
  if ($b -ge 1024.0) { return (([int][Math]::Round($b / 1024.0)).ToString() + ' КБ/с') }
  return (([int][Math]::Round($b)).ToString() + ' Б/с')
}

function Draw-Spark([string]$k) {
  $L = $ui.hist[$k]
  $n = $L.Count
  $step = $PLOT_W / ($n - 1)
  $pc = New-Object System.Windows.Media.PointCollection
  $pg = New-Object System.Windows.Media.PointCollection
  for ($i = 0; $i -lt $n; $i++) {
    $y = ($PLOT_H - 3.0) - ([double]$L[$i] / 100.0) * ($PLOT_H - 8.0)
    $pt = [System.Windows.Point]::new([double]($i * $step), [double]$y)
    $pc.Add($pt); $pg.Add($pt)
  }
  $pg.Add([System.Windows.Point]::new($PLOT_W, $PLOT_H))
  $pg.Add([System.Windows.Point]::new(0.0, $PLOT_H))
  $E["${k}Line"].Points = $pc
  $E["${k}Area"].Points = $pg
}
# network: two raw series (down / up) scaled to the busiest value seen in the window (at least 256 KB/s)
function Draw-Net {
  $D = $ui.netD; $U = $ui.netU
  $n = $D.Count
  $mx = 262144.0
  foreach ($v in $D) { if ($v -gt $mx) { $mx = $v } }
  foreach ($v in $U) { if ($v -gt $mx) { $mx = $v } }
  $step = $PLOT_W / ($n - 1)
  $pd = New-Object System.Windows.Media.PointCollection
  $pa = New-Object System.Windows.Media.PointCollection
  $pu = New-Object System.Windows.Media.PointCollection
  for ($i = 0; $i -lt $n; $i++) {
    $x = [double]($i * $step)
    $yd = ($PLOT_H - 3.0) - ([double]$D[$i] / $mx) * ($PLOT_H - 8.0)
    $yu = ($PLOT_H - 3.0) - ([double]$U[$i] / $mx) * ($PLOT_H - 8.0)
    $pd.Add([System.Windows.Point]::new($x, [double]$yd)); $pa.Add([System.Windows.Point]::new($x, [double]$yd))
    $pu.Add([System.Windows.Point]::new($x, [double]$yu))
  }
  $pa.Add([System.Windows.Point]::new($PLOT_W, $PLOT_H)); $pa.Add([System.Windows.Point]::new(0.0, $PLOT_H))
  $E.netLine.Points = $pd; $E.netArea.Points = $pa; $E.netLine2.Points = $pu
}
function Set-SysHot([string]$k, [bool]$hot) {
  if ($ui.sysHot[$k] -eq $hot) { return }
  $ui.sysHot[$k] = $hot
  $c = $script:SYS_COL[$k]
  $E["${k}Line"].Stroke = $(if ($hot) { $script:SYS_HOT.line } else { $c.line })
  $E["${k}Area"].Fill = $(if ($hot) { $script:SYS_HOT.area } else { $c.area })
  $E["${k}Dot"].Fill = $(if ($hot) { $script:SYS_HOT.line } else { $c.line })
}
function Reset-SysUi {
  $sync.Sys = $null
  $ui.sysRef = $null
  foreach ($k in 'cpu', 'gpu', 'ram') {
    $L = New-Object 'System.Collections.Generic.List[double]'
    for ($i = 0; $i -lt $SYS_N; $i++) { $L.Add(0.0) }
    $ui.hist[$k] = $L
    Draw-Spark $k
    $E["${k}Val"].Text = '—'
    $E["${k}Sub"].Text = ''
    $E["${k}Tmp"].Text = ''
    Set-SysHot $k $false
  }
  $ui.netD = New-Object 'System.Collections.Generic.List[double]'
  $ui.netU = New-Object 'System.Collections.Generic.List[double]'
  for ($i = 0; $i -lt $SYS_N; $i++) { $ui.netD.Add(0.0); $ui.netU.Add(0.0) }
  Draw-Net
  $E.netVal.Text = '—'; $E.netSub.Text = ''; $E.netTmp.Text = ''
  $E.netTmp.Foreground = $script:brOrange
}
function Scroll-Plot([string]$k) {
  if ($ui.reduceMotion) { return }
  $a = New-Object System.Windows.Media.Animation.DoubleAnimation
  $a.From = $PLOT_W / ($SYS_N - 1); $a.To = 0.0
  $a.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(1000))
  $E["${k}Plot"].RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $a)
}
function Push-Sys([string]$k, [double]$v, [string]$valText, [string]$sub) {
  $L = $ui.hist[$k]
  if ((-not $L) -or $L.Count -lt 2) { return }
  $L.RemoveAt(0)
  $L.Add([Math]::Max(0.0, [Math]::Min(100.0, $v)))
  Draw-Spark $k
  Scroll-Plot $k
  $E["${k}Val"].Text = $valText
  $E["${k}Sub"].Text = $sub
  Set-SysHot $k ($v -ge 90.0)
}
function Set-Temp([string]$k, [double]$c) {
  $tb = $E["${k}Tmp"]
  if ($c -lt 0) { $tb.Text = ''; return }
  $tb.Text = ("{0} °C" -f [int][Math]::Round($c))
  $tb.Foreground = $(if ($c -ge 85) { $script:brTmpHot } elseif ($c -ge 70) { $script:brTmpWarm } else { $script:brTmpOk })
}
function Update-SysUi {
  $sys = $sync.Sys
  if (-not $sys) { return }
  if ([object]::ReferenceEquals($sys, $ui.sysRef)) { return }
  $ui.sysRef = $sys
  # CPU
  $c = [double]$sys.cpu
  $cpuSub = ''
  if ($sys.cpuName) { $cpuSub = "$($sys.cpuName) · $($sys.threads) потоков" } else { $cpuSub = "$($sys.threads) потоков" }
  if ($c -ge 0) { Push-Sys 'cpu' $c ("{0}%" -f [int][Math]::Round($c)) $cpuSub }
  Set-Temp 'cpu' ([double]$sys.cpuTemp)
  # GPU
  $g = [double]$sys.gpu
  if ($g -ge 0) {
    $gsub = [string]$sys.gpuName
    if ([double]$sys.vram -ge 0) {
      $v = "VRAM " + (Fmt1 ([double]$sys.vram))
      if ([double]$sys.vramTotal -gt 0.1) { $v += " / " + (Fmt1 ([double]$sys.vramTotal)) }
      $v += " ГБ"
      $gsub = $(if ($gsub) { "$gsub · $v" } else { $v })
    }
    Push-Sys 'gpu' $g ("{0}%" -f [int][Math]::Round($g)) $gsub
  } else {
    Push-Sys 'gpu' 0.0 '—' $(if ($sys.gpuName) { "$($sys.gpuName) · нет данных о нагрузке" } else { 'Нет данных о нагрузке видеокарты' })
  }
  Set-Temp 'gpu' ([double]$sys.gpuTemp)
  # RAM
  $r = [double]$sys.ram
  if ($r -ge 0) {
    Push-Sys 'ram' $r ("{0}%" -f [int][Math]::Round($r)) ("Занято " + (Fmt1 ([double]$sys.ramUsed)) + " из " + (Fmt1 ([double]$sys.ramTotal)) + " ГБ")
  }
  # network
  $nd = [double]$sys.netDown; $nu = [double]$sys.netUp
  if ($nd -ge 0 -and $ui.netD) {
    $ui.netD.RemoveAt(0); $ui.netD.Add($nd)
    $ui.netU.RemoveAt(0); $ui.netU.Add([Math]::Max(0.0, $nu))
    Draw-Net
    Scroll-Plot 'net'
    $E.netVal.Text = '↓ ' + (Fmt-Speed $nd)
    $E.netTmp.Text = '↑ ' + (Fmt-Speed $nu)
    $E.netSub.Text = 'Загрузка · отдача'
  }
}
try {

# ============================================================
#  Small UI helpers shared by the new tabs
# ============================================================
function Utc-Ms { return [long]([DateTime]::UtcNow.Ticks / 10000) }
function Up($el, [int]$n) {
  for ($i = 0; $i -lt $n; $i++) { if ($el) { $el = $el.Parent } }
  return $el
}
function New-Tb([string]$text, [double]$size, $fg, [string]$weight = 'Normal') {
  $tb = New-Object System.Windows.Controls.TextBlock
  $tb.Text = $text; $tb.FontSize = $size; $tb.Foreground = $fg
  $tb.FontWeight = [System.Windows.FontWeights]::$weight
  return $tb
}
$script:brWhite = New-Br '#FFFFFFFF'
$script:brSoft = New-Br '#A0FFFFFF'
$script:brDim = New-Br '#70FFFFFF'
function Set-Hint($tb, $hint) { if ($hint) { $hint.Visibility = $(if ($tb.Text) { 'Collapsed' } else { 'Visible' }) } }
# a text box on the glass: first click grabs the keyboard (the island window normally never takes focus)
function Hook-Kbd($tb) {
  $tb.Add_PreviewMouseLeftButtonDown({ param($snd, $ev) Begin-Kbd $snd })
  $hint = $E["$($tb.Name)Hint"]
  if ($hint) { $tb.Add_TextChanged({ param($snd, $ev) Set-Hint $snd $E["$($snd.Name)Hint"] }) }
}
function Wait-Spin($el) { }

# ============================================================
#  Lyrics (LRCLIB through the internet worker, synced line by line)
# ============================================================
$ui.lyr = @{ n = 0; synced = $false; times = $null; lines = @(); tops = @(); hs = @(); idx = -2; userUntil = 0.0; viewH = 380.0; textH = 0.0 }
$ui.lyrReq = ''
$ui.lyrRef = $null
$ui.lyrSeq = 0; $ui.lyrPend = ''; $ui.lyrPendAt = 0.0; $ui.lyrGapAt = 0.0; $ui.lyrErrAt = 0.0
$ui.lyrCache = @{}
$script:lyrT = $E.lyrHost.RenderTransform

function Lyr-Show([string]$msg) {
  $E.lyrMsg.Text = $msg
  FadeTo $E.lyrEmpty 1.0 240
  FadeTo $E.lyrHost 0.0 160
}
function Lyr-Clear {
  $E.lyrHost.Children.Clear()
  $L = $ui.lyr
  $L.lines = @(); $L.tops = @(); $L.hs = @(); $L.n = 0; $L.idx = -2; $L.synced = $false; $L.times = $null; $L.userUntil = 0.0
}
# show a finished lookup (fresh from the worker or from the cache)
function Lyr-Apply($res) {
  if ($res.state -eq 'ok') { Lyr-Build $res }
  elseif ($res.state -eq 'err') { $ui.lyrErrAt = Now-Ms; Lyr-Show 'Не удалось загрузить текст. Проверь интернет' }
  else { Lyr-Show 'Для этой песни текста не нашлось' }
}
# ask for the lyrics of the track that is playing now (only while the Music tab is open)
function Lyr-Sync {
  if (-not ($ui.expanded -and (-not $ui.closing) -and $ui.tab -eq 'music')) { return }
  $now = Now-Ms
  $st = $sync.State
  if ((-not $st) -or $st.mode -ne 'music' -or (-not $st.title)) {
    # a short gap (the player flaps between tracks) keeps the text on screen
    if ($ui.lyrGapAt -le 0.0) { $ui.lyrGapAt = $now }
    if ((($now - $ui.lyrGapAt) -gt 3000.0) -and $ui.lyrReq -ne '#none') { $ui.lyrReq = '#none'; Lyr-Clear; Lyr-Show 'Включи песню — текст появится здесь' }
    return
  }
  $ui.lyrGapAt = 0.0
  $key = (([string]$st.artist) + '|' + ([string]$st.title)).ToLower()
  if ($key -eq $ui.lyrReq) {
    # a failed lookup is tried again after a while
    if ($ui.lyrErrAt -gt 0.0 -and (($now - $ui.lyrErrAt) -gt 15000.0)) { $ui.lyrErrAt = 0.0 } else { return }
  } else {
    # a new track: wait a moment until the player has published the real length of the track (it makes the match exact)
    $cached = $ui.lyrCache.ContainsKey($key)
    if ($key -ne $ui.lyrPend) {
      $ui.lyrPend = $key; $ui.lyrPendAt = $now
      if (-not $cached) { Lyr-Clear; Lyr-Show 'Ищу текст…' }
    }
    if (-not $cached) {
      $waited = $now - $ui.lyrPendAt
      if ($waited -lt 700.0) { return }
      if (([double]$st.len -lt 1.0) -and $waited -lt 2000.0) { return }
    }
  }
  $ui.lyrReq = $key
  Lyr-Clear
  $cc = $ui.lyrCache[$key]
  if ($cc -and (($cc.res.state -eq 'ok') -or (($now - $cc.at) -lt 600000.0))) {
    $ui.lyrRef = $cc.res
    Lyr-Apply $cc.res
    return
  }
  Lyr-Show 'Ищу текст…'
  $ui.lyrSeq++
  $sync.LyrReq = @{ seq = $ui.lyrSeq; key = $key; title = [string]$st.title; artist = [string]$st.artist; dur = [double]$st.len }
}
function Lyr-Poll {
  $res = $sync.Lyr
  if (-not $res) { return }
  if ([object]::ReferenceEquals($res, $ui.lyrRef)) { return }
  if ([string]$res.key -ne $ui.lyrReq) { return }
  $ui.lyrRef = $res
  if ($res.state -ne 'err') {
    if ($ui.lyrCache.Count -gt 30) { $ui.lyrCache.Clear() }
    $ui.lyrCache[[string]$res.key] = @{ res = $res; at = (Now-Ms) }
  }
  Lyr-Apply $res
}
function Lyr-Build($res) {
  Lyr-Clear
  $L = $ui.lyr
  $lh = $E.lyrHost
  $synced = [bool]$res.synced
  $L.synced = $synced
  if ($synced) { $L.times = [double[]]$res.times }
  $lines = New-Object System.Collections.ArrayList
  foreach ($s in @($res.texts)) {
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = [string]$s
    $tb.TextWrapping = 'Wrap'
    $tb.Foreground = $script:brWhite
    if ($synced) {
      $tb.FontSize = 18.5; $tb.FontWeight = [System.Windows.FontWeights]::SemiBold
      $tb.Margin = [System.Windows.Thickness]::new(0, 0, 0, 16)
      $tb.Opacity = 0.24
      $tb.RenderTransformOrigin = [System.Windows.Point]::new(0.0, 0.5)
      $tb.RenderTransform = New-Object System.Windows.Media.ScaleTransform (0.9, 0.9)
    } else {
      $tb.FontSize = 14.5
      $tb.Margin = [System.Windows.Thickness]::new(0, 0, 0, $(if (([string]$s).Trim()) { 6 } else { 12 }))
      $tb.Opacity = 0.88
    }
    [void]$lh.Children.Add($tb)
    [void]$lines.Add($tb)
  }
  $L.lines = $lines.ToArray()
  $L.n = $lines.Count
  try { $lh.UpdateLayout() } catch {}
  $tops = New-Object 'System.Collections.Generic.List[double]'
  $hs = New-Object 'System.Collections.Generic.List[double]'
  $zero = New-Object System.Windows.Point (0.0, 0.0)
  foreach ($tb in $L.lines) {
    $tops.Add([double]$tb.TranslatePoint($zero, $lh).Y)
    $hs.Add([double]$tb.ActualHeight)
  }
  $L.tops = $tops.ToArray(); $L.hs = $hs.ToArray()
  $vh = [double]$E.lyrView.ActualHeight
  if ($vh -lt 60) { $vh = 380.0 }
  $L.viewH = $vh
  $L.textH = $(if ($L.n -gt 0) { $L.tops[$L.n - 1] + $L.hs[$L.n - 1] } else { 0.0 })
  $script:lyrT.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $null)
  $script:lyrT.Y = $(if ($synced) { $vh * 0.4 } else { 24.0 })
  Set-Op $E.lyrHost 0.0
  FadeTo $E.lyrHost 1.0 340
  FadeTo $E.lyrEmpty 0.0 200
  if ($synced) { Lyr-Tick }
}
function Lyr-Scroll([bool]$instant = $false) {
  $L = $ui.lyr
  if ($L.n -lt 1) { return }
  $ref = [Math]::Max(0, [Math]::Min($L.idx, $L.n - 1))
  $top = [double]$L.tops[$ref]; $hh = [double]$L.hs[$ref]
  # measured again now: the numbers taken when the text was built are wrong if the panel was not laid out yet
  try {
    $tbr = $L.lines[$ref]
    if ($tbr.ActualHeight -gt 1.0) {
      $top = [double]$tbr.TranslatePoint((New-Object System.Windows.Point (0.0, 0.0)), $E.lyrHost).Y
      $hh = [double]$tbr.ActualHeight
    }
  } catch {}
  $vh = [double]$E.lyrView.ActualHeight
  if ($vh -lt 60.0) { $vh = [double]$L.viewH }
  $ty = $vh * 0.4 - ($top + $hh / 2.0)
  $yp = [System.Windows.Media.TranslateTransform]::YProperty
  if ($instant -or $ui.reduceMotion) { $script:lyrT.BeginAnimation($yp, $null); $script:lyrT.Y = $ty }
  else { Anim-To $script:lyrT $yp $ty 620 }
}
function Lyr-Activate([int]$new) {
  $L = $ui.lyr
  $old = $L.idx
  $L.idx = $new
  $n = $L.n
  if ($old -eq -2) { $lo = 0; $hi = $n - 1 }
  else {
    $o = $(if ($old -lt 0) { $new } else { $old })
    $lo = [Math]::Max(0, [Math]::Min($o, $new) - 3)
    $hi = [Math]::Min($n - 1, [Math]::Max($o, $new) + 3)
  }
  $opP = [System.Windows.UIElement]::OpacityProperty
  $sxP = [System.Windows.Media.ScaleTransform]::ScaleXProperty
  $syP = [System.Windows.Media.ScaleTransform]::ScaleYProperty
  for ($i = $lo; $i -le $hi; $i++) {
    $d = $(if ($new -lt 0) { 9 } else { [Math]::Abs($i - $new) })
    $op = 0.24; if ($d -eq 0) { $op = 1.0 } elseif ($d -eq 1) { $op = 0.52 } elseif ($d -eq 2) { $op = 0.36 }
    $sc = $(if ($d -eq 0) { 1.0 } else { 0.9 })
    $tb = $L.lines[$i]
    if ($old -eq -2 -or $ui.reduceMotion) {
      $tb.BeginAnimation($opP, $null); $tb.Opacity = $op
      $tb.RenderTransform.BeginAnimation($sxP, $null); $tb.RenderTransform.BeginAnimation($syP, $null)
      $tb.RenderTransform.ScaleX = $sc; $tb.RenderTransform.ScaleY = $sc
    } else {
      Anim-To $tb $opP $op 320
      Anim-To $tb.RenderTransform $sxP $sc 360
      Anim-To $tb.RenderTransform $syP $sc 360
    }
  }
  if ((Now-Ms) -ge $L.userUntil) { Lyr-Scroll ($old -eq -2) }
}
function Lyr-Tick {
  $L = $ui.lyr
  if ((-not $L.synced) -or $L.n -lt 1 -or (-not $L.times)) { return }
  if (-not ($ui.expanded -and $ui.tab -eq 'music')) { return }
  $p = [double]$ui.lastPos + 0.3
  $r = [Array]::BinarySearch($L.times, $p)
  $idx = $(if ($r -ge 0) { $r } else { (-bnot $r) - 1 })
  if ($idx -ne $L.idx) { Lyr-Activate $idx }
  elseif ($L.userUntil -gt 0 -and (Now-Ms) -ge $L.userUntil) { $L.userUntil = 0.0; Lyr-Scroll }
}
# The Music tab appears: put the progress bar and the lyrics exactly where the song is NOW (no jump from the old state)
function Music-Resume {
  try {
    if ($ui.len -gt 0) {
      Slider-Set 'prog' ([double]$ui.lastPos / [double]$ui.len) $false
      $E.mPos.Text = Format-Time ([double]$ui.lastPos)
      $E.mRem.Text = '-' + (Format-Time ([double]$ui.len - [double]$ui.lastPos))
    }
  } catch {}
  try {
    $L = $ui.lyr
    if ($L.n -gt 0) {
      try { $E.lyrHost.UpdateLayout() } catch {}
      $L.userUntil = 0.0
      if ($L.synced -and $L.times) {
        $p = [double]$ui.lastPos + 0.3
        $r = [Array]::BinarySearch($L.times, $p)
        $idx = $(if ($r -ge 0) { $r } else { (-bnot $r) - 1 })
        $L.idx = -2
        Lyr-Activate $idx
      }
    }
  } catch { Log "music resume: $($_.Exception.Message)" }
}
$E.lyrView.Add_MouseWheel({
  param($snd, $ev)
  $L = $ui.lyr
  if ($L.n -lt 1) { return }
  $yp = [System.Windows.Media.TranslateTransform]::YProperty
  $cur = [double]$script:lyrT.Y
  $ny = $cur + ($ev.Delta / 120.0) * 52.0
  if (-not $L.synced) {
    # plain text: the limit is the REAL height of the text (measured now), so it can always be read to the very end
    $th = [Math]::Max([double]$L.textH, [double]$E.lyrHost.ActualHeight)
    $vh2 = [double]$E.lyrView.ActualHeight
    if ($vh2 -lt 60.0) { $vh2 = [double]$L.viewH }
    $minY = [Math]::Min(24.0, $vh2 - $th - 24.0)
    $ny = [Math]::Max($minY, [Math]::Min(24.0, $ny))
  }
  $script:lyrT.BeginAnimation($yp, $null)
  $script:lyrT.Y = $cur
  Anim-To $script:lyrT $yp $ny 200
  $L.userUntil = (Now-Ms) + 3500
  $ev.Handled = $true
})

# ============================================================
#  Weather: saved cities (chips), city search, hourly strip, details, 5 days
# ============================================================
$ui.wx = @{ ref = $null; seq = 0; qId = 0; cityRef = $null; searchOpen = $false; autoName = ''; sel = $null; dim = $false }

function Wx-Cur {
  $i = [int]$cfg.cityIdx
  $cs = @($cfg.cities)
  if ($i -ge 0 -and $i -lt $cs.Count) {
    $c = $cs[$i]
    return @{ key = ('c:' + ([string]$c.n).ToLower()); auto = $false; name = [string]$c.n; lat = $c.lat; lon = $c.lon; idx = $i }
  }
  return @{ key = 'auto'; auto = $true; name = ''; lat = $null; lon = $null; idx = -1 }
}
function Wx-Request($c) {
  $ui.wx.seq++
  $sync.WxReq = @{ seq = $ui.wx.seq; key = $c.key; auto = $c.auto; name = $c.name; lat = $c.lat; lon = $c.lon }
}
# the content rows fade while another city loads
function Wx-Dim([bool]$on) {
  if ($ui.wx.dim -eq $on) { return }
  $ui.wx.dim = $on
  foreach ($ch in $E.mWeather.Children) {
    $nm = [string]$ch.Name
    if ($nm -eq 'wxChips' -or $nm -eq 'wxStatus' -or $nm -eq 'wxSearch') { continue }
    FadeTo $ch $(if ($on) { 0.18 } else { 1.0 }) 260
  }
}
function Wx-Status([string]$text) {
  if ($text) {
    $E.wxStatus.Text = $text
    if ($E.wxStatus.Visibility -ne 'Visible') { Set-Op $E.wxStatus 0.0; $E.wxStatus.Visibility = 'Visible'; FadeTo $E.wxStatus 1.0 220 }
  } else { $E.wxStatus.Visibility = 'Collapsed' }
}

function New-Chip([string]$text, [bool]$sel) {
  $b = New-Object System.Windows.Controls.Button
  $b.Style = $E.wxChips.FindResource('PillBtn')
  $b.Content = $text
  $b.Margin = [System.Windows.Thickness]::new(0)
  $b.Padding = [System.Windows.Thickness]::new(14, 6, 14, 6)
  $b.Background = New-Object System.Windows.Media.SolidColorBrush ($(if ($sel) { [System.Windows.Media.Color]::FromRgb(242, 242, 242) } else { [System.Windows.Media.Color]::FromArgb(0x22, 255, 255, 255) }))
  $b.Foreground = New-Object System.Windows.Media.SolidColorBrush ($(if ($sel) { [System.Windows.Media.Color]::FromRgb(16, 16, 20) } else { [System.Windows.Media.Color]::FromRgb(255, 255, 255) }))
  return $b
}
function Sync-WxChips {
  $sel = [int]$cfg.cityIdx
  foreach ($w in $E.wxChips.Children) {
    if (-not ($w -is [System.Windows.Controls.Grid])) { continue }
    $b = $w.Children[0]
    if ($b.Tag -is [int]) {
      $on = ([int]$b.Tag -eq $sel)
      Anim-Color $b.Background $(if ($on) { [System.Windows.Media.Color]::FromRgb(242, 242, 242) } else { [System.Windows.Media.Color]::FromArgb(0x22, 255, 255, 255) }) 260
      Anim-Color $b.Foreground $(if ($on) { [System.Windows.Media.Color]::FromRgb(16, 16, 20) } else { [System.Windows.Media.Color]::FromRgb(255, 255, 255) }) 260
    }
  }
}
function Build-WxChips {
  $h = $E.wxChips
  $h.Children.Clear()
  $cs = @($cfg.cities)
  $sel = [int]$cfg.cityIdx
  $i = 0
  $items = @(@{ idx = -1; text = $(if ($ui.wx.autoName) { 'Моё место · ' + $ui.wx.autoName } else { 'Моё место' }); del = $false })
  for ($k = 0; $k -lt $cs.Count; $k++) { $items += , @{ idx = $k; text = [string]$cs[$k].n; del = $true } }
  foreach ($it in $items) {
    $w = New-Object System.Windows.Controls.Grid
    $w.Margin = [System.Windows.Thickness]::new(0, 0, 6, 6)
    $b = New-Chip $it.text ($it.idx -eq $sel)
    $b.Tag = [int]$it.idx
    if ($it.del) { $b.Padding = [System.Windows.Thickness]::new(14, 6, 28, 6) }
    $b.Add_Click({ param($snd, $ev) Select-City ([int]$snd.Tag) })
    [void]$w.Children.Add($b)
    if ($it.del) {
      $x = New-Object System.Windows.Controls.Button
      $x.Style = $E.wxChips.FindResource('IcoBtn')
      $x.Width = 18; $x.Height = 18
      $x.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(0x30, 0, 0, 0))
      $x.HorizontalAlignment = 'Right'; $x.VerticalAlignment = 'Center'
      $x.Margin = [System.Windows.Thickness]::new(0, 0, 5, 0)
      $x.Opacity = 0.0
      $x.Tag = [int]$it.idx
      $xp = New-Object System.Windows.Shapes.Path
      $xp.Data = [System.Windows.Media.Geometry]::Parse('M0 0 L6 6 M6 0 L0 6')
      $xp.Stroke = $script:brWhite; $xp.StrokeThickness = 1.5; $xp.StrokeStartLineCap = 'Round'; $xp.StrokeEndLineCap = 'Round'
      $xp.Width = 7; $xp.Height = 7; $xp.Stretch = 'Uniform'
      $x.Content = $xp
      $x.Add_Click({ param($snd, $ev) $ev.Handled = $true; Remove-City ([int]$snd.Tag) })
      [void]$w.Children.Add($x)
      $w.Add_MouseEnter({ param($snd, $ev) FadeTo $snd.Children[1] 1.0 140 })
      $w.Add_MouseLeave({ param($snd, $ev) FadeTo $snd.Children[1] 0.0 200 })
    }
    [void]$h.Children.Add($w)
    Pop-In $w $i 6
    $i++
  }
  $add = New-Object System.Windows.Controls.Button
  $add.Style = $E.wxChips.FindResource('PillBtn')
  $add.Content = '+  Город'
  $add.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
  $add.Padding = [System.Windows.Thickness]::new(14, 6, 14, 6)
  $add.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(0x14, 255, 255, 255))
  $add.Add_Click({ Wx-OpenSearch })
  [void]$h.Children.Add($add)
  Pop-In $add $i 6
}
function Select-City([int]$i) {
  if ([int]$cfg.cityIdx -eq $i) { return }
  $cfg.cityIdx = $i
  Request-Save
  Sync-WxChips
  Wx-Load $false
}
function Add-City($it) {
  $cs = @($cfg.cities)
  for ($k = 0; $k -lt $cs.Count; $k++) {
    if (([string]$cs[$k].n).ToLower() -eq ([string]$it.n).ToLower()) { $cfg.cityIdx = $k; Request-Save; Wx-CloseSearch; Sync-WxChips; Wx-Load $false; return }
  }
  if ($cs.Count -ge 6) { $cs = @($cs[1..5]) }
  $cfg.cities = @($cs) + (, @{ n = [string]$it.n; lat = [double]$it.lat; lon = [double]$it.lon })
  $cfg.cityIdx = @($cfg.cities).Count - 1
  Request-Save
  Wx-CloseSearch
  Build-WxChips
  Wx-Load $false
}
function Remove-City([int]$idx) {
  $cs = @($cfg.cities)
  $new = @()
  for ($k = 0; $k -lt $cs.Count; $k++) { if ($k -ne $idx) { $new += , $cs[$k] } }
  $cfg.cities = $new
  $ci = [int]$cfg.cityIdx
  if ($ci -eq $idx) { $cfg.cityIdx = -1 } elseif ($ci -gt $idx) { $cfg.cityIdx = $ci - 1 }
  Request-Save
  Build-WxChips
  Wx-Load $false
}

# data -> screen
function Uv-Text([double]$u) {
  $w = 'низкий'
  if ($u -ge 8) { $w = 'очень высокий' } elseif ($u -ge 6) { $w = 'высокий' } elseif ($u -ge 3) { $w = 'умеренный' }
  return ("{0} · {1}" -f [int][Math]::Round($u), $w)
}
function Render-Weather($wx) {
  if ((-not $wx) -or (-not $wx.ok)) {
    Wx-Dim $true
    Wx-Status 'Нет данных о погоде. Проверь интернет — попробую снова'
    return
  }
  Wx-Status ''
  $c = Wx-Cur
  if ($wx.key -eq 'auto') {
    if ($ui.wx.autoName -ne [string]$wx.city) { $ui.wx.autoName = [string]$wx.city; Build-WxChips }
  } elseif ((-not $c.auto) -and $null -eq $c.lat -and $null -ne $wx.lat) {
    try { $cfg.cities[$c.idx].lat = [double]$wx.lat; $cfg.cities[$c.idx].lon = [double]$wx.lon; Request-Save } catch {}
  }
  Set-WxIcon $E.wIco $wx.icon
  $E.wTemp.Text = "$($wx.temp)°"
  $E.wCity.Text = [string]$wx.city
  $cond = [string]$wx.cond
  if ($wx.rainP -ge 0) { $cond = $(if ($cond) { "$cond · осадки $($wx.rainP)%" } else { "Осадки $($wx.rainP)%" }) }
  $E.wCond.Text = $cond
  $E.wFeels.Text = "Ощущается как $($wx.feels)° · сегодня $($wx.hi)° / $($wx.lo)°"
  $E.wSun.Text = $(if ($wx.sunrise) { "Восход $($wx.sunrise) · закат $($wx.sunset)" } else { '' })
  $E.wdtWind.Text = "$($wx.wind) км/ч"
  $E.wdtHum.Text = "$($wx.hum)%"
  $E.wdtUv.Text = Uv-Text ([double]$wx.uv)
  $E.wdtPress.Text = "$($wx.press) мм"
  $hrs = @($wx.hours)
  # the rows always fill the whole width and never leave a hole: missing cells are collapsed, not hidden
  $E.wxHourly.Columns = [Math]::Max(1, [Math]::Min(8, $hrs.Count))
  for ($i = 1; $i -le 8; $i++) {
    $whp = $E["wh${i}t"].Parent
    if ($i -le $hrs.Count) {
      $h = $hrs[$i - 1]
      $E["wh${i}t"].Text = [string]$h.t
      Set-WxIcon $E["wh${i}i"] ([string]$h.icon)
      $E["wh${i}v"].Text = "$($h.v)°"
      $whp.Visibility = 'Visible'
    } else { $whp.Visibility = 'Collapsed' }
  }
  $E.wxHourly.Parent.Visibility = $(if ($hrs.Count -gt 0) { 'Visible' } else { 'Collapsed' })
  $ds = @($wx.days)
  $E.wxDays.Columns = [Math]::Max(1, [Math]::Min(5, $ds.Count))
  for ($i = 1; $i -le 5; $i++) {
    $card = Up $E["wd${i}d"] 2
    if ($i -le $ds.Count) {
      $d = $ds[$i - 1]
      $E["wd${i}d"].Text = [string]$d.d
      Set-WxIcon $E["wd${i}i"] ([string]$d.icon)
      $E["wd${i}t"].Text = "$($d.hi)° / $($d.lo)°"
      $rm = 8.0
      if ($i -ge $ds.Count) { $rm = 0.0 }
      $card.Margin = [System.Windows.Thickness]::new(0.0, 0.0, $rm, 0.0)
      $card.Visibility = 'Visible'
    } else { $card.Visibility = 'Collapsed' }
  }
  # everything comes in one after another
  Wx-Dim $false
  $n = 0
  foreach ($el in @((Up $E.wTemp 3), (Up $E.wdtWind 2), (Up $E.wdtHum 2), (Up $E.wdtUv 2), (Up $E.wdtPress 2), $E.wxHourly.Parent)) { Pop-In $el $n 8; $n++ }
  for ($i = 1; $i -le 8; $i++) { if ($i -le $hrs.Count) { Pop-In $E["wh${i}t"].Parent ($n + $i) 6 } }
  for ($i = 1; $i -le 5; $i++) { if ($i -le $ds.Count) { Pop-In (Up $E["wd${i}d"] 2) ($n + 8 + $i) 8 } }
}
function Wx-Load([bool]$force) {
  $c = Wx-Cur
  $res = $sync.WxRes[$c.key]
  $now = Utc-Ms
  if ($res -and $res.ok) {
    $ui.wx.ref = $res
    Render-Weather $res
    if ($force -or (($now - [long]$res.at) -gt 1200000)) { Wx-Request $c }
  } else {
    $ui.wx.ref = $null
    Wx-Dim $true
    if ($res -and (-not $res.ok) -and (($now - [long]$res.at) -lt 20000) -and (-not $force)) { Wx-Status 'Нет данных о погоде. Проверь интернет — попробую снова'; Wx-Request $c; return }
    Wx-Status 'Загружаю погоду…'
    Wx-Request $c
  }
}
function Wx-Show {
  Build-WxChips
  $ui.wx.dim = $false
  Wx-Load $false
}
function Update-WeatherUi {
  $c = Wx-Cur
  $res = $sync.WxRes[$c.key]
  if ($res -and (-not [object]::ReferenceEquals($res, $ui.wx.ref))) {
    $ui.wx.ref = $res
    Render-Weather $res
  }
  Wx-PollSearch
}

# city search overlay
function Wx-OpenSearch {
  if ($ui.wx.searchOpen) { return }
  $ui.wx.searchOpen = $true
  $E.wxQuery.Text = ''
  $E.wxResHost.Children.Clear()
  $E.wxResMsg.Text = 'Например: Казань, Минск, Tokyo'
  $E.wxResMsg.Visibility = 'Visible'
  $E.wxSearch.Visibility = 'Visible'
  Set-Op $E.wxSearch 0.0
  FadeTo $E.wxSearch 1.0 200
  $g = $E.wxSearch.RenderTransform.Children
  foreach ($ax in @([System.Windows.Media.ScaleTransform]::ScaleXProperty, [System.Windows.Media.ScaleTransform]::ScaleYProperty)) {
    $g[0].BeginAnimation($ax, $null)
    if ($ax -eq [System.Windows.Media.ScaleTransform]::ScaleXProperty) { $g[0].ScaleX = 0.96 } else { $g[0].ScaleY = 0.96 }
    Anim-To $g[0] $ax 1.0 320 $script:easeBack
  }
  $g[1].BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $null); $g[1].Y = -8.0
  Anim-To $g[1] ([System.Windows.Media.TranslateTransform]::YProperty) 0.0 300
  Begin-Kbd $E.wxQuery
}
function Wx-CloseSearch([bool]$instant = $false) {
  if (-not $ui.wx.searchOpen) { return }
  $ui.wx.searchOpen = $false
  if ($ui.kbd -and (-not $ui.siteAddOpen)) { End-Kbd }
  if ($instant) { Set-Op $E.wxSearch 0.0; $E.wxSearch.Visibility = 'Collapsed' }
  else { FadeTo $E.wxSearch 0.0 150; Later 180 { if (-not $ui.wx.searchOpen) { $E.wxSearch.Visibility = 'Collapsed' } } }
}
$script:wxQTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:wxQTimer.Interval = [TimeSpan]::FromMilliseconds(380)
$script:wxQTimer.Add_Tick({
  $script:wxQTimer.Stop()
  $q = $E.wxQuery.Text.Trim()
  if ($q.Length -ge 2) {
    $ui.wx.qId++
    $sync.CityQ = @{ id = $ui.wx.qId; q = $q }
    $E.wxResMsg.Text = 'Ищу…'; $E.wxResMsg.Visibility = 'Visible'
  } else {
    $E.wxResHost.Children.Clear()
    $E.wxResMsg.Text = 'Например: Казань, Минск, Tokyo'; $E.wxResMsg.Visibility = 'Visible'
  }
})
$E.wxQuery.Add_TextChanged({ $script:wxQTimer.Stop(); $script:wxQTimer.Start() })
$E.wxQuery.Add_KeyDown({
  param($snd, $ev)
  if ($ev.Key -eq [System.Windows.Input.Key]::Escape) { Wx-CloseSearch; $ev.Handled = $true }
  elseif ($ev.Key -eq [System.Windows.Input.Key]::Return) {
    $first = $null
    if ($E.wxResHost.Children.Count -gt 0) { $first = $E.wxResHost.Children[0].Tag }
    if ($first) { Add-City $first }
    $ev.Handled = $true
  }
})
$E.btnWxClose.Add_Click({ Wx-CloseSearch })
function Wx-PollSearch {
  $r = $sync.CityRes
  if ((-not $r) -or ([int]$r.id -ne [int]$ui.wx.qId) -or [object]::ReferenceEquals($r, $ui.wx.cityRef)) { return }
  $ui.wx.cityRef = $r
  $h = $E.wxResHost
  $h.Children.Clear()
  $items = @($r.items) | Where-Object { $_ }
  if (-not $r.ok) { $E.wxResMsg.Text = 'Не удалось выполнить поиск. Проверь интернет'; $E.wxResMsg.Visibility = 'Visible'; return }
  if (@($items).Count -eq 0) { $E.wxResMsg.Text = 'Ничего не нашлось'; $E.wxResMsg.Visibility = 'Visible'; return }
  $E.wxResMsg.Visibility = 'Collapsed'
  $i = 0
  foreach ($it in $items) {
    $b = New-Object System.Windows.Controls.Button
    $b.Style = $E.wxResHost.FindResource('RowBtn')
    $b.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
    $b.Padding = [System.Windows.Thickness]::new(14, 8, 14, 8)
    $b.Tag = $it
    $g = New-Object System.Windows.Controls.Grid
    $g.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)) | Out-Null
    $nm = New-Tb ([string]$it.n) 13 $script:brWhite 'SemiBold'
    $sb = New-Tb ([string]$it.sub) 11 $script:brSoft
    $sb.HorizontalAlignment = 'Right'; $sb.TextTrimming = 'CharacterEllipsis'; $sb.MaxWidth = 300
    $nm.HorizontalAlignment = 'Left'
    [void]$g.Children.Add($nm); [void]$g.Children.Add($sb)
    $b.Content = $g
    $b.Add_Click({ param($snd, $ev) Add-City $snd.Tag })
    [void]$h.Children.Add($b)
    Pop-In $b $i 6
    $i++
  }
}

} catch { Log ("init c4a failed: " + $_.Exception.Message + " @ line " + $_.InvocationInfo.ScriptLineNumber) }
try {

# ============================================================
#  Дела, заметки, события, напоминания, календарь по ссылке (ICS)
# ============================================================
$script:inv = [Globalization.CultureInfo]::InvariantCulture
$script:colGreen = [System.Windows.Media.Color]::FromRgb(48, 209, 88)
$script:colClear = [System.Windows.Media.Color]::FromArgb(0, 255, 255, 255)
$script:colRing = [System.Windows.Media.Color]::FromArgb(0x99, 255, 255, 255)
$script:brIcoBg = New-Br '#22FFFFFF'
$ui.evList = @(); $ui.evDirty = $true
$ui.icsItems = @(); $ui.icsSeq = 0; $ui.icsAt = 0.0; $ui.icsRef = $null
$ui.notified = @{}; $ui.heroKey = '#'; $ui.heroAt = 0.0; $ui.heroErrUntil = 0.0
$RU_WD = @{
  'понедельник' = 1; 'пн' = 1; 'вторник' = 2; 'вт' = 2; 'среда' = 3; 'среду' = 3; 'ср' = 3; 'четверг' = 4; 'чт' = 4
  'пятница' = 5; 'пятницу' = 5; 'пт' = 5; 'суббота' = 6; 'субботу' = 6; 'сб' = 6; 'воскресенье' = 0; 'вс' = 0
}
function New-Id { return [guid]::NewGuid().ToString('N').Substring(0, 8) }

# small round "×" button that appears when the pointer is over a row
function New-XButton([double]$size = 22.0) {
  $x = New-Object System.Windows.Controls.Button
  $x.Style = $E.tdHost.FindResource('IcoBtn')
  $x.Width = $size; $x.Height = $size
  $x.Background = $script:brIcoBg
  $x.HorizontalAlignment = 'Right'; $x.VerticalAlignment = 'Center'
  $x.Opacity = 0.0
  $xp = New-Object System.Windows.Shapes.Path
  $xp.Data = [System.Windows.Media.Geometry]::Parse('M0 0 L7 7 M7 0 L0 7')
  $xp.Stroke = $script:brWhite; $xp.StrokeThickness = 1.6
  $xp.StrokeStartLineCap = 'Round'; $xp.StrokeEndLineCap = 'Round'
  $xp.Width = 8; $xp.Height = 8; $xp.Stretch = 'Uniform'
  $x.Content = $xp
  return $x
}
function Pulse-Scale($el, [double]$from, [int]$ms = 420) {
  try {
    $st = $el.RenderTransform
    foreach ($ax in @([System.Windows.Media.ScaleTransform]::ScaleXProperty, [System.Windows.Media.ScaleTransform]::ScaleYProperty)) {
      $a = New-Object System.Windows.Media.Animation.DoubleAnimation
      $a.From = $from; $a.To = 1.0
      $a.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds($ms))
      $a.EasingFunction = $script:easeBack
      $st.BeginAnimation($ax, $a)
    }
  } catch {}
}

# ------------------------------------------------------------
#  Parsing a phrase like "завтра 15:30 Созвон", "через 20 мин чай", "в пятницу в 19 кино", "25.11 12:00 врач"
# ------------------------------------------------------------
function Cut-Match([string]$s, $m) { return ($s.Substring(0, $m.Index) + ' ' + $s.Substring($m.Index + $m.Length)) }
function Parse-Event([string]$text) {
  $s = ' ' + ([string]$text).Trim() + ' '
  $now = Get-Date
  $ic = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  $fmt = "yyyy-MM-dd'T'HH:mm"
  # relative
  $m = [regex]::Match($s, '\sчерез\s+(\d{1,3})\s*(мин\w*|м|час\w*|ч)(?=\s|$)', $ic)
  if ($m.Success) {
    $n = [int]$m.Groups[1].Value
    $unit = $m.Groups[2].Value.ToLower()
    $dt = $(if ($unit.StartsWith('ч')) { $now.AddHours($n) } else { $now.AddMinutes($n) })
    $dt = $dt.AddSeconds(-$dt.Second)
    $name = ((Cut-Match $s $m) -replace '\s+', ' ').Trim()
    if (-not $name) { $name = 'Напоминание' }
    return @{ t = $dt.ToString($fmt, $script:inv); n = $name }
  }
  $date = $null; $wd = -1; $h = -1; $mi = 0
  $m = [regex]::Match($s, '\s(сегодня|завтра|послезавтра)(?=\s|$)', $ic)
  if ($m.Success) {
    $w = $m.Groups[1].Value.ToLower()
    if ($w -eq 'сегодня') { $date = $now.Date } elseif ($w -eq 'завтра') { $date = $now.Date.AddDays(1) } else { $date = $now.Date.AddDays(2) }
    $s = Cut-Match $s $m
  }
  if ($null -eq $date) {
    $m = [regex]::Match($s, '\s(\d{1,2})\.(\d{1,2})(?:\.(\d{2,4}))?(?=\s|$)')
    if ($m.Success) {
      try {
        $dd = [int]$m.Groups[1].Value; $mo = [int]$m.Groups[2].Value
        $yy = $now.Year; $explicit = $false
        if ($m.Groups[3].Success) { $yy = [int]$m.Groups[3].Value; if ($yy -lt 100) { $yy += 2000 }; $explicit = $true }
        $cand = New-Object DateTime ($yy, $mo, $dd)
        if ((-not $explicit) -and $cand -lt $now.Date) { $cand = $cand.AddYears(1) }
        $date = $cand
        $s = Cut-Match $s $m
      } catch {}
    }
  }
  if ($null -eq $date) {
    $m = [regex]::Match($s, '\s(?:(?:в|во)\s+)?(понедельник|вторник|среду?|четверг|пятницу?|субботу?|воскресенье|пн|вт|ср|чт|пт|сб|вс)(?=\s|$)', $ic)
    if ($m.Success) { $wd = [int]$RU_WD[$m.Groups[1].Value.ToLower()]; $s = Cut-Match $s $m }
  }
  # time: 15:30 / в 15:30 / в 18 / в 18 часов
  $m = [regex]::Match($s, '\s(?:в\s+)?(\d{1,2}):(\d{2})(?=\s|$)', $ic)
  if ($m.Success -and [int]$m.Groups[1].Value -le 23 -and [int]$m.Groups[2].Value -le 59) {
    $h = [int]$m.Groups[1].Value; $mi = [int]$m.Groups[2].Value
    $s = Cut-Match $s $m
  } else {
    $m = [regex]::Match($s, '\sв\s+(\d{1,2})(?:\s*(?:час\w*|ч))?(?=\s|$)', $ic)
    if ($m.Success -and [int]$m.Groups[1].Value -le 23) { $h = [int]$m.Groups[1].Value; $mi = 0; $s = Cut-Match $s $m }
  }
  if (($null -eq $date) -and $wd -lt 0 -and $h -lt 0) { return $null }
  $name = ($s -replace '\s+', ' ').Trim()
  $name = ($name -replace '^[\s,.:;\-–—]+', '').Trim()
  if (-not $name) { $name = 'Событие' }
  $hh = $h; $mm = $mi
  if ($hh -lt 0) { $hh = 9; $mm = 0 }
  if ($wd -ge 0) {
    $delta = ($wd - [int]$now.DayOfWeek + 7) % 7
    $date = $now.Date.AddDays($delta)
    if ($delta -eq 0 -and $date.AddHours($hh).AddMinutes($mm) -le $now) { $date = $date.AddDays(7) }
  }
  if ($null -eq $date) {
    $date = $now.Date
    if ($date.AddHours($hh).AddMinutes($mm) -le $now) { $date = $date.AddDays(1) }
  }
  $dt = $date.AddHours($hh).AddMinutes($mm)
  return @{ t = $dt.ToString($fmt, $script:inv); n = $name.Substring(0, [Math]::Min(120, $name.Length)) }
}

# ------------------------------------------------------------
#  Events: own + calendar link, cached and sorted
# ------------------------------------------------------------
function Get-AllEvents {
  if (-not $ui.evDirty) { return $ui.evList }
  $out = New-Object System.Collections.ArrayList
  $fmt = "yyyy-MM-dd'T'HH:mm"
  foreach ($evt in @($cfg.events)) {
    try {
      $dt = [datetime]::ParseExact([string]$evt.t, $fmt, $script:inv)
      [void]$out.Add(@{ dt = $dt; n = [string]$evt.n; manual = $true; ad = $false; key = ([string]$evt.t + '|' + [string]$evt.n) })
    } catch {}
  }
  foreach ($evt in @($ui.icsItems)) {
    try {
      $dt = [datetime]::ParseExact([string]$evt.t, $fmt, $script:inv)
      [void]$out.Add(@{ dt = $dt; n = [string]$evt.n; manual = $false; ad = [bool]$evt.ad; key = ('ics|' + [string]$evt.t + '|' + [string]$evt.n) })
    } catch {}
  }
  $sorted = @($out | Sort-Object { $_.dt })
  $ui.evList = $sorted
  $ui.evDirty = $false
  return $sorted
}
function Ev-Upcoming($evt, [datetime]$now) {
  if ($evt.ad) { return ($evt.dt.Date -ge $now.Date) }
  return ($evt.dt -ge $now.AddMinutes(-30))
}
function Fmt-Day([datetime]$dt) {
  $diff = ($dt.Date - (Get-Date).Date).Days
  if ($diff -eq 0) { return 'Сегодня' }
  if ($diff -eq 1) { return 'Завтра' }
  if ($diff -eq 2) { return 'Послезавтра' }
  if ($diff -gt 2 -and $diff -lt 7) {
    $w = $dt.ToString('dddd', $ruRu)
    return $w.Substring(0, 1).ToUpper() + $w.Substring(1)
  }
  return (($dt.ToString('d MMM', $ruRu)) -replace '\.$', '')
}
function Fmt-When([datetime]$dt, [bool]$ad) {
  $d = Fmt-Day $dt
  if ($ad) { return "$d · весь день" }
  return ($d + ' · ' + $dt.ToString('HH:mm', $script:inv))
}
function Fmt-In([datetime]$dt, [bool]$ad) {
  $now = Get-Date
  if ($ad) {
    $d = ($dt.Date - $now.Date).Days
    if ($d -le 0) { return 'Сегодня весь день' }
    if ($d -eq 1) { return 'Завтра' }
    return "Через $d дн."
  }
  $mins = [int][Math]::Floor(($dt - $now).TotalMinutes)
  if ($mins -lt 0) { return 'Идёт сейчас' }
  if ($mins -lt 1) { return 'Сейчас' }
  if ($mins -lt 60) { return "Через $mins мин" }
  if ($mins -lt 1440) {
    $hh = [int][Math]::Floor($mins / 60); $rm = $mins % 60
    if ($rm -eq 0) { return "Через $hh ч" }
    return "Через $hh ч $rm мин"
  }
  $dd = [int][Math]::Floor($mins / 1440)
  return "Через $dd дн."
}

# the big card with the next event
function Refresh-Hero([bool]$animate = $true) {
  if ((Now-Ms) -lt $ui.heroErrUntil) { return }
  $now = Get-Date
  $next = $null
  foreach ($evt in @(Get-AllEvents)) { if (Ev-Upcoming $evt $now) { $next = $evt; break } }
  if ($next) {
    $key = $next.key
    $E.evHeroIn.Text = (Fmt-In $next.dt $next.ad)
    $soon = ((-not $next.ad) -and (($next.dt - $now).TotalMinutes -lt 60))
    $E.evHeroIn.Foreground = $(if ($soon) { $script:brOrange } else { $script:brGreen })
    $E.evHeroTitle.Text = $next.n
    $E.evHeroWhen.Text = (Fmt-When $next.dt $next.ad)
  } else {
    $key = 'none'
    $E.evHeroIn.Text = 'Свободно'
    $E.evHeroIn.Foreground = $script:brSoft
    $E.evHeroTitle.Text = 'Событий пока нет'
    $E.evHeroWhen.Text = 'Добавь первое ниже: «завтра 15:30 Созвон»'
  }
  if ($key -ne $ui.heroKey) {
    $ui.heroKey = $key
    if ($animate -and (-not $ui.reduceMotion)) {
      Set-Op $E.evHero 0.0
      FadeTo $E.evHero 1.0 300
      Pulse-Scale $E.evHero 0.965 460
    }
  }
}
function Hero-Error([string]$msg) {
  $ui.heroErrUntil = (Now-Ms) + 3200
  $E.evHeroIn.Text = 'Не понял время'
  $E.evHeroIn.Foreground = $script:brRed
  $E.evHeroWhen.Text = $msg
  Pulse-Scale $E.evHero 0.97 380
  Later 3300 { $ui.heroKey = '#'; Refresh-Hero $true }
}

function New-EventRow($evt) {
  $row = New-Object System.Windows.Controls.Grid
  $row.Margin = [System.Windows.Thickness]::new(0, 0, 0, 5)
  $row.Background = [System.Windows.Media.Brushes]::Transparent
  $bd = New-Object System.Windows.Controls.Border
  $bd.CornerRadius = [System.Windows.CornerRadius]::new(14)
  $bd.Background = New-Br '#10FFFFFF'
  $bd.Padding = [System.Windows.Thickness]::new(12, 8, 12, 8)
  $g = New-Object System.Windows.Controls.Grid
  $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = [System.Windows.GridLength]::new(86)
  $c1 = New-Object System.Windows.Controls.ColumnDefinition
  [void]$g.ColumnDefinitions.Add($c0); [void]$g.ColumnDefinitions.Add($c1)
  $when = New-Tb $(if ($evt.ad) { (Fmt-Day $evt.dt) } else { (Fmt-Day $evt.dt) + ' ' + $evt.dt.ToString('HH:mm', $script:inv) }) 10.5 $script:brSoft
  $when.TextTrimming = 'CharacterEllipsis'; $when.VerticalAlignment = 'Center'
  $nm = New-Tb $evt.n 12.5 $script:brWhite
  $nm.TextTrimming = 'CharacterEllipsis'; $nm.VerticalAlignment = 'Center'
  if ($evt.manual) { $nm.Margin = [System.Windows.Thickness]::new(0, 0, 24, 0) }
  [System.Windows.Controls.Grid]::SetColumn($nm, 1)
  [void]$g.Children.Add($when); [void]$g.Children.Add($nm)
  $bd.Child = $g
  [void]$row.Children.Add($bd)
  if ($evt.manual) {
    $x = New-XButton 22.0
    $x.Margin = [System.Windows.Thickness]::new(0, 0, 6, 0)
    $x.Tag = [string]$evt.key
    $x.Add_Click({ param($snd, $ev) $ev.Handled = $true; Remove-Event ([string]$snd.Tag) $snd.Parent })
    [void]$row.Children.Add($x)
    $row.Add_MouseEnter({ param($snd, $ev) FadeTo $snd.Children[1] 1.0 140 })
    $row.Add_MouseLeave({ param($snd, $ev) FadeTo $snd.Children[1] 0.0 200 })
  }
  return $row
}
function Build-Events([string]$onlyKey = '') {
  $now = Get-Date
  # forget our own events that ended more than 6 hours ago
  $old = @($cfg.events | Where-Object {
      $keep = $true
      try { $keep = ([datetime]::ParseExact([string]$_.t, "yyyy-MM-dd'T'HH:mm", $script:inv) -gt $now.AddHours(-6)) } catch {}
      $keep
    })
  if ($old.Count -ne @($cfg.events).Count) { $cfg.events = $old; $ui.evDirty = $true; Request-Save }
  $h = $E.evHost
  $h.Children.Clear()
  $all = @(Get-AllEvents)
  $shown = 0; $first = $true
  foreach ($evt in $all) {
    if (-not (Ev-Upcoming $evt $now)) { continue }
    if ($first) { $first = $false; continue }     # the first one lives in the big card
    if ($shown -ge 10) { break }
    $r = New-EventRow $evt
    [void]$h.Children.Add($r)
    if ($onlyKey -eq '' -or $evt.key -eq $onlyKey) { Pop-In $r $shown 7 }
    $shown++
  }
  Refresh-Hero $true
}
function Add-Event {
  $txt = $E.evIn.Text.Trim()
  if (-not $txt) { return }
  $p = Parse-Event $txt
  if (-not $p) { Hero-Error 'Напиши время: «завтра 15:30 Созвон», «через 20 мин чай»'; return }
  $cfg.events = @($cfg.events) + (, @{ t = [string]$p.t; n = [string]$p.n })
  $cfg.events = @($cfg.events | Sort-Object { $_.t } | Select-Object -Last 60)
  $ui.evDirty = $true
  Request-Save
  $E.evIn.Text = ''
  $ui.heroErrUntil = 0.0
  Build-Events ([string]$p.t + '|' + [string]$p.n)
}
function Remove-Event([string]$key, $row) {
  $done = $false
  $new = @()
  foreach ($evt in @($cfg.events)) {
    if ((-not $done) -and (([string]$evt.t + '|' + [string]$evt.n) -eq $key)) { $done = $true; continue }
    $new += , $evt
  }
  $cfg.events = $new
  $ui.evDirty = $true
  Request-Save
  if ($row) { Pop-Out $row 170 }
  Later 190 { if ($ui.expanded -and $ui.tab -eq 'todo') { Build-Events } }
}
$E.evIn.Add_KeyDown({
  param($snd, $ev)
  if ($ev.Key -eq [System.Windows.Input.Key]::Return) { Add-Event; $ev.Handled = $true }
})

# reminders: 5 minutes before and at the start (a pill with sound)
function Notify-Event([string]$text, [bool]$now) {
  $E.cEventTxt.Text = $text
  $ui.evtUntil = (Now-Ms) + 7000
  try { if ($now) { [System.Media.SystemSounds]::Exclamation.Play() } else { [System.Media.SystemSounds]::Asterisk.Play() } } catch {}
  Update-Mode
}
function Check-Reminders {
  $now = Get-Date
  foreach ($evt in @(Get-AllEvents)) {
    if ($evt.ad) { continue }
    $mins = ($evt.dt - $now).TotalMinutes
    if ($mins -gt 5.5 -or $mins -lt -3) { continue }
    $nm = [string]$evt.n
    if ($nm.Length -gt 26) { $nm = $nm.Substring(0, 25) + '…' }
    if ($mins -le 0) {
      $k = $evt.key + '|now'
      if (-not $ui.notified[$k]) { $ui.notified[$k] = $true; Notify-Event ("Сейчас · $nm") $true }
    } elseif ($mins -le 5) {
      $k = $evt.key + '|pre'
      if (-not $ui.notified[$k]) {
        $ui.notified[$k] = $true
        Notify-Event ("Через " + [int][Math]::Ceiling($mins) + " мин · $nm") $false
      }
    }
  }
  if ($ui.notified.Count -gt 300) { $ui.notified.Clear() }
}
# the "Через 12 мин" label stays fresh while the tab is open
function Events-Tick {
  $n = Now-Ms
  if (($n - $ui.heroAt) -lt 4000) { return }
  $ui.heroAt = $n
  Refresh-Hero $true
}

# ------------------------------------------------------------
#  Calendar link (ICS)
# ------------------------------------------------------------
function Ics-Request {
  $url = ([string]$cfg.icsUrl).Trim()
  if (-not $url) { return }
  $ui.icsSeq++
  $ui.icsAt = Utc-Ms
  $sync.IcsReq = @{ seq = $ui.icsSeq; url = $url }
}
function Ics-Info([string]$text, [bool]$bad = $false) {
  $E.icsInfo.Text = $text
  $E.icsInfo.Foreground = $(if ($bad) { $script:brTmpHot } else { $script:brSoft })
}
function Ics-Tick {
  $url = ([string]$cfg.icsUrl).Trim()
  if ($url -and (((Utc-Ms) - $ui.icsAt) -gt 1800000.0)) { Ics-Request }
  $r = $sync.Ics
  if ($r -and (-not [object]::ReferenceEquals($r, $ui.icsRef)) -and ([int]$r.seq -eq $ui.icsSeq)) {
    $ui.icsRef = $r
    if ($r.ok) {
      $ui.icsItems = @($r.items)
      $ui.evDirty = $true
      Ics-Info ("Подключено. Событий на 45 дней вперёд: " + @($r.items).Count)
      if ($ui.expanded -and $ui.tab -eq 'todo') { Build-Events }
    } else {
      Ics-Info 'Не удалось загрузить календарь. Проверь ссылку и интернет' $true
    }
  }
}
function Save-Ics {
  $u = $E.icsIn.Text.Trim()
  if ($u -match '^webcal://') { $u = 'https://' + $u.Substring(9) }
  if ($u -and ($u -notmatch '^https?://')) { Ics-Info 'Нужна ссылка вида https://…' $true; return }
  $cfg.icsUrl = $u
  Request-Save
  $ui.icsItems = @(); $ui.evDirty = $true
  if ($u) { Ics-Info 'Загружаю календарь…'; Ics-Request } else { Ics-Info 'Календарь отключён' }
}
$E.icsIn.Text = [string]$cfg.icsUrl
if ($cfg.icsUrl) { Ics-Info 'Календарь подключён' }
$E.btnIcsSave.Add_Click({ Save-Ics })
$E.icsIn.Add_KeyDown({
  param($snd, $ev)
  if ($ev.Key -eq [System.Windows.Input.Key]::Return) { Save-Ics; $ev.Handled = $true }
})

# ------------------------------------------------------------
#  To-do list and notes
# ------------------------------------------------------------
function Todo-Look($tg, [bool]$done, [bool]$animate) {
  $fillC = $(if ($done) { $script:colGreen } else { $script:colClear })
  $ringC = $(if ($done) { $script:colGreen } else { $script:colRing })
  $op = $(if ($done) { 0.45 } else { 1.0 })
  if ($animate) {
    Anim-Color $tg.ell.Fill $fillC 240
    Anim-Color $tg.ell.Stroke $ringC 240
    FadeTo $tg.ck $(if ($done) { 1.0 } else { 0.0 }) 200
    FadeTo $tg.txt $op 260
  } else {
    $tg.ell.Fill.Color = $fillC
    $tg.ell.Stroke.Color = $ringC
    Set-Op $tg.ck $(if ($done) { 1.0 } else { 0.0 })
    Set-Op $tg.txt $op
  }
  $tg.txt.TextDecorations = $(if ($done) { [System.Windows.TextDecorations]::Strikethrough } else { $null })
}
function Todo-Count-Update {
  $all = @($cfg.todos)
  if ($all.Count -eq 0) { $E.tdCount.Text = ''; return }
  $left = @($all | Where-Object { -not $_.d }).Count
  $E.tdCount.Text = "Осталось $left из $($all.Count)"
}
function New-TodoRow($t) {
  $done = [bool]$t.d
  $row = New-Object System.Windows.Controls.Grid
  $row.Margin = [System.Windows.Thickness]::new(0, 0, 0, 2)
  $row.Background = [System.Windows.Media.Brushes]::Transparent
  $cA = New-Object System.Windows.Controls.ColumnDefinition; $cA.Width = [System.Windows.GridLength]::Auto
  $cB = New-Object System.Windows.Controls.ColumnDefinition
  $cC = New-Object System.Windows.Controls.ColumnDefinition; $cC.Width = [System.Windows.GridLength]::Auto
  [void]$row.ColumnDefinitions.Add($cA); [void]$row.ColumnDefinitions.Add($cB); [void]$row.ColumnDefinitions.Add($cC)
  # the round check box
  $chk = New-Object System.Windows.Controls.Button
  $chk.Style = $E.tdHost.FindResource('IcoBtn')
  $chk.Width = 30; $chk.Height = 30
  $chk.Background = [System.Windows.Media.Brushes]::Transparent
  $chk.VerticalAlignment = 'Top'
  $g = New-Object System.Windows.Controls.Grid
  $g.Width = 20; $g.Height = 20
  $ell = New-Object System.Windows.Shapes.Ellipse
  $ell.Width = 20; $ell.Height = 20; $ell.StrokeThickness = 1.7
  $ell.Stroke = New-Object System.Windows.Media.SolidColorBrush $script:colRing
  $ell.Fill = New-Object System.Windows.Media.SolidColorBrush $script:colClear
  $ck = New-Object System.Windows.Shapes.Path
  $ck.Data = [System.Windows.Media.Geometry]::Parse('M5.5 10.5 L8.8 13.8 L14.8 6.8')
  $ck.Stroke = $script:brWhite; $ck.StrokeThickness = 2.0
  $ck.StrokeStartLineCap = 'Round'; $ck.StrokeEndLineCap = 'Round'; $ck.StrokeLineJoin = 'Round'
  $ck.Opacity = 0.0
  [void]$g.Children.Add($ell); [void]$g.Children.Add($ck)
  $chk.Content = $g
  $txt = New-Tb ([string]$t.t) 13 $script:brWhite
  $txt.TextWrapping = 'Wrap'; $txt.VerticalAlignment = 'Top'
  $txt.Margin = [System.Windows.Thickness]::new(6, 6, 6, 6)
  [System.Windows.Controls.Grid]::SetColumn($txt, 1)
  $chk.Tag = @{ id = [string]$t.id; ell = $ell; ck = $ck; txt = $txt }
  $chk.Add_Click({ param($snd, $ev) $ev.Handled = $true; Todo-Toggle $snd })
  $del = New-XButton 22.0
  $del.VerticalAlignment = 'Top'
  $del.Margin = [System.Windows.Thickness]::new(0, 4, 2, 0)
  [System.Windows.Controls.Grid]::SetColumn($del, 2)
  $del.Tag = [string]$t.id
  $del.Add_Click({ param($snd, $ev) $ev.Handled = $true; Todo-Remove ([string]$snd.Tag) $snd.Parent })
  [void]$row.Children.Add($chk); [void]$row.Children.Add($txt); [void]$row.Children.Add($del)
  $row.Add_MouseEnter({ param($snd, $ev) FadeTo $snd.Children[2] 1.0 140 })
  $row.Add_MouseLeave({ param($snd, $ev) FadeTo $snd.Children[2] 0.0 200 })
  Todo-Look $chk.Tag $done $false
  return $row
}
function Build-Todos([bool]$animate = $true, [string]$onlyId = '') {
  $h = $E.tdHost
  $h.Children.Clear()
  $items = @($cfg.todos)
  $open = @($items | Where-Object { -not $_.d })
  $done = @($items | Where-Object { $_.d })
  $i = 0
  foreach ($t in (@($open) + @($done))) {
    $r = New-TodoRow $t
    [void]$h.Children.Add($r)
    if ($animate -and (($onlyId -eq '') -or ($t.id -eq $onlyId))) { Pop-In $r $i 7 }
    $i++
  }
  $E.tdEmpty.Visibility = $(if ($items.Count -eq 0) { 'Visible' } else { 'Collapsed' })
  Todo-Count-Update
}
function Todo-Toggle($btn) {
  $tg = $btn.Tag
  $item = $null
  foreach ($x in @($cfg.todos)) { if ($x.id -eq $tg.id) { $item = $x; break } }
  if (-not $item) { return }
  $item.d = (-not [bool]$item.d)
  Request-Save
  Todo-Look $tg ([bool]$item.d) $true
  Todo-Count-Update
  Later 560 { if ($ui.expanded -and $ui.tab -eq 'todo') { Build-Todos $false } }
}
function Todo-Remove([string]$id, $row) {
  $cfg.todos = @($cfg.todos | Where-Object { $_.id -ne $id })
  Request-Save
  if ($row) { Pop-Out $row 170 }
  Todo-Count-Update
  Later 190 { if ($ui.expanded -and $ui.tab -eq 'todo') { Build-Todos $false } }
}
function Add-Todo {
  $t = $E.tdIn.Text.Trim()
  if (-not $t) { return }
  $id = New-Id
  $item = @{ id = $id; t = $t.Substring(0, [Math]::Min(160, $t.Length)); d = $false }
  $cfg.todos = @(@($item) + @($cfg.todos) | Select-Object -First 80)
  Request-Save
  $E.tdIn.Text = ''
  Build-Todos $true $id
}
$E.tdIn.Add_KeyDown({
  param($snd, $ev)
  if ($ev.Key -eq [System.Windows.Input.Key]::Return) { Add-Todo; $ev.Handled = $true }
})

# text boxes grab the keyboard on the first click; Esc clears, then lets go
foreach ($tbx in @($E.evIn, $E.tdIn, $E.clipQ, $E.icsIn, $E.wxQuery)) { Hook-Kbd $tbx }
Set-Hint $E.icsIn $E.icsInHint
foreach ($tbx in @($E.evIn, $E.tdIn, $E.clipQ, $E.icsIn)) {
  $tbx.Add_KeyDown({
    param($snd, $ev)
    if ($ev.Key -eq [System.Windows.Input.Key]::Escape) {
      if ($snd.Text) { $snd.Text = '' } else { End-Kbd }
      $ev.Handled = $true
    }
  })
}

} catch { Log ("init c4b failed: " + $_.Exception.Message + " @ line " + $_.InvocationInfo.ScriptLineNumber) }
try {

# ============================================================
#  Sound: per-application volume (Windows volume mixer) — every app gets its own slider
# ============================================================
$ui.mix = @{}; $ui.mixById = @{}; $ui.mixN = 0; $ui.mixAt = 0.0; $ui.mixErrLogged = $false
$script:brDimWhite = New-Br '#33FFFFFF'
$script:brFillWhite = New-Br '#F2F2F2'
$script:brSpeaker = New-Br '#F2FFFFFF'
$MIX_NAMES = @{
  'chrome' = 'Google Chrome'; 'msedge' = 'Microsoft Edge'; 'firefox' = 'Firefox'; 'opera' = 'Opera'; 'opera_gx' = 'Opera GX'
  'brave' = 'Brave'; 'browser' = 'Яндекс Браузер'; 'yandex' = 'Яндекс Браузер'; 'vivaldi' = 'Vivaldi'
  'spotify' = 'Spotify'; 'discord' = 'Discord'; 'telegram' = 'Telegram'; 'vlc' = 'VLC'; 'steam' = 'Steam'
  'obs64' = 'OBS Studio'; 'zoom' = 'Zoom'; 'teams' = 'Teams'; 'ms-teams' = 'Teams'; 'wmplayer' = 'Проигрыватель Windows'
  'яндекс музыка' = 'Яндекс Музыка'; 'yandexmusic' = 'Яндекс Музыка'; 'applemusic' = 'Apple Music'; 'itunes' = 'iTunes'
  'whatsapp' = 'WhatsApp'; 'skype' = 'Skype'; 'code' = 'VS Code'; 'epicgameslauncher' = 'Epic Games'; 'javaw' = 'Minecraft'
  'gta5' = 'GTA V'; 'cs2' = 'Counter-Strike 2'; 'dota2' = 'Dota 2'; 'valorant-win64-shipping' = 'Valorant'
}
function Mix-Label($it) {
  if ($it.System) { return 'Системные звуки' }
  $n = [string]$it.Name
  $k = $n.ToLower()
  if ($MIX_NAMES.ContainsKey($k)) { return [string]$MIX_NAMES[$k] }
  if ($n.Length -gt 0) { return $n.Substring(0, 1).ToUpper() + $n.Substring(1) }
  return '?'
}

# a slider built in code: the same parts and names as the ones in the XAML, so Add-Slider works on it
function New-SliderParts([string]$sid, [double]$w) {
  $hit = New-Object System.Windows.Controls.Grid
  $hit.Name = "${sid}Hit"; $hit.Width = $w; $hit.Height = 28
  $hit.Background = [System.Windows.Media.Brushes]::Transparent
  $hit.Cursor = [System.Windows.Input.Cursors]::Hand
  $track = New-Object System.Windows.Controls.Border
  $track.Name = "${sid}Track"; $track.Height = 6; $track.CornerRadius = [System.Windows.CornerRadius]::new(5)
  $track.Background = $script:brDimWhite; $track.VerticalAlignment = 'Center'; $track.IsHitTestVisible = $false
  $fill = New-Object System.Windows.Controls.Border
  $fill.Name = "${sid}Fill"; $fill.Height = 6; $fill.CornerRadius = [System.Windows.CornerRadius]::new(5)
  $fill.Background = $script:brFillWhite; $fill.HorizontalAlignment = 'Left'; $fill.VerticalAlignment = 'Center'
  $fill.Width = 0; $fill.IsHitTestVisible = $false
  $knob = New-Object System.Windows.Shapes.Ellipse
  $knob.Name = "${sid}Knob"; $knob.Width = 14; $knob.Height = 14; $knob.Fill = [System.Windows.Media.Brushes]::White
  $knob.HorizontalAlignment = 'Left'; $knob.VerticalAlignment = 'Center'; $knob.Opacity = 0.0
  $knob.RenderTransformOrigin = [System.Windows.Point]::new(0.5, 0.5); $knob.IsHitTestVisible = $false
  $tg = New-Object System.Windows.Media.TransformGroup
  [void]$tg.Children.Add((New-Object System.Windows.Media.ScaleTransform (0.5, 0.5)))
  [void]$tg.Children.Add((New-Object System.Windows.Media.TranslateTransform))
  $knob.RenderTransform = $tg
  # the bubble is not used here (the percentage sits next to the slider); the parts only have to exist
  $tip = New-Object System.Windows.Controls.Border
  $tip.Name = "${sid}Tip"; $tip.Opacity = 0.0; $tip.Visibility = 'Collapsed'; $tip.IsHitTestVisible = $false
  $tip.RenderTransform = New-Object System.Windows.Media.TranslateTransform
  $tipTxt = New-Object System.Windows.Controls.TextBlock
  $tipTxt.Name = "${sid}TipTxt"
  $tip.Child = $tipTxt
  foreach ($el in @($track, $fill, $knob, $tip)) { [void]$hit.Children.Add($el) }
  $E["${sid}Hit"] = $hit; $E["${sid}Track"] = $track; $E["${sid}Fill"] = $fill
  $E["${sid}Knob"] = $knob; $E["${sid}Tip"] = $tip; $E["${sid}TipTxt"] = $tipTxt
  return $hit
}

function Mix-Apply($r, [double]$f, [bool]$force) {
  $r.pct.Text = "$([int][Math]::Round($f * 100.0))%"
  $now = Now-Ms
  if ((-not $force) -and (($now - $r.at) -lt 45)) { return }   # the COM call walks all sessions: not on every mouse move
  $r.at = $now
  $rc = [DI.Mixer]::SetVol([string]$r.name, [float]$f)
  if ($rc -ne 0 -and (-not $ui.mixErrLogged)) { $ui.mixErrLogged = $true; Log ("mixer set failed (" + $r.name + "): " + [DI.Mixer]::LastError) }
  $r.vol = $f
  if ($r.muted -and $f -gt 0.0) { [void][DI.Mixer]::SetMute([string]$r.name, $false); Mix-SetMuted $r $false }
}
function Mix-SetMuted($r, [bool]$m) {
  $r.muted = $m
  $r.x.Visibility = $(if ($m) { 'Visible' } else { 'Collapsed' })
  $r.wave.Visibility = $(if ($m) { 'Collapsed' } else { 'Visible' })
  FadeTo $r.slider $(if ($m) { 0.4 } else { 1.0 }) 220
}
function Mix-SetStatus($r, [bool]$active, [bool]$sys) {
  if ($r.active -eq $active -and $r.statusSet) { return }
  $r.active = $active; $r.statusSet = $true
  if ($sys) { $r.st.Text = 'Звуки Windows'; $r.st.Foreground = $script:brSoft; return }
  $r.st.Text = $(if ($active) { 'Сейчас играет' } else { 'Тихо' })
  $r.st.Foreground = $(if ($active) { $script:brGreen } else { $script:brDim })
}

function New-MixRow($it, [string]$key) {
  $ui.mixN++
  $sid = "mx$($ui.mixN)"
  $sys = [bool]$it.System
  $r = @{ sid = $sid; key = $key; name = [string]$it.Name; sys = $sys; vol = [double]$it.Vol; muted = $false; at = 0.0; active = $false; statusSet = $false; init = $false }
  $el = New-Object System.Windows.Controls.Border
  $el.CornerRadius = [System.Windows.CornerRadius]::new(20)
  $el.Background = New-Br '#14FFFFFF'
  $el.BorderBrush = New-Br '#1CFFFFFF'
  $el.BorderThickness = [System.Windows.Thickness]::new(1)
  $el.Padding = [System.Windows.Thickness]::new(12, 9, 14, 9)
  $el.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
  $g = New-Object System.Windows.Controls.Grid
  foreach ($wd in @('Auto', '168', '*', '46', 'Auto')) {
    $cd = New-Object System.Windows.Controls.ColumnDefinition
    if ($wd -eq 'Auto') { $cd.Width = [System.Windows.GridLength]::Auto }
    elseif ($wd -eq '*') { $cd.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) }
    else { $cd.Width = [System.Windows.GridLength]::new([double]$wd) }
    [void]$g.ColumnDefinitions.Add($cd)
  }
  # coloured plate with the first letter (or a speaker for system sounds)
  $label = Mix-Label $it
  $sum = 0
  foreach ($ch in $label.ToCharArray()) { $sum += [int]$ch }
  $plate = New-Object System.Windows.Controls.Border
  $plate.Width = 36; $plate.Height = 36; $plate.CornerRadius = [System.Windows.CornerRadius]::new(11)
  $plate.Background = (New-Br ([string]$SITE_COLORS[$sum % $SITE_COLORS.Count]))
  $lt = New-Tb $(if ($sys) { '♪' } else { $label.Substring(0, 1).ToUpper() }) 16 $script:brWhite 'SemiBold'
  $lt.HorizontalAlignment = 'Center'; $lt.VerticalAlignment = 'Center'
  $plate.Child = $lt
  [void]$g.Children.Add($plate)
  # name + state
  $spn = New-Object System.Windows.Controls.StackPanel
  $spn.VerticalAlignment = 'Center'; $spn.Margin = [System.Windows.Thickness]::new(12, 0, 8, 0)
  $nm = New-Tb $label 13 $script:brWhite 'SemiBold'
  $nm.TextTrimming = 'CharacterEllipsis'
  $st = New-Tb '' 10.5 $script:brSoft
  $st.Margin = [System.Windows.Thickness]::new(0, 2, 0, 0)
  [void]$spn.Children.Add($nm); [void]$spn.Children.Add($st)
  [System.Windows.Controls.Grid]::SetColumn($spn, 1)
  [void]$g.Children.Add($spn)
  # slider
  $hit = New-SliderParts $sid 248.0
  $hit.HorizontalAlignment = 'Center'; $hit.VerticalAlignment = 'Center'
  [System.Windows.Controls.Grid]::SetColumn($hit, 2)
  [void]$g.Children.Add($hit)
  # percentage
  $pct = New-Tb '' 13 $script:brWhite 'SemiBold'
  $pct.TextAlignment = 'Right'; $pct.VerticalAlignment = 'Center'
  [System.Windows.Controls.Grid]::SetColumn($pct, 3)
  [void]$g.Children.Add($pct)
  # mute button
  $mb = New-Object System.Windows.Controls.Button
  $mb.Style = $E.mixHost.FindResource('IcoBtn')
  $mb.Width = 34; $mb.Height = 34; $mb.Margin = [System.Windows.Thickness]::new(10, 0, 0, 0)
  $mb.Background = $script:brIcoBg
  $vb = New-Object System.Windows.Controls.Viewbox
  $vb.Width = 17; $vb.Height = 17
  $cv = New-Object System.Windows.Controls.Canvas
  $cv.Width = 24; $cv.Height = 24
  $sp1 = New-Object System.Windows.Shapes.Path
  $sp1.Data = [System.Windows.Media.Geometry]::Parse('M11 5 6.5 9H3v6h3.5L11 19z'); $sp1.Fill = $script:brSpeaker
  $wave = New-Object System.Windows.Shapes.Path
  $wave.Data = [System.Windows.Media.Geometry]::Parse('M15.5 8.5a5 5 0 0 1 0 7 M18.5 5.5a9 9 0 0 1 0 13')
  $wave.Stroke = $script:brSpeaker; $wave.StrokeThickness = 2; $wave.StrokeStartLineCap = 'Round'; $wave.StrokeEndLineCap = 'Round'
  $xx = New-Object System.Windows.Shapes.Path
  $xx.Data = [System.Windows.Media.Geometry]::Parse('M15 9.5l5 5 M20 9.5l-5 5')
  $xx.Stroke = $script:brRed; $xx.StrokeThickness = 2; $xx.StrokeStartLineCap = 'Round'; $xx.StrokeEndLineCap = 'Round'; $xx.Visibility = 'Collapsed'
  foreach ($p in @($sp1, $wave, $xx)) { [void]$cv.Children.Add($p) }
  $vb.Child = $cv
  $mb.Content = $vb
  [System.Windows.Controls.Grid]::SetColumn($mb, 4)
  $mb.Tag = $r
  $mb.Add_Click({
    param($snd, $ev)
    $rr = $snd.Tag
    $m = (-not [bool]$rr.muted)
    [void][DI.Mixer]::SetMute([string]$rr.name, $m)
    Mix-SetMuted $rr $m
  })
  [void]$g.Children.Add($mb)
  $el.Child = $g
  $r.el = $el; $r.pct = $pct; $r.st = $st; $r.slider = $hit; $r.wave = $wave; $r.x = $xx
  $ui.mixById[$sid] = $r
  Add-Slider $sid {
    param($f, $id)
    $rr = $ui.mixById[$id]
    if ($rr) { Mix-Apply $rr $f $false }
  } {
    param($f, $id)
    $rr = $ui.mixById[$id]
    if ($rr) { Mix-Apply $rr $f $true }
  } {
    param($f)
    "$([int][Math]::Round($f * 100.0))%"
  } $false 0.04
  return $r
}

function Mix-Update($r, $it) {
  $vol = [double]$it.Vol
  $r.pct.Text = "$([int][Math]::Round($vol * 100.0))%"
  if (-not $SL[$r.sid].drag) {
    if ((-not $r.init) -or ([Math]::Abs($SL[$r.sid].frac - $vol) -gt 0.006)) {
      Slider-Set $r.sid $vol ([bool]$r.init)
    }
    $r.vol = $vol
  }
  $r.init = $true
  if ([bool]$it.Muted -ne [bool]$r.muted) { Mix-SetMuted $r ([bool]$it.Muted) }
  Mix-SetStatus $r ([bool]$it.Active) ([bool]$it.System)
}
function Mix-Sweep {
  foreach ($c in @($E.mixHost.Children)) { if ($c.Tag -eq 'gone') { $E.mixHost.Children.Remove($c) } }
}
function Mixer-Poll {
  if (-not ($ui.expanded -and (-not $ui.closing) -and $ui.tab -eq 'sound')) { return }
  $now = Now-Ms
  if (($now - $ui.mixAt) -lt 700) { return }
  $ui.mixAt = $now
  $items = @([DI.Mixer]::List())
  $seen = @{}
  foreach ($it in $items) {
    if (-not $it) { continue }
    $key = $(if ($it.System) { '#sys' } else { ([string]$it.Name).ToLower() })
    $seen[$key] = $true
    $r = $ui.mix[$key]
    if (-not $r) {
      $r = New-MixRow $it $key
      $ui.mix[$key] = $r
      [void]$E.mixHost.Children.Add($r.el)
      Pop-In $r.el ($E.mixHost.Children.Count - 1) 8
    }
    Mix-Update $r $it
  }
  $gone = $false
  foreach ($k in @($ui.mix.Keys)) {
    if (-not $seen[$k]) {
      $r = $ui.mix[$k]
      $r.el.Tag = 'gone'
      Pop-Out $r.el 170
      [void]$ui.mixById.Remove($r.sid)
      [void]$SL.Remove($r.sid)
      [void]$ui.mix.Remove($k)
      $gone = $true
    }
  }
  if ($gone) { Later 200 { Mix-Sweep } }
  $E.mixEmpty.Visibility = $(if ($ui.mix.Count -eq 0) { 'Visible' } else { 'Collapsed' })
}

} catch { Log ("init c4c failed: " + $_.Exception.Message + " @ line " + $_.InvocationInfo.ScriptLineNumber) }
try {

# ============================================================
#  Clipboard: history + pinned + search
# ============================================================
$script:colGold = [System.Windows.Media.Color]::FromRgb(255, 214, 10)
$script:colStarOff = [System.Windows.Media.Color]::FromArgb(0x99, 255, 255, 255)
$script:colCardBase = [System.Windows.Media.Color]::FromArgb(0x12, 255, 255, 255)
$script:colCardPin = [System.Windows.Media.Color]::FromArgb(0x26, 255, 214, 10)
$script:colCardOk = [System.Windows.Media.Color]::FromArgb(0x78, 48, 209, 88)
$ui.clipRef = $null
$STAR_PATH = 'M12 2l3.09 6.26L22 9.27l-5 4.87 1.18 6.88L12 17.77l-6.18 3.25L7 14.14 2 9.27l6.91-1.01L12 2z'

function Copy-Text([string]$t) {
  $sync.ClipWrite = $t     # tells the worker this is our own write: the history keeps its order
  for ($i = 0; $i -lt 3; $i++) {
    try { [System.Windows.Clipboard]::SetDataObject($t, $true); return $true }
    catch { Start-Sleep -Milliseconds 40 }
  }
  Log 'clipboard write failed'
  $sync.ClipWrite = ''
  return $false
}
function Clip-Preview([string]$s) {
  $t = ($s -replace '\s+', ' ').Trim()
  if ($t.Length -gt 170) { $t = $t.Substring(0, 170) + '…' }
  return $t
}
function Clip-Pin([string]$text) {
  $pins = @($cfg.pins)
  if ($pins -ccontains $text) { $cfg.pins = @($pins | Where-Object { $_ -cne $text }) }
  else { $cfg.pins = @(@($text) + $pins | Select-Object -First 20) }
  Request-Save
  Build-Clip $false
}
function New-ClipRow($text, [bool]$pinned) {
  $w = New-Object System.Windows.Controls.Grid
  $card = New-Object System.Windows.Controls.Button
  $card.Style = $E.clipHost.FindResource('ClipCard')
  $card.Content = (Clip-Preview $text)
  $card.Tag = $text
  $card.Margin = [System.Windows.Thickness]::new(0, 0, 34, 0)
  $card.Background = New-Object System.Windows.Media.SolidColorBrush $(if ($pinned) { $script:colCardPin } else { $script:colCardBase })
  $card.Add_Click({
    param($snd, $ev)
    if (Copy-Text ([string]$snd.Tag)) {
      # a short green flash says "copied"
      Clip-Restore
      Anim-Color $snd.Background $script:colCardOk 120
      Later 460 { Clip-Restore }
      $ui.clipFlash = $snd
    }
  })
  $star = New-Object System.Windows.Controls.Button
  $star.Style = $E.clipHost.FindResource('IcoBtn')
  $star.Width = 26; $star.Height = 26
  $star.Background = [System.Windows.Media.Brushes]::Transparent
  $star.HorizontalAlignment = 'Right'; $star.VerticalAlignment = 'Top'
  $star.Margin = [System.Windows.Thickness]::new(0, 3, 4, 0)
  $vb = New-Object System.Windows.Controls.Viewbox
  $vb.Width = 15; $vb.Height = 15
  $cv = New-Object System.Windows.Controls.Canvas
  $cv.Width = 24; $cv.Height = 24
  $spn = New-Object System.Windows.Shapes.Path
  $spn.Data = [System.Windows.Media.Geometry]::Parse($STAR_PATH)
  $spn.StrokeThickness = 1.8; $spn.StrokeLineJoin = 'Round'
  $spn.Stroke = New-Object System.Windows.Media.SolidColorBrush $(if ($pinned) { $script:colGold } else { $script:colStarOff })
  $spn.Fill = New-Object System.Windows.Media.SolidColorBrush $(if ($pinned) { $script:colGold } else { [System.Windows.Media.Color]::FromArgb(0, 255, 255, 255) })
  [void]$cv.Children.Add($spn)
  $vb.Child = $cv
  $star.Content = $vb
  $star.Tag = $text
  $star.Add_Click({ param($snd, $ev) $ev.Handled = $true; Clip-Pin ([string]$snd.Tag) })
  [void]$w.Children.Add($card)
  [void]$w.Children.Add($star)
  return $w
}
function Clip-Restore {
  try {
    $c = $ui.clipFlash
    $ui.clipFlash = $null
    if ($c) {
      $pinned = ($cfg.pins -ccontains [string]$c.Tag)
      Anim-Color $c.Background $(if ($pinned) { $script:colCardPin } else { $script:colCardBase }) 320
    }
  } catch {}
}
function Build-Clip([bool]$animate = $true) {
  $h = $E.clipHost
  $h.Children.Clear()
  $q = $E.clipQ.Text.Trim()
  $hist = @()
  if ($sync.Clip) { $hist = @($sync.Clip) }
  $pins = @($cfg.pins)
  $rows = New-Object System.Collections.ArrayList
  foreach ($p in $pins) {
    if (-not $p) { continue }
    if ((-not $q) -or ([string]$p).IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0) { [void]$rows.Add(@{ t = [string]$p; pin = $true }) }
  }
  foreach ($c in $hist) {
    if (-not $c) { continue }
    if ($pins -ccontains [string]$c) { continue }
    if ((-not $q) -or ([string]$c).IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0) { [void]$rows.Add(@{ t = [string]$c; pin = $false }) }
  }
  $i = 0
  foreach ($r in $rows) {
    if ($i -ge 60) { break }
    $w = New-ClipRow $r.t $r.pin
    [void]$h.Children.Add($w)
    if ($animate) { Pop-In $w $i 7 }
    $i++
  }
  if ($i -eq 0) {
    $E.clipHintTxt.Text = $(if ($q) { 'Ничего не нашлось' } else { 'Пока пусто — скопируй что-нибудь' })
    $E.clipHint.Visibility = 'Visible'
  } else { $E.clipHint.Visibility = 'Collapsed' }
}
$E.clipQ.Add_TextChanged({ if ($ui.expanded -and $ui.tab -eq 'clip') { Build-Clip $false } })
$E.btnClipClear.Add_Click({
  $sync.ClipClear = $true
  Later 200 { $ui.clipRef = $null; Build-Clip $true }
})

# ============================================================
#  Shelf: files wait here; drag them in from anywhere, drag them out to any window
# ============================================================
$SHELF_MAX = 24
$ui.shelfHot = $false; $ui.dragged = $false; $ui.dragStart = $null
$script:imgExt = @('.png', '.jpg', '.jpeg', '.bmp', '.gif', '.webp', '.tif', '.tiff')

function Shelf-Icon([string]$path) {
  # picture -> its own thumbnail, anything else -> the Windows icon
  try {
    $isDir = [IO.Directory]::Exists($path)
    $ext = [IO.Path]::GetExtension($path).ToLower()
    if ((-not $isDir) -and ($script:imgExt -contains $ext)) {
      $bi = New-Object System.Windows.Media.Imaging.BitmapImage
      $bi.BeginInit()
      $bi.UriSource = New-Object System.Uri ($path)
      $bi.DecodePixelWidth = 96
      $bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
      $bi.EndInit(); $bi.Freeze()
      return @{ src = $bi; thumb = $true }
    }
    $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($path)
    if ($ico) {
      $bs = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($ico.Handle, [System.Windows.Int32Rect]::Empty, [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
      $bs.Freeze()
      $ico.Dispose()
      return @{ src = $bs; thumb = $false }
    }
  } catch {}
  return $null
}
function New-ShelfTile([string]$path) {
  $wrap = New-Object System.Windows.Controls.Grid
  $wrap.Width = 104.0; $wrap.Height = 96.0
  $wrap.Margin = [System.Windows.Thickness]::new(0, 0, 8, 8)
  $btn = New-Object System.Windows.Controls.Button
  $btn.Style = $E.shelfHost.FindResource('SiteTile')
  $btn.Tag = $path
  $stack = New-Object System.Windows.Controls.StackPanel
  $stack.HorizontalAlignment = 'Center'; $stack.VerticalAlignment = 'Center'
  $holder = New-Object System.Windows.Controls.Border
  $holder.Width = 44; $holder.Height = 44; $holder.CornerRadius = [System.Windows.CornerRadius]::new(11)
  $holder.Background = New-Br '#1FFFFFFF'
  $holder.ClipToBounds = $true
  $ic = Shelf-Icon $path
  if ($ic) {
    $img = New-Object System.Windows.Controls.Image
    $img.Source = $ic.src
    [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($img, [System.Windows.Media.BitmapScalingMode]::HighQuality)
    if ($ic.thumb) { $img.Stretch = 'UniformToFill' } else { $img.Width = 30; $img.Height = 30; $img.Stretch = 'Uniform' }
    $img.HorizontalAlignment = 'Center'; $img.VerticalAlignment = 'Center'
    $holder.Child = $img
  } else {
    $lt = New-Tb $(if ([IO.Directory]::Exists($path)) { '📁' } else { '▭' }) 22 $script:brWhite
    $lt.HorizontalAlignment = 'Center'; $lt.VerticalAlignment = 'Center'
    $holder.Child = $lt
  }
  $nmText = [IO.Path]::GetFileName($path.TrimEnd('\'))
  if (-not $nmText) { $nmText = $path }
  $nm = New-Tb $nmText 11 (New-Br '#E6FFFFFF') 'SemiBold'
  $nm.MaxWidth = 92; $nm.TextTrimming = 'CharacterEllipsis'; $nm.HorizontalAlignment = 'Center'
  $nm.Margin = [System.Windows.Thickness]::new(0, 7, 0, 0)
  $nm.ToolTip = $path
  [void]$stack.Children.Add($holder); [void]$stack.Children.Add($nm)
  $btn.Content = $stack
  $btn.Add_PreviewMouseLeftButtonDown({ param($snd, $ev) $ui.dragged = $false; $ui.dragStart = $ev.GetPosition($null) })
  $btn.Add_PreviewMouseMove({
    param($snd, $ev)
    if ($ev.LeftButton -ne [System.Windows.Input.MouseButtonState]::Pressed -or $null -eq $ui.dragStart) { return }
    $p = $ev.GetPosition($null)
    if ([Math]::Abs($p.X - $ui.dragStart.X) -lt 8 -and [Math]::Abs($p.Y - $ui.dragStart.Y) -lt 8) { return }
    $ui.dragStart = $null; $ui.dragged = $true
    Shelf-DragOut $snd
  })
  $btn.Add_Click({
    param($snd, $ev)
    if ($ui.dragged) { $ui.dragged = $false; return }
    Shelf-Open ([string]$snd.Tag)
  })
  [void]$wrap.Children.Add($btn)
  $x = New-XButton 20.0
  $x.HorizontalAlignment = 'Right'; $x.VerticalAlignment = 'Top'
  $x.Margin = [System.Windows.Thickness]::new(0, 4, 4, 0)
  $x.Tag = $path
  $x.Add_Click({ param($snd, $ev) $ev.Handled = $true; Shelf-Remove ([string]$snd.Tag) $snd.Parent })
  [void]$wrap.Children.Add($x)
  $wrap.Add_MouseEnter({ param($snd, $ev) FadeTo $snd.Children[1] 1.0 140 })
  $wrap.Add_MouseLeave({ param($snd, $ev) FadeTo $snd.Children[1] 0.0 200 })
  $wrap.RenderTransformOrigin = [System.Windows.Point]::new(0.5, 0.5)
  return $wrap
}
function Shelf-Existing {
  $out = @()
  foreach ($p in @($cfg.shelf)) {
    if ($p -and ([IO.File]::Exists([string]$p) -or [IO.Directory]::Exists([string]$p))) { $out += [string]$p }
  }
  return $out
}
function Build-Shelf([bool]$animate = $true, [string]$onlyPath = '') {
  $list = @(Shelf-Existing)
  if ($list.Count -ne @($cfg.shelf).Count) { $cfg.shelf = $list; Request-Save }
  $h = $E.shelfHost
  $h.Children.Clear()
  $i = 0
  foreach ($p in $list) {
    $t = New-ShelfTile $p
    [void]$h.Children.Add($t)
    if ($animate -and (($onlyPath -eq '') -or ($p -eq $onlyPath))) { Pop-In $t $i 8 }
    $i++
  }
  $E.shelfHint.Visibility = $(if ($i -eq 0) { 'Visible' } else { 'Collapsed' })
  $E.btnShelfClear.Visibility = $(if ($i -eq 0) { 'Collapsed' } else { 'Visible' })
  $E.shelfLabel.Text = $(if ($i -eq 0) { 'ПОЛКА ДЛЯ ФАЙЛОВ · ПЕРЕТАЩИ СЮДА' } else { "ПОЛКА · $i · КЛИК — ОТКРЫТЬ · ТАЩИ В ЛЮБОЕ ОКНО" })
}
function Shelf-Open([string]$path) {
  try { [void][System.Diagnostics.Process]::Start($path) }
  catch { Log "shelf open: $($_.Exception.Message)"; return }
  Collapse
}
function Shelf-Remove([string]$path, $tile) {
  $cfg.shelf = @($cfg.shelf | Where-Object { $_ -ne $path })
  Request-Save
  if ($tile) { Pop-Out $tile 170 }
  Later 190 { if ($ui.expanded -and $ui.tab -eq 'shelf') { Build-Shelf $false } }
}
function Shelf-DragOut($btn) {
  try {
    $path = [string]$btn.Tag
    $files = New-Object System.Collections.Specialized.StringCollection
    [void]$files.Add($path)
    $data = New-Object System.Windows.DataObject
    $data.SetFileDropList($files)
    $eff = [System.Windows.DragDrop]::DoDragDrop($btn, $data, [System.Windows.DragDropEffects]::Copy -bor [System.Windows.DragDropEffects]::Link)
    if ($eff -ne [System.Windows.DragDropEffects]::None) { Later 150 { Collapse } }
  } catch { Log "drag out: $($_.Exception.Message)" }
}
# add files that were dropped (from the Explorer, the desktop, ...)
function Shelf-Add([string[]]$paths) {
  $added = @()
  $cur = @($cfg.shelf)
  foreach ($p in $paths) {
    if (-not $p) { continue }
    if (-not ([IO.File]::Exists($p) -or [IO.Directory]::Exists($p))) { continue }
    if ($cur -contains $p) { $cur = @(@($p) + @($cur | Where-Object { $_ -ne $p })); continue }
    $cur = @(@($p) + $cur)
    $added += $p
  }
  $cfg.shelf = @($cur | Select-Object -First $SHELF_MAX)
  Request-Save
  return $added
}
function Shelf-Dropped($data) {
  $paths = @()
  try {
    if ($data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) { $paths = @($data.GetData([System.Windows.DataFormats]::FileDrop)) }
  } catch {}
  if ($paths.Count -eq 0) { return }
  $added = @(Shelf-Add $paths)
  if ($ui.expanded -and (-not $ui.closing)) {
    if ($ui.tab -ne 'shelf' -and $E.tabBar.Visibility -eq 'Visible') { Set-Tab 'shelf' }
    else { Build-Shelf $true $(if ($added.Count -gt 0) { [string]$added[0] } else { '' }) }
  } else {
    $n = $paths.Count
    $E.cDoneTxt.Text = $(if ($n -eq 1) { 'На полке: ' + [IO.Path]::GetFileName(([string]$paths[0]).TrimEnd('\')) } else { "На полке: $n файла" })
    if ($E.cDoneTxt.Text.Length -gt 26) { $E.cDoneTxt.Text = $E.cDoneTxt.Text.Substring(0, 25) + '…' }
    $ui.doneUntil = (Now-Ms) + 2200
    Update-Mode
  }
}
function Shelf-Glow([bool]$on) {
  if ($ui.shelfHot -eq $on) { return }
  $ui.shelfHot = $on
  Anim-Color $script:shelfDashBr $(if ($on) { [System.Windows.Media.Color]::FromArgb(0xE0, 255, 255, 255) } else { [System.Windows.Media.Color]::FromArgb(0x44, 255, 255, 255) }) 180
  Anim-Color $script:shelfFillBr $(if ($on) { [System.Windows.Media.Color]::FromArgb(0x2A, 255, 255, 255) } else { [System.Windows.Media.Color]::FromArgb(0x0F, 255, 255, 255) }) 200
  $st = $E.shelfZone.RenderTransform
  Anim-To $st ([System.Windows.Media.ScaleTransform]::ScaleXProperty) $(if ($on) { 1.012 } else { 1.0 }) 260 $script:easeBack
  Anim-To $st ([System.Windows.Media.ScaleTransform]::ScaleYProperty) $(if ($on) { 1.012 } else { 1.0 }) 260 $script:easeBack
}
$script:shelfDashBr = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(0x44, 255, 255, 255))
$script:shelfFillBr = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(0x0F, 255, 255, 255))
$E.shelfDash.Stroke = $script:shelfDashBr
$E.shelfFill.Fill = $script:shelfFillBr
$E.Island.AllowDrop = $true
$E.shelfZone.AllowDrop = $true
$E.Island.Add_DragEnter({
  param($snd, $ev)
  if ($ev.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
    $ev.Effects = [System.Windows.DragDropEffects]::Copy
    if (-not $ui.expanded) { $ui.hover = $true; Retarget 0.30 0.80 }
  } else { $ev.Effects = [System.Windows.DragDropEffects]::None }
  $ev.Handled = $true
})
$E.Island.Add_DragOver({
  param($snd, $ev)
  if ($ev.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) { $ev.Effects = [System.Windows.DragDropEffects]::Copy }
  else { $ev.Effects = [System.Windows.DragDropEffects]::None }
  $ev.Handled = $true
})
$E.Island.Add_DragLeave({
  param($snd, $ev)
  if (-not $ui.expanded) { $ui.hover = $false; Retarget 0.34 0.86 }
  Shelf-Glow $false
})
$E.Island.Add_Drop({
  param($snd, $ev)
  Shelf-Glow $false
  if (-not $ui.expanded) { $ui.hover = $false }
  try { Shelf-Dropped $ev.Data } catch { Log "drop: $($_.Exception.Message)" }
  $ev.Handled = $true
})
$E.shelfZone.Add_DragEnter({ param($snd, $ev) if ($ev.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) { Shelf-Glow $true } })
$E.shelfZone.Add_DragLeave({ param($snd, $ev) Shelf-Glow $false })
$E.btnShelfClear.Add_Click({
  $cfg.shelf = @()
  Request-Save
  foreach ($t in @($E.shelfHost.Children)) { Pop-Out $t 170 }
  Later 200 { Build-Shelf $false }
})

# ---- screenshot / area / screen recording ----
function Shot-Done([string]$msg, [string]$file) {
  if ($file) { try { [void](Shelf-Add @($file)) } catch {} }
  $E.cDoneTxt.Text = $msg
  $ui.doneUntil = (Now-Ms) + 2400
  try { [System.Media.SystemSounds]::Asterisk.Play() } catch {}
  Update-Mode
}
function Take-Screenshot {
  if ($ui.expanded) { Collapse }
  # the island must be gone from the picture: hide the window for a blink.
  # The picture goes to the clipboard FIRST and is saved to the island's own folder (not to "Pictures": Windows
  # "Controlled folder access" / antivirus blocks PowerShell from writing there). The folder can be changed with "shotDir" in settings.json.
  Later 520 {
    $bmp = $null
    try {
      [DI.Native]::Visible($mainHwnd, $false)
      Start-Sleep -Milliseconds 140
      $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
      $bmp = New-Object System.Drawing.Bitmap ($b.Width, $b.Height)
      $gr = [System.Drawing.Graphics]::FromImage($bmp)
      try { $gr.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size) } finally { $gr.Dispose() }
    } catch {
      Log "screenshot capture: $($_.Exception.Message)"
      if ($bmp) { $bmp.Dispose(); $bmp = $null }
    }
    try { [DI.Native]::Visible($mainHwnd, (-not $ui.hidden)) } catch {}
    if ($bmp) {
      $inClip = $false
      try { [System.Windows.Forms.Clipboard]::SetImage($bmp); $inClip = $true } catch { Log "screenshot clipboard: $($_.Exception.Message)" }
      $file = ''
      try {
        $dir = [Environment]::ExpandEnvironmentVariables([string]$cfg.shotDir)
        if (-not $dir) { $dir = Join-Path $DataDir 'Screenshots' }
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $f = Join-Path $dir ('Island_' + (Get-Date).ToString('yyyyMMdd_HHmmss') + '.png')
        $bmp.Save($f, [System.Drawing.Imaging.ImageFormat]::Png)
        $file = $f
        # keep the folder small: the newest 40 pictures stay
        try { Get-ChildItem $dir -Filter 'Island_*.png' | Sort-Object LastWriteTime -Descending | Select-Object -Skip 40 | Remove-Item -Force -ErrorAction SilentlyContinue } catch {}
      } catch { Log "screenshot save: $($_.Exception.Message)" }
      $bmp.Dispose()
      if ($file) { Shot-Done 'Скриншот готов' $file }
      elseif ($inClip) { Shot-Done 'Скриншот в буфере' '' }
      else { Shot-Done 'Не получилось' '' }
    } else { Shot-Done 'Не получилось' '' }
  }
}
$E.btnShot.Add_Click({ Take-Screenshot })
$E.btnSnip.Add_Click({
  Collapse
  # Win + Shift + S : the system "snip" overlay
  Later 650 { try { [DI.Native]::Chord([byte[]](0x5B, 0x10, 0x53)) } catch { Log "snip: $($_.Exception.Message)" } }
})
$E.btnRec.Add_Click({
  Collapse
  # Win + Alt + R : Xbox Game Bar starts / stops recording (Game Bar must be on in Windows settings)
  Later 550 { try { [DI.Native]::Chord([byte[]](0x5B, 0x12, 0x52)) } catch { Log "record: $($_.Exception.Message)" } }
})

# ============================================================
#  View: glass themes
# ============================================================
function Theme-Chip([string]$key, $th, [bool]$sel) {
  $b = New-Object System.Windows.Controls.Button
  $b.Style = $E.themeHost.FindResource('PillBtn')
  $b.Margin = [System.Windows.Thickness]::new(0, 0, 8, 8)
  $b.Padding = [System.Windows.Thickness]::new(12, 7, 14, 7)
  $b.Tag = $key
  $spn = New-Object System.Windows.Controls.StackPanel
  $spn.Orientation = 'Horizontal'
  $dot = New-Object System.Windows.Shapes.Ellipse
  $dot.Width = 12; $dot.Height = 12; $dot.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
  if ($th[1]) {
    $dot.Fill = New-Br ('#FF{0:X2}{1:X2}{2:X2}' -f [int]$th[1][0], [int]$th[1][1], [int]$th[1][2])
  } else {
    $lg = New-Object System.Windows.Media.LinearGradientBrush
    $lg.StartPoint = [System.Windows.Point]::new(0, 0); $lg.EndPoint = [System.Windows.Point]::new(1, 1)
    foreach ($pair in @(@('#FF7CC4FF', 0.0), @('#FFBF5AF2', 0.5), @('#FFFF9F0A', 1.0))) {
      $gs = New-Object System.Windows.Media.GradientStop ([System.Windows.Media.ColorConverter]::ConvertFromString($pair[0]), [double]$pair[1])
      $lg.GradientStops.Add($gs)
    }
    $dot.Fill = $lg
  }
  $lb = New-Object System.Windows.Controls.TextBlock
  $lb.Text = [string]$th[0]; $lb.VerticalAlignment = 'Center'
  [void]$spn.Children.Add($dot); [void]$spn.Children.Add($lb)
  $b.Content = $spn
  $b.Background = New-Object System.Windows.Media.SolidColorBrush $(if ($sel) { [System.Windows.Media.Color]::FromRgb(242, 242, 242) } else { [System.Windows.Media.Color]::FromArgb(0x22, 255, 255, 255) })
  $b.Foreground = New-Object System.Windows.Media.SolidColorBrush $(if ($sel) { [System.Windows.Media.Color]::FromRgb(16, 16, 20) } else { [System.Windows.Media.Color]::FromRgb(255, 255, 255) })
  $b.Add_Click({
    param($snd, $ev)
    $cfg.theme = [string]$snd.Tag
    Request-Save
    Sync-Themes
    Set-PillTint 340 $false
    Set-Wash
  })
  return $b
}
function Sel-Look($b, [bool]$on) {
  Anim-Color $b.Background $(if ($on) { [System.Windows.Media.Color]::FromRgb(242, 242, 242) } else { [System.Windows.Media.Color]::FromArgb(0x22, 255, 255, 255) }) 260
  Anim-Color $b.Foreground $(if ($on) { [System.Windows.Media.Color]::FromRgb(16, 16, 20) } else { [System.Windows.Media.Color]::FromRgb(255, 255, 255) }) 260
}
function Sync-Themes {
  $h = $E.themeHost
  $cur = [string]$cfg.theme
  if (-not $THEMES.Contains($cur)) { $cur = 'auto' }
  if ($h.Children.Count -eq 0) {
    $i = 0
    foreach ($k in $THEMES.Keys) {
      $c = Theme-Chip $k $THEMES[$k] ($k -eq $cur)
      [void]$h.Children.Add($c)
      Pop-In $c $i 6
      $i++
    }
    return
  }
  foreach ($c in $h.Children) { Sel-Look $c ([string]$c.Tag -eq $cur) }
}

# ============================================================
#  More: global hotkey (polled, so it works while any app has the focus) + pomodoro dots
# ============================================================
$HOTKEYS = @('Ctrl+Alt+I', 'Ctrl+Alt+Space', 'Ctrl+Shift+Space', 'Ctrl+Alt+D', 'Off')
$script:hkVk = @()
$script:hkMods = @{ ctrl = $false; alt = $false; shift = $false; win = $false }
$script:hkWas = $false
function Set-Hotkey([string]$spec) {
  $cfg.hotkey = $spec
  $script:hkVk = @()
  $script:hkMods = @{ ctrl = $false; alt = $false; shift = $false; win = $false }
  if ((-not $spec) -or $spec -eq 'Off') { return }
  foreach ($part in ($spec -split '\+')) {
    switch ($part.ToLower()) {
      'ctrl' { $script:hkVk += 0x11; $script:hkMods.ctrl = $true }
      'alt' { $script:hkVk += 0x12; $script:hkMods.alt = $true }
      'shift' { $script:hkVk += 0x10; $script:hkMods.shift = $true }
      'win' { $script:hkVk += 0x5B; $script:hkMods.win = $true }
      'space' { $script:hkVk += 0x20 }
      default { if ($part.Length -eq 1) { $script:hkVk += [int][char]($part.ToUpper()) } }
    }
  }
}
function Hk-Tick {
  if ($script:hkVk.Count -eq 0) { return }
  $all = $true
  foreach ($vk in $script:hkVk) { if (-not [DI.Native]::KeyDown([int]$vk)) { $all = $false; break } }
  if ($all) {
    # no extra modifiers (Ctrl+Alt+Shift+I is something else)
    if ((-not $script:hkMods.ctrl) -and [DI.Native]::KeyDown(0x11)) { $all = $false }
    if ((-not $script:hkMods.alt) -and [DI.Native]::KeyDown(0x12)) { $all = $false }
    if ((-not $script:hkMods.shift) -and [DI.Native]::KeyDown(0x10)) { $all = $false }
    if ((-not $script:hkMods.win) -and ([DI.Native]::KeyDown(0x5B) -or [DI.Native]::KeyDown(0x5C))) { $all = $false }
  }
  if ($all -and (-not $script:hkWas)) {
    if ($ui.expanded) { Collapse } else { Expand }
  }
  $script:hkWas = $all
}
$hkTimer = New-Object System.Windows.Threading.DispatcherTimer
$hkTimer.Interval = [TimeSpan]::FromMilliseconds(60)
$hkTimer.Add_Tick({ try { Hk-Tick } catch {} })
Set-Hotkey ([string]$cfg.hotkey)
$hkTimer.Start()
function Sync-Hotkeys {
  $h = $E.hkHost
  $cur = [string]$cfg.hotkey
  if (-not $cur) { $cur = 'Off' }
  if ($h.Children.Count -eq 0) {
    foreach ($k in $HOTKEYS) {
      $b = New-Object System.Windows.Controls.Button
      $b.Style = $h.FindResource('PillBtn')
      $b.Margin = [System.Windows.Thickness]::new(0, 0, 6, 6)
      $b.Padding = [System.Windows.Thickness]::new(11, 5, 11, 5)
      $b.Content = $(if ($k -eq 'Off') { 'Выкл' } else { $k.Replace('Space', 'Пробел') })
      $b.Tag = $k
      $b.Background = New-Object System.Windows.Media.SolidColorBrush $(if ($k -eq $cur) { [System.Windows.Media.Color]::FromRgb(242, 242, 242) } else { [System.Windows.Media.Color]::FromArgb(0x22, 255, 255, 255) })
      $b.Foreground = New-Object System.Windows.Media.SolidColorBrush $(if ($k -eq $cur) { [System.Windows.Media.Color]::FromRgb(16, 16, 20) } else { [System.Windows.Media.Color]::FromRgb(255, 255, 255) })
      $b.Add_Click({
        param($snd, $ev)
        Set-Hotkey ([string]$snd.Tag)
        Request-Save
        Sync-Hotkeys
      })
      [void]$h.Children.Add($b)
    }
    return
  }
  foreach ($c in $h.Children) { Sel-Look $c ([string]$c.Tag -eq $cur) }
}

# pomodoro dots: filled = finished focus rounds in the current set of four
$script:pomoBr = @{}
foreach ($n in 1..4) {
  $br = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(0x33, 255, 255, 255))
  $E["pm$n"].Fill = $br
  $script:pomoBr[$n] = $br
}
function Sync-Pomo {
  $rounds = [int]$ui.pomoRound
  $filled = $rounds % 4
  if ($rounds -gt 0 -and $filled -eq 0) { $filled = 4 }
  foreach ($n in 1..4) {
    $on = ($n -le $filled)
    Anim-Color $script:pomoBr[$n] $(if ($on) { [System.Windows.Media.Color]::FromRgb(255, 159, 10) } else { [System.Windows.Media.Color]::FromArgb(0x33, 255, 255, 255) }) 300
  }
  if ($rounds -gt 0) { $E.pomoInfo.Text = "Закончено кругов фокуса: $rounds. Следующий круг — 25 минут, потом отдых 5." }
  else { $E.pomoInfo.Text = '25 мин работы, 5 мин отдыха. После четырёх кругов — длинный перерыв 15 мин.' }
  $E.btnPomo.Content = $(if ($rounds -gt 0) { 'Новый цикл' } else { 'Начать фокус' })
}

} catch { Log ("init c4d failed: " + $_.Exception.Message + " @ line " + $_.InvocationInfo.ScriptLineNumber) }

# ============================================================
#  Pill texts: what the collapsed pill says.
#  Music: title / artist / "artist — title" (the pill is exactly as wide as the text needs).
#  Idle: nothing (clock on hover) / clock / date.
# ============================================================
$PILL_MUSIC = [ordered]@{ title = 'Название'; artist = 'Исполнитель'; both = 'Исполнитель — название' }
$PILL_IDLE = [ordered]@{ hover = 'Пусто'; clock = 'Часы'; date = 'Дата' }
$MONTHS_RU = @('янв', 'фев', 'мар', 'апр', 'мая', 'июн', 'июл', 'авг', 'сен', 'окт', 'ноя', 'дек')
$DAYS_RU = @('вс', 'пн', 'вт', 'ср', 'чт', 'пт', 'сб')

function Pill-Text($st) {
  $t = ([string]$st.title).Trim()
  $a = ([string]$st.artist).Trim()
  $m = [string]$cfg.pillMusic
  if ($m -eq 'artist' -and $a) { return $a }
  if ($m -eq 'both' -and $a) { return ($a + ' — ' + $t) }
  return $t
}
function Pill-Sig($st) { return (([string]$st.title) + '|' + ([string]$st.artist) + '|' + [string]$cfg.pillMusic) }
# short text = narrow pill, long text = wide pill (the glass springs to the new width)
function Set-PillText($st) {
  $ui.pillSig = Pill-Sig $st
  $E.cMusicTxt.Text = (Pill-Text $st)
  $w = 248.0
  try {
    $E.cMusicTxt.Measure([System.Windows.Size]::new([double]::PositiveInfinity, 40.0))
    $w = [Math]::Ceiling(66.0 + [double]$E.cMusicTxt.DesiredSize.Width)
  } catch { Log "pill measure: $($_.Exception.Message)" }
  if ($w -lt 120.0) { $w = 120.0 }
  if ($w -gt 340.0) { $w = 340.0 }
  $old = [double]$SIZES.music[0]
  $SIZES.music[0] = $w
  $E.cMusic.Width = $w
  if ((-not $ui.expanded) -and $ui.sizeKey -eq 'music' -and [Math]::Abs($old - $w) -gt 0.5) { Retarget 0.38 0.84 }
}
function Pill-Refresh {
  $st = $sync.State
  if ($st -and $st.mode -eq 'music' -and $st.title) { Set-PillText $st }
}
function Idle-Str([string]$m) {
  $d = Get-Date
  if ($m -eq 'date') { return ($DAYS_RU[[int]$d.DayOfWeek] + ', ' + [string]$d.Day + ' ' + $MONTHS_RU[$d.Month - 1]) }
  return $d.ToString('HH:mm')
}
function Update-IdleText {
  $m = [string]$cfg.pillIdle
  if ($m -eq 'clock' -or $m -eq 'date') {
    $s = Idle-Str $m
    if ($E.cIdleTxt.Text -ne $s) { $E.cIdleTxt.Text = $s }
    if (-not $ui.idleShown) { $ui.idleShown = $true; FadeTo $E.cIdleTxt 1.0 220 }
  } else {
    if ($ui.idleShown) { $ui.idleShown = $false; if (-not $ui.hover) { FadeTo $E.cIdleTxt 0.0 150 } }
    if ($ui.hover -and $ui.mode -eq 'idle') { $E.cIdleTxt.Text = (Get-Date).ToString('HH:mm') }
  }
}
function Pill-Chip([string]$grp, [string]$key, [string]$text, [bool]$sel) {
  $b = New-Object System.Windows.Controls.Button
  $b.Style = $E.pillMusicHost.FindResource('PillBtn')
  $b.Margin = [System.Windows.Thickness]::new(0, 0, 6, 6)
  $b.Padding = [System.Windows.Thickness]::new(11, 5, 11, 5)
  $b.Content = $text
  $b.Tag = ($grp + ':' + $key)
  $b.Background = New-Object System.Windows.Media.SolidColorBrush $(if ($sel) { [System.Windows.Media.Color]::FromRgb(242, 242, 242) } else { [System.Windows.Media.Color]::FromArgb(0x22, 255, 255, 255) })
  $b.Foreground = New-Object System.Windows.Media.SolidColorBrush $(if ($sel) { [System.Windows.Media.Color]::FromRgb(16, 16, 20) } else { [System.Windows.Media.Color]::FromRgb(255, 255, 255) })
  $b.Add_Click({
    param($snd, $ev)
    $parts = ([string]$snd.Tag).Split(':')
    if ($parts[0] -eq 'm') { $cfg.pillMusic = $parts[1]; Pill-Refresh }
    else { $cfg.pillIdle = $parts[1]; Update-IdleText }
    Request-Save
    Sync-PillOpts
  })
  return $b
}
function Sync-PillOpts {
  $curM = [string]$cfg.pillMusic
  $curI = [string]$cfg.pillIdle
  $hm = $E.pillMusicHost; $hi = $E.pillIdleHost
  if ($hm.Children.Count -eq 0) {
    foreach ($k in $PILL_MUSIC.Keys) { [void]$hm.Children.Add((Pill-Chip 'm' ([string]$k) ([string]$PILL_MUSIC[$k]) ($k -eq $curM))) }
    foreach ($k in $PILL_IDLE.Keys) { [void]$hi.Children.Add((Pill-Chip 'i' ([string]$k) ([string]$PILL_IDLE[$k]) ($k -eq $curI))) }
    return
  }
  foreach ($c in $hm.Children) { Sel-Look $c ([string]$c.Tag -eq ('m:' + $curM)) }
  foreach ($c in $hi.Children) { Sel-Look $c ([string]$c.Tag -eq ('i:' + $curI)) }
}

# ============================================================
#  Poll (250 ms): worker state -> UI
# ============================================================
function Update-Battery($st) {
  if (-not $st.hasBatt) { return }
  $now = Now-Ms
  $chg = [bool]$st.charging
  if (-not $ui.battInit) { $ui.battInit = $true; $ui.lastCharging = $chg }
  else {
    if ($chg -and (-not $ui.lastCharging) -and $cfg.charge) { $ui.chargeLow = $false; $ui.chargeUntil = $now + 4200 }
    $ui.lastCharging = $chg
  }
  if ((-not $chg) -and $st.batt -le 15 -and (-not $ui.lowShown) -and $cfg.charge) {
    $ui.lowShown = $true; $ui.chargeLow = $true; $ui.chargeUntil = $now + 5200
  }
  if ($chg -or $st.batt -gt 20) { $ui.lowShown = $false }
  $E.cChargeTxt.Text = "$($st.batt)%"
  $E.cChargeIco.Fill = if ($ui.chargeLow) { $script:brRed } else { $script:brGreen }
}

function Update-Volume {
  $mu = $false
  $v = [DI.Vol]::GetEx([ref]$mu)
  if ($v -lt 0) { return }
  $first = (-not $ui.volInit)
  $ui.volInit = $true
  $changed = $first -or ([Math]::Abs($v - $ui.lastVol) -gt 0.004) -or ($mu -ne $ui.lastMute)
  if ($changed) {
    $E.cVolFill.Width = if ($mu) { 0.0 } else { 130.0 * $v }
    $vis = if ($mu) { 'Visible' } else { 'Collapsed' }
    $nvis = if ($mu) { 'Collapsed' } else { 'Visible' }
    $E.cVolMute.Visibility = $vis; $E.cVolWave.Visibility = $nvis
    $E.muteX.Visibility = $vis; $E.muteWave.Visibility = $nvis
    $E.mute2X.Visibility = $vis; $E.mute2Wave.Visibility = $nvis
    if ((-not $first) -and (-not $ui.expanded)) { $ui.volUntil = (Now-Ms) + 1700 }
  }
  $ui.lastVol = $v; $ui.lastMute = $mu
  # keep the slider of the open tab in step with the system volume (keys, other apps); a drag in progress is never overwritten
  if ($ui.expanded -and (-not $ui.closing)) {
    $sid = $null; $pt = $null
    if ($ui.tab -eq 'music') { $sid = 'vol'; $pt = $E.volPct } elseif ($ui.tab -eq 'sound') { $sid = 'mvol'; $pt = $E.mvolPct }
    if ($sid -and (-not $SL[$sid].drag)) {
      if (([Math]::Abs($SL[$sid].frac - $v) -gt 0.004) -or (-not $ui.vs[$sid])) {
        Slider-Set $sid $v ([bool]$ui.vs[$sid])
        $pt.Text = "$([int][Math]::Round($v * 100.0))%"
        $ui.vs[$sid] = $true
      }
    }
  }
}

function Set-Art($bytes) {
  try {
    if ($bytes) {
      $ms = New-Object System.IO.MemoryStream (,([byte[]]$bytes))
      $bi = New-Object System.Windows.Media.Imaging.BitmapImage
      $bi.BeginInit(); $bi.StreamSource = $ms; $bi.CacheOption = 'OnLoad'; $bi.EndInit(); $bi.Freeze()
      $ms.Dispose()
      $E.artS.ImageSource = $bi
      $E.artB.ImageSource = $bi
      foreach ($ab in @($E.artS, $E.artB)) {
        $aa = New-Object System.Windows.Media.Animation.DoubleAnimation
        $aa.From = 0; $aa.To = 1
        $aa.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(300))
        $aa.EasingFunction = $script:easeOut
        $ab.BeginAnimation([System.Windows.Media.Brush]::OpacityProperty, $aa)
      }
    } else {
      $E.artS.ImageSource = $null; $E.artB.ImageSource = $null
    }
  } catch { Log "art: $($_.Exception.Message)" }
}

# --- play / pause glyph on the big button: the two shapes cross-morph (fade + scale) ---
function Set-PlayGlyph([bool]$playing, [bool]$animate) {
  $ms = $(if ($animate) { 180 } else { 1 })
  $pairs = @(
    @($(if ($playing) { $E.icoPause } else { $E.icoPlay }), 1.0, 1.0),
    @($(if ($playing) { $E.icoPlay } else { $E.icoPause }), 0.0, 0.55)
  )
  foreach ($pr in $pairs) {
    $g = $pr[0]
    $ao = New-Object System.Windows.Media.Animation.DoubleAnimation
    $ao.To = [double]$pr[1]; $ao.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds($ms))
    $g.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $ao)
    foreach ($axis in @([System.Windows.Media.ScaleTransform]::ScaleXProperty, [System.Windows.Media.ScaleTransform]::ScaleYProperty)) {
      $as = New-Object System.Windows.Media.Animation.DoubleAnimation
      $as.To = [double]$pr[2]; $as.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds($ms))
      $as.EasingFunction = $script:easeOut
      $g.RenderTransform.BeginAnimation($axis, $as)
    }
  }
}

# the whole island reflects play / pause: button glyph, equalizer <-> pause mark in the pill, dimmed title
function Set-PlayState([bool]$playing) {
  $first = ($null -eq $ui.shownPlaying)
  $ui.playing = $playing
  $ui.shownPlaying = $playing
  Set-PlayGlyph $playing (-not $first)
  if ($playing) {
    FadeTo $E.cMusicTxt 1.0 200
    FadeTo $E.wavePanel 1.0 160
    FadeTo $E.pausePanel 0.0 120
    if ($ui.waveStarted -and $ui.wavePaused) { WaveResume; $ui.wavePaused = $false }
  } else {
    FadeTo $E.cMusicTxt 0.6 200
    FadeTo $E.wavePanel 0.0 120
    FadeTo $E.pausePanel 1.0 160
    if ($ui.waveStarted -and (-not $ui.wavePaused)) { WavePause; $ui.wavePaused = $true }
  }
}

# a short nudge of the skip icon in its direction
function Nudge-Icon($path, [double]$dx) {
  try {
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation
    $a.From = 0; $a.To = $dx; $a.AutoReverse = $true
    $a.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(110))
    $a.EasingFunction = $script:easeOut
    $path.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $a)
  } catch {}
}

# new title fades in instead of snapping
function Pop-Title([double]$pillOpacity) {
  try {
    foreach ($pr in @(@($E.cMusicTxt, $pillOpacity), @($E.mTitle, 1.0), @($E.mArtist, 1.0))) {
      $a = New-Object System.Windows.Media.Animation.DoubleAnimation
      $a.From = 0; $a.To = [double]$pr[1]
      $a.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(240))
      $a.EasingFunction = $script:easeOut
      $pr[0].BeginAnimation([System.Windows.UIElement]::OpacityProperty, $a)
    }
  } catch {}
}

function Update-MusicUi($st) {
  $real = ($st.status -eq 'Playing' -or $st.status -eq 'Buffering')
  $playing = $real
  # after a click the UI shows the wanted state at once; the real state is ignored until it agrees (or 1.5 s pass)
  $tn = Now-Ms
  if ($tn -lt $ui.optUntil) {
    if ($real -eq $ui.optPlaying) { $ui.optUntil = 0.0 } else { $playing = $ui.optPlaying }
  }
  if ($st.title -ne $ui.lastTitle) {
    $hadTitle = ($ui.lastTitle -ne '')
    $ui.lastTitle = $st.title
    Set-PillText $st
    $E.mTitle.Text = $st.title
    $E.mArtist.Text = if ($st.artist) { $st.artist } else { ' ' }
    if ($hadTitle) { Pop-Title $(if ($playing) { 1.0 } else { 0.6 }) }
  }
  # the artist can arrive a moment after the title, or the person picks another pill text: the pill follows
  if ((Pill-Sig $st) -ne $ui.pillSig) { Set-PillText $st }
  $artTxt = $(if ($st.artist) { [string]$st.artist } else { ' ' })
  if ($E.mArtist.Text -ne $artTxt) { $E.mArtist.Text = $artTxt }
  if ((-not [object]::ReferenceEquals($st.art, $ui.lastArt)) -or ($st.artKey -ne $ui.lastArtKey)) {
    $ui.lastArt = $st.art; $ui.lastArtKey = $st.artKey
    Set-Art $st.art
    $ui.tint = $st.tint
    Set-PillTint
    Set-Wash
  }
  if (($null -eq $ui.shownPlaying) -or ($playing -ne $ui.shownPlaying)) { Set-PlayState $playing }
  if ((-not $playing) -and $ui.waveStarted -and (-not $ui.wavePaused)) { WavePause; $ui.wavePaused = $true }
  if ($playing -and $ui.wavePaused) { WaveResume; $ui.wavePaused = $false }
  if ($st.len -gt 0) {
    $ui.len = [double]$st.len
    $pos = [double]$st.pos
    if ($playing) { $pos += ([DateTime]::UtcNow - $st.ts).TotalSeconds }
    $now = Now-Ms
    if ($now -lt $ui.seekHold) {
      $pos = $ui.seekPos
      if ($playing) { $pos += ($now - $ui.seekAt) / 1000.0 }
    }
    if ($pos -gt $st.len) { $pos = [double]$st.len }
    # some players report position 0 for a moment (a refresh of their timeline): the progress bar and the lyrics
    # keep their own clock for about a second before they believe it. A new track or a seek made here is not affected.
    if ($now -ge $ui.seekHold -and [string]$st.title -ceq [string]$ui.posTitle -and $pos -lt 1.5 -and $ui.lastPos -gt 10.0) {
      $ui.zeroHits++
      if ($ui.zeroHits -lt 7) { $pos = [double]$ui.lastPos; if ($playing) { $pos += 0.12 } }
    } else { $ui.zeroHits = 0 }
    $ui.posTitle = [string]$st.title
    # SMTC updates lazily: ignore small backward jumps, real seeks are bigger
    $drop = $ui.lastPos - $pos
    if ($drop -gt 0.6 -and $drop -lt 5.0 -and $st.title -eq $ui.lastTitle -and $now -ge $ui.seekHold) { $pos = $ui.lastPos }
    $ui.lastPos = $pos
    if ($ui.expanded -and $ui.tab -eq 'music' -and (-not $SL.prog.drag)) {
      Slider-Set 'prog' ($pos / $st.len) $false
      $E.mPos.Text = Format-Time $pos
      $E.mRem.Text = '-' + (Format-Time ($st.len - $pos))
    }
  }
}

function Poll-Tick {
  $ln = $null
  while ($sync.Log.TryDequeue([ref]$ln)) { Log $ln }

  if ($cfg.hideFull) { Set-Hidden ([DI.Native]::FullscreenBusy()) }
  elseif ($ui.hidden) { Set-Hidden $false }

  $st = $sync.State
  if ($st) {
    $ui.musicOn = ($st.mode -eq 'music')
    Update-Battery $st
  }
  Update-Volume
  Update-Mode

  if ($st -and $ui.musicOn) {
    Update-MusicUi $st
  } elseif ($ui.tint -or $ui.lastArtKey -ne '#') {
    $ui.tint = $null; $ui.lastArt = $null; $ui.lastArtKey = '#'; $ui.shownPlaying = $null; $ui.lastTitle = ''
    Set-Art $null
    Set-PillTint
    Set-Wash
  }

  if ($ui.expanded -and (-not $ui.closing)) {
    try {
      switch ($ui.tab) {
        'music'   { Lyr-Sync; Lyr-Poll; Lyr-Tick }
        'weather' { Update-WeatherUi }
        'sys'     { Update-SysUi }
        'sound'   { Mixer-Poll }
        'todo'    { Events-Tick }
        'clip'    {
          if (-not [object]::ReferenceEquals($sync.Clip, $ui.clipRef)) { $ui.clipRef = $sync.Clip; Build-Clip $false }
        }
      }
    } catch {
      $ui.tabErr++
      if ($ui.tabErr -lt 8) { Log ("tab-tick " + $ui.tab + ": " + $_.Exception.Message + " @ " + $_.InvocationInfo.ScriptLineNumber) }
    }
  }
  try { Ics-Tick } catch { $ui.tabErr++; if ($ui.tabErr -lt 8) { Log ("ics: " + $_.Exception.Message) } }
  try { Update-IdleText } catch { }
}

$ui.pollErr = 0; $ui.tabErr = 0
$poll = New-Object System.Windows.Threading.DispatcherTimer
$poll.Interval = [TimeSpan]::FromMilliseconds(120)
$poll.Add_Tick({
  try { Poll-Tick }
  catch {
    $ui.pollErr++
    if ($ui.pollErr -lt 6) { Log ("poll: " + $_.Exception.Message + " @ " + $_.InvocationInfo.ScriptLineNumber) }
  }
})

# ============================================================
#  Go
# ============================================================
$window.Add_Closed({ Quit-App })
$window.Show()
Reposition
Apply-Geo
Update-Glass
$ui.sizeKey = 'idle'; $ui.mode = 'idle'
Set-Compact 'idle'
Retarget 0.62 0.72      # soft pop when the island appears
$timerDt.Start(); $poll.Start(); $keep.Start()
Log "running v2.5: scale=$($ui.scale) win=($($ui.winX),$($ui.winY)) glassOn=$($ui.glassOn)"
[void]$app.Run()

try { $sync.Running = $false } catch {}
Log 'bye'
exit 0
