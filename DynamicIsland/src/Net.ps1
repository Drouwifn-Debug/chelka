# ============================================================
#  Internet worker (own runspace): weather, city search, song lyrics, calendar (.ics).
#  Slow network calls live here so the media session never waits for them.
#  Talks to the UI only through $sync (requests in, results out).
# ============================================================
$ErrorActionPreference = 'Continue'
$inv = [Globalization.CultureInfo]::InvariantCulture
# this script runs in four runspaces: 'lyr' (song lyrics), 'wx' (weather + calendar), 'city' (city search), 'upd' (updates),
# so a slow request of one kind never delays the others
if (-not $role) { $role = 'all' }
function NLog($m) { try { $sync.Log.Enqueue("net: $m") } catch {} }

function Get-Text([string]$url, [int]$timeoutMs = 9000) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $req = [Net.HttpWebRequest]::Create($url)
  $req.UserAgent = 'DynamicIsland/2.7 (desktop widget)'
  $req.Timeout = $timeoutMs
  $req.ReadWriteTimeout = $timeoutMs
  $req.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
  $resp = $req.GetResponse()
  $txt = ''
  try {
    $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
    $txt = $sr.ReadToEnd()
    $sr.Dispose()
  } finally { $resp.Close() }
  return $txt
}
function Get-Json([string]$url, [int]$timeoutMs = 9000) {
  return ((Get-Text $url $timeoutMs) | ConvertFrom-Json)
}

# ---------------------------------------------------------------- weather
function WmoKey([int]$c, [bool]$day) {
  if ($c -eq 0 -or $c -eq 1) { if ($day) { return 'sun' } else { return 'moon' } }
  if ($c -eq 2) { return 'pcloud' }
  if ($c -eq 3) { return 'cloud' }
  if ($c -eq 45 -or $c -eq 48) { return 'fog' }
  if ($c -ge 51 -and $c -le 57) { return 'drizzle' }
  if (($c -ge 61 -and $c -le 67) -or ($c -ge 80 -and $c -le 82)) { return 'rain' }
  if (($c -ge 71 -and $c -le 77) -or $c -eq 85 -or $c -eq 86) { return 'snow' }
  if ($c -ge 95) { return 'storm' }
  return 'cloud'
}
function WmoText([int]$c) {
  if ($c -eq 0) { return 'Ясно' }
  if ($c -eq 1) { return 'Малооблачно' }
  if ($c -eq 2) { return 'Переменная облачность' }
  if ($c -eq 3) { return 'Пасмурно' }
  if ($c -eq 45 -or $c -eq 48) { return 'Туман' }
  if ($c -ge 51 -and $c -le 57) { return 'Морось' }
  if (($c -ge 61 -and $c -le 65) -or $c -eq 66 -or $c -eq 67) { return 'Дождь' }
  if ($c -ge 80 -and $c -le 82) { return 'Ливень' }
  if (($c -ge 71 -and $c -le 77)) { return 'Снег' }
  if ($c -eq 85 -or $c -eq 86) { return 'Снегопад' }
  if ($c -ge 95) { return 'Гроза' }
  return 'Облачно'
}
function WwoKey([int]$c) {
  if ($c -eq 113) { return 'sun' }
  if ($c -eq 116) { return 'pcloud' }
  if ($c -eq 119 -or $c -eq 122) { return 'cloud' }
  if ($c -in 143, 248, 260) { return 'fog' }
  if ($c -in 200, 386, 389, 392, 395) { return 'storm' }
  if ($c -in 179, 182, 185, 227, 230, 317, 320, 323, 326, 329, 332, 335, 338, 350, 368, 371, 374, 377) { return 'snow' }
  if ($c -in 263, 266, 281, 284) { return 'drizzle' }
  return 'rain'
}
$script:autoGeo = $null
$script:autoGeoAt = 0
function Get-AutoGeo {
  # the place found by IP is remembered for 30 minutes (a VPN / a trip changes it)
  $age = [Environment]::TickCount - $script:autoGeoAt
  if ($script:autoGeo -and $age -ge 0 -and $age -lt 1800000) { return $script:autoGeo }
  try {
    $g = Get-Json 'https://ipwho.is/?lang=ru' 7000
    if ($g.latitude) { $script:autoGeo = @{ lat = [double]$g.latitude; lon = [double]$g.longitude; city = [string]$g.city }; $script:autoGeoAt = [Environment]::TickCount; return $script:autoGeo }
  } catch { NLog "ipwho.is failed: $($_.Exception.Message)" }
  try {
    $g = Get-Json 'https://ipapi.co/json/' 7000
    if ($g.latitude) { $script:autoGeo = @{ lat = [double]$g.latitude; lon = [double]$g.longitude; city = [string]$g.city }; $script:autoGeoAt = [Environment]::TickCount; return $script:autoGeo }
  } catch { NLog "ipapi.co failed: $($_.Exception.Message)" }
  if ($script:autoGeo) { return $script:autoGeo }
  return $null
}
function Get-GeoByName([string]$name) {
  try {
    $r = @(Search-City $name)
    if ($r.Count -gt 0) { return @{ lat = [double]$r[0].lat; lon = [double]$r[0].lon; city = [string]$r[0].n } }
  } catch { NLog "geocode failed: $($_.Exception.Message)" }
  return $null
}
function Get-DayName([datetime]$dt, [int]$i) {
  if ($i -eq 0) { return 'Сегодня' }
  if ($i -eq 1) { return 'Завтра' }
  $n = [Globalization.CultureInfo]::GetCultureInfo('ru-RU').DateTimeFormat.GetAbbreviatedDayName($dt.DayOfWeek)
  return ($n.Substring(0, 1).ToUpper() + $n.Substring(1))
}
function Get-Weather($req) {
  $lat = $null; $lon = $null; $city = [string]$req.name
  if ($req.auto) {
    $g = Get-AutoGeo
    if (-not $g) { return $null }
    $lat = $g.lat; $lon = $g.lon; $city = $g.city
  } elseif ($null -ne $req.lat -and $null -ne $req.lon) {
    $lat = [double]$req.lat; $lon = [double]$req.lon
  } else {
    $g = Get-GeoByName $city
    if (-not $g) { return $null }
    $lat = $g.lat; $lon = $g.lon; $city = $g.city
  }
  $la = ([double]$lat).ToString('0.####', $inv); $lo = ([double]$lon).ToString('0.####', $inv)
  try {
    $u = 'https://api.open-meteo.com/v1/forecast?latitude=' + $la + '&longitude=' + $lo +
         '&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,is_day,pressure_msl,precipitation' +
         '&hourly=temperature_2m,weather_code,is_day,precipitation_probability' +
         '&daily=weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset,uv_index_max,precipitation_probability_max' +
         '&timezone=auto&forecast_days=6&wind_speed_unit=kmh'
    $w = Get-Json $u 8000
    $cur = $w.current
    $days = @()
    for ($d = 0; $d -lt 5; $d++) {
      $dt = [datetime]::ParseExact([string]$w.daily.time[$d], 'yyyy-MM-dd', $inv)
      $days += , @{ d = (Get-DayName $dt $d); icon = (WmoKey ([int]$w.daily.weather_code[$d]) $true); hi = [int][Math]::Round([double]$w.daily.temperature_2m_max[$d]); lo = [int][Math]::Round([double]$w.daily.temperature_2m_min[$d]) }
    }
    # next hours, every second one: current hour + 0, 2, 4 ... 14
    $hours = @()
    $ct = ([string]$cur.time).Substring(0, 13)
    $i0 = 0
    for ($i = 0; $i -lt $w.hourly.time.Count; $i++) { if (([string]$w.hourly.time[$i]).StartsWith($ct)) { $i0 = $i; break } }
    for ($k = 0; $k -lt 8; $k++) {
      $ix = $i0 + 2 * $k
      if ($ix -ge $w.hourly.time.Count) { break }
      $lab = ([string]$w.hourly.time[$ix]).Substring(11, 5)
      if ($k -eq 0) { $lab = 'Сейчас' }
      $hours += , @{ t = $lab; icon = (WmoKey ([int]$w.hourly.weather_code[$ix]) ([bool]([int]$w.hourly.is_day[$ix] -eq 1))); v = [int][Math]::Round([double]$w.hourly.temperature_2m[$ix]) }
    }
    $code = [int]$cur.weather_code
    $rainP = 0
    try { $rainP = [int]$w.daily.precipitation_probability_max[0] } catch {}
    $uv = 0.0
    try { $uv = [double]$w.daily.uv_index_max[0] } catch {}
    return @{
      ok = $true; key = [string]$req.key; city = $city; lat = $lat; lon = $lon; at = [long]([DateTime]::UtcNow.Ticks / 10000)
      temp = [int][Math]::Round([double]$cur.temperature_2m); feels = [int][Math]::Round([double]$cur.apparent_temperature)
      hum = [int]$cur.relative_humidity_2m; wind = [int][Math]::Round([double]$cur.wind_speed_10m)
      press = [int][Math]::Round([double]$cur.pressure_msl * 0.75006); uv = $uv; rainP = $rainP
      cond = (WmoText $code); icon = (WmoKey $code ([bool]([int]$cur.is_day -eq 1)))
      sunrise = ([string]$w.daily.sunrise[0]).Substring(11, 5); sunset = ([string]$w.daily.sunset[0]).Substring(11, 5)
      hi = [int][Math]::Round([double]$w.daily.temperature_2m_max[0]); lo = [int][Math]::Round([double]$w.daily.temperature_2m_min[0])
      hours = $hours; days = $days
    }
  } catch { NLog "open-meteo failed: $($_.Exception.Message)" }
  # fallback: wttr.in (current + 3 days + a strip of the next hours, every 3 hours)
  try {
    $wx = Get-Json ('https://wttr.in/' + $la + ',' + $lo + '?format=j1') 9000
    $cc = $wx.current_condition[0]
    $days = @()
    for ($d = 0; $d -lt 3; $d++) {
      $dt = [datetime]::ParseExact([string]$wx.weather[$d].date, 'yyyy-MM-dd', $inv)
      $days += , @{ d = (Get-DayName $dt $d); icon = (WwoKey ([int]$wx.weather[$d].hourly[4].weatherCode)); hi = [int]$wx.weather[$d].maxtempC; lo = [int]$wx.weather[$d].mintempC }
    }
    $nowLoc = Get-Date
    try { $nowLoc = [datetime]::ParseExact(([string]$cc.localObsDateTime).Trim(), 'yyyy-MM-dd hh:mm tt', $inv) } catch {}
    $hours = @()
    try {
      $slots = @()
      for ($d = 0; $d -lt 3; $d++) {
        $day0 = [datetime]::ParseExact([string]$wx.weather[$d].date, 'yyyy-MM-dd', $inv)
        foreach ($e in @($wx.weather[$d].hourly)) {
          $hh = [int]([int]$e.time / 100)
          $slots += , @{ at = $day0.AddHours($hh); h = $hh; code = [int]$e.weatherCode; v = [int]$e.tempC }
        }
      }
      $from = $nowLoc.AddMinutes(-100)
      $k = 0
      foreach ($sl in $slots) {
        if ($sl.at -lt $from) { continue }
        if ($k -ge 8) { break }
        $ic = WwoKey $sl.code
        if ($ic -eq 'sun' -and ($sl.h -lt 6 -or $sl.h -ge 20)) { $ic = 'moon' }
        $lab = 'Сейчас'
        if ($k -gt 0) { $lab = ('{0:00}:00' -f $sl.h) }
        $hours += , @{ t = $lab; icon = $ic; v = $sl.v }
        $k++
      }
    } catch { NLog "wttr hourly: $($_.Exception.Message)" }
    $sunrise = ''; $sunset = ''
    try {
      $ast = $wx.weather[0].astronomy[0]
      $sunrise = ([datetime]::ParseExact(([string]$ast.sunrise).Trim(), 'hh:mm tt', $inv)).ToString('HH:mm')
      $sunset = ([datetime]::ParseExact(([string]$ast.sunset).Trim(), 'hh:mm tt', $inv)).ToString('HH:mm')
    } catch {}
    $ik = WwoKey ([int]$cc.weatherCode)
    if ($ik -eq 'sun' -and ($nowLoc.Hour -lt 6 -or $nowLoc.Hour -ge 20)) { $ik = 'moon' }
    return @{
      ok = $true; key = [string]$req.key; city = $city; lat = $lat; lon = $lon; at = [long]([DateTime]::UtcNow.Ticks / 10000)
      temp = [int]$cc.temp_C; feels = [int]$cc.FeelsLikeC; hum = [int]$cc.humidity; wind = [int]$cc.windspeedKmph
      press = [int][Math]::Round([double]$cc.pressure * 0.75006); uv = [double]$cc.uvIndex; rainP = -1
      cond = (KeyText $ik); icon = $ik; sunrise = $sunrise; sunset = $sunset
      hi = [int]$wx.weather[0].maxtempC; lo = [int]$wx.weather[0].mintempC
      hours = $hours; days = $days
    }
  } catch { NLog "wttr.in failed: $($_.Exception.Message)" }
  return $null
}
function KeyText([string]$k) {
  if ($k -eq 'sun' -or $k -eq 'moon') { return 'Ясно' }
  if ($k -eq 'pcloud') { return 'Переменная облачность' }
  if ($k -eq 'fog') { return 'Туман' }
  if ($k -eq 'drizzle') { return 'Морось' }
  if ($k -eq 'rain') { return 'Дождь' }
  if ($k -eq 'snow') { return 'Снег' }
  if ($k -eq 'storm') { return 'Гроза' }
  return 'Облачно'
}

# city search: open-meteo first, OpenStreetMap Nominatim as a second source (when the first one is unreachable or knows nothing)
function Search-City([string]$q) {
  $out = @()
  $failed = $false
  try {
    $r = Get-Json ('https://geocoding-api.open-meteo.com/v1/search?name=' + [uri]::EscapeDataString($q) + '&count=6&language=ru&format=json') 7000
    foreach ($x in @($r.results)) {
      if (-not $x) { continue }
      $sub = @()
      if ($x.admin1) { $sub += [string]$x.admin1 }
      if ($x.country) { $sub += [string]$x.country }
      $out += , @{ n = [string]$x.name; sub = ($sub -join ', '); lat = [double]$x.latitude; lon = [double]$x.longitude }
    }
  } catch { NLog "geocoding (open-meteo): $($_.Exception.Message)"; $failed = $true }
  if ($out.Count -gt 0) { return $out }
  try {
    $r2 = Get-Json ('https://nominatim.openstreetmap.org/search?q=' + [uri]::EscapeDataString($q) + '&format=jsonv2&limit=6&addressdetails=1&accept-language=ru&featuretype=settlement') 8000
    foreach ($x in @($r2)) {
      if (-not $x) { continue }
      $nm = [string]$x.name
      if (-not $nm) { $nm = ([string]$x.display_name).Split(',')[0].Trim() }
      if (-not $nm) { continue }
      $sub = @()
      try {
        if ($x.address.state) { $sub += [string]$x.address.state }
        if ($x.address.country) { $sub += [string]$x.address.country }
      } catch {}
      $out += , @{ n = $nm; sub = ($sub -join ', '); lat = [double]::Parse([string]$x.lat, $inv); lon = [double]::Parse([string]$x.lon, $inv) }
    }
    $failed = $false
  } catch { NLog "geocoding (nominatim): $($_.Exception.Message)" }
  if ($out.Count -eq 0 -and $failed) { throw 'city search unavailable' }
  return $out
}

# ---------------------------------------------------------------- lyrics (LRCLIB, free, no key)
# Titles and artists come in many shapes ("Artist - Song (Official Video)", "Artist - Topic", "Song feat. X"),
# so the lookup cleans them, tries several spellings and picks the most COMPLETE and best matching version.
function Clean-Title([string]$t) {
  $t = [string]$t
  $t = $t -replace '(?i)\s*[\(\[\{][^\)\]\}]*\b(feat\.?|ft\.?|featuring|remaster(ed)?|live|version|edit|remix|official|lyrics?|audio|video|visuali[sz]er|clip|karaoke|cover|ost|soundtrack|hd|4k|из фильма|саундтрек|премьера)\b[^\)\]\}]*[\)\]\}]', ''
  $t = $t -replace '(?i)\s+[-–—]\s+(remaster(ed)?|live|radio edit|single version|album version|official|lyrics?|audio|\d{4}).*$', ''
  $t = $t -replace '(?i)\s+(feat\.?|ft\.?|featuring)\s+.*$', ''
  return (($t -replace '\s+', ' ').Trim())
}
function Clean-Artist([string]$a) {
  $a = [string]$a
  $a = $a -replace '(?i)\s*[-–—]\s*topic\s*$', ''
  $a = $a -replace '(?i)\s*vevo\s*$', ''
  $a = $a -replace '(?i)\s*\(official\)\s*$', ''
  return ($a.Trim())
}
function Norm([string]$s) {
  if (-not $s) { return '' }
  $t = $s.ToLowerInvariant().Replace('ё', 'е')
  $t = [regex]::Replace($t, '[^\p{L}\p{Nd}]+', ' ')
  return $t.Trim()
}
function Artist-Match([string]$want, [string]$have) {
  $a = Norm $want; $b = Norm $have
  if ((-not $a) -or (-not $b)) { return $false }
  if ($a -ceq $b) { return $true }
  if ($a.Length -ge 3 -and $b.Length -ge 3 -and ($a.Contains($b) -or $b.Contains($a))) { return $true }
  $hb = ' ' + $b + ' '
  foreach ($w in ($a -split ' ')) {
    if ($w.Length -ge 4 -and $w -ne 'feat' -and $w -ne 'with' -and $hb.Contains(' ' + $w + ' ')) { return $true }
  }
  return $false
}
# 3 = same title, 2 = one contains the other, 0 = different song
function Title-Score([string]$cand, $wants) {
  $c = Norm $cand
  if (-not $c) { return 0 }
  $best = 0
  foreach ($w0 in $wants) {
    $w = [string]$w0
    if (-not $w) { continue }
    if ($c -ceq $w) { return 3 }
    if ($c.Length -ge 3 -and $w.Length -ge 3 -and ($c.Contains($w) -or $w.Contains($c))) { $best = 2 }
  }
  return $best
}
# time of the last stamp and number of stamps of an LRC text (to spot a version that stops half-way)
function Lrc-Stat([string]$lrc) {
  $last = 0.0; $n = 0
  foreach ($m in [regex]::Matches($lrc, '\[(\d{1,3}):(\d{2})(?:[.:]\d{1,3})?\]')) {
    $t = [double]$m.Groups[1].Value * 60.0 + [double]$m.Groups[2].Value
    if ($t -gt $last) { $last = $t }
    $n++
  }
  return @{ last = $last; n = $n }
}
function Parse-Lrc([string]$lrc) {
  $items = New-Object 'System.Collections.Generic.List[object]'
  foreach ($ln in ($lrc -split "\r?\n")) {
    $ms = [regex]::Matches($ln, '\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]')
    if ($ms.Count -eq 0) { continue }
    $txt = ([regex]::Replace($ln, '\[[^\]]*\]|<\d{1,3}:\d{2}(?:[.:]\d{1,3})?>', '')).Trim()
    if (-not $txt) { continue }
    foreach ($m in $ms) {
      $t = [double]$m.Groups[1].Value * 60.0 + [double]$m.Groups[2].Value
      if ($m.Groups[3].Success) { $t += [double]('0.' + $m.Groups[3].Value) }
      $items.Add(@{ t = $t; s = $txt })
    }
  }
  $sorted = @($items | Sort-Object { [double]$_.t })
  $times = New-Object double[] $sorted.Count
  $texts = New-Object string[] $sorted.Count
  for ($i = 0; $i -lt $sorted.Count; $i++) { $times[$i] = [double]$sorted[$i].t; $texts[$i] = [string]$sorted[$i].s }
  return @{ times = $times; texts = $texts }
}
function Get-Lyrics($req) {
  $title = [string]$req.title; $artist = [string]$req.artist; $dur = [double]$req.dur
  $ct = Clean-Title $title
  if (-not $ct) { $ct = $title.Trim() }
  $ca = Clean-Artist $artist
  $firstA = $ca
  if ($ca) { $firstA = ([regex]::Split($ca, '\s*(?:,|;|&|/|\sfeat\.?\s|\sft\.?\s)\s*')[0]).Trim() }

  $wantT = New-Object System.Collections.ArrayList
  $wantA = New-Object System.Collections.ArrayList
  $pairs = New-Object System.Collections.ArrayList
  [void]$wantT.Add((Norm $ct))
  if ($ct -ne $title) { [void]$wantT.Add((Norm $title)) }
  if ($ca) {
    [void]$wantA.Add($ca)
    [void]$pairs.Add(@{ t = $ct; a = $ca })
    if ($firstA -and $firstA -ne $ca) { [void]$wantA.Add($firstA); [void]$pairs.Add(@{ t = $ct; a = $firstA }) }
  }
  # "Artist - Song" written inside the title (typical for YouTube): try both orders
  $mm = [regex]::Match($ct, '^(.+?)\s+[-–—|]\s+(.+)$')
  if ($mm.Success) {
    $p1 = $mm.Groups[1].Value.Trim(); $p2 = $mm.Groups[2].Value.Trim()
    [void]$wantT.Add((Norm $p1)); [void]$wantT.Add((Norm $p2))
    [void]$wantA.Add($p1); [void]$wantA.Add($p2)
    [void]$pairs.Add(@{ t = $p2; a = $p1 })
    [void]$pairs.Add(@{ t = $p1; a = $p2 })
  }

  $queries = New-Object System.Collections.ArrayList
  foreach ($pr in $pairs) {
    $qs = 'track_name=' + [uri]::EscapeDataString([string]$pr.t) + '&artist_name=' + [uri]::EscapeDataString([string]$pr.a)
    if (-not $queries.Contains($qs)) { [void]$queries.Add($qs) }
  }
  if ($ca) {
    $qa = 'q=' + [uri]::EscapeDataString(($ca + ' ' + $ct))
    if (-not $queries.Contains($qa)) { [void]$queries.Add($qa) }
  }
  $qb = 'q=' + [uri]::EscapeDataString($ct)
  if (-not $queries.Contains($qb)) { [void]$queries.Add($qb) }
  if ($ct -ne $title) {
    $qc = 'q=' + [uri]::EscapeDataString($title)
    if (-not $queries.Contains($qc)) { [void]$queries.Add($qc) }
  }

  $best = $null; $bestScore = -999.0; $okN = 0; $failN = 0; $tries = 0
  foreach ($q in $queries) {
    if ($tries -ge 7) { break }
    $tries++
    $arr = @()
    try {
      $arr = @(Get-Json ('https://lrclib.net/api/search?' + $q) 8000) | Where-Object { $_ }
      $okN++
    } catch {
      NLog "lrclib: $($_.Exception.Message)"
      $failN++
      if ($failN -ge 2 -and $okN -eq 0) { break }
      continue
    }
    foreach ($c in $arr) {
      $hasS = [bool]$c.syncedLyrics; $hasP = [bool]$c.plainLyrics
      if (-not ($hasS -or $hasP)) { continue }
      $ts = Title-Score ([string]$c.trackName) $wantT
      if ($ts -eq 0) { continue }
      $am = $false
      foreach ($wa in $wantA) { if (Artist-Match ([string]$wa) ([string]$c.artistName)) { $am = $true; break } }
      $dm = 0
      if ($dur -gt 1 -and $c.duration) {
        $dd = [Math]::Abs([double]$c.duration - $dur)
        if ($dd -le 2.5) { $dm = 3 } elseif ($dd -le 6) { $dm = 2 } elseif ($dd -le 12) { $dm = 1 }
      }
      if ($wantA.Count -gt 0 -and (-not $am) -and $dm -eq 0) { continue }
      $score = $ts * 3.0 + $dm * 3.0
      if ($am) { $score += 5 }
      if ($hasS) { $score += 6 }
      if ($hasP) { $score += 1 }
      if ($hasS) {
        # a synced text that ends half-way through the song is worse than a complete one
        $stt = Lrc-Stat ([string]$c.syncedLyrics)
        $refd = 0.0
        if ($c.duration) { $refd = [double]$c.duration }
        if ($refd -lt 30 -and $dur -gt 30) { $refd = $dur }
        if ($refd -gt 30 -and $stt.n -ge 2 -and (($stt.last / $refd) -lt 0.55)) { $score -= 8 }
      }
      if ($score -gt $bestScore) { $bestScore = $score; $best = $c }
    }
    if ($best -and $bestScore -ge 24) { break }
  }
  if (-not $best) {
    if ($okN -eq 0 -and $failN -gt 0) { return @{ key = [string]$req.key; state = 'err' } }
    return @{ key = [string]$req.key; state = 'none' }
  }
  $useSynced = $false
  $parsed = $null
  if ($best.syncedLyrics) {
    $parsed = Parse-Lrc ([string]$best.syncedLyrics)
    if ($parsed.times.Count -ge 2) {
      $useSynced = $true
      if ($best.plainLyrics) {
        # the synced text has far fewer lines than the plain one: it is only a piece of the song, show the whole plain text
        $pn = @(([string]$best.plainLyrics) -split "\r?\n" | Where-Object { $_.Trim() }).Count
        if ($pn -ge 8 -and $parsed.times.Count -lt ($pn * 0.6)) { $useSynced = $false }
      }
    }
  }
  if ($useSynced) { return @{ key = [string]$req.key; state = 'ok'; synced = $true; times = $parsed.times; texts = $parsed.texts } }
  if ($best.plainLyrics) {
    $lines = @(([string]$best.plainLyrics) -split "\r?\n")
    return @{ key = [string]$req.key; state = 'ok'; synced = $false; times = $null; texts = [string[]]$lines }
  }
  return @{ key = [string]$req.key; state = 'none' }
}

# ---------------------------------------------------------------- calendar (.ics)
function Parse-IcsDate([string]$params, [string]$val) {
  $v = $val.Trim()
  try {
    if ($v -match '^\d{8}$') { return @{ dt = [datetime]::ParseExact($v, 'yyyyMMdd', $inv); ad = $true } }
    if ($v -match '^\d{8}T\d{6}Z$') {
      $u = [datetime]::ParseExact($v, 'yyyyMMdd\THHmmss\Z', $inv, [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
      return @{ dt = $u.ToLocalTime(); ad = $false }
    }
    if ($v -match '^\d{8}T\d{6}$') { return @{ dt = [datetime]::ParseExact($v, 'yyyyMMdd\THHmmss', $inv); ad = $false } }
  } catch {}
  return $null
}
function Get-Ics([string]$url) {
  $u = $url.Trim()
  if ($u -match '^webcal://') { $u = 'https://' + $u.Substring(9) }
  $txt = Get-Text $u 15000
  $txt = $txt -replace "\r?\n[ \t]", ''
  $now = Get-Date
  $from = $now.Date.AddDays(-1); $to = $now.Date.AddDays(45)
  $out = New-Object 'System.Collections.Generic.List[object]'
  $dayMap = @{ SU = 0; MO = 1; TU = 2; WE = 3; TH = 4; FR = 5; SA = 6 }
  foreach ($blk in ([regex]::Matches($txt, '(?s)BEGIN:VEVENT(.*?)END:VEVENT'))) {
    $body = $blk.Groups[1].Value
    $sum = ''; $start = $null; $rrule = ''
    foreach ($ln in ($body -split "\r?\n")) {
      if ($ln -match '^SUMMARY[^:]*:(.*)$') { $sum = ($Matches[1] -replace '\\,', ',' -replace '\\;', ';' -replace '\\n', ' ').Trim() }
      elseif ($ln -match '^DTSTART([^:]*):(.*)$') { $start = Parse-IcsDate $Matches[1] $Matches[2] }
      elseif ($ln -match '^RRULE:(.*)$') { $rrule = $Matches[1].Trim() }
    }
    if (-not $start -or -not $sum) { continue }
    $s0 = [datetime]$start.dt
    $dates = @()
    if (-not $rrule) { $dates = @($s0) }
    else {
      $rp = @{}
      foreach ($kv in ($rrule -split ';')) { $p = $kv -split '=', 2; if ($p.Count -eq 2) { $rp[$p[0].ToUpper()] = $p[1] } }
      $freq = [string]$rp['FREQ']; $step = 1
      if ($rp['INTERVAL']) { $step = [Math]::Max(1, [int]$rp['INTERVAL']) }
      $cnt = 100000; if ($rp['COUNT']) { $cnt = [int]$rp['COUNT'] }
      $until = [datetime]::MaxValue
      if ($rp['UNTIL']) { $ud = Parse-IcsDate '' ([string]$rp['UNTIL']); if ($ud) { $until = ([datetime]$ud.dt).AddDays(1) } }
      $by = @()
      if ($rp['BYDAY']) { foreach ($d in ($rp['BYDAY'] -split ',')) { $k = ($d -replace '[^A-Z]', ''); if ($dayMap.ContainsKey($k)) { $by += $dayMap[$k] } } }
      $n = 0; $guard = 0
      if ($freq -eq 'WEEKLY' -and $by.Count -gt 0) {
        $wk0 = $s0.Date.AddDays(-[int]$s0.DayOfWeek)
        $d = $s0.Date
        while ($d -le $to -and $d -lt $until -and $n -lt $cnt -and $guard -lt 3000) {
          $guard++
          $wi = [Math]::Floor(($d - $wk0).TotalDays / 7)
          if (($wi % $step) -eq 0 -and ($by -contains [int]$d.DayOfWeek) -and $d -ge $s0.Date) {
            $n++
            if ($d -ge $from) { $dates += $d.Add($s0.TimeOfDay) }
          }
          $d = $d.AddDays(1)
        }
      } else {
        $d = $s0
        while ($d -le $to -and $d -lt $until -and $n -lt $cnt -and $guard -lt 1500) {
          $guard++; $n++
          if ($d -ge $from) { $dates += $d }
          switch ($freq) {
            'DAILY'   { $d = $d.AddDays($step) }
            'WEEKLY'  { $d = $d.AddDays(7 * $step) }
            'MONTHLY' { $d = $s0.AddMonths($step * $n) }
            'YEARLY'  { $d = $s0.AddYears($step * $n) }
            default   { $d = [datetime]::MaxValue.AddDays(-1) }
          }
        }
      }
    }
    foreach ($d in $dates) {
      if ($d -ge $from -and $d -le $to) { $out.Add(@{ t = $d.ToString("yyyy-MM-dd'T'HH:mm", $inv); n = $sum; ad = [bool]$start.ad }) }
    }
  }
  return @($out | Sort-Object { $_.t } | Select-Object -First 300)
}

# ---------------------------------------------------------------- updates (GitHub releases)
function Clean-Notes([string]$b) {
  $t = ([string]$b) -replace "`r", ''
  $t = [regex]::Replace($t, '(?im)^\s*sha-?256\s*[:=].*$', '')
  $t = [regex]::Replace($t, '(?m)^\s*#+\s*', '')
  $t = [regex]::Replace($t, '\[([^\]]+)\]\([^)]*\)', '$1')
  $t = [regex]::Replace($t, '(?m)^\s*[-*]\s+', '• ')
  $t = [regex]::Replace($t, '[*`]+', '')
  $t = [regex]::Replace($t, '\n{3,}', "`n`n").Trim()
  if ($t.Length -gt 700) { $t = $t.Substring(0, 700).TrimEnd() + '…' }
  return $t
}

# the newest published release of the repository: version, notes, archive address, checksum
function Check-Update($req) {
  $repo = [string]$sync.UpdRepo
  $rel = $null
  try { $rel = Get-Json ('https://api.github.com/repos/' + $repo + '/releases/latest') 12000 }
  catch [System.Net.WebException] {
    $st = 0
    try { $st = [int]$_.Exception.Response.StatusCode } catch {}
    if ($st -eq 404) { return @{ seq = $req.seq; op = 'check'; ok = $true; none = $true } }
    if ($st -eq 403 -or $st -eq 429) { throw 'GitHub временно ограничил запросы, попробуй позже' }
    throw
  }
  $ver = ([string]$rel.tag_name) -replace '^[vV]', ''
  if ($ver -notmatch '^\d+(\.\d+){1,3}$') { throw ('неверный номер версии в релизе: ' + [string]$rel.tag_name) }
  $url = ''; $size = 0L
  foreach ($a in @($rel.assets)) {
    if ($a -and ([string]$a.name) -match '(?i)^DynamicIsland.*\.zip$') { $url = [string]$a.browser_download_url; $size = [long]$a.size; break }
  }
  if (-not $url) { $url = [string]$rel.zipball_url }
  if (-not $url) { throw 'в релизе нет архива' }
  $body = [string]$rel.body
  $sha = ''
  $m = [regex]::Match($body, '(?im)^\s*sha-?256\s*[:=]\s*([0-9a-f]{64})')
  if ($m.Success) { $sha = $m.Groups[1].Value.ToLower() }
  return @{ seq = $req.seq; op = 'check'; ok = $true; none = $false; ver = $ver; tag = [string]$rel.tag_name; url = $url; size = $size; sha = $sha; notes = (Clean-Notes $body); page = [string]$rel.html_url }
}

# download the archive to %TEMP% (progress goes to $sync.UpdProg), return its path and SHA-256
function Download-Update($req) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $dir = Join-Path ([IO.Path]::GetTempPath()) 'DynamicIsland-update'
  [void][IO.Directory]::CreateDirectory($dir)
  $dest = Join-Path $dir ([IO.Path]::GetFileName([string]$req.name))
  $sync.UpdProg = 0.0
  $r = [Net.HttpWebRequest]::Create([string]$req.url)
  $r.UserAgent = 'DynamicIsland/2.7 (updater)'
  $r.Timeout = 20000
  $r.ReadWriteTimeout = 20000
  $resp = $r.GetResponse()
  try {
    $total = [long]$resp.ContentLength
    if ($total -le 0) { $total = [long]$req.size }
    if ($total -gt 30MB) { throw 'архив слишком большой' }
    $inp = $resp.GetResponseStream()
    $out = [IO.File]::Create($dest)
    try {
      $buf = New-Object byte[] 32768
      $done = 0L
      while (($n = $inp.Read($buf, 0, $buf.Length)) -gt 0) {
        $out.Write($buf, 0, $n)
        $done += $n
        if ($done -gt 30MB) { throw 'архив слишком большой' }
        if ($total -gt 0) { $sync.UpdProg = [Math]::Min(0.99, $done / [double]$total) }
      }
    } finally { $out.Dispose(); $inp.Dispose() }
  } finally { $resp.Close() }
  $sha = [Security.Cryptography.SHA256]::Create()
  $fs = [IO.File]::OpenRead($dest)
  $hex = ''
  try { $hex = ([BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '').ToLower() }
  finally { $fs.Dispose(); $sha.Dispose() }
  $sync.UpdProg = 1.0
  return @{ seq = $req.seq; op = 'download'; ok = $true; path = $dest; sha = $hex }
}

# ---------------------------------------------------------------- main loop
$lastCity = -1; $lastLyr = -1; $lastWx = -1; $lastIcs = -1; $lastUpd = -1
NLog "started ($role)"
while ($sync.Running) {
  $busy = $false

  $cq = $sync.CityQ
  if (($role -eq 'all' -or $role -eq 'city') -and $cq -and ([int]$cq.id -ne $lastCity)) {
    $lastCity = [int]$cq.id; $busy = $true
    try { $sync.CityRes = @{ id = $cq.id; q = $cq.q; ok = $true; items = @(Search-City ([string]$cq.q)) } }
    catch { NLog "city search: $($_.Exception.Message)"; $sync.CityRes = @{ id = $cq.id; q = $cq.q; ok = $false; items = @() } }
  }

  $lr = $sync.LyrReq
  if (($role -eq 'all' -or $role -eq 'lyr') -and $lr -and ([int]$lr.seq -ne $lastLyr)) {
    $lastLyr = [int]$lr.seq; $busy = $true
    try { $sync.Lyr = (Get-Lyrics $lr) }
    catch { NLog "lyrics: $($_.Exception.Message)"; $sync.Lyr = @{ key = [string]$lr.key; state = 'err' } }
  }

  $wr = $sync.WxReq
  if (($role -eq 'all' -or $role -eq 'wx') -and $wr -and ([int]$wr.seq -ne $lastWx)) {
    $lastWx = [int]$wr.seq; $busy = $true
    $res = $null
    try { $res = Get-Weather $wr } catch { NLog "weather: $($_.Exception.Message)" }
    if ($res) { $sync.WxRes[[string]$wr.key] = $res }
    else { $sync.WxRes[[string]$wr.key] = @{ ok = $false; key = [string]$wr.key; at = [long]([DateTime]::UtcNow.Ticks / 10000) } }
  }

  $ir = $sync.IcsReq
  if (($role -eq 'all' -or $role -eq 'wx') -and $ir -and ([int]$ir.seq -ne $lastIcs)) {
    $lastIcs = [int]$ir.seq; $busy = $true
    try { $sync.Ics = @{ seq = $ir.seq; ok = $true; items = @(Get-Ics ([string]$ir.url)) } }
    catch { NLog "ics: $($_.Exception.Message)"; $sync.Ics = @{ seq = $ir.seq; ok = $false; items = @() } }
  }

  $ur = $sync.UpdReq
  if (($role -eq 'all' -or $role -eq 'upd') -and $ur -and ([int]$ur.seq -ne $lastUpd)) {
    $lastUpd = [int]$ur.seq; $busy = $true
    try {
      if ([string]$ur.op -eq 'download') { $sync.UpdRes = (Download-Update $ur) } else { $sync.UpdRes = (Check-Update $ur) }
    } catch {
      NLog "update: $($_.Exception.Message)"
      $sync.UpdRes = @{ seq = $ur.seq; op = [string]$ur.op; ok = $false; err = [string]$_.Exception.Message }
    }
  }

  if (-not $busy) { Start-Sleep -Milliseconds 120 }
}
