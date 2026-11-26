@echo off
REM GorilaPlay - lanzador para Windows
REM Si algo falla, deja la ventana abierta con el mensaje de error.
setlocal
cd /d "%~dp0"

where powershell.exe >nul 2>nul
if errorlevel 1 (
    echo No se ha encontrado Windows PowerShell en este equipo.
    echo GorilaPlay necesita PowerShell, que viene con Windows 10 y 11.
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0GorilaPlay.ps1"
set "CODIGO=%ERRORLEVEL%"

if not "%CODIGO%"=="0" (
    echo.
    echo GorilaPlay se ha cerrado con un error ^(codigo %CODIGO%^).
    echo Revisa el registro en %%LOCALAPPDATA%%\GorilaPlay\gorilaplay.log
    echo y prueba a ejecutar windows\instalar.cmd para reparar las dependencias.
    echo.
    pause
)

exit /b %CODIGO%
