# GorilaPlay - instalador para Windows
# Copia el programa a %LOCALAPPDATA%\Programs\GorilaPlay, descarga yt-dlp y
# ffmpeg, y deja accesos directos en el escritorio y en el menu Inicio.
# No toca el PATH ni instala nada a nivel de sistema.

$ErrorActionPreference = "Stop"

# Windows PowerShell 5.1 no activa TLS 1.2 por defecto y GitHub lo exige.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}
catch { }
$ProgressPreference = "SilentlyContinue"

function Fallo([string]$texto) {
    Write-Host ""
    Write-Host "ERROR: $texto" -ForegroundColor Red
    Write-Host ""
    exit 1
}

$Origen = Split-Path -Parent $MyInvocation.MyCommand.Path
$Raiz = Split-Path -Parent $Origen
$Destino = Join-Path $env:LOCALAPPDATA "Programs\GorilaPlay"
$App = Join-Path $Destino "GorilaPlay.ps1"
$Icono = Join-Path $Destino "assets\icono.ico"
$PowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

Write-Host "GorilaPlay - instalador para Windows"
Write-Host ""

if (-not (Test-Path (Join-Path $Origen "GorilaPlay.ps1"))) {
    Fallo "No encuentro GorilaPlay.ps1 junto a este instalador. Descomprime el ZIP completo y ejecuta windows\instalar.cmd desde la carpeta extraida."
}
if (-not (Test-Path $PowerShell)) {
    Fallo "No encuentro Windows PowerShell en este equipo."
}
if (-not $env:LOCALAPPDATA) {
    Fallo "No encuentro la carpeta LOCALAPPDATA de tu usuario."
}
if ($env:PROCESSOR_ARCHITECTURE -eq "x86" -and -not $env:PROCESSOR_ARCHITEW6432) {
    Fallo "GorilaPlay necesita un Windows de 64 bits."
}

Write-Host "Copiando el programa en:"
Write-Host "  $Destino"
New-Item -ItemType Directory -Force -Path $Destino, (Join-Path $Destino "assets"), (Join-Path $Destino "bin") | Out-Null

if ($Origen -ne $Destino) {
    Copy-Item -Force (Join-Path $Origen "GorilaPlay.ps1") $Destino
    Copy-Item -Force (Join-Path $Origen "GorilaPlay.cmd") $Destino
    $icoOrigen = Join-Path $Raiz "assets\icono.ico"
    if (Test-Path $icoOrigen) { Copy-Item -Force $icoOrigen $Icono }
}

# Quita la marca de "archivo descargado de internet", que puede bloquear el script.
Get-ChildItem -Path $Destino -Recurse -File -ErrorAction SilentlyContinue |
    Unblock-File -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Descargando yt-dlp y ffmpeg (la primera vez tarda un poco)..."
& $PowerShell -NoProfile -ExecutionPolicy Bypass -File $App -Preparar
if ($LASTEXITCODE -ne 0) {
    Fallo "No he podido preparar las dependencias. Comprueba la conexion a internet y vuelve a ejecutar este instalador."
}

function Crear-Acceso([string]$ruta) {
    $shell = New-Object -ComObject WScript.Shell
    $acceso = $shell.CreateShortcut($ruta)
    $acceso.TargetPath = $PowerShell
    $acceso.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $App + '"'
    $acceso.WorkingDirectory = $Destino
    $acceso.Description = "GorilaPlay"
    if (Test-Path $Icono) { $acceso.IconLocation = $Icono + ",0" }
    $acceso.Save()
}

$accesos = @()
$escritorio = [Environment]::GetFolderPath("Desktop")
if ($escritorio) { $accesos += (Join-Path $escritorio "GorilaPlay.lnk") }
$accesos += (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\GorilaPlay.lnk")

$creados = 0
foreach ($acceso in $accesos) {
    try {
        Crear-Acceso $acceso
        $creados++
    }
    catch {
        Write-Host "Aviso: no he podido crear $acceso"
    }
}

Write-Host ""
Write-Host "Listo. Abre GorilaPlay desde el escritorio o desde el menu Inicio."
Write-Host ""
Write-Host "  programa  $Destino"
Write-Host "  registro  $(Join-Path $env:LOCALAPPDATA 'GorilaPlay')"
Write-Host "  accesos   $creados"
Write-Host ""
Write-Host "Si SmartScreen avisa la primera vez, elige 'Mas informacion' y"
Write-Host "'Ejecutar de todas formas'. Es un script de texto plano y puedes leerlo."
Write-Host ""
