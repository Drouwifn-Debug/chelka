# ============================================================
#  Dynamic Island for Windows  v2.3   (PowerShell 5.1 + WPF, no dependencies)
#  Liquid Glass pill: blurred snapshot of the screen behind it, clipped to the
#  pill shape, spring morphing, music / sites / system load / clipboard /
#  weather / timer / volume HUD / charging.
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
Log "=== start v2.3  PS $($PSVersionTable.PSVersion)  dir=$ScriptDir"

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
  # sites come back from JSON as objects: normalise them to plain hashtables
  $list = @()
  foreach ($x in @($cfg.sites)) {
    try { if ($x.u) { $list += , @{ n = [string]$x.n; u = [string]$x.u } } } catch {}
  }
  $cfg.sites = $list
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
  Running = $true; State = $null; Clip = $null; Weather = $null
  ClipWrite = ''; ClipClear = $false; Seek = -1.0; Cmd = ''; WxRefresh = $false; City = [string]$cfg.city
  SysOn = $false; Sys = $null
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
if (-not $E.washC0)      { $E.washC0      = $E.WashLayer.Background.GradientStops[0] }
if (-not $E.washC1)      { $E.washC1      = $E.WashLayer.Background.GradientStops[1] }
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
$WIN_W = 720.0; $WIN_H = 580.0; $TOP = 10.0
$SIZES = @{
  idle      = @(116.0, 34.0, 17.0)
  idleHover = @(152.0, 34.0, 17.0)
  music     = @(248.0, 34.0, 17.0)
  timer     = @(160.0, 34.0, 17.0)
  charge    = @(150.0, 34.0, 17.0)
  done      = @(150.0, 34.0, 17.0)
  vol       = @(220.0, 34.0, 17.0)
  panel     = @(540.0, 440.0, 34.0)
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
$BD_W = 540.0; $BD_H = 440.0
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
function Set-PillTint([int]$ms = 320, [bool]$solid = $false) {
  if ($ui.tint) {
    $mr = [double]$ui.tint[0]; $mg = [double]$ui.tint[1]; $mb = [double]$ui.tint[2]; $k = 0.30
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
function Set-Wash {
  if ($ui.tint -and $ui.mode -eq 'music' -and $ui.glassOn) {
    $E.washC0.Color = [System.Windows.Media.Color]::FromArgb(150, [byte]$ui.tint[0], [byte]$ui.tint[1], [byte]$ui.tint[2])
    $E.washC1.Color = [System.Windows.Media.Color]::FromArgb(0, [byte]$ui.tint[0], [byte]$ui.tint[1], [byte]$ui.tint[2])
    FadeTo $E.WashLayer 0.6 400
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
    & $s2.onMove $f
  })
  $hit.Add_MouseMove({
    param($snd, $ev)
    $id2 = $snd.Name -replace 'Hit$', ''
    $s2 = $SL[$id2]
    $x = $ev.GetPosition($snd).X
    $f = Slider-FracAt $s2 $x
    if ($s2.drag) {
      Slider-Set $id2 $f $false
      & $s2.onMove $f
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
      & $s2.onCommit $s2.frac
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
      & $s2.onCommit $s2.frac
    }
  })
  if ($wheel -gt 0) {
    $hit.Add_MouseWheel({
      param($snd, $ev)
      $id2 = $snd.Name -replace 'Hit$', ''
      $s2 = $SL[$id2]
      $nf = $s2.frac + ($ev.Delta / 120.0) * $s2.wheel
      Slider-Set $id2 $nf $true
      & $s2.onMove $s2.frac
      & $s2.onCommit $s2.frac
      $ev.Handled = $true
    })
  }
}

# ============================================================
#  State, navigation, expand / collapse
# ============================================================
$COMPACT_OF = @{ idle = 'cIdle'; music = 'cMusic'; timer = 'cTimer'; charge = 'cCharge'; done = 'cDone'; vol = 'cVol' }
$SECTIONS   = @{ music = 'mMusic'; sites = 'mSites'; sys = 'mSys'; clip = 'mClip'; weather = 'mWeather'; view = 'mView'; more = 'mMore'; timer = 'mTimerRun' }
$TABS       = @{ music = 'tbMusic'; sites = 'tbSites'; sys = 'tbSys'; clip = 'tbClip'; weather = 'tbWeather'; view = 'tbView'; more = 'tbMore' }
$ui.musicOn = $false

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
  Show-Section $tab $animate
  Update-SysOn
  if ($tab -eq 'weather') { Update-WeatherUi }
  if ($tab -eq 'clip') { $ui.clipRef = $null }
  if ($tab -eq 'sites') { Build-Sites }
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
      $ax.From = -240; $ax.To = 700; $ax.Duration = $swDur
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
  $ui.volSynced = $false
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
function Update-WeatherUi {
  $wx = $sync.Weather
  if (-not $wx) { return }
  if ([object]::ReferenceEquals($wx, $ui.wxRef)) { return }
  $ui.wxRef = $wx
  if ($wx.ok -and $wx.city) {
    Set-WxIcon $E.wIco $wx.icon
    $E.wTemp.Text = "$($wx.temp)°"
    $E.wCity.Text = $wx.city
    $E.wFeels.Text = "Ощущается как $($wx.feels)°"
    $E.wHum.Text = "Влажность $($wx.hum)% · Ветер $($wx.wind) км/ч"
    for ($i = 1; $i -le 3; $i++) {
      $d = $wx.days[$i - 1]
      $E["wd${i}d"].Text = [string]$d.d
      Set-WxIcon $E["wd${i}i"] ([string]$d.icon)
      $E["wd${i}t"].Text = "$($d.hi)° / $($d.lo)°"
    }
  } else {
    $E.wCity.Text = 'Нет данных'
    $E.wTemp.Text = '—°'
    $E.wFeels.Text = 'Проверь интернет — повторю через пару минут'
    $E.wHum.Text = ''
  }
}

# ============================================================
#  Timer
# ============================================================
function Format-Time([double]$sec) {
  if ($sec -lt 0) { $sec = 0 }
  return ("{0}:{1:d2}" -f [int][Math]::Floor($sec / 60), [int]([Math]::Floor($sec) % 60))
}
function Start-Timer([int]$sec) {
  $ui.timerTotal = $sec; $ui.timerLeft = $sec; $ui.timerPaused = $false
  $E.btnPause.Content = 'Пауза'
  $t = Format-Time $sec
  $E.cTimerTxt.Text = $t; $E.xTimerBig.Text = $t
  Collapse
  Update-Mode
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

# volume: press / drag / mouse wheel
Add-Slider 'vol' {
  param($f)
  $r = [DI.Vol]::Set([float]$f)
  if (($r -ne 0) -and (-not $ui.volErrLogged)) { $ui.volErrLogged = $true; Log ('volume set failed: ' + [DI.Vol]::LastError) }
  if (($f -gt 0.0) -and $ui.lastMute) { [void][DI.Vol]::SetMute($false); $ui.lastMute = $false }
  $ui.lastVol = $f
  $E.volPct.Text = "$([int][Math]::Round($f * 100.0))%"
} { param($f) } {
  param($f)
  "$([int][Math]::Round($f * 100.0))%"
} $false 0.03

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
$E.btnMute.Add_Click({ [void][DI.Vol]::SetMute(-not $ui.lastMute) })

# clipboard
foreach ($id in 'cb1', 'cb2', 'cb3', 'cb4', 'cb5', 'cb6') {
  $E[$id].Add_Click([System.Windows.RoutedEventHandler]{
    param($snd, $ev)
    $idx = [int]($snd.Name.Substring(2)) - 1
    $clip = $sync.Clip
    if ($clip -and $clip.Count -gt $idx) {
      $txt = [string]$clip[$idx]
      for ($i = 0; $i -lt 3; $i++) {
        try { Set-Clipboard -Value $txt -ErrorAction Stop; $sync.ClipWrite = $txt; break } catch { Start-Sleep -Milliseconds 60 }
      }
      try {
        $hov = $snd.Template.FindName('hov', $snd)
        if ($hov) {
          $fa = New-Object System.Windows.Media.Animation.DoubleAnimation
          $fa.From = 0.24; $fa.To = 0
          $fa.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(280))
          $fa.EasingFunction = $script:easeOut
          $hov.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fa)
        }
      } catch {}
    }
  })
}
$E.btnClipClear.Add_Click({ $sync.ClipClear = $true; $sync.Clip = @(); $ui.clipRef = $null; Update-ClipUi })

# tabs
foreach ($id in 'tbMusic', 'tbSites', 'tbSys', 'tbClip', 'tbWeather', 'tbView', 'tbMore') {
  $E[$id].Add_Click([System.Windows.RoutedEventHandler]{
    param($snd, $ev)
    Set-Tab $snd.Name.Substring(2).ToLower()
  })
}
$E.btnX.Add_Click({ Collapse })

# timer
foreach ($id in 't1', 't5', 't10', 't25', 't45') {
  $E[$id].Add_Click({
    param($snd, $ev)
    $secs = switch ($snd.Name) { 't1' { 60 } 't5' { 300 } 't10' { 600 } 't25' { 1500 } 't45' { 2700 } default { 300 } }
    Start-Timer $secs
  })
}
$E.btnPause.Add_Click({
  $ui.timerPaused = -not $ui.timerPaused
  $E.btnPause.Content = if ($ui.timerPaused) { 'Дальше' } else { 'Пауза' }
})
$E.btnStop.Add_Click({ $ui.timerLeft = 0; $ui.timerPaused = $false; Collapse; Update-Mode })

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
  if ($ui.mode -eq 'idle' -and $cfg.hoverClock) {
    $E.cIdleTxt.Text = (Get-Date).ToString('HH:mm')
    FadeTo $E.cIdleTxt 1.0 220
  }
})
$E.Island.Add_MouseLeave({
  $ui.hover = $false; $ui.pressed = $false
  FadeTo $E.cIdleTxt 0.0 150
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
    $tt = Format-Time $ui.timerLeft
    $E.cTimerTxt.Text = $tt; $E.xTimerBig.Text = $tt
    if ($ui.timerLeft -le 0) {
      $ui.doneUntil = (Now-Ms) + 2800
      try { [System.Media.SystemSounds]::Asterisk.Play() } catch {}
      if ($ui.expanded) { Collapse }
      Update-Mode
    }
  }
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
$SITE_MAX = 11
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
#  System load: CPU / GPU / RAM cards with a scrolling graph (samples come from src\Sys.ps1)
# ============================================================
$SYS_N = 61
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
$ui.hist = @{}
$ui.sysHot = @{ cpu = $false; gpu = $false; ram = $false }
$ruRu = [Globalization.CultureInfo]::GetCultureInfo('ru-RU')
function Fmt1([double]$v) { return $v.ToString('0.0', $ruRu) }

function Draw-Spark([string]$k) {
  $L = $ui.hist[$k]
  $n = $L.Count
  $step = 442.0 / ($n - 1)
  $pc = New-Object System.Windows.Media.PointCollection
  $pg = New-Object System.Windows.Media.PointCollection
  for ($i = 0; $i -lt $n; $i++) {
    $y = 32.0 - ([double]$L[$i] / 100.0) * 30.0
    $pt = [System.Windows.Point]::new([double]($i * $step), [double]$y)
    $pc.Add($pt); $pg.Add($pt)
  }
  $pg.Add([System.Windows.Point]::new(442.0, 34.0))
  $pg.Add([System.Windows.Point]::new(0.0, 34.0))
  $E["${k}Line"].Points = $pc
  $E["${k}Area"].Points = $pg
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
    Set-SysHot $k $false
  }
}
function Push-Sys([string]$k, [double]$v, [string]$valText, [string]$sub) {
  $L = $ui.hist[$k]
  if ((-not $L) -or $L.Count -lt 2) { return }
  $L.RemoveAt(0)
  $L.Add([Math]::Max(0.0, [Math]::Min(100.0, $v)))
  Draw-Spark $k
  if (-not $ui.reduceMotion) {
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation
    $a.From = 442.0 / ($SYS_N - 1); $a.To = 0.0
    $a.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(1000))
    $E["${k}Plot"].RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $a)
  }
  $E["${k}Val"].Text = $valText
  $E["${k}Sub"].Text = $sub
  Set-SysHot $k ($v -ge 90.0)
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
  # RAM
  $r = [double]$sys.ram
  if ($r -ge 0) {
    Push-Sys 'ram' $r ("{0}%" -f [int][Math]::Round($r)) ("Занято " + (Fmt1 ([double]$sys.ramUsed)) + " из " + (Fmt1 ([double]$sys.ramTotal)) + " ГБ")
  }
}

# ============================================================
#  Poll (250 ms): worker state -> UI
# ============================================================
function Update-ClipUi {
  $clip = $sync.Clip
  $n = 0
  if ($clip) { $n = [Math]::Min(@($clip).Count, 6) }
  for ($i = 1; $i -le 6; $i++) {
    $b = $E["cb$i"]
    if ($i -le $n) {
      $b.Visibility = 'Visible'
      $b.Content = (([string]$clip[$i - 1]) -replace '\s+', ' ').Trim()
    } else { $b.Visibility = 'Collapsed' }
  }
  $E.clipHint.Visibility = if ($n -eq 0) { 'Visible' } else { 'Collapsed' }
}

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
    if ((-not $first) -and (-not $ui.expanded)) { $ui.volUntil = (Now-Ms) + 1700 }
  }
  $ui.lastVol = $v; $ui.lastMute = $mu
  # keep the slider in step with the system volume (keys, other apps); a drag in progress is never overwritten
  if ($ui.expanded -and $ui.tab -eq 'music' -and (-not $SL.vol.drag)) {
    if (([Math]::Abs($SL.vol.frac - $v) -gt 0.004) -or (-not $ui.volSynced)) {
      Slider-Set 'vol' $v ([bool]$ui.volSynced)
      $E.volPct.Text = "$([int][Math]::Round($v * 100.0))%"
      $ui.volSynced = $true
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
    $E.cMusicTxt.Text = $st.title
    $E.mTitle.Text = $st.title
    $E.mArtist.Text = if ($st.artist) { $st.artist } else { ' ' }
    if ($hadTitle) { Pop-Title $(if ($playing) { 1.0 } else { 0.6 }) }
  }
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

  if ($ui.expanded) {
    if (-not [object]::ReferenceEquals($sync.Clip, $ui.clipRef)) { $ui.clipRef = $sync.Clip; Update-ClipUi }
    if ($ui.tab -eq 'weather') { Update-WeatherUi }
    if ($ui.tab -eq 'sys') { Update-SysUi }
  }
  if ($ui.hover -and $ui.mode -eq 'idle') { $E.cIdleTxt.Text = (Get-Date).ToString('HH:mm') }
}

$ui.pollErr = 0
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
Log "running v2.3: scale=$($ui.scale) win=($($ui.winX),$($ui.winY)) glassOn=$($ui.glassOn)"
[void]$app.Run()

try { $sync.Running = $false } catch {}
Log 'bye'
exit 0
