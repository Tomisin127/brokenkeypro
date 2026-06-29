@echo off
setlocal
set "SCRIPT=%~dp0keymapperV2.ahk"

where AutoHotkey64.exe >nul 2>&1 && set "AHK=AutoHotkey64.exe" && goto :run
where AutoHotkey.exe >nul 2>&1 && set "AHK=AutoHotkey.exe" && goto :run

for %%P in (
  "%ProgramFiles%\AutoHotkey\v2\AutoHotkey64.exe"
  "%ProgramFiles%\AutoHotkey\v2\AutoHotkey.exe"
  "%LocalAppData%\Programs\AutoHotkey\v2\AutoHotkey64.exe"
) do if exist %%P set "AHK=%%~P" && goto :run

echo AutoHotkey v2 not found. Install from https://www.autohotkey.com/
pause
exit /b 1

:run
start "" "%AHK%" "%SCRIPT%"
