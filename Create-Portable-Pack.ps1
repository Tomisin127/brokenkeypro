# Creates a portable ZIP ready to sell/distribute on Gumroad.
# Run: powershell -ExecutionPolicy Bypass -File Create-Portable-Pack.ps1
param(
    [switch]$CompileExe
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$OutDir = Join-Path $Root "dist\BrokenKeyRemapper-Portable"
$ZipPath = Join-Path $Root "dist\BrokenKeyRemapper-Portable.zip"

$include = @(
    "keymapperV2.ahk",
    "LlamaEngine.ahk",
    "McpClient.ahk",
    "I18n.ahk",
    "License.ahk",
    "english_words.txt",
    "english_bigrams.txt",
    "learned_words.txt",
    "RunRemapper.bat",
    "Start-MCP-Server.bat",
    "McpBridge.ps1",
    "Setup-AI.ps1",
    "BrokenKeyRemapper.ini",
    "README.txt"
)

Write-Host "Building portable pack..."

if (Test-Path $OutDir) { Remove-Item $OutDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

foreach ($f in $include) {
    $src = Join-Path $Root $f
    if (Test-Path $src) {
        Copy-Item $src (Join-Path $OutDir $f) -Force
        Write-Host "  + $f"
    } else {
        Write-Host "  ! missing: $f"
    }
}

# Optional: compile to EXE with Ahk2Exe (AutoHotkey v2)
$ahk2exeCandidates = @(
    "${env:ProgramFiles}\AutoHotkey\UX\Ahk2Exe.exe",
    "${env:ProgramFiles}\AutoHotkey\v2\Ahk2Exe.exe",
    "${env:ProgramFiles}\AutoHotkey\Compiler\Ahk2Exe.exe",
    "${env:LocalAppData}\Programs\AutoHotkey\UX\Ahk2Exe.exe"
)
$ahk2exe = $ahk2exeCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($CompileExe -and $ahk2exe) {
    Write-Host "Compiling BrokenKeyRemapper.exe..."
    $scriptPath = Join-Path $OutDir "keymapperV2.ahk"
    $exePath = Join-Path $OutDir "BrokenKeyRemapper.exe"
    & $ahk2exe /in $scriptPath /out $exePath /cp 65001
    if (Test-Path $exePath) {
        Write-Host "  + BrokenKeyRemapper.exe"
        @"
@echo off
cd /d "%~dp0"
start "" "%~dp0BrokenKeyRemapper.exe"
"@ | Set-Content (Join-Path $OutDir "RunRemapper.bat") -Encoding ASCII
    }
} elseif ($CompileExe) {
    Write-Host "Ahk2Exe not found - shipping script + RunRemapper.bat (requires AutoHotkey v2 on target PC)."
}

if (Test-Path (Join-Path $Root "dist")) {
    if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
}
New-Item -ItemType Directory -Force -Path (Split-Path $ZipPath) | Out-Null
Compress-Archive -Path (Join-Path $OutDir "*") -DestinationPath $ZipPath -Force

Write-Host ""
Write-Host "Done."
Write-Host "  Folder: $OutDir"
Write-Host "  ZIP:    $ZipPath"
Write-Host ""
Write-Host "Upload BrokenKeyRemapper-Portable.zip to Gumroad."
Write-Host "Buyers need: Windows, AutoHotkey v2 (unless you compiled EXE), internet for first activation."
