# ============================================================
#  Dynamic Island for Windows  (PowerShell 5.1 + WPF, zero deps)
#  Compact pill + tabbed panel: Music / Clipboard / Weather /
#  Color / More. SMTC media, clipboard history, open-meteo.
# ============================================================
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('Win32.Kbd' -as [type])) {
  Add-Type -Namespace Win32 -Name Kbd -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
'@
}
function Send-MediaKey([byte]$vk) {
  [Win32.Kbd]::keybd_event($vk, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 30
  [Win32.Kbd]::keybd_event($vk, 0, 2, [UIntPtr]::Zero)
}
function Log($msg) {
  try { [IO.File]::AppendAllText("$env:TEMP\opencode\island_log.txt", "$(Get-Date -Format 'HH:mm:ss.fff') $msg`r`n", [Text.Encoding]::UTF8) } catch {}
}

# --- single instance ----------------------------------------
$script:mutex = New-Object System.Threading.Mutex($false, 'Global\DynamicIslandPS')
if (-not $script:mutex.WaitOne(0)) { exit }
$sync = [hashtable]::Synchronized(@{ Running = $true; State = $null; Clip = $null; Weather = $null; ClipWrite = '' })

# ============================================================
#  WORKER RUNSPACE — SMTC + battery + clipboard + weather
# ============================================================
$worker = @'
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
Add-Type -AssemblyName System.Windows.Forms

if (-not ('Win32.Clip' -as [type])) {
Add-Type -Namespace Win32 -Name Clip -MemberDefinition @"
[DllImport("user32.dll")] public static extern bool OpenClipboard(IntPtr h);
[DllImport("user32.dll")] public static extern bool CloseClipboard();
[DllImport("user32.dll")] public static extern IntPtr GetClipboardData(uint fmt);
[DllImport("kernel32.dll")] public static extern IntPtr GlobalLock(IntPtr h);
[DllImport("kernel32.dll")] public static extern bool GlobalUnlock(IntPtr h);
[DllImport("kernel32.dll")] public static extern UIntPtr GlobalSize(IntPtr h, out uint size);
"@
}
function Get-ClipboardTextSafe {
  for ($i = 0; $i -lt 3; $i++) {
    if ([Win32.Clip]::OpenClipboard([IntPtr]::Zero)) {
      try {
        $h = [Win32.Clip]::GetClipboardData(13)   # CF_UNICODETEXT
        if ($h -ne [IntPtr]::Zero) {
          $p = [Win32.Clip]::GlobalLock($h)
          if ($p -ne [IntPtr]::Zero) {
            $sz = 0; $null = [Win32.Clip]::GlobalSize($h, [ref]$sz)
            $s = [Runtime.InteropServices.Marshal]::PtrToStringUni($p)
            $null = [Win32.Clip]::GlobalUnlock($h)
            if ($s -and $s.Length -gt 300) { $s = $s.Substring(0, 300) }
            return $s
          }
        }
      } finally { [void][Win32.Clip]::CloseClipboard() }
    }
    Start-Sleep -Milliseconds 40
  }
  return $null
}

$null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
$null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSession, Windows.Media.Control, ContentType = WindowsRuntime]
$null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties, Windows.Media.Control, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.DataReader, Windows.Storage.Streams, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.IRandomAccessStreamWithContentType, Windows.Storage.Streams, ContentType = WindowsRuntime]

$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() |
  Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await($op, $t) {
  $task = $asTaskGeneric.MakeGenericMethod($t).Invoke($null, @($op))
  $task.Wait(-1) | Out-Null
  $task.Result
}
$mgr = $null
try {
  $mgr = Await ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
} catch { $mgr = $null }

function Get-ThumbB64($props) {
  try {
    $ref = $props.Thumbnail
    if (-not $ref) { return '' }
    $ras = Await ($ref.OpenReadAsync()) ([Windows.Storage.Streams.IRandomAccessStreamWithContentType])
    if (-not $ras -or $ras.Size -le 0) { return '' }
    $size = [UInt32][Math]::Min($ras.Size, [uint64]2000000)
    $dr = New-Object Windows.Storage.Streams.DataReader($ras)
    $null = Await ($dr.LoadAsync($size)) ([System.UInt32])
    $bytes = New-Object byte[] $size
    if ($size -gt 0) { $dr.ReadBytes($bytes) }
    return [Convert]::ToBase64String($bytes)
  } catch { return '' }
}

function Get-UrlB64([string]$url) {
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)')
    $b = $wc.DownloadData($url)
    if ($b -and $b.Length -gt 500) { return [Convert]::ToBase64String($b) }
  } catch {}
  return ''
}
function Get-NetArt([string]$title, [string]$artist) {
  $key = ($artist + '|' + $title).ToLower()
  if ($artCache.ContainsKey($key)) { return $artCache[$key] }
  $b64 = ''
  try {
    $q = [uri]::EscapeDataString(($artist + ' ' + $title))
    $r = Invoke-RestMethod ('https://api.deezer.com/search?q=' + $q + '&limit=1') -TimeoutSec 7
    if ($r.data -and $r.data.Count -gt 0) {
      $url = $r.data[0].album.cover_big
      if (-not $url) { $url = $r.data[0].album.cover_medium }
      if ($url) { $b64 = Get-UrlB64 $url }
    }
  } catch {}
  if (-not $b64) {
    try {
      $q2 = [uri]::EscapeDataString(($title + ' ' + $artist))
      $r2 = Invoke-RestMethod ('https://itunes.apple.com/search?term=' + $q2 + '&limit=1') -TimeoutSec 7
      if ($r2.results -and $r2.results.Count -gt 0) {
        $u = $r2.results[0].artworkUrl100
        if ($u) { $u = $u -replace '100x100', '512x512bb'; $b64 = Get-UrlB64 $u }
      }
    } catch {}
  }
  if ($artCache.Count -gt 24) { $artCache.Clear() }
  $artCache[$key] = $b64
  return $b64
}
$artCache = @{}
$artFail = @{}
function WxIcon([int]$code) {
  # WWO codes used by wttr.in; returns string (surrogate pairs for emoji above BMP)
  if ($code -eq 200 -or $code -eq 386 -or $code -eq 389) { return [char]::ConvertFromUtf32(0x26C8) }  # thunderstorm
  if ($code -in 179, 182, 185, 317, 320, 323, 326, 329, 332, 335, 338, 368, 371, 392, 395) { return [char]::ConvertFromUtf32(0x1F328) }  # snow
  if ($code -eq 113) { return [char]::ConvertFromUtf32(0x2600) }            # sunny
  if ($code -eq 116) { return [char]::ConvertFromUtf32(0x26C5) }            # partly cloudy
  if ($code -eq 119 -or $code -eq 122) { return [char]::ConvertFromUtf32(0x2601) }  # cloudy
  if ($code -in 143, 248, 260) { return [char]::ConvertFromUtf32(0x1F32B) } # fog
  return [char]::ConvertFromUtf32(0x1F327)                                   # rain/drizzle
}

$clipHist = New-Object 'System.Collections.Generic.List[string]'
$lastClip = ''
$wxLoadedAt = 0
$wlp = 0.0; $wlpAt = 0; $wTitle = ''; $wfrz = $false; $wfrzAt = 0.0; $pPrev = -1.0

while ($sync.Running) {
  $st = @{ mode = 'idle'; title = ''; artist = ''; status = ''; pos = 0.0; len = 0.0; thumb = ''; batt = 0; charging = $false; ts = [DateTime]::UtcNow }
  try {
    if ($mgr) {
      $s = $mgr.GetCurrentSession()
      if (-not $s) {
        $ss = $mgr.GetSessions()
        if ($ss.Count -gt 0) { $s = $ss[0] }
      }
      if ($s) {
        try {
          $pb = $s.GetPlaybackInfo()
          $status = [string]$pb.PlaybackStatus
          $props = Await ($s.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
          if ($props -and $props.Title -and ($status -eq 'Playing' -or $status -eq 'Paused')) {
            $st.mode = 'music'; $st.status = $status
            $st.title = [string]$props.Title
            $st.artist = [string]$props.Artist
            $akey = ($st.artist + '|' + $st.title).ToLower()
            $nowMs = [DateTime]::UtcNow.Ticks / 10000
            if ($artCache.ContainsKey($akey)) {
              $st.thumb = $artCache[$akey]
            } elseif ($artFail.ContainsKey($akey) -and ($nowMs - $artFail[$akey]) -lt 60000) {
              $st.thumb = ''
            } else {
              $st.thumb = Get-ThumbB64 $props
              if (-not $st.thumb) { $st.thumb = Get-NetArt $st.title $st.artist }
              if (-not $st.thumb) { $artFail[$akey] = $nowMs }
            }
            try {
              $tl = $s.GetTimelineProperties()
              $st.len = $tl.EndTime.TotalSeconds
              $p = $tl.Position.TotalSeconds
              # SMTC position updates lazily (often frozen) and PlaybackStatus briefly flaps
              # (Buffering/Paused); drive the position with our own clock and only resync
              # when the player actually refreshes its timeline (position value changed)
              $isPlaying = ($status -eq 'Playing' -or $status -eq 'Buffering')
              if ($wlpAt -eq 0 -or $st.title -ne $wTitle) {
                $wlp = $p; $wlpAt = $nowMs; $wfrz = $false
              } elseif (-not $isPlaying) {
                if (-not $wfrz) { $wfrz = $true; $wfrzAt = $wlp + ($nowMs - $wlpAt) / 1000.0 }
              } elseif ($wfrz) {
                $wfrz = $false
                if ([Math]::Abs($p - $wfrzAt) -gt 2.0) { $wlp = $p } else { $wlp = $wfrzAt }
                $wlpAt = $nowMs
              } elseif ($p -ne $pPrev -or [Math]::Abs($p - ($wlp + ($nowMs - $wlpAt) / 1000.0)) -gt 30.0) {
                $wlp = $p; $wlpAt = $nowMs
              }
              $pPrev = $p
              $wTitle = $st.title
              $st.pos = if ($wfrz) { $wfrzAt } else { $wlp + ($nowMs - $wlpAt) / 1000.0 }
              $st.ts = [DateTime]::UtcNow
            } catch {}
          }
        } catch {}
      }
    }
    $p = [System.Windows.Forms.SystemInformation]::PowerStatus
    $st.batt = [int][Math]::Round($p.BatteryLifePercent * 100)
    $st.charging = $p.PowerOnline
  } catch {}

  # clipboard history (dedupe; manual copies bump to top, our own card writes stay in place)
  try {
    $c = Get-ClipboardTextSafe
    if ($c -and $c.Trim().Length -gt 0 -and $c -ne $lastClip) {
      $lastClip = $c
      if ($sync.ClipWrite -eq $c) { $sync.ClipWrite = '' }
      elseif ($clipHist.Contains($c)) {
        $null = $clipHist.Remove($c)
        $clipHist.Insert(0, $c)
        $sync.Clip = $clipHist.ToArray()
      } else {
        $clipHist.Insert(0, $c)
        while ($clipHist.Count -gt 6) { $clipHist.RemoveAt($clipHist.Count - 1) }
        $sync.Clip = $clipHist.ToArray()
      }
    }
  } catch {}

  # weather (every 30 min): ipwho.is -> nominatim (city, ru) -> wttr.in
  $nowMs = [DateTime]::UtcNow.Ticks / 10000
  if ($nowMs - $wxLoadedAt -gt 1800000) {
    $wxLoadedAt = $nowMs
    try {
      [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
      $geo = Invoke-RestMethod 'https://ipwho.is/' -TimeoutSec 8
      $lat = [double]$geo.latitude
      $lon = [double]$geo.longitude
      $city = [string]$geo.city
      try {
        $h = @{ 'User-Agent' = 'DynamicIsland/1.0 (desktop widget)' }
        $nm = Invoke-RestMethod ('https://nominatim.openstreetmap.org/reverse?lat=' + $lat + '&lon=' + $lon + '&zoom=10&format=json&accept-language=ru') -Headers $h -TimeoutSec 8
        $ad = $nm.address
        if ($ad.city) { $city = [string]$ad.city }
        elseif ($ad.town) { $city = [string]$ad.town }
        elseif ($ad.village) { $city = [string]$ad.village }
        elseif ($ad.state) { $city = [string]$ad.state }
      } catch {}
      $wx = Invoke-RestMethod ('https://wttr.in/' + $lat + ',' + $lon + '?format=j1') -TimeoutSec 12
      $cc = $wx.current_condition[0]
      $ru = [Globalization.CultureInfo]::GetCultureInfo('ru-RU')
      $days = @()
      for ($d = 0; $d -le 2; $d++) {
        $dt = [datetime]::ParseExact([string]$wx.weather[$d].date, 'yyyy-MM-dd', $null)
        $dn = $ru.DateTimeFormat.GetAbbreviatedDayName($dt.DayOfWeek)
        $dcode = [int]$wx.weather[$d].hourly[4].weatherCode
        $days += ,@("$dn", "$(WxIcon $dcode)", "$([int]$wx.weather[$d].maxtempC)", "$([int]$wx.weather[$d].mintempC)")
      }
      $sync.Weather = @{
        city = $city
        temp = [int]$cc.temp_C
        wind = [int]$cc.windspeedKmph
        icon = [string](WxIcon ([int]$cc.weatherCode))
        feels = [int]$cc.FeelsLikeC
        hum = [int]$cc.humidity
        days = $days
      }
    } catch {
      $sync.Weather = @{ ok = $false }
      $wxLoadedAt = $nowMs - 1755000
    }
  }

  $sync.State = $st
  Start-Sleep -Milliseconds 700
}
'@

$rs = [runspacefactory]::CreateRunspace()
$rs.Open()
$rs.SessionStateProxy.SetVariable('sync', $sync)
$workerPs = [powershell]::Create()
$workerPs.Runspace = $rs
$null = $workerPs.AddScript($worker)
$null = $workerPs.BeginInvoke()

# ============================================================
#  UI (XAML)
# ============================================================
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Dynamic Island" Width="600" Height="480"
        WindowStyle="None" AllowsTransparency="True" Background="{x:Null}"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False"
        ResizeMode="NoResize" Focusable="False"
        FontFamily="Segoe UI" TextOptions.TextRenderingMode="ClearType">
  <Window.Resources>
    <Style x:Key="IcoBtn" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border x:Name="bg" Background="{TemplateBinding Background}" CornerRadius="12" Padding="{TemplateBinding Padding}">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <Border x:Name="hov" CornerRadius="12" Background="#FFFFFF" Opacity="0" IsHitTestVisible="False"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="hov" Storyboard.TargetProperty="Opacity" To="0.13" Duration="0:0:0.14"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="hov" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.25"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="hov" Storyboard.TargetProperty="Opacity" To="0.26" Duration="0:0:0.08"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="hov" Storyboard.TargetProperty="Opacity" To="0.13" Duration="0:0:0.18"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="RoundBtn" TargetType="Button">
      <Setter Property="Background" Value="#14FFFFFF"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border x:Name="bg" Background="{TemplateBinding Background}" CornerRadius="99"/>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
              <Border x:Name="hov" CornerRadius="99" Background="#FFFFFF" Opacity="0" IsHitTestVisible="False"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="hov" Storyboard.TargetProperty="Opacity" To="0.12" Duration="0:0:0.14"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="hov" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.25"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="hov" Storyboard.TargetProperty="Opacity" To="0.24" Duration="0:0:0.08"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="hov" Storyboard.TargetProperty="Opacity" To="0.12" Duration="0:0:0.18"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="PlayBtn" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border x:Name="bg" Background="{TemplateBinding Background}" CornerRadius="99"/>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
              <Border x:Name="hov" CornerRadius="99" Background="#000000" Opacity="0" IsHitTestVisible="False"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="hov" Storyboard.TargetProperty="Opacity" To="0.07" Duration="0:0:0.14"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="hov" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.25"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="hov" Storyboard.TargetProperty="Opacity" To="0.14" Duration="0:0:0.08"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="hov" Storyboard.TargetProperty="Opacity" To="0.07" Duration="0:0:0.18"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="TabBtn" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#99FFFFFF"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,0,4,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border x:Name="bg" Background="{TemplateBinding Background}" CornerRadius="14" Padding="13,7">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <Border x:Name="hov" CornerRadius="14" Background="#FFFFFF" Opacity="0" IsHitTestVisible="False"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="hov" Storyboard.TargetProperty="Opacity" To="0.09" Duration="0:0:0.14"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="hov" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.25"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="PillBtn" TargetType="Button" BasedOn="{StaticResource IcoBtn}">
      <Setter Property="Background" Value="#1FFFFFFF"/>
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="12,6"/>
      <Setter Property="Margin" Value="0,0,7,0"/>
    </Style>
    <Style x:Key="ClipCard" TargetType="Button">
      <Setter Property="Background" Value="#10FFFFFF"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border x:Name="bg" Background="{TemplateBinding Background}" CornerRadius="10" Padding="10,6" Margin="0,0,0,4">
                <TextBlock Text="{TemplateBinding Content}" FontSize="11" Foreground="#D9FFFFFF" TextTrimming="CharacterEllipsis"/>
              </Border>
              <Border x:Name="hov" CornerRadius="10" Background="#FFFFFF" Opacity="0" IsHitTestVisible="False" Margin="0,0,0,4"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="hov" Storyboard.TargetProperty="Opacity" To="0.10" Duration="0:0:0.14"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="hov" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.25"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="hov" Storyboard.TargetProperty="Opacity" To="0.22" Duration="0:0:0.08"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="hov" Storyboard.TargetProperty="Opacity" To="0.10" Duration="0:0:0.18"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="DotBtn" TargetType="Button">
      <Setter Property="Width" Value="24"/>
      <Setter Property="Height" Value="24"/>
      <Setter Property="Margin" Value="0,0,8,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border x:Name="bg" Background="{TemplateBinding Background}" CornerRadius="12" BorderBrush="#40FFFFFF" BorderThickness="1"/>
              <Border x:Name="hov" CornerRadius="12" Background="#FFFFFF" Opacity="0" IsHitTestVisible="False"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="hov" Storyboard.TargetProperty="Opacity" To="0.28" Duration="0:0:0.15"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="hov" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.25"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="hov" Storyboard.TargetProperty="Opacity" To="0.45" Duration="0:0:0.08"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Switch" TargetType="ToggleButton">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Border x:Name="track" Width="40" Height="23" CornerRadius="12" Background="#2EFFFFFF">
              <Border x:Name="knob" Width="17" Height="17" CornerRadius="9" Background="#F2FFFFFF"
                      HorizontalAlignment="Left" Margin="3,0,0,0">
                <Border.RenderTransform>
                  <TranslateTransform X="0"/>
                </Border.RenderTransform>
              </Border>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <ColorAnimation Storyboard.TargetName="track" Storyboard.TargetProperty="(Border.Background).(SolidColorBrush.Color)" To="#FF30D158" Duration="0:0:0.22"/>
                      <DoubleAnimation Storyboard.TargetName="knob" Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" To="17" Duration="0:0:0.22">
                        <DoubleAnimation.EasingFunction>
                          <BackEase Amplitude="0.55" EasingMode="EaseOut"/>
                        </DoubleAnimation.EasingFunction>
                      </DoubleAnimation>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <ColorAnimation Storyboard.TargetName="track" Storyboard.TargetProperty="(Border.Background).(SolidColorBrush.Color)" To="#2EFFFFFF" Duration="0:0:0.26"/>
                      <DoubleAnimation Storyboard.TargetName="knob" Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" To="0" Duration="0:0:0.26"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="GlassSlider" TargetType="Slider">
      <Setter Property="Height" Value="18"/>
      <Setter Property="IsMoveToPointEnabled" Value="True"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Slider">
            <Grid Background="Transparent">
              <Border Height="4" CornerRadius="2" Background="#24FFFFFF" VerticalAlignment="Center"/>
              <Track x:Name="PART_Track" VerticalAlignment="Center">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="Slider.DecreaseLarge" Opacity="0" Focusable="False"/>
                </Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="Slider.IncreaseLarge" Opacity="0" Focusable="False"/>
                </Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb Width="14" Height="14" Focusable="False">
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Ellipse Fill="#F2F2F2" Stroke="#3A000000" StrokeThickness="1"/>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="CardTxt" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#99FFFFFF"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>
    <Style x:Key="SecLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#78FFFFFF"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,0,0,8"/>
    </Style>
  </Window.Resources>

  <Canvas x:Name="root">
    <Grid x:Name="IslandHost" Width="116" Height="34" Canvas.Left="242" Canvas.Top="8">
      <Border x:Name="IslandShadow" Background="#FF0B0B0F" CornerRadius="17">
        <Border.Effect>
          <DropShadowEffect BlurRadius="24" ShadowDepth="6" Direction="270" Opacity="0.5"/>
        </Border.Effect>
      </Border>
      <Border x:Name="Island" Background="#FF0B0B0F" CornerRadius="17" Cursor="Hand" ClipToBounds="True">
        <Grid>

        <!-- ================= COMPACT ================= -->
        <Grid x:Name="CompactLayer" Visibility="Visible">
          <Grid x:Name="cMusic" Visibility="Hidden" RenderTransformOrigin="0.5,0.5">
            <Grid.RenderTransform><ScaleTransform ScaleX="1" ScaleY="1"/></Grid.RenderTransform>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Border Width="22" Height="22" CornerRadius="7" Margin="6,0,0,0" VerticalAlignment="Center">
              <Border.Background><ImageBrush x:Name="artS" Stretch="UniformToFill"/></Border.Background>
              <TextBlock Text="♪" FontSize="11" Foreground="#66FFFFFF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <TextBlock x:Name="cMusicTxt" Grid.Column="1" Text="" Foreground="White" FontSize="11.5" FontWeight="SemiBold"
                       Margin="8,0,7,0" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
            <StackPanel Grid.Column="2" Orientation="Horizontal" Margin="0,0,8,0" VerticalAlignment="Center" x:Name="wavePanel">
              <Rectangle x:Name="w1" Width="2.6" Height="9"  RadiusX="1.3" RadiusY="1.3" Fill="#F2F2F2" Margin="0,0,2.4,0"/>
              <Rectangle x:Name="w2" Width="2.6" Height="14" RadiusX="1.3" RadiusY="1.3" Fill="#F2F2F2" Margin="0,0,2.4,0"/>
              <Rectangle x:Name="w3" Width="2.6" Height="6"  RadiusX="1.3" RadiusY="1.3" Fill="#F2F2F2" Margin="0,0,2.4,0"/>
              <Rectangle x:Name="w4" Width="2.6" Height="12" RadiusX="1.3" RadiusY="1.3" Fill="#F2F2F2" Margin="0,0,2.4,0"/>
              <Rectangle x:Name="w5" Width="2.6" Height="8"  RadiusX="1.3" RadiusY="1.3" Fill="#F2F2F2"/>
            </StackPanel>
          </Grid>

          <Grid x:Name="cTimer" Visibility="Hidden" RenderTransformOrigin="0.5,0.5">
            <Grid.RenderTransform><ScaleTransform ScaleX="1" ScaleY="1"/></Grid.RenderTransform>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center">
              <Canvas Width="16" Height="16" VerticalAlignment="Center" Margin="0,0,7,0">
                <Ellipse Canvas.Left="1" Canvas.Top="2" Width="14" Height="14" Stroke="#FF9F0A" StrokeThickness="1.8"/>
                <Path Data="M8 5.5 V9 L10.5 10.5" Stroke="#FF9F0A" StrokeThickness="1.8" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                <Path Data="M5.5 1 h5" Stroke="#FF9F0A" StrokeThickness="1.8" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
              </Canvas>
              <TextBlock x:Name="cTimerTxt" Text="5:00" Foreground="White" FontSize="12.5" FontWeight="SemiBold" VerticalAlignment="Center"/>
            </StackPanel>
          </Grid>

          <Grid x:Name="cCharge" Visibility="Hidden" RenderTransformOrigin="0.5,0.5">
            <Grid.RenderTransform><ScaleTransform ScaleX="1" ScaleY="1"/></Grid.RenderTransform>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center">
              <Path Data="M9 0 L2.5 9 h4 L6 16 L13.5 6 H9.5 Z" Fill="#30D158" Width="13" Margin="0,0,7,0" Stretch="Uniform" VerticalAlignment="Center"/>
              <TextBlock x:Name="cChargeTxt" Text="84%" Foreground="White" FontSize="12.5" FontWeight="SemiBold" VerticalAlignment="Center"/>
            </StackPanel>
          </Grid>

          <Grid x:Name="cDone" Visibility="Hidden" RenderTransformOrigin="0.5,0.5">
            <Grid.RenderTransform><ScaleTransform ScaleX="1" ScaleY="1"/></Grid.RenderTransform>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center">
              <Path Data="M2 8 l4.5 4.5 L14.5 3" Stroke="#30D158" StrokeThickness="2.6" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Width="14" Stretch="Uniform" VerticalAlignment="Center" Margin="0,0,7,0"/>
              <TextBlock Text="Готово" Foreground="White" FontSize="12.5" FontWeight="SemiBold" VerticalAlignment="Center"/>
            </StackPanel>
          </Grid>
        </Grid>

        <!-- ================= EXPANDED PANEL ================= -->
        <Grid x:Name="ExpandedLayer" Visibility="Hidden" RenderTransformOrigin="0.5,0">
          <Grid.RenderTransform><ScaleTransform ScaleX="1" ScaleY="1"/></Grid.RenderTransform>

          <StackPanel x:Name="tabBar" Orientation="Horizontal" Margin="16,14,16,0" VerticalAlignment="Top" HorizontalAlignment="Center">
            <Button x:Name="tbMusic" Style="{StaticResource TabBtn}" Content="Музыка" Foreground="#F2F2F2" Background="#F2F2F2"/>
            <Button x:Name="tbClip" Style="{StaticResource TabBtn}" Content="Буфер"/>
            <Button x:Name="tbWeather" Style="{StaticResource TabBtn}" Content="Погода"/>
            <Button x:Name="tbColor" Style="{StaticResource TabBtn}" Content="Цвет"/>
            <Button x:Name="tbMore" Style="{StaticResource TabBtn}" Content="Ещё"/>
          </StackPanel>

          <Grid x:Name="mMusic" Visibility="Visible" Margin="22,50,22,12" RenderTransformOrigin="0.5,0">
            <Grid.RenderTransform><TranslateTransform Y="0"/></Grid.RenderTransform>
            <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
              <Border Width="108" Height="108" CornerRadius="16" HorizontalAlignment="Center">
                <Border.Background><ImageBrush x:Name="artB" Stretch="UniformToFill"/></Border.Background>
                <TextBlock Text="♪" FontSize="34" Foreground="#40FFFFFF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <TextBlock x:Name="mTitle" Text="" Foreground="White" FontSize="14.5" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,12,0,0" TextTrimming="CharacterEllipsis" MaxWidth="380"/>
              <TextBlock x:Name="mArtist" Text="" Foreground="#99FFFFFF" FontSize="11.5" HorizontalAlignment="Center" Margin="0,3,0,0" TextTrimming="CharacterEllipsis" MaxWidth="380"/>
              <Grid Margin="0,14,0,0" Height="4" Width="400" HorizontalAlignment="Center">
                <Border x:Name="mProgTrack" Background="#24FFFFFF" CornerRadius="2"/>
                <Border x:Name="mProgFill" Background="#F2F2F2" CornerRadius="2" HorizontalAlignment="Left" Width="0"/>
              </Grid>
              <Grid Margin="0,4,0,0" Width="400" HorizontalAlignment="Center">
                <TextBlock x:Name="mPos" Text="0:00" Style="{StaticResource CardTxt}" FontSize="10.5" HorizontalAlignment="Left"/>
                <TextBlock x:Name="mRem" Text="-0:00" Style="{StaticResource CardTxt}" FontSize="10.5" HorizontalAlignment="Right"/>
              </Grid>
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,12,0,0">
                <Button x:Name="btnPrev" Style="{StaticResource RoundBtn}" Width="38" Height="38" Margin="0,0,14,0">
                  <Path Data="M6.5 5 h2.2 v14 H6.5 z M17.5 5 v14 L9 12 Z" Fill="#D9FFFFFF" Width="15" Stretch="Uniform"/>
                </Button>
                <Button x:Name="btnPlay" Style="{StaticResource PlayBtn}" Background="#F2F2F2" Width="48" Height="48">
                  <Path x:Name="playIco" Data="M8 5 h3 v14 H8 z M13.5 5 h3 v14 h-3 z" Fill="#FF0E0E12" Width="19" Stretch="Uniform"/>
                </Button>
                <Button x:Name="btnNext" Style="{StaticResource RoundBtn}" Width="38" Height="38" Margin="14,0,0,0">
                  <Path Data="M15.3 5 h2.2 v14 h-2.2 z M4.5 5 v14 L13 12 Z" Fill="#D9FFFFFF" Width="15" Stretch="Uniform"/>
                </Button>
              </StackPanel>
            </StackPanel>
          </Grid>

          <Grid x:Name="mClip" Visibility="Hidden" Margin="22,50,22,12" RenderTransformOrigin="0.5,0">
            <Grid.RenderTransform><TranslateTransform Y="0"/></Grid.RenderTransform>
            <StackPanel>
              <TextBlock Text="БУФЕР ОБМЕНА · КЛИК — СКОПИРОВАТЬ" Style="{StaticResource SecLabel}"/>
              <Button x:Name="cb1" Style="{StaticResource ClipCard}" Content=""/>
              <Button x:Name="cb2" Style="{StaticResource ClipCard}" Content=""/>
              <Button x:Name="cb3" Style="{StaticResource ClipCard}" Content=""/>
              <Button x:Name="cb4" Style="{StaticResource ClipCard}" Content=""/>
              <Button x:Name="cb5" Style="{StaticResource ClipCard}" Content=""/>
              <Button x:Name="cb6" Style="{StaticResource ClipCard}" Content=""/>
              <TextBlock x:Name="clipHint" Text="Пока пусто — скопируй что-нибудь" Foreground="#66FFFFFF" FontSize="11"/>
            </StackPanel>
          </Grid>

          <Grid x:Name="mWeather" Visibility="Hidden" Margin="22,50,22,12" RenderTransformOrigin="0.5,0">
            <Grid.RenderTransform><TranslateTransform Y="0"/></Grid.RenderTransform>
            <StackPanel VerticalAlignment="Center">
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                <TextBlock x:Name="wIcon" Text="☁" FontFamily="Segoe UI Symbol" FontSize="40" Foreground="#EAF2FF" VerticalAlignment="Center"/>
                <TextBlock x:Name="wTemp" Text="—°" Foreground="White" FontSize="44" FontWeight="Light" VerticalAlignment="Center" Margin="10,0,0,0"/>
                <StackPanel VerticalAlignment="Center" Margin="13,0,0,0">
                  <TextBlock x:Name="wCity" Text="…" Foreground="White" FontSize="13" FontWeight="SemiBold"/>
                  <TextBlock x:Name="wFeels" Text="Ощущается как —°" Style="{StaticResource CardTxt}" FontSize="10.5" Margin="0,3,0,0"/>
                  <TextBlock x:Name="wHum" Text="Влажность —% · Ветер — км/ч" Style="{StaticResource CardTxt}" FontSize="10.5" Margin="0,1,0,0"/>
                </StackPanel>
              </StackPanel>
              <UniformGrid Columns="3" Margin="0,16,0,0">
                <Border Background="#12FFFFFF" CornerRadius="14" Margin="0,0,6,0" Padding="0,10">
                  <StackPanel>
                    <TextBlock x:Name="wd1d" Text="" Style="{StaticResource CardTxt}" FontSize="10" HorizontalAlignment="Center"/>
                    <TextBlock x:Name="wd1i" Text="" FontFamily="Segoe UI Symbol" FontSize="16" Foreground="#EAF2FF" HorizontalAlignment="Center" Margin="0,3,0,3"/>
                    <TextBlock x:Name="wd1t" Text="" Foreground="White" FontSize="11" HorizontalAlignment="Center"/>
                  </StackPanel>
                </Border>
                <Border Background="#12FFFFFF" CornerRadius="14" Margin="0,0,6,0" Padding="0,10">
                  <StackPanel>
                    <TextBlock x:Name="wd2d" Text="" Style="{StaticResource CardTxt}" FontSize="10" HorizontalAlignment="Center"/>
                    <TextBlock x:Name="wd2i" Text="" FontFamily="Segoe UI Symbol" FontSize="16" Foreground="#EAF2FF" HorizontalAlignment="Center" Margin="0,3,0,3"/>
                    <TextBlock x:Name="wd2t" Text="" Foreground="White" FontSize="11" HorizontalAlignment="Center"/>
                  </StackPanel>
                </Border>
                <Border Background="#12FFFFFF" CornerRadius="14" Padding="0,10">
                  <StackPanel>
                    <TextBlock x:Name="wd3d" Text="" Style="{StaticResource CardTxt}" FontSize="10" HorizontalAlignment="Center"/>
                    <TextBlock x:Name="wd3i" Text="" FontFamily="Segoe UI Symbol" FontSize="16" Foreground="#EAF2FF" HorizontalAlignment="Center" Margin="0,3,0,3"/>
                    <TextBlock x:Name="wd3t" Text="" Foreground="White" FontSize="11" HorizontalAlignment="Center"/>
                  </StackPanel>
                </Border>
              </UniformGrid>
            </StackPanel>
          </Grid>

          <Grid x:Name="mColor" Visibility="Hidden" Margin="22,50,22,12" RenderTransformOrigin="0.5,0">
            <Grid.RenderTransform><TranslateTransform Y="0"/></Grid.RenderTransform>
            <StackPanel>
              <TextBlock Text="АКЦЕНТНЫЙ ЦВЕТ" Style="{StaticResource SecLabel}"/>
              <WrapPanel x:Name="dotsHost" Margin="0,0,0,10"/>
              <TextBlock Text="ПРОСМОТР" Style="{StaticResource SecLabel}"/>
              <Border x:Name="colPrev" Height="10" CornerRadius="5" Background="#F2F2F2"/>
              <TextBlock Text="Цвет пилюли, эквалайзера и прогресса" Foreground="#66FFFFFF" FontSize="10.5" Margin="0,6,0,0"/>
              <TextBlock Text="ЖИДКОЕ СТЕКЛО" Style="{StaticResource SecLabel}" Margin="0,14,0,0"/>
              <Grid>
                <TextBlock Text="Размытие фона (acrylic)" Foreground="#E6FFFFFF" FontSize="11.5" VerticalAlignment="Center"/>
                <ToggleButton x:Name="swGlass" Style="{StaticResource Switch}" HorizontalAlignment="Right"/>
              </Grid>
              <Grid Margin="0,8,0,0">
                <TextBlock Text="Прозрачность" Foreground="#E6FFFFFF" FontSize="11.5" VerticalAlignment="Center"/>
                <Slider x:Name="slAlpha" Style="{StaticResource GlassSlider}" Minimum="0" Maximum="100" Width="200" HorizontalAlignment="Right" VerticalAlignment="Center"/>
              </Grid>
            </StackPanel>
          </Grid>

          <Grid x:Name="mMore" Visibility="Hidden" Margin="22,50,22,12" RenderTransformOrigin="0.5,0">
            <Grid.RenderTransform><TranslateTransform Y="0"/></Grid.RenderTransform>
            <StackPanel>
              <TextBlock Text="ТАЙМЕР" Style="{StaticResource SecLabel}"/>
              <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
                <Button x:Name="t1" Style="{StaticResource PillBtn}" Content="1 мин"/>
                <Button x:Name="t5" Style="{StaticResource PillBtn}" Content="5 мин"/>
                <Button x:Name="t10" Style="{StaticResource PillBtn}" Content="10 мин"/>
              </StackPanel>
              <TextBlock Text="НАСТРОЙКИ" Style="{StaticResource SecLabel}"/>
              <Grid Margin="0,0,0,8">
                <TextBlock Text="Автозапуск с Windows" Foreground="#E6FFFFFF" FontSize="11.5" VerticalAlignment="Center"/>
                <ToggleButton x:Name="swAuto" Style="{StaticResource Switch}" HorizontalAlignment="Right"/>
              </Grid>
              <Grid Margin="0,0,0,8">
                <TextBlock Text="Эквалайзер в пилюле" Foreground="#E6FFFFFF" FontSize="11.5" VerticalAlignment="Center"/>
                <ToggleButton x:Name="swEq" Style="{StaticResource Switch}" IsChecked="True" HorizontalAlignment="Right"/>
              </Grid>
              <Grid Margin="0,0,0,12">
                <TextBlock Text="Показывать зарядку" Foreground="#E6FFFFFF" FontSize="11.5" VerticalAlignment="Center"/>
                <ToggleButton x:Name="swCharge" Style="{StaticResource Switch}" IsChecked="True" HorizontalAlignment="Right"/>
              </Grid>
              <Button x:Name="btnQuit" Style="{StaticResource PillBtn}" Content="Выключить островок" Background="#47FF453A" Foreground="#FFB4AB" HorizontalAlignment="Left" Margin="0"/>
            </StackPanel>
          </Grid>

          <Grid x:Name="mTimerRun" Visibility="Hidden" Margin="22,50,22,12" RenderTransformOrigin="0.5,0">
            <Grid.RenderTransform><TranslateTransform Y="0"/></Grid.RenderTransform>
            <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
              <TextBlock x:Name="xTimerBig" Text="5:00" Foreground="White" FontSize="36" FontWeight="Light" HorizontalAlignment="Center"/>
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,12,0,0">
                <Button x:Name="btnPause" Style="{StaticResource PillBtn}" Content="Пауза"/>
                <Button x:Name="btnStop" Style="{StaticResource PillBtn}" Content="Стоп" Background="#47FF453A" Foreground="#FFB4AB"/>
              </StackPanel>
            </StackPanel>
          </Grid>

          <Button x:Name="btnX" Style="{StaticResource IcoBtn}" Background="#22FFFFFF" Width="26" Height="26" Margin="0,12,14,0"
                  HorizontalAlignment="Right" VerticalAlignment="Top">
            <Path Data="M0 0 L8 8 M8 0 L0 8" Stroke="White" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Width="9" Stretch="Uniform"/>
          </Button>
        </Grid>

        <Canvas x:Name="glassLens" IsHitTestVisible="False" Opacity="0">
          <Ellipse x:Name="lensGlow" Width="170" Height="170">
            <Ellipse.RenderTransform><TranslateTransform X="-300" Y="-300"/></Ellipse.RenderTransform>
            <Ellipse.Fill>
              <RadialGradientBrush>
                <GradientStop Color="#26FFFFFF" Offset="0"/>
                <GradientStop Color="#00FFFFFF" Offset="0.5"/>
                <GradientStop Color="#30FFFFFF" Offset="0.85"/>
                <GradientStop Color="#00FFFFFF" Offset="1"/>
              </RadialGradientBrush>
            </Ellipse.Fill>
          </Ellipse>
          <Ellipse x:Name="lensCore" Width="64" Height="64">
            <Ellipse.RenderTransform><TranslateTransform x:Name="lensCoreT" X="-300" Y="-300"/></Ellipse.RenderTransform>
            <Ellipse.Fill>
              <RadialGradientBrush>
                <GradientStop Color="#42FFFFFF" Offset="0"/>
                <GradientStop Color="#00FFFFFF" Offset="1"/>
              </RadialGradientBrush>
            </Ellipse.Fill>
          </Ellipse>
        </Canvas>

        <Canvas x:Name="sweepLight" IsHitTestVisible="False" Opacity="0">
          <Rectangle x:Name="sweepBar" Width="110" Height="520" Canvas.Top="-70">
            <Rectangle.RenderTransform>
              <TransformGroup>
                <RotateTransform Angle="16"/>
                <TranslateTransform x:Name="sweepX" X="-240"/>
              </TransformGroup>
            </Rectangle.RenderTransform>
            <Rectangle.Fill>
              <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                <GradientStop Color="#00FFFFFF" Offset="0"/>
                <GradientStop Color="#5AFFFFFF" Offset="0.5"/>
                <GradientStop Color="#00FFFFFF" Offset="1"/>
              </LinearGradientBrush>
            </Rectangle.Fill>
          </Rectangle>
        </Canvas>
      </Grid>
      </Border>
    </Grid>
  </Canvas>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Parse($xaml)

# --- element handles ---
$E = @{}
foreach ($n in 'Island','IslandHost','IslandShadow','CompactLayer','ExpandedLayer','cMusic','cTimer','cCharge','cDone','cMusicTxt','wavePanel','w1','w2','w3','w4','w5',
               'tabBar','tbMusic','tbClip','tbWeather','tbColor','tbMore','mMusic','mClip','mWeather','mColor','mMore','mTimerRun',
               'artS','artB','mTitle','mArtist','mProgFill','mProgTrack','mPos','mRem','playIco','btnPrev','btnPlay','btnNext',
               'cb1','cb2','cb3','cb4','cb5','cb6','clipHint',
               'wIcon','wTemp','wCity','wFeels','wHum','wd1d','wd1i','wd1t','wd2d','wd2i','wd2t','wd3d','wd3i','wd3t',
               'dotsHost','colPrev','t1','t5','t10','swAuto','swEq','swCharge','btnQuit','btnX','btnPause','btnStop','xTimerBig','cTimerTxt','cChargeTxt',
               'swGlass','slAlpha','glassLens','lensGlow','lensCoreT','sweepLight','sweepX') {
  $E[$n] = $window.FindName($n)
}
$miss = @($E.Keys | Where-Object { -not $E[$_] })

$app = New-Object System.Windows.Application
$app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$app.add_DispatcherUnhandledException([System.Windows.Threading.DispatcherUnhandledExceptionEventHandler]{
  param($snd, $ev)
  $pos = ''
  try { $pos = $ev.Exception.ErrorRecord.InvocationInfo.PositionMessage } catch {}
  $txt = $ev.Exception.ToString() + "`r`n`r`n--- POSITION ---`r`n" + $pos + "`r`n`r`n--- STACK ---`r`n" + $ev.Exception.StackTrace
  try { [IO.File]::WriteAllText("$env:TEMP\opencode\island_crash.txt", $txt, [Text.Encoding]::UTF8) } catch {}
  $ev.Handled = $true
})

# ============================================================
#  Glass underlay window (acrylic blur behind the pill)
# ============================================================
if (-not ('Win32.Compo' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Win32 {
  public struct ACCENT_POLICY { public int AccentState; public uint AccentFlags; public uint GradientColor; public int AnimationId; }
  public class Compo {
    [DllImport("user32.dll")] public static extern int SetWindowCompositionAttribute(IntPtr hwnd, ref ACCENT_POLICY p);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int i, int v);
  }
}
'@
}
$glassWin = New-Object Windows.Window
$glassWin.WindowStyle = [Windows.WindowStyle]::None
$glassWin.AllowsTransparency = $true
$glassWin.Background = [Windows.Media.Brushes]::Transparent
$glassWin.Topmost = $true
$glassWin.ShowInTaskbar = $false
$glassWin.ShowActivated = $false
$glassWin.ResizeMode = [Windows.ResizeMode]::NoResize
$glassWin.Focusable = $false
$glassWin.Width = 10; $glassWin.Height = 10
$glassWin.Show()
$glassWin.Hide()
$glassHwnd = (New-Object System.Windows.Interop.WindowInteropHelper $glassWin).Handle
$mainHwnd = (New-Object System.Windows.Interop.WindowInteropHelper $window).Handle
$glassEx = [Win32.Compo]::GetWindowLong($glassHwnd, -20)
[void][Win32.Compo]::SetWindowLong($glassHwnd, -20, ($glassEx -bor 0x080000A0))

# ============================================================
#  Island geometry + animation
# ============================================================
$WIN_W = 600.0
$SIZES = @{
  idle   = @{ w = 116.0; h = 34.0; r = 17.0 }
  music  = @{ w = 248.0; h = 34.0; r = 17.0 }
  timer  = @{ w = 160.0; h = 34.0; r = 17.0 }
  charge = @{ w = 148.0; h = 34.0; r = 17.0 }
  done   = @{ w = 150.0; h = 34.0; r = 17.0 }
  panel  = @{ w = 460.0; h = 370.0; r = 24.0 }
}
$script:easeSnap = New-Object Windows.Media.Animation.PowerEase
$script:easeSnap.Power = 6; $script:easeSnap.EasingMode = 'EaseOut'
$script:easeSpring = New-Object Windows.Media.Animation.BackEase
$script:easeSpring.Amplitude = 0.35; $script:easeSpring.EasingMode = 'EaseOut'
$script:easeOut = New-Object Windows.Media.Animation.CubicEase
$script:easeOut.EasingMode = 'EaseOut'
$script:radT = @{ timer = $null; from = 19.0; to = 19.0; start = [DateTime]::Now; dur = 1; ease = $null }
function TweenRadius([double]$to, [int]$ms, $ease) {
  if ($script:radT.timer) { $script:radT.timer.Stop() }
  $script:radT.from = $E.Island.CornerRadius.TopLeft
  $script:radT.to = $to
  $script:radT.dur = [Math]::Max(1, $ms)
  $script:radT.start = [DateTime]::Now
  $script:radT.ease = $ease
  if (-not $script:radT.timer) {
    $t = New-Object Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(16)
    $t.Add_Tick({
      $rt = $script:radT
      $p = ([DateTime]::Now - $rt.start).TotalMilliseconds / $rt.dur
      if ($p -ge 1) { $p = 1; $rt.timer.Stop() }
      $ep = if ($rt.ease) { $rt.ease.Ease($p) } else { $p }
      $r = $rt.from + ($rt.to - $rt.from) * $ep
      $cr = New-Object Windows.CornerRadius $r
      $E.Island.CornerRadius = $cr
      $E.IslandShadow.CornerRadius = $cr
      Update-GlassPos
    })
    $script:radT.timer = $t
  }
  $script:radT.timer.Start()
}
function Morph([string]$key, [bool]$springy) {
  if (-not $SIZES.ContainsKey($key)) { return }
  $s = $SIZES[$key]
  $left = ($WIN_W - $s.w) / 2
  $dur = [TimeSpan]::FromMilliseconds($(if ($springy) { 480 } else { 320 }))
  $sb = New-Object Windows.Media.Animation.Storyboard
  function Add-Anim($target, [string]$prop, [double]$to, $easing) {
    $a = New-Object Windows.Media.Animation.DoubleAnimation
    $a.To = $to
    $a.Duration = New-Object Windows.Duration $dur
    $a.EasingFunction = $easing
    [Windows.Media.Animation.Storyboard]::SetTarget($a, $target)
    [Windows.Media.Animation.Storyboard]::SetTargetProperty($a, $prop)
    $sb.Children.Add($a) | Out-Null
  }
  $ease = if ($springy) { $script:easeSpring } else { $script:easeSnap }
  Add-Anim $E.IslandHost 'Width'  $s.w $ease
  Add-Anim $E.IslandHost 'Height' $s.h $ease
  Add-Anim $E.IslandHost '(Canvas.Left)' $left $ease
  $sb.Begin($E.IslandHost, $true)
  TweenRadius $s.r $(if ($springy) { 480 } else { 320 }) $ease
}
function FadeTo($el, [double]$to, [int]$ms) {
  $a = New-Object Windows.Media.Animation.DoubleAnimation
  $a.To = $to
  $a.Duration = New-Object Windows.Duration ([TimeSpan]::FromMilliseconds($ms))
  $sb = New-Object Windows.Media.Animation.Storyboard
  [Windows.Media.Animation.Storyboard]::SetTarget($a, $el)
  [Windows.Media.Animation.Storyboard]::SetTargetProperty($a, 'Opacity')
  $sb.Children.Add($a) | Out-Null
  $sb.Begin($el)
}
function SwapPanel($from, $to, [int]$ms) {
  if ($from -and $from -ne $to) { $from.Visibility = 'Hidden' }
  if ($to) {
    $to.Opacity = 0
    $to.Visibility = 'Visible'
    $sb = New-Object Windows.Media.Animation.Storyboard
    $d = New-Object Windows.Duration ([TimeSpan]::FromMilliseconds($ms))
    $a1 = New-Object Windows.Media.Animation.DoubleAnimation
    $a1.To = 1; $a1.Duration = $d
    [Windows.Media.Animation.Storyboard]::SetTarget($a1, $to)
    [Windows.Media.Animation.Storyboard]::SetTargetProperty($a1, 'Opacity')
    $sb.Children.Add($a1) | Out-Null
    foreach ($pp in @('(UIElement.RenderTransform).(ScaleTransform.ScaleX)', '(UIElement.RenderTransform).(ScaleTransform.ScaleY)')) {
      $a = New-Object Windows.Media.Animation.DoubleAnimation
      $a.From = 0.92; $a.To = 1; $a.Duration = $d
      $a.EasingFunction = $script:easeOut
      [Windows.Media.Animation.Storyboard]::SetTarget($a, $to)
      [Windows.Media.Animation.Storyboard]::SetTargetProperty($a, $pp)
      $sb.Children.Add($a) | Out-Null
    }
    $sb.Begin($to)
  }
}

# --- waveform loop ---
$waveSb = New-Object Windows.Media.Animation.Storyboard
$i = 0
foreach ($n in 'w1','w2','w3','w4','w5') {
  $a = New-Object Windows.Media.Animation.DoubleAnimation
  $a.From = 3.5; $a.To = 14
  $a.Duration = New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(500 + 90 * $i))
  $a.AutoReverse = $true
  $a.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
  $a.BeginTime = [TimeSpan]::FromMilliseconds(70 * $i)
  [Windows.Media.Animation.Storyboard]::SetTarget($a, $E[$n])
  [Windows.Media.Animation.Storyboard]::SetTargetProperty($a, 'Height')
  $waveSb.Children.Add($a) | Out-Null
  $i++
}
function WaveStart { try { $waveSb.Begin($E.wavePanel, $true) } catch {} }
function WaveStop  { try { $waveSb.Stop($E.wavePanel) } catch {} }
function WavePause { try { $waveSb.Pause($E.wavePanel) } catch {} }
function WaveResume { try { $waveSb.Resume($E.wavePanel) } catch {} }

# ============================================================
#  Settings (registry)
# ============================================================
$setPath = 'HKCU:\Software\DynamicIsland'
function Save-Settings {
  try {
    if (-not (Test-Path $setPath)) { New-Item -Path $setPath -Force | Out-Null }
    $c = $ui.accent
    Set-ItemProperty -Path $setPath -Name 'Accent' -Value ("$($c.R),$($c.G),$($c.B)") -Type String
    Set-ItemProperty -Path $setPath -Name 'EqOn' -Value ([int]$ui.eqOn) -Type DWord
    Set-ItemProperty -Path $setPath -Name 'ChargeOn' -Value ([int]$ui.showCharge) -Type DWord
    Set-ItemProperty -Path $setPath -Name 'GlassOn' -Value ([int]$ui.glass) -Type DWord
    Set-ItemProperty -Path $setPath -Name 'GlassAlpha' -Value ([int]$ui.glassAlpha) -Type DWord
  } catch {}
}
function Load-Settings {
  try {
    $p = Get-ItemProperty -Path $setPath -ErrorAction SilentlyContinue
    if ($p -and $p.Accent) {
      $rgb = [string]$p.Accent -split ','
      if ($rgb.Count -eq 3) { $ui.accent = [Windows.Media.Color]::FromRgb([byte]$rgb[0], [byte]$rgb[1], [byte]$rgb[2]) }
    }
    if ($p -and $null -ne $p.EqOn) { $ui.eqOn = [bool](1 -eq [int]$p.EqOn) }
    if ($p -and $null -ne $p.ChargeOn) { $ui.showCharge = [bool](1 -eq [int]$p.ChargeOn) }
    if ($p -and $null -ne $p.GlassOn) { $ui.glass = [bool](1 -eq [int]$p.GlassOn) }
    if ($p -and $null -ne $p.GlassAlpha) { $ui.glassAlpha = [Math]::Min(100, [Math]::Max(0, [int]$p.GlassAlpha)) }
  } catch {}
}

# ============================================================
#  App state
# ============================================================
$ui = @{
  mode = 'idle'; expanded = $false; compactPanel = $null
  lastCompact = 'idle'; lastTitle = ''; lastArt = ''; lastPos = 0.0
  timerLeft = 0; timerTotal = 0; timerPaused = $false
  waveStarted = $false; wavePaused = $false
  tab = 'music'
  accent = [Windows.Media.Color]::FromRgb(242, 242, 242)
  eqOn = $true; showCharge = $true
  glass = $true; glassAlpha = 60
}
Load-Settings
# Liquid Glass accessibility gate: if system-wide transparency is off, degrade to opaque
try {
  $tp = Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue
  if ($tp -and $tp.EnableTransparency -eq 0) { $ui.glass = $false }
} catch {}
$COMPACT_OF = @{ music = 'cMusic'; timer = 'cTimer'; charge = 'cCharge'; done = 'cDone' }
$SECTIONS   = @{ music = 'mMusic'; clip = 'mClip'; weather = 'mWeather'; color = 'mColor'; more = 'mMore'; timer = 'mTimerRun' }
$TABS       = @{ music = 'tbMusic'; clip = 'tbClip'; weather = 'tbWeather'; color = 'tbColor'; more = 'tbMore' }

function Set-Compact([string]$mode) {
  $panelName = $COMPACT_OF[$mode]
  $panel = if ($panelName) { $E[$panelName] } else { $null }
  if ($panel -ne $ui.compactPanel) {
    SwapPanel $ui.compactPanel $panel 130
    $ui.compactPanel = $panel
    if ($mode -eq 'music' -and $ui.eqOn) {
      WaveStart; $ui.waveStarted = $true; $ui.wavePaused = $false
    } else {
      WaveStop; $ui.waveStarted = $false; $ui.wavePaused = $false
    }
  }
}
function Show-Section([string]$name, [int]$delay = 0) {
  foreach ($k in $SECTIONS.Keys) {
    $sec = $E[$SECTIONS[$k]]
    if ($k -eq $name) {
      if ($sec.Visibility -ne 'Visible') {
        $sec.Opacity = 0
        $sec.Visibility = 'Visible'
        $sb = New-Object Windows.Media.Animation.Storyboard
        $d = New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(190))
        $bt = [TimeSpan]::FromMilliseconds($delay)
        $a1 = New-Object Windows.Media.Animation.DoubleAnimation
        $a1.From = 0; $a1.To = 1; $a1.Duration = $d; $a1.BeginTime = $bt
        [Windows.Media.Animation.Storyboard]::SetTarget($a1, $sec)
        [Windows.Media.Animation.Storyboard]::SetTargetProperty($a1, 'Opacity')
        $sb.Children.Add($a1) | Out-Null
        $a2 = New-Object Windows.Media.Animation.DoubleAnimation
        $a2.From = 10; $a2.To = 0; $a2.Duration = $d; $a2.BeginTime = $bt
        $a2.EasingFunction = $script:easeOut
        [Windows.Media.Animation.Storyboard]::SetTarget($a2, $sec)
        [Windows.Media.Animation.Storyboard]::SetTargetProperty($a2, '(UIElement.RenderTransform).(TranslateTransform.Y)')
        $sb.Children.Add($a2) | Out-Null
        $sb.Begin($sec)
      }
    } else {
      $sec.Visibility = 'Hidden'
    }
  }
}
$script:tabActiveBg = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(242, 242, 242))
$script:tabActiveBg.Freeze()
$script:tabActiveFg = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(14, 14, 18))
$script:tabActiveFg.Freeze()
$script:tabIdleFg = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb(0x99, 0xFF, 0xFF, 0xFF))
$script:tabIdleFg.Freeze()
function Set-Tab([string]$tab, [int]$delay = 0) {
  $ui.tab = $tab
  foreach ($k in $TABS.Keys) {
    $btn = $E[$TABS[$k]]
    if ($k -eq $tab) {
      $btn.Background = $script:tabActiveBg
      $btn.Foreground = $script:tabActiveFg
    } else {
      $btn.Background = [Windows.Media.Brushes]::Transparent
      $btn.Foreground = $script:tabIdleFg
    }
  }
  Show-Section $tab $delay
}
function Expand {
  if ($ui.mode -eq 'done') { $ui.mode = 'idle' }
  $ui.expanded = $true
  $E.ExpandedLayer.Visibility = 'Visible'
  $E.CompactLayer.Visibility = 'Hidden'
  # entrance: panel scales up from the pill, tab bar fades in slightly later
  $sb = New-Object Windows.Media.Animation.Storyboard
  $d = New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(300))
  foreach ($pp in @('(UIElement.RenderTransform).(ScaleTransform.ScaleX)', '(UIElement.RenderTransform).(ScaleTransform.ScaleY)')) {
    $a = New-Object Windows.Media.Animation.DoubleAnimation
    $a.From = 0.955; $a.To = 1; $a.Duration = $d
    $a.EasingFunction = $script:easeOut
    [Windows.Media.Animation.Storyboard]::SetTarget($a, $E.ExpandedLayer)
    [Windows.Media.Animation.Storyboard]::SetTargetProperty($a, $pp)
    $sb.Children.Add($a) | Out-Null
  }
  $ab = New-Object Windows.Media.Animation.DoubleAnimation
  $ab.From = 0; $ab.To = 1; $ab.Duration = (New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(210)))
  $ab.BeginTime = [TimeSpan]::FromMilliseconds(50)
  [Windows.Media.Animation.Storyboard]::SetTarget($ab, $E.tabBar)
  [Windows.Media.Animation.Storyboard]::SetTargetProperty($ab, 'Opacity')
  $sb.Children.Add($ab) | Out-Null
  $sb.Begin($E.ExpandedLayer)
  # specular sweep: a light band glides across the glass as it morphs open
  try {
    $swSb = New-Object Windows.Media.Animation.Storyboard
    $swDur = New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(560))
    $ax = New-Object Windows.Media.Animation.DoubleAnimation
    $ax.From = -240; $ax.To = 590; $ax.Duration = $swDur
    $ax.EasingFunction = $script:easeOut
    [Windows.Media.Animation.Storyboard]::SetTarget($ax, $E.sweepX)
    [Windows.Media.Animation.Storyboard]::SetTargetProperty($ax, 'X')
    $swSb.Children.Add($ax) | Out-Null
    $ao = New-Object Windows.Media.Animation.DoubleAnimation
    $ao.From = 0.6; $ao.To = 0; $ao.Duration = $swDur
    [Windows.Media.Animation.Storyboard]::SetTarget($ao, $E.sweepLight)
    [Windows.Media.Animation.Storyboard]::SetTargetProperty($ao, 'Opacity')
    $swSb.Children.Add($ao) | Out-Null
    $swSb.Begin()
  } catch {}
  if ($ui.mode -eq 'timer' -and $ui.timerLeft -gt 0) {
    $E.tabBar.Visibility = 'Collapsed'
    Show-Section 'timer' 70
  } else {
    $E.tabBar.Visibility = 'Visible'
    Set-Tab $ui.tab 70
  }
  Morph 'panel' $true
}
function Collapse {
  $ui.expanded = $false
  $E.ExpandedLayer.Visibility = 'Hidden'
  $E.CompactLayer.Visibility = 'Visible'
  foreach ($k in $SECTIONS.Keys) { $E[$SECTIONS[$k]].Visibility = 'Hidden' }
  Set-Compact $ui.mode
  Morph $ui.mode $false
}

# --- liquid glass + pill tint ---
function Set-PillTint {
  $a = $ui.accent
  $tr = [Math]::Min(255, [int](11 + $a.R * 0.22))
  $tg = [Math]::Min(255, [int](11 + $a.G * 0.22))
  $tb = [Math]::Min(255, [int](15 + $a.B * 0.22))
  if ($ui.glass) {
    $al = [byte][Math]::Max(90, 255 - [int](1.65 * $ui.glassAlpha))
    $col = [Windows.Media.Color]::FromArgb($al, [byte]$tr, [byte]$tg, [byte]$tb)
    $shCol = [Windows.Media.Color]::FromArgb(70, 11, 11, 15)
  } else {
    $col = [Windows.Media.Color]::FromRgb([byte]$tr, [byte]$tg, [byte]$tb)
    $shCol = $col
  }
  # cross-fade the pill color instead of snapping it
  foreach ($pair in @(@('Island', $col), @('IslandShadow', $shCol))) {
    $old = $E[$pair[0]].Background
    $from = $null
    if ($old -is [Windows.Media.SolidColorBrush] -and -not $old.IsFrozen) { $from = $old.Color }
    $nb = New-Object Windows.Media.SolidColorBrush $pair[1]
    $E[$pair[0]].Background = $nb
    if ($null -ne $from) {
      $ca = New-Object Windows.Media.Animation.ColorAnimation
      $ca.From = $from; $ca.To = $pair[1]
      $ca.Duration = (New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(320)))
      $ca.EasingFunction = $script:easeOut
      $nb.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $ca)
    }
  }
}
function Update-GlassPos {
  if (-not $ui.glass) { return }
  try {
    $cl = [double]$E.IslandHost.GetValue([Windows.Controls.Canvas]::LeftProperty)
    $ct = [double]$E.IslandHost.GetValue([Windows.Controls.Canvas]::TopProperty)
    $glassWin.Left = $window.Left + $cl
    $glassWin.Top = $window.Top + $ct
    $glassWin.Width = $E.IslandHost.ActualWidth
    $glassWin.Height = $E.IslandHost.ActualHeight
  } catch {}
}
function Update-Glass {
  Set-PillTint
  try {
    $pol = New-Object Win32.ACCENT_POLICY
    if ($ui.glass) {
      # 4 = ACCENT_ENABLE_ACRYLICBLURBEHIND; neutral dark tint so the accent color stays on top
      $pol.AccentState = 4
      $pol.GradientColor = [uint32](((110 -shl 24) -bor (15 -shl 16) -bor (11 -shl 8) -bor 11) -band 0x7FFFFFFF)
      if (-not $glassWin.IsVisible) {
        Update-GlassPos
        $glassWin.Show()
        [void][Win32.Compo]::SetWindowPos($glassHwnd, $mainHwnd, 0, 0, 0, 0, 0x13)
      }
    } else {
      $pol.AccentState = 0
      if ($glassWin.IsVisible) { $glassWin.Hide() }
    }
    [void][Win32.Compo]::SetWindowCompositionAttribute($glassHwnd, [ref]$pol)
  } catch {}
  $E.slAlpha.IsEnabled = $ui.glass
}

# --- accent color dots ---
$ACCENTS = @(
  @(242,242,242), @(255,69,58), @(255,159,10), @(255,214,10), @(48,209,88),
  @(100,210,255), @(10,132,255), @(191,90,242), @(255,55,95), @(172,142,104), @(16,16,18)
)
foreach ($a in $ACCENTS) {
  $btn = New-Object System.Windows.Controls.Button
  $btn.Style = $E.dotsHost.FindResource('DotBtn')
  $btn.Background = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb([byte]$a[0], [byte]$a[1], [byte]$a[2]))
  $btn.Add_Click([System.Windows.RoutedEventHandler]{
    param($snd, $ev)
    Apply-Accent ([Windows.Media.SolidColorBrush]$snd.Background).Color
  })
  $null = $E.dotsHost.Children.Add($btn)
}
function Apply-Accent([Windows.Media.Color]$c) {
  $ui.accent = $c
  $br = New-Object Windows.Media.SolidColorBrush $c
  $br.Freeze()
  foreach ($n in 'w1','w2','w3','w4','w5') { $E[$n].Fill = $br }
  $E.mProgFill.Background = $br
  $E.colPrev.Background = $br
  Set-PillTint
  Save-Settings
}
Apply-Accent $ui.accent
$E.swEq.IsChecked = $ui.eqOn
$E.swCharge.IsChecked = $ui.showCharge
if (-not $ui.eqOn) { $E.wavePanel.Visibility = 'Collapsed' }
$E.swAuto.IsChecked = ($null -ne (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'DynamicIsland' -ErrorAction SilentlyContinue))
$E.swGlass.IsChecked = $ui.glass
$E.slAlpha.Value = $ui.glassAlpha

# --- media keys ---
$VK_PLAY = 0xB3; $VK_NEXT = 0xB0; $VK_PREV = 0xB1

# --- liquid glass lens: specular sheen glides with the cursor ---
$script:lensOn = $false
$E.Island.Add_MouseMove({
  param($snd, $ev)
  if (-not $ui.glass) { return }
  $p = $ev.GetPosition($E.Island)
  $tt = $E.lensGlow.RenderTransform
  $tt.X = $p.X - 85
  $tt.Y = $p.Y - 85
  $tc = $E.lensCoreT
  $tc.X = $p.X - 32
  $tc.Y = $p.Y - 32
  if (-not $script:lensOn) {
    $script:lensOn = $true
    $a = New-Object Windows.Media.Animation.DoubleAnimation
    $a.To = 1; $a.Duration = (New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(160)))
    $a.EasingFunction = $script:easeOut
    $E.glassLens.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $a)
  }
})
$E.Island.Add_MouseLeave({
  param($snd, $ev)
  if (-not $script:lensOn) { return }
  $script:lensOn = $false
  $a = New-Object Windows.Media.Animation.DoubleAnimation
  $a.To = 0; $a.Duration = (New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(260)))
  $a.EasingFunction = $script:easeOut
  $E.glassLens.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $a)
})

# --- island click: expand when collapsed ---
$E.Island.AddHandler([System.Windows.UIElement]::MouseLeftButtonDownEvent,
  ([System.Windows.Input.MouseButtonEventHandler]{
    param($snd, $ev)
    if (-not $ui.expanded) { Expand }
  }), $false)

$window.Add_PreviewKeyDown({ param($snd, $ev) if ($ev.Key -eq 'Escape' -and $ui.expanded) { Collapse } })

# --- buttons ---
$E.btnPlay.Add_Click({ Send-MediaKey $VK_PLAY })
$E.btnPrev.Add_Click({ Send-MediaKey $VK_PREV })
$E.btnNext.Add_Click({ Send-MediaKey $VK_NEXT })
$E.btnX.Add_Click({ Collapse })
$E.btnPause.Add_Click({
  $ui.timerPaused = -not $ui.timerPaused
  $E.btnPause.Content = if ($ui.timerPaused) { 'Дальше' } else { 'Пауза' }
})
$E.btnStop.Add_Click({ $ui.timerLeft = 0; $ui.timerPaused = $false; $ui.mode = 'idle'; Collapse })
foreach ($id in 't1','t5','t10') {
  $E[$id].Add_Click({
    param($snd, $ev)
    $ui.timerTotal = switch ($snd.Name) { 't1' { 60 } 't5' { 300 } 't10' { 600 } default { 300 } }
    $ui.timerLeft = $ui.timerTotal
    $ui.timerPaused = $false
    $ui.mode = 'timer'
    $E.cTimerTxt.Text = "{0}:{1}" -f [int][Math]::Floor($ui.timerLeft / 60), ("{0:d2}" -f ($ui.timerLeft % 60))
    $E.xTimerBig.Text = $E.cTimerTxt.Text
    $ui.lastCompact = 'timer'
    Collapse
  })
}
foreach ($id in 'tbMusic','tbClip','tbWeather','tbColor','tbMore') {
  $E[$id].Add_Click([System.Windows.RoutedEventHandler]{
    param($snd, $ev)
    Set-Tab $snd.Name.Substring(2).ToLower()
  })
}
foreach ($id in 'cb1','cb2','cb3','cb4','cb5','cb6') {
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
          $fa = New-Object Windows.Media.Animation.DoubleAnimation
          $fa.From = 0.22; $fa.To = 0
          $fa.Duration = (New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(260)))
          $fa.EasingFunction = $script:easeOut
          $hov.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fa)
        }
      } catch {}
    }
  })
}
$E.swAuto.Add_Click({
  $on = [bool]$E.swAuto.IsChecked
  $runKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
  $vbsPath = Join-Path $PSScriptRoot 'Dynamic Island.vbs'
  if ($on) {
    Set-ItemProperty -Path $runKeyPath -Name 'DynamicIsland' -Value ('wscript.exe "' + $vbsPath + '"') -ErrorAction SilentlyContinue
  } else {
    Remove-ItemProperty -Path $runKeyPath -Name 'DynamicIsland' -ErrorAction SilentlyContinue
  }
  if ($miAuto) { $miAuto.Checked = $on }
})
$E.swEq.Add_Click({
  $ui.eqOn = [bool]$E.swEq.IsChecked
  if ($ui.eqOn -and $ui.compactPanel -eq $E.cMusic -and -not $ui.expanded) {
    $E.wavePanel.Visibility = 'Visible'; WaveStart; $ui.waveStarted = $true; $ui.wavePaused = $false
  } else {
    $E.wavePanel.Visibility = 'Collapsed'; WaveStop; $ui.waveStarted = $false; $ui.wavePaused = $false
  }
  Save-Settings
})
$E.swCharge.Add_Click({ $ui.showCharge = [bool]$E.swCharge.IsChecked; Save-Settings })
$E.swGlass.Add_Click({
  $ui.glass = [bool]$E.swGlass.IsChecked
  Update-Glass
  Save-Settings
})
$E.slAlpha.Add_ValueChanged({
  param($snd, $ev)
  $ui.glassAlpha = [int][Math]::Round($snd.Value)
  Update-Glass
  Save-Settings
})
$E.btnQuit.Add_Click({ $sync.Running = $false; $ni.Visible = $false; $app.Shutdown() })

# --- timer tick (1 s) ---
$timerDt = New-Object Windows.Threading.DispatcherTimer
$timerDt.Interval = [TimeSpan]::FromSeconds(1)
$timerDt.Add_Tick({
  if ($ui.mode -eq 'timer' -and -not $ui.timerPaused -and $ui.timerLeft -gt 0) {
    $ui.timerLeft--
    $t = "{0}:{1}" -f [int][Math]::Floor($ui.timerLeft / 60), ("{0:d2}" -f ($ui.timerLeft % 60))
    $E.cTimerTxt.Text = $t
    $E.xTimerBig.Text = $t
    if ($ui.timerLeft -le 0) {
      $ui.mode = 'done'; $ui.lastCompact = 'done'
      if ($ui.expanded) { Collapse }
      Set-Compact 'done'
      Morph 'done' $true
      $script:doneDt = New-Object Windows.Threading.DispatcherTimer
      $script:doneDt.Interval = [TimeSpan]::FromSeconds(2.6)
      $script:doneDt.Add_Tick({
        $script:doneDt.Stop()
        if ($ui.mode -eq 'done') {
          $ui.mode = 'idle'; $ui.lastCompact = 'idle'
          Set-Compact 'idle'
          if ($ui.expanded) { Expand } else { Morph 'idle' $false }
        }
      })
      $script:doneDt.Start()
    }
  }
})
$timerDt.Start()

# ============================================================
#  SMTC/clipboard/weather sync (every 250 ms)
# ============================================================
$poll = New-Object Windows.Threading.DispatcherTimer
$poll.Interval = [TimeSpan]::FromMilliseconds(250)
$poll.Add_Tick({
  $st = $sync.State
  if (-not $st) { return }

  $musicOn = ($st.mode -eq 'music')
  $want = if ($ui.mode -eq 'timer' -and $ui.timerLeft -gt 0) { 'timer' }
          elseif ($ui.mode -eq 'done') { 'done' }
          elseif ($musicOn) { 'music' }
          elseif ($st.charging -and $ui.showCharge) { 'charge' }
          else { 'idle' }

  if ($ui.mode -ne 'timer' -and $ui.mode -ne 'done') { $ui.mode = $want }

  if ($want -ne $ui.lastCompact) {
    if (-not $ui.expanded) {
      Set-Compact $want
      Morph $want $false
    }
    $ui.lastCompact = $want
  }

  if ($musicOn) {
    if ($st.title -ne $ui.lastTitle) {
      $ui.lastTitle = $st.title
      $E.cMusicTxt.Text = $st.title
      $E.mTitle.Text = $st.title
      $E.mArtist.Text = if ($st.artist) { $st.artist } else { ' ' }
    }
    if ($st.thumb -ne $ui.lastArt) {
      $ui.lastArt = $st.thumb
      try {
        if ($st.thumb) {
          $bytes = [Convert]::FromBase64String($st.thumb)
          $ms = New-Object System.IO.MemoryStream (,$bytes)
          $bi = New-Object Windows.Media.Imaging.BitmapImage
          $bi.BeginInit(); $bi.StreamSource = $ms; $bi.CacheOption = 'OnLoad'; $bi.EndInit(); $bi.Freeze()
          $ms.Dispose()
          $E.artS.ImageSource = $bi
          $E.artB.ImageSource = $bi
          foreach ($ab in @($E.artS, $E.artB)) {
            $aa = New-Object Windows.Media.Animation.DoubleAnimation
            $aa.From = 0; $aa.To = 1
            $aa.Duration = (New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(260)))
            $aa.EasingFunction = $script:easeOut
            $ab.BeginAnimation([Windows.Media.Brush]::OpacityProperty, $aa)
          }
        } else {
          $E.artS.ImageSource = $null; $E.artB.ImageSource = $null
        }
      } catch {}
    }
    $playing = ($st.status -eq 'Playing' -or $st.status -eq 'Buffering')
    if (-not $playing -and $ui.waveStarted -and -not $ui.wavePaused) { WavePause; $ui.wavePaused = $true }
    if ($playing -and $ui.wavePaused) { WaveResume; $ui.wavePaused = $false }
    $ico = if ($playing) { 'M8 5 h3 v14 H8 z M13.5 5 h3 v14 h-3 z' } else { 'M8 5 v14 l11-7 Z' }
    if ($E.playIco.Data.ToString() -ne $ico) {
      $E.playIco.Data = [Windows.Media.Geometry]::Parse($ico)
    }
    if ($st.len -gt 0) {
      $pos = $st.pos + $(if ($playing) { ((Get-Date).ToUniversalTime() - $st.ts).TotalSeconds } else { 0 })
      if ($pos -gt $st.len) { $pos = $st.len }
      # guard: ignore small backward jumps (artifact of lazy SMTC updates); real seeks are bigger
      $drop = $ui.lastPos - $pos
      if ($drop -gt 0.6 -and $drop -lt 5.0 -and $st.title -eq $ui.lastTitle) { $pos = $ui.lastPos }
      $ui.lastPos = $pos
      $frac = $pos / $st.len
      $tw = $E.mProgTrack.ActualWidth
      if ($tw -gt 10) { $E.mProgFill.Width = [Math]::Max(0, $tw * $frac) }
      $E.mPos.Text = "{0}:{1}" -f [int][Math]::Floor($pos / 60), ("{0:d2}" -f ([int]$pos % 60))
      $rem = $st.len - $pos
      $E.mRem.Text = "-{0}:{1}" -f [int][Math]::Floor($rem / 60), ("{0:d2}" -f ([int]$rem % 60))
    }
  }

  # clipboard list
  $clip = $sync.Clip
  $n = if ($clip) { [Math]::Min($clip.Count, 6) } else { 0 }
  for ($i = 1; $i -le 6; $i++) {
    $btn = $E["cb$i"]
    if ($i -le $n) { $btn.Visibility = 'Visible'; $btn.Content = $clip[$i - 1] }
    else { $btn.Visibility = 'Collapsed' }
  }
  $E.clipHint.Visibility = if ($n -eq 0) { 'Visible' } else { 'Collapsed' }

  # weather
  $wx = $sync.Weather
  if ($wx) {
    if ($wx.city) {
      if ($E.wCity.Text -ne $wx.city) {
        $E.wIcon.Text = $wx.icon
        $E.wTemp.Text = "$($wx.temp)°"
        $E.wCity.Text = $wx.city
        $E.wFeels.Text = "Ощущается как $($wx.feels)°"
        $E.wHum.Text = "Влажность $($wx.hum)% · Ветер $($wx.wind) км/ч"
        for ($i = 1; $i -le 3; $i++) {
          $d = $wx.days[$i - 1]
          $E["wd${i}d"].Text = $d[0]
          $E["wd${i}i"].Text = $d[1]
          $E["wd${i}t"].Text = "$($d[2])° / $($d[3])°"
        }
      }
    } elseif ($E.wCity.Text -ne 'Нет данных') {
      $E.wCity.Text = 'Нет данных'
      $E.wTemp.Text = '—°'
    }
  }

  Update-GlassPos
})
$poll.Start()

# ============================================================
#  Tray icon
# ============================================================
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

$ni = New-Object System.Windows.Forms.NotifyIcon
$ni.Icon = $icon
$ni.Text = 'Dynamic Island'
$ni.Visible = $true

$cms = New-Object System.Windows.Forms.ContextMenuStrip
$runKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$vbsPath = Join-Path $PSScriptRoot 'Dynamic Island.vbs'
$miAuto = New-Object System.Windows.Forms.ToolStripMenuItem 'Запускать при входе в Windows'
$miAuto.CheckOnClick = $true
$miAuto.Checked = ($null -ne (Get-ItemProperty -Path $runKeyPath -Name 'DynamicIsland' -ErrorAction SilentlyContinue))
$miAuto.Add_Click({
  if ($miAuto.Checked) {
    Set-ItemProperty -Path $runKeyPath -Name 'DynamicIsland' -Value ('wscript.exe "' + $vbsPath + '"')
  } else {
    Remove-ItemProperty -Path $runKeyPath -Name 'DynamicIsland' -ErrorAction SilentlyContinue
  }
  if ($E.swAuto) { $E.swAuto.IsChecked = $miAuto.Checked }
})
$miExit = New-Object System.Windows.Forms.ToolStripMenuItem 'Выход'
$miExit.Add_Click({ $sync.Running = $false; $ni.Visible = $false; $app.Shutdown() })
[void]$cms.Items.Add($miAuto)
[void]$cms.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$cms.Items.Add($miExit)
$ni.ContextMenuStrip = $cms

# ============================================================
#  Position + run
# ============================================================
$wa = [System.Windows.SystemParameters]::WorkArea
$window.Left = ($wa.Width - $WIN_W) / 2
$window.Top = $wa.Top
Update-Glass

$window.Add_Closed({ $sync.Running = $false; $ni.Visible = $false; $ni.Dispose() })
$window.Show()
[void]$app.Run()
