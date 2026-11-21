# ============================================================
#  Internet worker (own runspace): weather, city search, song lyrics, calendar (.ics).
#  Slow network calls live here so the media session never waits for them.
#  Talks to the UI only through $sync (requests in, results out).
# ============================================================
$ErrorActionPreference = 'Continue'
$inv = [Globalization.CultureInfo]::InvariantCulture
function NLog($m) { try { $sync.Log.Enqueue("net: $m") } catch {} }

function Get-Text([string]$url, [int]$timeoutMs = 9000) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $req = [Net.HttpWebRequest]::Create($url)
  $req.UserAgent = 'DynamicIsland/2.4 (desktop widget)'
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
function Get-AutoGeo {
  if ($script:autoGeo) { return $script:autoGeo }
  try {
    $g = Get-Json 'https://ipwho.is/?lang=ru'
    if ($g.latitude) { $script:autoGeo = @{ lat = [double]$g.latitude; lon = [double]$g.longitude; city = [string]$g.city }; return $script:autoGeo }
  } catch { NLog "ipwho.is failed: $($_.Exception.Message)" }
  try {
    $g = Get-Json 'https://ipapi.co/json/'
    if ($g.latitude) { $script:autoGeo = @{ lat = [double]$g.latitude; lon = [double]$g.longitude; city = [string]$g.city }; return $script:autoGeo }
  } catch { NLog "ipapi.co failed: $($_.Exception.Message)" }
  return $null
}
function Get-GeoByName([string]$name) {
  try {
    $r = Get-Json ('https://geocoding-api.open-meteo.com/v1/search?name=' + [uri]::EscapeDataString($name) + '&count=1&language=ru&format=json')
    $x = @($r.results) | Where-Object { $_ } | Select-Object -First 1
    if ($x) { return @{ lat = [double]$x.latitude; lon = [double]$x.longitude; city = [string]$x.name } }
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
    $w = Get-Json $u 12000
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
  # fallback: wttr.in (current + 3 days, no hourly strip)
  try {
    $wx = Get-Json ('https://wttr.in/' + $la + ',' + $lo + '?format=j1') 12000
    $cc = $wx.current_condition[0]
    $days = @()
    for ($d = 0; $d -lt 3; $d++) {
      $dt = [datetime]::ParseExact([string]$wx.weather[$d].date, 'yyyy-MM-dd', $inv)
      $days += , @{ d = (Get-DayName $dt $d); icon = (WwoKey ([int]$wx.weather[$d].hourly[4].weatherCode)); hi = [int]$wx.weather[$d].maxtempC; lo = [int]$wx.weather[$d].mintempC }
    }
    return @{
      ok = $true; key = [string]$req.key; city = $city; lat = $lat; lon = $lon; at = [long]([DateTime]::UtcNow.Ticks / 10000)
      temp = [int]$cc.temp_C; feels = [int]$cc.FeelsLikeC; hum = [int]$cc.humidity; wind = [int]$cc.windspeedKmph
      press = [int][Math]::Round([double]$cc.pressure * 0.75006); uv = [double]$cc.uvIndex; rainP = -1
      cond = ''; icon = (WwoKey ([int]$cc.weatherCode)); sunrise = ''; sunset = ''
      hi = [int]$wx.weather[0].maxtempC; lo = [int]$wx.weather[0].mintempC
      hours = @(); days = $days
    }
  } catch { NLog "wttr.in failed: $($_.Exception.Message)" }
  return $null
}

function Search-City([string]$q) {
  $out = @()
  $r = Get-Json ('https://geocoding-api.open-meteo.com/v1/search?name=' + [uri]::EscapeDataString($q) + '&count=6&language=ru&format=json')
  foreach ($x in @($r.results)) {
    if (-not $x) { continue }
    $sub = @()
    if ($x.admin1) { $sub += [string]$x.admin1 }
    if ($x.country) { $sub += [string]$x.country }
    $out += , @{ n = [string]$x.name; sub = ($sub -join ', '); lat = [double]$x.latitude; lon = [double]$x.longitude }
  }
  return $out
}

# ---------------------------------------------------------------- lyrics (LRCLIB, free, no key)
function Clean-Title([string]$t) {
  $t = $t -replace '\s*[\(\[][^\)\]]*(feat|ft\.|remaster|live|version|edit|remix|official|lyrics|audio|video|из фильма|ost)[^\)\]]*[\)\]]', ''
  $t = $t -replace '\s+-\s+(remaster(ed)?|live|radio edit|single version|\d{4}).*$', ''
  return $t.Trim()
}
function Parse-Lrc([string]$lrc) {
  $items = New-Object 'System.Collections.Generic.List[object]'
  foreach ($ln in ($lrc -split "\r?\n")) {
    $ms = [regex]::Matches($ln, '\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]')
    if ($ms.Count -eq 0) { continue }
    $txt = ([regex]::Replace($ln, '\[[^\]]*\]', '')).Trim()
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
  $qt = Clean-Title $title
  $queries = @()
  if ($artist) {
    $queries += ('track_name=' + [uri]::EscapeDataString($qt) + '&artist_name=' + [uri]::EscapeDataString($artist))
    $queries += ('q=' + [uri]::EscapeDataString(($artist + ' ' + $qt)))
  } else {
    $queries += ('q=' + [uri]::EscapeDataString($qt))
  }
  if ($qt -ne $title -and $artist) { $queries += ('q=' + [uri]::EscapeDataString(($artist + ' ' + $title))) }
  $best = $null; $bestScore = -1
  $failed = $false
  foreach ($q in $queries) {
    $arr = @()
    try { $arr = @(Get-Json ('https://lrclib.net/api/search?' + $q) 10000) | Where-Object { $_ } }
    catch { NLog "lrclib: $($_.Exception.Message)"; $failed = $true; continue }
    foreach ($c in $arr) {
      $hasS = [bool]$c.syncedLyrics; $hasP = [bool]$c.plainLyrics
      if (-not ($hasS -or $hasP)) { continue }
      $am = $false
      if ($artist -and $c.artistName) {
        $a1 = ([string]$c.artistName).ToLower(); $a2 = $artist.ToLower()
        $am = ($a1.Contains($a2) -or $a2.Contains($a1))
      }
      $dm = 0
      if ($dur -gt 1 -and $c.duration) {
        $dd = [Math]::Abs([double]$c.duration - $dur)
        if ($dd -le 2.5) { $dm = 2 } elseif ($dd -le 6) { $dm = 1 }
      }
      if ((-not $am) -and $dm -eq 0) { continue }
      $score = ($(if ($hasS) { 10 } else { 0 })) + ($(if ($am) { 4 } else { 0 })) + $dm * 3 + ($(if ($hasP) { 1 } else { 0 }))
      if ($score -gt $bestScore) { $bestScore = $score; $best = $c }
    }
    if ($best -and $bestScore -ge 14) { break }
  }
  if (-not $best) {
    if ($failed) { return @{ key = [string]$req.key; state = 'err' } }
    return @{ key = [string]$req.key; state = 'none' }
  }
  if ($best.syncedLyrics) {
    $p = Parse-Lrc ([string]$best.syncedLyrics)
    if ($p.times.Count -ge 2) { return @{ key = [string]$req.key; state = 'ok'; synced = $true; times = $p.times; texts = $p.texts } }
  }
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

# ---------------------------------------------------------------- main loop
$lastCity = -1; $lastLyr = ''; $lastWx = -1; $lastIcs = -1
NLog 'started'
while ($sync.Running) {
  $busy = $false

  $cq = $sync.CityQ
  if ($cq -and ([int]$cq.id -ne $lastCity)) {
    $lastCity = [int]$cq.id; $busy = $true
    try { $sync.CityRes = @{ id = $cq.id; q = $cq.q; ok = $true; items = @(Search-City ([string]$cq.q)) } }
    catch { NLog "city search: $($_.Exception.Message)"; $sync.CityRes = @{ id = $cq.id; q = $cq.q; ok = $false; items = @() } }
  }

  $lr = $sync.LyrReq
  if ($lr -and ([string]$lr.key -ne $lastLyr)) {
    $lastLyr = [string]$lr.key; $busy = $true
    try { $sync.Lyr = (Get-Lyrics $lr) }
    catch { NLog "lyrics: $($_.Exception.Message)"; $sync.Lyr = @{ key = [string]$lr.key; state = 'err' } }
  }

  $wr = $sync.WxReq
  if ($wr -and ([int]$wr.seq -ne $lastWx)) {
    $lastWx = [int]$wr.seq; $busy = $true
    $res = $null
    try { $res = Get-Weather $wr } catch { NLog "weather: $($_.Exception.Message)" }
    if ($res) { $sync.WxRes[[string]$wr.key] = $res }
    else { $sync.WxRes[[string]$wr.key] = @{ ok = $false; key = [string]$wr.key; at = [long]([DateTime]::UtcNow.Ticks / 10000) } }
  }

  $ir = $sync.IcsReq
  if ($ir -and ([int]$ir.seq -ne $lastIcs)) {
    $lastIcs = [int]$ir.seq; $busy = $true
    try { $sync.Ics = @{ seq = $ir.seq; ok = $true; items = @(Get-Ics ([string]$ir.url)) } }
    catch { NLog "ics: $($_.Exception.Message)"; $sync.Ics = @{ seq = $ir.seq; ok = $false; items = @() } }
  }

  if (-not $busy) { Start-Sleep -Milliseconds 120 }
}
