# Broken Key Remapper Pro - one-click installer (no Inno Setup required)
# Run: powershell -ExecutionPolicy Bypass -File Install.ps1
param(
    [string]$InstallDir = "$env:LOCALAPPDATA\Programs\BrokenKeyRemapper"
)

$ErrorActionPreference = "Stop"
$Source = Split-Path -Parent $MyInvocation.MyCommand.Path

$include = @(
    "keymapperV2.ahk", "LlamaEngine.ahk", "McpClient.ahk", "I18n.ahk", "License.ahk",
    "english_words.txt", "english_bigrams.txt", "learned_words.txt",
    "RunRemapper.bat", "Start-MCP-Server.bat", "McpBridge.ps1", "Setup-AI.ps1",
    "BrokenKeyRemapper.ini", "README.txt"
)

Write-Host "Installing Broken Key Remapper Pro..."
Write-Host "  Target: $InstallDir"

if (!(Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
}

foreach ($f in $include) {
    $src = Join-Path $Source $f
    if (Test-Path $src) {
        Copy-Item $src (Join-Path $InstallDir $f) -Force
    }
}

if (Test-Path (Join-Path $Source "BrokenKeyRemapper.exe")) {
    Copy-Item (Join-Path $Source "BrokenKeyRemapper.exe") $InstallDir -Force
}

$desktop = [Environment]::GetFolderPath("Desktop")
$shortcutPath = Join-Path $desktop "Broken Key Remapper Pro.lnk"
$target = Join-Path $InstallDir "RunRemapper.bat"
$wsh = New-Object -ComObject WScript.Shell
$sc = $wsh.CreateShortcut($shortcutPath)
$sc.TargetPath = $target
$sc.WorkingDirectory = $InstallDir
$sc.Description = "Broken Key Remapper Pro"
$sc.Save()

$startMenu = Join-Path ([Environment]::GetFolderPath("Programs")) "Broken Key Remapper Pro"
New-Item -ItemType Directory -Force -Path $startMenu | Out-Null
$sc2 = $wsh.CreateShortcut((Join-Path $startMenu "Broken Key Remapper Pro.lnk"))
$sc2.TargetPath = $target
$sc2.WorkingDirectory = $InstallDir
$sc2.Save()

Write-Host ""
Write-Host "Installed successfully."
Write-Host "  Shortcut: $shortcutPath"
Write-Host ""
Write-Host "Launch the app - you will be prompted for your Gumroad license key (internet required)."
Write-Host "One license = one PC."

$launch = Read-Host "Launch now? (Y/n)"
if ($launch -eq "" -or $launch -eq "Y" -or $launch -eq "y") {
    Start-Process $target
}
