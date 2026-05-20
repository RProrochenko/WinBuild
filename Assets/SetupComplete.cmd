@echo off
setlocal EnableDelayedExpansion

REM ============================================================================
REM SetupComplete.cmd
REM
REM Runs automatically after OOBE under the SYSTEM account, on first boot.
REM Use it to install MSI/EXE packages, copy config files, etc. — anything
REM that must run with full privileges before the desktop becomes available.
REM
REM Log: C:\Windows\Setup\Scripts\SetupComplete.log
REM
REM This file is a TEMPLATE with ONE example step (silent MSI install).
REM Duplicate the example block to add more installers as needed. Each step
REM should use `if not exist ... goto :NEXT_LABEL` so a missing file does not
REM stop the whole script.
REM ============================================================================

set "APPS=C:\Setup\Apps"
set "LOG=C:\Windows\Setup\Scripts\SetupComplete.log"
set "SCRIPTS_DIR=C:\Windows\Setup\Scripts"

REM ---- Configure path to your installer below --------------------------------
set "APP_MSI=%APPS%\example.msi"
REM ---------------------------------------------------------------------------

REM --- Create log IMMEDIATELY ------------------------------------------------
echo === SetupComplete START === > "%LOG%"
echo Date: %date% Time: %time% >> "%LOG%"
echo APPS=%APPS% >> "%LOG%"
echo. >> "%LOG%"

REM --- Anti double-run flag --------------------------------------------------
set "FLAG=%APPS%\.installed"
if exist "%FLAG%" (
    echo [INFO] Already installed, skipping. >> "%LOG%"
    goto :ALREADY_DONE
)

REM --- Verify APPS folder ----------------------------------------------------
if not exist "%APPS%" (
    echo [ERROR] Folder %APPS% not found >> "%LOG%"
    goto :END
)

cd /d "%APPS%"

REM ============================================================================
REM Example step — silent MSI install
REM   /qn               quiet, no UI
REM   /norestart        do not reboot
REM   REBOOT=...        suppress reboot prompts from the package itself
REM   /log "..."        write per-package install log
REM ============================================================================
echo [STEP] Example MSI install >> "%LOG%"
echo Start: %date% %time% >> "%LOG%"
if not exist "%APP_MSI%" ( echo [WARN] Missing: %APP_MSI% (skipping) >> "%LOG%" & goto :END )

msiexec /i "%APP_MSI%" REBOOT=ReallySuppress /qn /norestart /log "%SCRIPTS_DIR%\example_install.log"
echo End:   %date% %time% (exit=!errorlevel!) >> "%LOG%"
echo. >> "%LOG%"

:END
echo installed > "%FLAG%"
echo [INFO] Flag set. >> "%LOG%"

:ALREADY_DONE
echo === SetupComplete END === >> "%LOG%"
echo Date: %date% Time: %time% >> "%LOG%"
exit /b 0
