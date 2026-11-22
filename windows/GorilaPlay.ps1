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

# ---------- interfaz ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = "GorilaPlay 1.0.0"
$form.Size = New-Object System.Drawing.Size(760, 560)
$form.StartPosition = "CenterScreen"
$form.BackColor = [System.Drawing.Color]::FromArgb(24, 27, 33)
$form.ForeColor = [System.Drawing.Color]::White
$form.Font = New-Object System.Drawing.Font("Segoe UI", 10)
if (Test-Path (Join-Path $Root "assets\icono.ico")) {
    $form.Icon = New-Object System.Drawing.Icon((Join-Path $Root "assets\icono.ico"))
}

$lblUrl = New-Object System.Windows.Forms.Label
$lblUrl.Text = "URL del vídeo o de la playlist (YouTube o Spotify):"
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
$btnGo.SetBounds(20, 156, 520, 44)
$btnGo.BackColor = [System.Drawing.Color]::FromArgb(201, 43, 38)
$btnGo.ForeColor = [System.Drawing.Color]::White
$btnGo.FlatStyle = "Flat"
$btnGo.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnGo)

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

        Asegurar-YtDlp $log
        if (-not (Tiene-FFmpeg)) {
            Escribir "AVISO: no encuentro ffmpeg. Instálalo con:  winget install Gyan.FFmpeg" $log
            throw "Falta ffmpeg."
        }

        switch ($cmbFmt.SelectedIndex) {
            0 { $argsFmt = @("-x", "--audio-format", "mp3", "--audio-quality", "320K") }
            1 { $argsFmt = @("-x", "--audio-format", "mp3", "--audio-quality", "192K") }
            2 { $argsFmt = @("-f", "bestaudio[ext=m4a]/bestaudio") }
            3 { $argsFmt = @("-f", "bv*[height<=1080]+ba/b[height<=1080]", "--merge-output-format", "mp4") }
        }

        if ($url -match 'open\.spotify\.com') {
            $sp = Pistas-Spotify $url $log
            Escribir "Spotify: $($sp.Nombre)  ($($sp.Pistas.Count) pistas)" $log
            $carpeta = Join-Path $destino ($sp.Nombre -replace '[\\/:*?"<>|]', "_")
            New-Item -ItemType Directory -Force -Path $carpeta | Out-Null
            $i = 0
            foreach ($t in $sp.Pistas) {
                $i++
                $titulo = if ($t.Titulo) { $t.Titulo } else { "pista $i" }
                $artista = if ($t.Artista) { $t.Artista } else { "" }
                $nombre = ($artista + " - " + $titulo) -replace '[\\/:*?"<>|]', "_"
                $final = Join-Path $carpeta ($nombre.Trim(" -") + ".mp3")
                Escribir "[$i/$($sp.Pistas.Count)] $artista - $titulo" $log
                if (Test-Path $final) { Escribir "   ya existe, se omite" $log; continue }
                $consulta = (($titulo -replace '\s*\([^()]*\)', '') + " " + $artista).Trim()
                $json = & $YtDlp --flat-playlist -J "ytsearch10:$consulta" --no-warnings 2>$null
                try { $res = $json | ConvertFrom-Json } catch { Escribir "   sin resultados" $log; continue }
                $cand = Elegir-Candidato $res.entries $t.Dur $titulo $artista
                if (-not $cand) { Escribir "   sin resultados" $log; continue }
                $calidad = if ($cmbFmt.SelectedIndex -eq 1) { "192K" } else { "320K" }
                $tmp = Join-Path $carpeta ("tmp_" + $cand.id + ".%(ext)s")
                $rc = Ejecutar-YtDlp @("-x", "--audio-format", "mp3", "--audio-quality", $calidad,
                    "--no-overwrites", "-o", $tmp, "https://www.youtube.com/watch?v=" + $cand.id) $log
                $generado = Join-Path $carpeta ("tmp_" + $cand.id + ".mp3")
                if (Test-Path $generado) { Move-Item -Force $generado $final }
            }
        }
        else {
            $plantilla = Join-Path $destino "%(playlist_title,playlist_id|Sueltas)s\%(artist,creator,uploader,channel)s - %(title)s.%(ext)s"
            $argumentos = $argsFmt + @("--embed-metadata", "--embed-thumbnail", "--no-overwrites",
                "--download-archive", $Archivo, "--ignore-errors", "--newline", "--retries", "5",
                "-o", $plantilla, $url)
            Escribir "Descargando: $url" $log
            $rc = Ejecutar-YtDlp $argumentos $log
            if ($rc -ne 0) { Escribir "Terminó con errores (código $rc)." $log }
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
