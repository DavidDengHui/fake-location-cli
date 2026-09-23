@echo off
rem flc - Fake Location CLI for iPhone (portable launcher)
rem This is the single supported entry point. It forwards the raw command line
rem to flc-main.ps1 via FLC_ARGS so short switches (-i/-s) are preserved.
setlocal
set "FLC_ARGS=%*"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0flc-main.ps1"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo.
  echo flc exited with code %RC%.
  pause
)
endlocal
