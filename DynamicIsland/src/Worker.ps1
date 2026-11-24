# ============================================================
#  Background worker (own runspace): media session (SMTC), battery,
#  clipboard history.  Talks to the UI only through $sync.
# ============================================================
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('Win32.Clip' -as [type])) {
Add-Type -Namespace Win32 -Name Clip -MemberDefinition @"
[DllImport("user32.dll")] public static extern bool OpenClipboard(IntPtr h);
[DllImport("user32.dll")] public static extern bool CloseClipboard();
[DllImport("user32.dll")] public static extern IntPtr GetClipboardData(uint fmt);
[DllImport("kernel32.dll")] public static extern IntPtr GlobalLock(IntPtr h);
[DllImport("kernel32.dll")] public static extern bool GlobalUnlock(IntPtr h);
"@
}
function WLog($m) { try { $sync.Log.Enqueue("worker: $m") } catch {} }

function Get-ClipboardTextSafe {
  for ($i = 0; $i -lt 3; $i++) {
    if ([Win32.Clip]::OpenClipboard([IntPtr]::Zero)) {
      try {
        $h = [Win32.Clip]::GetClipboardData(13)   # CF_UNICODETEXT
        if ($h -ne [IntPtr]::Zero) {
          $p = [Win32.Clip]::GlobalLock($h)
          if ($p -ne [IntPtr]::Zero) {
            $s = [Runtime.InteropServices.Marshal]::PtrToStringUni($p)
            $null = [Win32.Clip]::GlobalUnlock($h)
            if ($s -and $s.Length -gt 20000) { $s = $s.Substring(0, 20000) }
            return $s
          }
        }
      } finally { [void][Win32.Clip]::CloseClipboard() }
    }
    Start-Sleep -Milliseconds 40
  }
  return $null
}

# ---------- WinRT plumbing ----------
$null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
$null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSession, Windows.Media.Control, ContentType = WindowsRuntime]
$null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties, Windows.Media.Control, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.DataReader, Windows.Storage.Streams, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.IRandomAccessStreamWithContentType, Windows.Storage.Streams, ContentType = WindowsRuntime]

$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() |
  Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await($op, $t, [int]$ms = 4000) {
  $task = $asTaskGeneric.MakeGenericMethod($t).Invoke($null, @($op))
  # never wait forever: a hung player must not freeze the media session AND the clipboard history
  if (-not $task.Wait($ms)) { throw 'WinRT call timed out' }
  $task.Result
}
$mgr = $null
try {
  $mgr = Await ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]) 30000
} catch { $mgr = $null; WLog "SMTC manager unavailable: $($_.Exception.Message)" }

# ---------- album art ----------
function Get-ThumbBytes($props) {
  try {
    $ref = $props.Thumbnail
    if (-not $ref) { return $null }
    $ras = Await ($ref.OpenReadAsync()) ([Windows.Storage.Streams.IRandomAccessStreamWithContentType])
    if (-not $ras -or $ras.Size -le 0) { return $null }
    $size = [UInt32][Math]::Min($ras.Size, [uint64]2000000)
    $dr = New-Object Windows.Storage.Streams.DataReader($ras)
    $null = Await ($dr.LoadAsync($size)) ([System.UInt32])
    $bytes = New-Object byte[] $size
    $dr.ReadBytes($bytes)
    try { $dr.Dispose() } catch {}
    try { $ras.Dispose() } catch {}
    return ,$bytes
  } catch { return $null }
}
function Get-UrlBytes([string]$url) {
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)')
    $b = $wc.DownloadData($url)
    if ($b -and $b.Length -gt 500) { return ,$b }
  } catch {}
  return $null
}
function Get-NetArt([string]$title, [string]$artist) {
  $b = $null
  try {
    $q = [uri]::EscapeDataString(($artist + ' ' + $title))
    $r = Invoke-RestMethod ('https://api.deezer.com/search?q=' + $q + '&limit=1') -TimeoutSec 5
    if ($r.data -and $r.data.Count -gt 0) {
      $url = $r.data[0].album.cover_big
      if (-not $url) { $url = $r.data[0].album.cover_medium }
      if ($url) { $b = Get-UrlBytes $url }
    }
  } catch {}
  if (-not $b) {
    try {
      $q2 = [uri]::EscapeDataString(($title + ' ' + $artist))
      $r2 = Invoke-RestMethod ('https://itunes.apple.com/search?term=' + $q2 + '&limit=1') -TimeoutSec 5
      if ($r2.results -and $r2.results.Count -gt 0) {
        $u = $r2.results[0].artworkUrl100
        if ($u) { $u = $u -replace '100x100', '512x512bb'; $b = Get-UrlBytes $u }
      }
    } catch {}
  }
  return $b
}
# average colour of the cover, weighted towards saturated pixels -> glass tint
function Get-Tint([byte[]]$bytes) {
  try {
    $ms = New-Object IO.MemoryStream (,$bytes)
    $bmp = New-Object System.Drawing.Bitmap $ms
    $sm = New-Object System.Drawing.Bitmap 8, 8
    $g = [System.Drawing.Graphics]::FromImage($sm)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.DrawImage($bmp, 0, 0, 8, 8)
    $g.Dispose()
    $sr = 0.0; $sg = 0.0; $sb = 0.0; $sw = 0.0
    for ($y = 0; $y -lt 8; $y++) {
      for ($x = 0; $x -lt 8; $x++) {
        $c = $sm.GetPixel($x, $y)
        $mx = [Math]::Max($c.R, [Math]::Max($c.G, $c.B)); $mn = [Math]::Min($c.R, [Math]::Min($c.G, $c.B))
        $w = 0.08 + (($mx - $mn) / 255.0) * (1.0 - [Math]::Abs($mx - 150) / 220.0)
        if ($w -lt 0.02) { $w = 0.02 }
        $sr += $c.R * $w; $sg += $c.G * $w; $sb += $c.B * $w; $sw += $w
      }
    }
    $sm.Dispose(); $bmp.Dispose(); $ms.Dispose()
    if ($sw -le 0) { return $null }
    $r = $sr / $sw; $g2 = $sg / $sw; $b = $sb / $sw
    # lift very dark covers a bit so the glass still gets some colour
    $m = [Math]::Max($r, [Math]::Max($g2, $b))
    if ($m -lt 90 -and $m -gt 0) { $k = 90.0 / $m; $r *= $k; $g2 *= $k; $b *= $k }
    return @([int][Math]::Min(255, $r), [int][Math]::Min(255, $g2), [int][Math]::Min(255, $b))
  } catch { return $null }
}

# ---------- cover art lookups on the internet run in their OWN runspace ----------
# (a slow Deezer/iTunes request must never delay play/pause/track-change updates)
function Get-FnText([string]$n) { return ('function ' + $n + " {`n" + (Get-Item ('function:' + $n)).ScriptBlock.ToString() + "`n}`n") }
$art = [hashtable]::Synchronized(@{
  Q = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]')
  R = (New-Object 'System.Collections.Concurrent.ConcurrentDictionary[string,object]')
})
$artLoop = @'
while ($sync.Running) {
  $job = $null
  if ($art.Q.TryDequeue([ref]$job)) {
    $res = @{ bytes = $null; tint = $null }
    try {
      $b = Get-NetArt $job.title $job.artist
      if ($b) { $res.bytes = $b; $res.tint = Get-Tint $b }
    } catch {}
    $art.R[[string]$job.key] = $res
  } else { Start-Sleep -Milliseconds 100 }
}
'@
$artText = "Add-Type -AssemblyName System.Drawing`n" + (Get-FnText 'Get-UrlBytes') + (Get-FnText 'Get-NetArt') + (Get-FnText 'Get-Tint') + $artLoop
try {
  $artRs = [runspacefactory]::CreateRunspace(); $artRs.Open()
  $artRs.SessionStateProxy.SetVariable('sync', $sync)
  $artRs.SessionStateProxy.SetVariable('art', $art)
  $artPs = [powershell]::Create(); $artPs.Runspace = $artRs
  $null = $artPs.AddScript($artText); $null = $artPs.BeginInvoke()
} catch { WLog "art runspace failed: $($_.Exception.Message)" }

# ---------- state ----------
$clipHist = New-Object 'System.Collections.Generic.List[string]'
$lastClip = ''
$lastSeq = [uint32]0
$wlp = 0.0; $wlpAt = 0; $wTitle = ''; $wfrz = $false; $wfrzAt = 0.0; $pPrev = -1.0
$artCache = @{}
$artFail = @{}
$artPending = @{}
$curKey = ''; $keySince = 0; $lastSig = ''; $lastSigKey = ''; $lastEnt = $null
$lastMusic = $null; $lastMusicAt = 0
WLog 'started'

while ($sync.Running) {
  $st = @{ mode = 'idle'; title = ''; artist = ''; status = ''; pos = 0.0; len = 0.0; art = $null; artKey = ''; tint = $null; batt = 0; hasBatt = $false; charging = $false; ts = [DateTime]::UtcNow }
  $nowMs = [DateTime]::UtcNow.Ticks / 10000
  try {
    if ($mgr) {
      $s = $mgr.GetCurrentSession()
      if (-not $s) {
        $ss = $mgr.GetSessions()
        if ($ss.Count -gt 0) { $s = $ss[0] }
      }
      # play / pause / next / previous from the island go to THE SAME session it shows
      # (media keys go to whatever Windows picks). The key press is only a fallback.
      $cmd = [string]$sync.Cmd
      if ($cmd) {
        $sync.Cmd = ''
        $tried = $false
        if ($s) {
          try {
            if ($cmd -eq 'play') { $null = Await ($s.TryPlayAsync()) ([bool]) }
            elseif ($cmd -eq 'pause') { $null = Await ($s.TryPauseAsync()) ([bool]) }
            elseif ($cmd -eq 'next') { $null = Await ($s.TrySkipNextAsync()) ([bool]) }
            elseif ($cmd -eq 'prev') { $null = Await ($s.TrySkipPreviousAsync()) ([bool]) }
            $tried = $true
          } catch { WLog "cmd $cmd failed: $($_.Exception.Message)" }
        }
        if (-not $tried) {
          $vk = 0xB3
          if ($cmd -eq 'next') { $vk = 0xB0 } elseif ($cmd -eq 'prev') { $vk = 0xB1 }
          try { [DI.Native]::MediaKey($vk) } catch {}
        }
      }
      if ($s) {
        # seek request from the UI (click on the progress bar)
        if ($sync.Seek -ge 0) {
          $seekTo = [double]$sync.Seek; $sync.Seek = -1.0
          try {
            $null = Await ($s.TryChangePlaybackPositionAsync([long]($seekTo * 10000000))) ([bool])
            $wlp = $seekTo; $wlpAt = $nowMs; $wfrz = $false
          } catch { WLog "seek failed: $($_.Exception.Message)" }
        }
        try {
          $pb = $s.GetPlaybackInfo()
          $status = [string]$pb.PlaybackStatus
          $props = Await ($s.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
          if ($props -and $props.Title -and ($status -eq 'Playing' -or $status -eq 'Paused')) {
            $st.mode = 'music'; $st.status = $status
            $st.title = [string]$props.Title
            $st.artist = [string]$props.Artist
            $akey = ($st.artist + '|' + $st.title).ToLower()
            if ($akey -ne $curKey) { $curKey = $akey; $keySince = $nowMs }
            $ent = $null
            $shownKey = $akey
            if ($artCache.ContainsKey($akey)) {
              $ent = $artCache[$akey]
            } elseif ($artPending.ContainsKey($akey)) {
              # the internet lookup runs in the art runspace: just collect its answer
              $res = $null
              if ($art.R.TryRemove($akey, [ref]$res)) {
                $null = $artPending.Remove($akey)
                if ($res -and $res.bytes) {
                  $ent = @{ bytes = $res.bytes; tint = $res.tint }
                  if ($artCache.Count -gt 24) { $artCache.Clear() }
                  $artCache[$akey] = $ent
                } else { $artFail[$akey] = $nowMs }
              } elseif (($nowMs - $artPending[$akey]) -gt 20000) {
                $null = $artPending.Remove($akey); $artFail[$akey] = $nowMs
              }
            } elseif (-not ($artFail.ContainsKey($akey) -and ($nowMs - $artFail[$akey]) -lt 60000)) {
              $b = Get-ThumbBytes $props
              if ($b) {
                $sig = [string]$b.Length + ':' + [BitConverter]::ToString($b, 0, [Math]::Min(24, $b.Length))
                if (($sig -eq $lastSig) -and ($akey -ne $lastSigKey) -and (($nowMs - $keySince) -lt 2500)) {
                  # some players keep handing out the PREVIOUS cover for a moment after a track change:
                  # show it, but do not cache it for the new track yet
                  $ent = $lastEnt; $shownKey = $lastSigKey
                } else {
                  $ent = @{ bytes = $b; tint = (Get-Tint $b) }
                  if ($artCache.Count -gt 24) { $artCache.Clear() }
                  $artCache[$akey] = $ent
                  $lastSig = $sig; $lastSigKey = $akey; $lastEnt = $ent
                }
              } else {
                $art.Q.Enqueue(@{ key = $akey; title = $st.title; artist = $st.artist })
                $artPending[$akey] = $nowMs
              }
            }
            $st.artKey = $shownKey
            if ($ent) { $st.art = $ent.bytes; $st.tint = $ent.tint }
            try {
              $tl = $s.GetTimelineProperties()
              $st.len = $tl.EndTime.TotalSeconds
              $p = $tl.Position.TotalSeconds
              # SMTC position updates lazily and PlaybackStatus briefly flaps; drive the position with our
              # own clock and only resync when the player really refreshed its timeline.
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
    if ($st.mode -eq 'music') { $lastMusic = $st.Clone(); $lastMusicAt = $nowMs }
    elseif ($lastMusic -and (($nowMs - $lastMusicAt) -lt 2500)) {
      foreach ($k in @('mode', 'title', 'artist', 'status', 'pos', 'len', 'art', 'artKey', 'tint', 'ts')) { $st[$k] = $lastMusic[$k] }
    }
    $pw = [System.Windows.Forms.SystemInformation]::PowerStatus
    $st.hasBatt = (([int]$pw.BatteryChargeStatus -band 128) -eq 0)
    if ($st.hasBatt) {
      $st.batt = [int][Math]::Round($pw.BatteryLifePercent * 100)
      $st.charging = ($pw.PowerLineStatus.ToString() -eq 'Online')
    }
  } catch {}

  # ---- clipboard history: only look when the clipboard sequence number changed ----
  try {
    if ($sync.ClipClear) { $clipHist.Clear(); $sync.Clip = @(); $sync.ClipClear = $false }
    $seq = [DI.Native]::GetClipboardSequenceNumber()
    if ($seq -ne $lastSeq) {
      $lastSeq = $seq
      if (-not [DI.Native]::ClipboardIsExcluded()) {
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
            while ($clipHist.Count -gt 40) { $clipHist.RemoveAt($clipHist.Count - 1) }
            $sync.Clip = $clipHist.ToArray()
          }
        }
      }
    }
  } catch { WLog "clipboard: $($_.Exception.Message)" }

  $sync.State = $st
  Start-Sleep -Milliseconds 100
}
