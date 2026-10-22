@echo off
setlocal
set "ROOT=%~dp0"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
echo [%date% %time%] 26H2 Warning launcher started.>>"%ROOT%Launcher.log"
"%PS%" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%ROOT%Upgrade-26H2-Warning.ps1" >>"%ROOT%Launcher.log" 2>&1
set "RC=%ERRORLEVEL%"
echo [%date% %time%] 26H2 Warning launcher finished with exit code %RC%.>>"%ROOT%Launcher.log"
exit /b %RC%
