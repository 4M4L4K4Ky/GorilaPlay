# GorilaPlay (Windows)
# Descargador de playlists de YouTube y Spotify con interfaz grafica.
# Requiere: yt-dlp.exe y ffmpeg.exe (el script descarga yt-dlp si falta).

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$BinDir = Join-Path $Root "bin"
$YtDlp = Join-Path $BinDir "yt-dlp.exe"
$Estado = Join-Path $env:LOCALAPPDATA "GorilaPlay"
$Archivo = Join-Path $Estado "descargados.txt"
New-Item -ItemType Directory -Force -Path $BinDir, $Estado | Out-Null

# ---------- utilidades ----------
function Escribir([string]$texto, [System.Windows.Forms.RichTextBox]$log) {
    $log.AppendText($texto + "`r`n")
    $log.SelectionStart = $log.TextLength
    $log.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Asegurar-YtDlp([System.Windows.Forms.RichTextBox]$log) {
    if (Test-Path $YtDlp) { return }
    Escribir "Descargando yt-dlp.exe..." $log
    $url = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe"
    Invoke-WebRequest -Uri $url -OutFile $YtDlp -UseBasicParsing
    Escribir "yt-dlp listo." $log
}

function Tiene-FFmpeg {
    $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($cmd) { return $true }
    return (Test-Path (Join-Path $BinDir "ffmpeg.exe"))
}

function FFmpegExe {
    $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return (Join-Path $BinDir "ffmpeg.exe")
}

function Ejecutar-YtDlp([string[]]$argumentos, [System.Windows.Forms.RichTextBox]$log) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $YtDlp
    $psi.Arguments = ($argumentos | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join " "
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    while (-not $p.HasExited) {
        while (-not $p.StandardOutput.EndOfStream) { Escribir $p.StandardOutput.ReadLine() $log }
        while (-not $p.StandardError.EndOfStream) { Escribir $p.StandardError.ReadLine() $log }
        Start-Sleep -Milliseconds 120
    }
    while (-not $p.StandardOutput.EndOfStream) { Escribir $p.StandardOutput.ReadLine() $log }
    return $p.ExitCode
}

function Normalizar([string]$s) {
    $s = $s.Normalize([Text.NormalizationForm]::FormD)
    $s = -join ($s.ToCharArray() | Where-Object { [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne 'NonSpacingMark' })
    return (($s.ToLower() -replace '[^a-z0-9]+', ' ').Trim())
}

function Similitud([string]$a, [string]$b) {
    if (-not $a -or -not $b) { return 0 }
    $max = [Math]::Max($a.Length, $b.Length)
    $dist = Levenshtein $a $b
    return 1.0 - ($dist / $max)
}

function Levenshtein([string]$a, [string]$b) {
    $n = $a.Length; $m = $b.Length
    $d = New-Object 'int[,]' ($n + 1), ($m + 1)
    for ($i = 0; $i -le $n; $i++) { $d[$i, 0] = $i }
    for ($j = 0; $j -le $m; $j++) { $d[0, $j] = $j }
    for ($i = 1; $i -le $n; $i++) {
        for ($j = 1; $j -le $m; $j++) {
            $costo = if ($a[$i - 1] -eq $b[$j - 1]) { 0 } else { 1 }
            $d[$i, $j] = [Math]::Min([Math]::Min($d[($i - 1), $j] + 1, $d[$i, ($j - 1)] + 1), $d[($i - 1), ($j - 1)] + $costo)
        }
    }
    return $d[$n, $m]
}

function Buscar-Nodo($obj, [string]$clave) {
    if ($null -eq $obj) { return }
    if ($obj -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $obj.PSObject.Properties) {
            if ($p.Name -eq $clave) { return $p.Value }
            $r = Buscar-Nodo $p.Value $clave
            if ($null -ne $r) { return $r }
        }
    }
    elseif ($obj -is [System.Collections.IEnumerable] -and $obj -isnot [string]) {
        foreach ($v in $obj) {
            $r = Buscar-Nodo $v $clave
            if ($null -ne $r) { return $r }
        }
    }
    return $null
}

function Pistas-Spotify([string]$url, [System.Windows.Forms.RichTextBox]$log) {
    if ($url -notmatch '(playlist|album|track|artist)/([A-Za-z0-9]+)') {
        throw "URL de Spotify no reconocida."
    }
    $tipo = $Matches[1]; $id = $Matches[2]
    $ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36"
    $html = Invoke-WebRequest -Uri "https://open.spotify.com/embed/$tipo/$id" -Headers @{ "User-Agent" = $ua } -UseBasicParsing
    $m = [regex]::Match($html.Content, '<script id="__NEXT_DATA__" type="application/json">(.*?)</script>', 'Singleline')
    if (-not $m.Success) { throw "No he podido leer la lista de Spotify." }
    $data = $m.Groups[1].Value | ConvertFrom-Json

    $entidad = Buscar-Nodo $data "entity"
    $nombre = if ($entidad.name) { $entidad.name } else { "Spotify" }
    $lista = @()
    $tl = Buscar-Nodo $data "trackList"
    if ($tl) {
        foreach ($t in $tl) {
            $lista += [pscustomobject]@{
                Titulo = $t.title
                Artista = (($t.subtitle -replace [char]0x00A0, ' ') -replace '\s*,\s*', ', ').Trim()
                Dur = [int]($t.duration / 1000)
            }
        }
    }
    if ($lista.Count -eq 0 -and $entidad.title) {
        $arts = ($entidad.artists | ForEach-Object { $_.name }) -join ", "
        $lista += [pscustomobject]@{ Titulo = $entidad.title; Artista = $arts; Dur = [int]($entidad.duration / 1000) }
    }
    return @{ Nombre = $nombre; Pistas = $lista }
}

function Pistas-Deezer([string]$url, [System.Windows.Forms.RichTextBox]$log) {
    if ($url -notmatch '(playlist|album|track)/(\d+)') { throw "URL de Deezer no reconocida." }
    $tipo = $Matches[1]; $id = $Matches[2]
    $d = Invoke-RestMethod -Uri "https://api.deezer.com/$tipo/$id" -Headers @{ "User-Agent" = "Mozilla/5.0" } -TimeoutSec 30
    if ($d.error) { throw "Deezer: $($d.error.message)" }

    if ($tipo -eq "track") {
        $nombre = if ($d.album.title) { $d.album.title } else { $d.title }
        $pistas = @([pscustomobject]@{ Titulo = $d.title; Artista = $d.artist.name; Dur = [int]$d.duration; Portada = $d.album.cover_xl })
        return @{ Nombre = $nombre; Pistas = $pistas; Portada = $d.album.cover_xl }
    }

    $nombre = if ($d.title) { $d.title } else { "Deezer" }
    $portada = if ($d.cover_xl) { $d.cover_xl } else { $d.picture_xl }
    $pistas = @()
    $siguiente = "https://api.deezer.com/$tipo/$id/tracks?limit=100"
    while ($siguiente -and $pistas.Count -lt 5000) {
        $pag = Invoke-RestMethod -Uri $siguiente -Headers @{ "User-Agent" = "Mozilla/5.0" } -TimeoutSec 30
        foreach ($t in @($pag.data)) {
            if (-not $t.title) { continue }
            $pt = if ($t.album.cover_xl) { $t.album.cover_xl } else { $portada }
            $pistas += [pscustomobject]@{
                Titulo = $t.title; Artista = $t.artist.name; Dur = [int]$t.duration; Portada = $pt
            }
        }
        $siguiente = $pag.next
    }
    return @{ Nombre = $nombre; Pistas = $pistas; Portada = $portada }
}

function Pistas-YtDlp([string]$url, [System.Windows.Forms.RichTextBox]$log) {
    $argumentos = @("--flat-playlist", "-J")
    if ($url -match 'mixcloud\.com') { $argumentos += @("--extractor-args", "generic:impersonate") }
    $argumentos += @($url, "--no-warnings")
    $json = & $YtDlp @argumentos 2>$null
    if (-not $json) {
        $json = & $YtDlp --flat-playlist -J $url --no-warnings 2>$null
    }
    try { $d = $json | ConvertFrom-Json } catch { throw "yt-dlp no pudo leer ese enlace." }
    if (-not $d) { throw "yt-dlp no pudo leer ese enlace." }
    $entradas = if ($d.entries) { @($d.entries) } else { @($d) }
    $nombre = if ($d.title) { $d.title } else { "Lista" }
    $pistas = @()
    foreach ($e in $entradas) {
        if (-not $e -or -not $e.id) { continue }
        $bruto = [string]$e.title
        if (-not $bruto -and $e.url) {
            # SoundCloud y Mixcloud devuelven las entradas sin titulo: se saca
            # del slug de la direccion (sitio/artista/tema).
            try {
                $partes = ([uri]$e.url).AbsolutePath.Trim('/').Split('/')
                if ($partes.Count -ge 2 -and $partes[-2] -ne 'sets') {
                    $bruto = ($partes[-2] -replace '-', ' ') + " - " + ($partes[-1] -replace '-', ' ')
                }
            }
            catch { }
        }
        $artista = ""; $titulo = $bruto
        if ($bruto -match "^(.*?) - (.*)$") { $artista = $Matches[1]; $titulo = $Matches[2] }
        if (-not $artista) { $artista = if ($e.channel) { [string]$e.channel } else { [string]$e.uploader } }
        $dur = [int]($e.duration)
        if ($dur -gt 21600) { continue }
        $pistas += [pscustomobject]@{ Titulo = $titulo.Trim(); Artista = $artista.Trim(); Dur = $dur; Portada = "" }
    }
    return @{ Nombre = $nombre; Pistas = $pistas; Portada = "" }
}

function Pistas-Texto([string[]]$lineas, [string]$nombre) {
    $pistas = @()
    foreach ($linea in $lineas) {
        $l = $linea.Trim().Trim("-•* ").Trim()
        $l = $l -replace '^\d+[.)]\s*', ''
        if (-not $l -or $l.StartsWith("#")) { continue }
        $artista = ""; $titulo = $l
        if ($l -match "^(.*?) - (.*)$") { $artista = $Matches[1]; $titulo = $Matches[2] }
        $pistas += [pscustomobject]@{ Titulo = $titulo.Trim(); Artista = $artista.Trim(); Dur = 0; Portada = "" }
    }
    return @{ Nombre = $nombre; Pistas = $pistas; Portada = "" }
}

function Buscar-Candidatos([string]$fuente, [string]$consulta, [int]$n = 6) {
    $prefijo = if ($fuente -eq "youtube") { "ytsearch" } else { "scsearch" }
    $json = & $YtDlp --flat-playlist -J "$prefijo${n}:$consulta" --no-warnings 2>$null
    try { $d = $json | ConvertFrom-Json } catch { return @() }
    $salida = @()
    foreach ($e in @($d.entries)) {
        if (-not $e -or -not $e.id) { continue }
        if ($fuente -eq "youtube") {
            $u = "https://www.youtube.com/watch?v=$($e.id)"
        }
        else {
            $u = [string]$e.url
            if (-not $u.StartsWith("http")) { continue }
        }
        $art = if ($e.channel) { [string]$e.channel } else { [string]$e.uploader }
        $salida += [pscustomobject]@{
            Fuente = $fuente; Id = [string]$e.id; Url = $u
            Titulo = [string]$e.title; Artista = $art; Dur = [int]($e.duration)
        }
    }
    return $salida
}

function Puntuar-Candidatos($candidatos, [string]$titulo, [string]$artista, [int]$dur) {
    $mejor = $null; $mejorP = -100.0; $mejorSt = 0.0
    $tNorm = Normalizar $titulo
    foreach ($c in $candidatos) {
        $cd = [int]$c.Dur
        if ($dur -gt 0 -and $cd -gt 0) {
            if ($cd -gt $dur * 2.5 -and ($cd - $dur) -gt 90) { continue }
            if ($cd -lt $dur * 0.4 -and ($dur - $cd) -gt 45) { continue }
        }
        elseif ($dur -eq 0 -and $cd -gt 1200) { continue }

        $ct = Normalizar $c.Titulo
        $st = Similitud $ct $tNorm
        $sa = if ($artista) { Similitud (Normalizar $c.Artista) (Normalizar $artista) } else { 0.0 }
        $p = 3.0 * $st + 1.6 * $sa
        if ($dur -gt 0 -and $cd -gt 0) {
            $dd = [Math]::Abs($cd - $dur)
            $p += 2.0 * $(if ($dd -le 2) { 1 } elseif ($dd -le 5) { .8 } elseif ($dd -le 10) { .55 } elseif ($dd -le 20) { .15 } else { 0 })
        }
        if (($c.Fuente -eq "youtube" -and $c.Artista -match 'Topic$') -or $c.Artista -match 'VEVO') { $p += 0.8 }
        if ($c.Fuente -eq "soundcloud" -and $artista -and (Normalizar $c.Artista) -like "*$(Normalizar $artista)*") { $p += 0.5 }
        foreach ($w in @('acustico','en vivo','live','cover','karaoke','instrumental','letra','lyric','sped up','reverb','8d','remix','version','tutorial','reaccion','reaction')) {
            if ($ct -like "*$w*" -and $tNorm -notlike "*$w*") { $p -= 0.9 }
        }
        if ($p -gt $mejorP) { $mejor = $c; $mejorP = $p; $mejorSt = $st }
    }
    if (-not $mejor) { return $null }
    return @{ Candidato = $mejor; Fiable = ($mejorSt -ge 0.62) }
}

function Buscar-Audio([string]$titulo, [string]$artista, [int]$dur, [System.Windows.Forms.RichTextBox]$log) {
    $consultas = @()
    if ($artista) { $consultas += ("$artista $titulo").Trim() }
    $consultas += $titulo

    foreach ($fuente in @("youtube", "soundcloud")) {
        foreach ($q in $consultas) {
            $cands = @(Buscar-Candidatos $fuente $q)
            if ($cands.Count -eq 0) { continue }
            $r = Puntuar-Candidatos $cands $titulo $artista $dur
            if ($r -and $r.Fiable) { return $r.Candidato }
        }
    }

    # reintento con el titulo "oficial" que da Deezer
    try {
        $q = ("$artista $titulo").Trim()
        $busq = Invoke-RestMethod -Uri ("https://api.deezer.com/search?q=" + [uri]::EscapeDataString($q) + "&limit=5") -Headers @{ "User-Agent" = "Mozilla/5.0" } -TimeoutSec 20
        if ($busq.data.Count -gt 0) {
            $d0 = $busq.data[0]
            $canT = [string]$d0.title; $canA = [string]$d0.artist.name; $canD = [int]$d0.duration
            if ((Normalizar $canT) -ne (Normalizar $titulo) -or (Normalizar $canA) -ne (Normalizar $artista)) {
                foreach ($fuente in @("youtube", "soundcloud")) {
                    $cands = @(Buscar-Candidatos $fuente (("$canA $canT").Trim()))
                    if ($cands.Count -eq 0) { continue }
                    $rr = Puntuar-Candidatos $cands $canT $canA $canD
                    if ($rr -and $rr.Fiable) { return $rr.Candidato }
                }
            }
        }
    }
    catch { }

    # ultimo recurso: la mejor coincidencia aunque no sea perfecta
    foreach ($fuente in @("youtube", "soundcloud")) {
        $cands = @(Buscar-Candidatos $fuente $consultas[0] 10)
        if ($cands.Count -eq 0) { continue }
        $r = Puntuar-Candidatos $cands $titulo $artista $dur
        if ($r) { return $r.Candidato }
    }
    return $null
}

function Descargar-Lista($lista, [string]$nombre, [string]$destino, [string]$calidad, [System.Windows.Forms.RichTextBox]$log) {
    $limpio = (($nombre -replace '[\\/:*?"<>|]', "_").Trim(" ."))
    if (-not $limpio) { $limpio = "Lista" }
    $carpeta = Join-Path $destino $limpio
    New-Item -ItemType Directory -Force -Path $carpeta | Out-Null
    Escribir "$nombre  ($($lista.Count) pistas)" $log
    Escribir "Destino: $carpeta" $log
    Escribir "" $log

    $i = 0; $ok = 0; $fallos = 0
    foreach ($t in $lista) {
        $i++
        $titulo = if ($t.Titulo) { $t.Titulo } else { "pista $i" }
        $artista = [string]$t.Artista
        $etiqueta = if ($artista) { "$artista - $titulo" } else { $titulo }
        Escribir "[$i/$($lista.Count)] $etiqueta" $log

        $base = (($artista + " - " + $titulo) -replace '[\\/:*?"<>|]', "_").Trim(" -.")
        if (-not $base) { $base = "pista $i" }
        $archivo = Join-Path $carpeta ($base + ".mp3")
        if (Test-Path $archivo) { Escribir "   ya existe, se omite" $log; continue }

        $c = Buscar-Audio $titulo $artista ([int]$t.Dur) $log
        if (-not $c) { Escribir "   sin resultados en ninguna fuente" $log; $fallos++; continue }
        Escribir "   $($c.Fuente): $($c.Titulo)" $log

        $tmp = Join-Path $carpeta ("tmp_" + $c.Id + ".%(ext)s")
        $rc = Ejecutar-YtDlp @("-x", "--audio-format", "mp3", "--audio-quality", $calidad,
            "--no-overwrites", "-o", $tmp, $c.Url) $log
        $generado = Join-Path $carpeta ("tmp_" + $c.Id + ".mp3")
        if (-not (Test-Path $generado)) { Escribir "   error al descargar" $log; $fallos++; continue }

        Move-Item -Force $generado $archivo
        try {
            $detalle = Poner-Caratula $archivo $log
            if ($detalle) { Escribir "   ok · caratula: $detalle" $log } else { Escribir "   ok · sin caratula" $log }
        }
        catch { Escribir "   ok · caratula fallida" $log }
        $ok++
    }
    return @{ Ok = $ok; Fallos = $fallos; Carpeta = $carpeta }
}

function Elegir-Candidato($candidatos, [int]$dur, [string]$titulo, [string]$artista) {
    $mejor = $null; $mejorP = -100.0
    foreach ($c in $candidatos) {
        $cd = [int]$c.duration
        $ct = Normalizar $c.title
        $sub = Normalizar ([string]$c.channel + " " + [string]$c.uploader)
        $p = 0.0
        if ($dur -gt 0 -and $cd -gt 0) {
            $d = [Math]::Abs($cd - $dur)
            $p += 4.5 * $(if ($d -le 2) { 1 } elseif ($d -le 5) { .85 } elseif ($d -le 12) { .6 } elseif ($d -le 30) { .25 } else { 0 })
        }
        $p += 2.0 * (Similitud $ct (Normalizar $titulo))
        if ($sub -match 'topic|vevo') { $p += 0.8 }
        if ($artista -and ($sub -like "*$(Normalizar $artista)*" -or $ct -like "*$(Normalizar $artista)*")) { $p += 0.4 }
        foreach ($w in @('acustico','en vivo','live','cover','karaoke','instrumental','lyric','letra','sped up','reverb','8d','remix','version','tutorial','reaction')) {
            if ($ct -like "*$w*" -and (Normalizar $titulo) -notlike "*$w*") { $p -= 1.0 }
        }
        if ($p -gt $mejorP) { $mejor = $c; $mejorP = $p }
    }
    return $mejor
}

function FFprobeExe {
    $cmd = Get-Command ffprobe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return (Join-Path $BinDir "ffprobe.exe")
}

function Tiene-Caratula([string]$ruta) {
    $ffp = FFprobeExe
    if (-not (Test-Path $ffp)) { return $false }
    $salida = & $ffp -v quiet -print_format json -show_streams -- $ruta 2>$null | Out-String
    try { $datos = $salida | ConvertFrom-Json } catch { return $false }
    foreach ($s in $datos.streams) {
        if ($s.codec_type -eq "video" -and $s.disposition.attached_pic -eq 1) { return $true }
    }
    return $false
}

function Poner-Caratula([string]$ruta, [System.Windows.Forms.RichTextBox]$log) {
    $base = [IO.Path]::GetFileNameWithoutExtension($ruta)
    $artista = ""
    $titulo = $base
    if ($base -match "^(.*?) - (.*)$") { $artista = $Matches[1]; $titulo = $Matches[2] }

    $consulta = ("$artista $titulo").Trim()
    $cands = @()
    try {
        $url = "https://api.deezer.com/search?q=" + [uri]::EscapeDataString($consulta) + "&limit=8"
        $r = Invoke-RestMethod -Uri $url -Headers @{ "User-Agent" = "Mozilla/5.0" } -TimeoutSec 20
        $cands = @($r.data)
    }
    catch { $cands = @() }

    $mejor = $null
    $mejorP = -100.0
    $tNorm = Normalizar $titulo
    foreach ($c in $cands) {
        if (-not $c.album.cover_xl) { continue }
        $st = Similitud (Normalizar $c.title) $tNorm
        $sa = Similitud (Normalizar $c.artist.name) (Normalizar $artista)
        $p = 3.0 * $st + 1.6 * $sa
        foreach ($w in @("acustico", "en vivo", "live", "cover", "karaoke", "instrumental", "lyric", "letra", "remix", "version")) {
            if ((Normalizar $c.title) -like "*$w*" -and $tNorm -notlike "*$w*") { $p -= 0.9 }
        }
        if ($p -gt $mejorP) { $mejor = $c; $mejorP = $p }
    }
    if (-not $mejor) { return "" }
    if ((Similitud (Normalizar $mejor.title) $tNorm) -lt 0.62) { return "" }

    $ff = FFmpegExe
    $id = [guid]::NewGuid().ToString("N")
    $bajada = Join-Path $env:TEMP ("gp_bajada_$id")
    $portada = Join-Path $env:TEMP ("gp_portada_$id.jpg")
    try {
        Invoke-WebRequest -Uri $mejor.album.cover_xl -OutFile $bajada -UseBasicParsing
        & $ff -v error -y -i $bajada -vf "scale=600:600:force_original_aspect_ratio=decrease,pad=600:600:(ow-iw)/2:(oh-ih)/2:color=black" -q:v 3 -frames:v 1 $portada 2>$null
        if (-not (Test-Path $portada)) { throw "no pude preparar la imagen" }

        $tmp = $ruta + ".gp-tmp" + [IO.Path]::GetExtension($ruta)
        $etiquetas = @("-metadata", "title=$titulo", "-metadata", "artist=$artista")
        if ($mejor.album.title) { $etiquetas += @("-metadata", "album=$($mejor.album.title)") }
        & $ff -v error -y -i $ruta -i $portada -map 0:a -map 1:v -c copy -disposition:v attached_pic `
            -id3v2_version 3 -metadata:s:v "title=Album cover" -metadata:s:v "comment=Cover (front)" `
            @etiquetas $tmp 2>$null
        if ($LASTEXITCODE -eq 0 -and (Test-Path $tmp)) {
            Move-Item -Force $tmp $ruta
        }
        else {
            Remove-Item -Force $tmp -ErrorAction SilentlyContinue
            throw "ffmpeg no pudo incrustar la carátula"
        }
    }
    finally {
        Remove-Item -Force $bajada, $portada -ErrorAction SilentlyContinue
    }
    return ("$($mejor.album.title) · Deezer")
}

function Preparar-Motor([System.Windows.Forms.RichTextBox]$log) {
    Asegurar-YtDlp $log
    if (-not (Tiene-FFmpeg)) {
        throw "Falta ffmpeg. Instálalo con:  winget install Gyan.FFmpeg"
    }
}

function Pedir-Texto {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = "GorilaPlay - pegar lista"
    $f.Size = New-Object System.Drawing.Size(660, 440)
    $f.StartPosition = "CenterScreen"
    $f.BackColor = [System.Drawing.Color]::FromArgb(24, 27, 33)
    $f.ForeColor = [System.Drawing.Color]::White

    $aviso = New-Object System.Windows.Forms.Label
    $aviso.Text = "Una canción por línea, con el formato  Artista - Título:"
    $aviso.SetBounds(16, 12, 620, 22)
    $f.Controls.Add($aviso)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Multiline = $true
    $txt.ScrollBars = "Vertical"
    $txt.AcceptsReturn = $true
    $txt.SetBounds(16, 38, 610, 300)
    $txt.Font = New-Object System.Drawing.Font("Consolas", 10)
    $f.Controls.Add($txt)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = "Usar esta lista"
    $ok.SetBounds(380, 350, 150, 34)
    $ok.DialogResult = "OK"
    $f.Controls.Add($ok)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = "Cancelar"
    $cancel.SetBounds(540, 350, 90, 34)
    $cancel.DialogResult = "Cancel"
    $f.Controls.Add($cancel)

    $f.AcceptButton = $ok
    $f.CancelButton = $cancel
    if ($f.ShowDialog() -ne "OK") { return $null }
    return $txt.Text
}

# ---------- interfaz ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = "GorilaPlay 1.2.0"
$form.Size = New-Object System.Drawing.Size(760, 560)
$form.StartPosition = "CenterScreen"
$form.BackColor = [System.Drawing.Color]::FromArgb(24, 27, 33)
$form.ForeColor = [System.Drawing.Color]::White
$form.Font = New-Object System.Drawing.Font("Segoe UI", 10)
if (Test-Path (Join-Path $Root "assets\icono.ico")) {
    $form.Icon = New-Object System.Drawing.Icon((Join-Path $Root "assets\icono.ico"))
}

$lblUrl = New-Object System.Windows.Forms.Label
$lblUrl.Text = "URL de la lista o vídeo (YouTube, Spotify, Deezer, SoundCloud, Mixcloud...):"
$lblUrl.SetBounds(20, 18, 700, 22)
$form.Controls.Add($lblUrl)

$txtUrl = New-Object System.Windows.Forms.TextBox
$txtUrl.SetBounds(20, 42, 700, 28)
$txtUrl.Text = "https://www.youtube.com/playlist?list="
$form.Controls.Add($txtUrl)

$lblFmt = New-Object System.Windows.Forms.Label
$lblFmt.Text = "Formato:"
$lblFmt.SetBounds(20, 84, 100, 22)
$form.Controls.Add($lblFmt)

$cmbFmt = New-Object System.Windows.Forms.ComboBox
$cmbFmt.SetBounds(20, 108, 240, 28)
$cmbFmt.DropDownStyle = "DropDownList"
[void]$cmbFmt.Items.AddRange(@("Audio MP3 320 kbps", "Audio MP3 192 kbps", "Audio original (m4a)", "Vídeo 1080p"))
$cmbFmt.SelectedIndex = 0
$form.Controls.Add($cmbFmt)

$btnFolder = New-Object System.Windows.Forms.Button
$btnFolder.Text = "Elegir carpeta..."
$btnFolder.SetBounds(280, 106, 150, 32)
$form.Controls.Add($btnFolder)

$txtDestino = New-Object System.Windows.Forms.TextBox
$txtDestino.SetBounds(440, 108, 280, 28)
$musica = [Environment]::GetFolderPath("MyMusic")
if (-not $musica) { $musica = [Environment]::GetFolderPath("MyDocuments") }
$txtDestino.Text = $musica
$form.Controls.Add($txtDestino)

$btnGo = New-Object System.Windows.Forms.Button
$btnGo.Text = "DESCARGAR"
$btnGo.SetBounds(210, 156, 330, 44)
$btnGo.BackColor = [System.Drawing.Color]::FromArgb(201, 43, 38)
$btnGo.ForeColor = [System.Drawing.Color]::White
$btnGo.FlatStyle = "Flat"
$btnGo.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnGo)

$btnTexto = New-Object System.Windows.Forms.Button
$btnTexto.Text = "LISTA .TXT"
$btnTexto.SetBounds(20, 156, 180, 44)
$btnTexto.BackColor = [System.Drawing.Color]::FromArgb(38, 44, 54)
$btnTexto.ForeColor = [System.Drawing.Color]::White
$btnTexto.FlatStyle = "Flat"
$btnTexto.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnTexto)

$btnCaratulas = New-Object System.Windows.Forms.Button
$btnCaratulas.Text = "CARÁTULAS"
$btnCaratulas.SetBounds(550, 156, 170, 44)
$btnCaratulas.BackColor = [System.Drawing.Color]::FromArgb(38, 44, 54)
$btnCaratulas.ForeColor = [System.Drawing.Color]::White
$btnCaratulas.FlatStyle = "Flat"
$btnCaratulas.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnCaratulas)

$log = New-Object System.Windows.Forms.RichTextBox
$log.SetBounds(20, 212, 700, 296)
$log.BackColor = [System.Drawing.Color]::FromArgb(14, 16, 20)
$log.ForeColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
$log.Font = New-Object System.Drawing.Font("Consolas", 9)
$log.ReadOnly = $true
$form.Controls.Add($log)

$btnFolder.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.SelectedPath = $txtDestino.Text
    if ($dlg.ShowDialog() -eq "OK") { $txtDestino.Text = $dlg.SelectedPath }
})

$btnGo.Add_Click({
    $btnGo.Enabled = $false
    try {
        $url = $txtUrl.Text.Trim()
        $destino = $txtDestino.Text.Trim()
        if (-not $url.StartsWith("http")) { throw "Pega una dirección válida." }
        if (-not (Test-Path $destino)) { New-Item -ItemType Directory -Force -Path $destino | Out-Null }

        Preparar-Motor $log

        if ($url -match 'music\.amazon\.|(nonoki|zozoki)\.com') {
            throw ("Esa plataforma no permite leer listas sin cuenta.`n`n" +
                "Copia las canciones en un .txt (una por línea, 'Artista - Título')`n" +
                "y usa el botón LISTA .TXT.")
        }

        $esYoutube = ($url -match 'youtube\.com|youtu\.be') -and ($url -notmatch 'music\.youtube\.com')
        if ($esYoutube) {
            switch ($cmbFmt.SelectedIndex) {
                0 { $argsFmt = @("-x", "--audio-format", "mp3", "--audio-quality", "320K") }
                1 { $argsFmt = @("-x", "--audio-format", "mp3", "--audio-quality", "192K") }
                2 { $argsFmt = @("-f", "bestaudio[ext=m4a]/bestaudio") }
                3 { $argsFmt = @("-f", "bv*[height<=1080]+ba/b[height<=1080]", "--merge-output-format", "mp4") }
            }
            $plantilla = Join-Path $destino "%(playlist_title,playlist_id|Sueltas)s\%(artist,creator,uploader,channel)s - %(title)s.%(ext)s"
            $argumentos = $argsFmt + @("--embed-metadata", "--embed-thumbnail", "--no-overwrites",
                "--download-archive", $Archivo, "--ignore-errors", "--newline", "--retries", "5",
                "-o", $plantilla, $url)
            Escribir "Descargando: $url" $log
            $rc = Ejecutar-YtDlp $argumentos $log
            if ($rc -ne 0) { Escribir "Terminó con errores (código $rc)." $log }
        }
        else {
            if ($url -match 'open\.spotify\.com') { $d = Pistas-Spotify $url $log }
            elseif ($url -match 'deezer\.com') { $d = Pistas-Deezer $url $log }
            else { $d = Pistas-YtDlp $url $log }

            if ($d.Pistas.Count -eq 0) { throw "No he encontrado pistas en esa lista." }
            $calidad = if ($cmbFmt.SelectedIndex -eq 1) { "192K" } else { "320K" }
            $r = Descargar-Lista $d.Pistas $d.Nombre $destino $calidad $log
            if ($r.Fallos -gt 0) { Escribir "$($r.Fallos) pistas no se pudieron descargar." $log }
        }

        Escribir "" $log
        Escribir "Terminado. Archivos en: $destino" $log
        [System.Windows.Forms.MessageBox]::Show("Descarga terminada.`n`n$destino", "GorilaPlay") | Out-Null
    }
    catch {
        Escribir ("ERROR: " + $_.Exception.Message) $log
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "GorilaPlay", "OK", "Error") | Out-Null
    }
    finally { $btnGo.Enabled = $true }
})

$btnTexto.Add_Click({
    $btnTexto.Enabled = $false
    try {
        $r = [System.Windows.Forms.MessageBox]::Show(
            "¿Quieres cargar un archivo .txt o pegar las canciones?`n`nSí = elegir archivo`nNo = pegar el texto",
            "GorilaPlay - lista de texto", "YesNoCancel", "Question")
        if ($r -eq "Cancel") { return }

        $nombre = "Lista pegada"
        if ($r -eq "Yes") {
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Filter = "Listas de texto (*.txt)|*.txt|Todos los archivos (*.*)|*.*"
            if ($dlg.ShowDialog() -ne "OK") { return }
            $lineas = Get-Content -Path $dlg.FileName -Encoding UTF8
            $nombre = [IO.Path]::GetFileNameWithoutExtension($dlg.FileName)
        }
        else {
            $texto = Pedir-Texto
            if (-not $texto) { return }
            $lineas = $texto -split "`r?`n"
        }

        $d = Pistas-Texto $lineas $nombre
        if ($d.Pistas.Count -eq 0) { throw "No he encontrado canciones en esa lista." }

        $destino = $txtDestino.Text.Trim()
        if (-not (Test-Path $destino)) { New-Item -ItemType Directory -Force -Path $destino | Out-Null }
        Preparar-Motor $log
        $calidad = if ($cmbFmt.SelectedIndex -eq 1) { "192K" } else { "320K" }
        $res = Descargar-Lista $d.Pistas $d.Nombre $destino $calidad $log
        Escribir "" $log
        Escribir "Terminado. Archivos en: $($res.Carpeta)" $log
        [System.Windows.Forms.MessageBox]::Show("Descarga terminada.`n`n$($res.Carpeta)", "GorilaPlay") | Out-Null
    }
    catch {
        Escribir ("ERROR: " + $_.Exception.Message) $log
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "GorilaPlay", "OK", "Error") | Out-Null
    }
    finally { $btnTexto.Enabled = $true }
})

$btnCaratulas.Add_Click({
    $btnCaratulas.Enabled = $false
    try {
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.SelectedPath = $txtDestino.Text
        if ($dlg.ShowDialog() -ne "OK") { return }
        $carpeta = $dlg.SelectedPath
        if (-not (Tiene-FFmpeg)) { throw "Falta ffmpeg. Instálalo con:  winget install Gyan.FFmpeg" }

        $archivos = @(Get-ChildItem -Path $carpeta -Recurse -File |
            Where-Object { $_.Extension -in ".mp3", ".m4a" })
        if ($archivos.Count -eq 0) { throw "No hay archivos mp3 ni m4a en esa carpeta." }
        Escribir "Carátulas: $($archivos.Count) archivos en $carpeta" $log
        $i = 0; $ok = 0; $fallos = 0
        foreach ($f in $archivos) {
            $i++
            if (Tiene-Caratula $f.FullName) {
                Escribir "[$i/$($archivos.Count)] ya tiene carátula · $($f.Name)" $log
                continue
            }
            try {
                $detalle = Poner-Caratula $f.FullName $log
                if ($detalle) {
                    $ok++
                    Escribir "[$i/$($archivos.Count)] ok ($detalle) · $($f.Name)" $log
                }
                else {
                    $fallos++
                    Escribir "[$i/$($archivos.Count)] sin resultados · $($f.Name)" $log
                }
            }
            catch {
                $fallos++
                Escribir "[$i/$($archivos.Count)] error: $($_.Exception.Message) · $($f.Name)" $log
            }
        }
        Escribir "" $log
        Escribir "Carátulas: $ok puestas, $fallos sin carátula." $log
        [System.Windows.Forms.MessageBox]::Show("Carátulas terminadas.`n`n$ok puestas, $fallos sin carátula.", "GorilaPlay") | Out-Null
    }
    catch {
        Escribir ("ERROR: " + $_.Exception.Message) $log
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "GorilaPlay", "OK", "Error") | Out-Null
    }
    finally { $btnCaratulas.Enabled = $true }
})

[void]$form.ShowDialog()
