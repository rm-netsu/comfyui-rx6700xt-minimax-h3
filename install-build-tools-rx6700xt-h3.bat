@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -File "%~dp0rx6700xt-h3\Install-BuildTools.ps1" %*
set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" pause
exit /b %EXIT_CODE%
