@echo off
REM GorilaPlay - instalador para Windows
REM Doble clic para instalar. No borra nada de lo que ya tengas.
setlocal
cd /d "%~dp0"
title GorilaPlay - instalacion

where powershell.exe >nul 2>nul
if errorlevel 1 (
    echo No se ha encontrado Windows PowerShell en este equipo.
    echo GorilaPlay necesita PowerShell, que viene con Windows 10 y 11.
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0instalar.ps1"
set "CODIGO=%ERRORLEVEL%"

echo.
if not "%CODIGO%"=="0" (
    echo La instalacion no ha terminado bien ^(codigo %CODIGO%^).
    echo Copia este mensaje si necesitas ayuda.
) else (
    echo Pulsa una tecla para cerrar esta ventana.
)
pause >nul
exit /b %CODIGO%
