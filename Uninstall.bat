@echo off
rem PwManager uninstall: double-click to run Uninstall.ps1 (vault data is kept unless you choose to delete it)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall.ps1" %*
set "RC=%ERRORLEVEL%"
echo.
pause
exit /b %RC%
