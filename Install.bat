@echo off
rem PwManager setup: double-click to run Install.ps1 (no need to change the execution policy)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1" %*
set "RC=%ERRORLEVEL%"
echo.
pause
exit /b %RC%
