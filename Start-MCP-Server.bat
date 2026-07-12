@echo off
title Broken Key Remapper - MCP Filesystem Server
cd /d "%~dp0"

echo.
echo  Broken Key Remapper Pro - MCP Server
echo  ====================================
echo  Directory: %CD%
echo  HTTP API:  http://127.0.0.1:8766/health
echo.
echo  Requires Node.js (npx) - https://nodejs.org/
echo  First run downloads @modelcontextprotocol/server-filesystem automatically.
echo.
echo  Keep this window open while MCP mode is enabled in Settings.
echo  Press Ctrl+C to stop.
echo.

where npx >nul 2>&1
if %ERRORLEVEL%==0 goto :start

where npx.cmd >nul 2>&1
if %ERRORLEVEL%==0 goto :start

where uvx >nul 2>&1
if %ERRORLEVEL%==0 goto :start

echo ERROR: Neither npx nor uvx found.
echo.
echo Download and install Node.js LTS from:
echo   https://nodejs.org/
echo.
echo Then re-run this batch file or use Settings - Setup MCP.
pause
exit /b 1

:start
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0McpBridge.ps1" -RootDir "%CD%" -Port 8766
echo.
echo MCP server stopped.
pause
