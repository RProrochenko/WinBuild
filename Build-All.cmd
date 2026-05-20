@echo off
REM ============================================================================
REM Build-All.cmd — запускає збірку Win10 та Win11 послідовно
REM Запускати від адміністратора (правий клік -> Run as administrator)
REM ============================================================================

cd /d "%~dp0"

echo.
echo === Збірка Windows 10 ===
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Build-CustomISO.ps1" -SourceISO ".\Origin\Windows10.iso" -OutputName "Win10"
if errorlevel 1 (
    echo.
    echo ПОМИЛКА під час збірки Win10. Дивіться Logs\
    pause
    exit /b 1
)

echo.
echo === Збірка Windows 11 ===
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Build-CustomISO.ps1" -SourceISO ".\Origin\Windows11.iso" -OutputName "Win11"
if errorlevel 1 (
    echo.
    echo ПОМИЛКА під час збірки Win11. Дивіться Logs\
    pause
    exit /b 1
)

echo.
echo === Усе готово. ISO у папці Modified\ ===
pause
