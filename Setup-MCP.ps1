# Setup-MCP.ps1
# Pre-installs @modelcontextprotocol/server-filesystem locally so the bridge
# never needs to download it at runtime (fixes timeouts on fresh PCs and
# machines without direct internet access / behind corporate proxies).
#
# Run once:  powershell -ExecutionPolicy Bypass -File Setup-MCP.ps1
#
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$McpDir = Join-Path $Root "mcp-server"

function Find-Npx {
    foreach ($c in @(
        (Get-Command npx.cmd -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
        (Get-Command npx     -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
        "$env:ProgramFiles\nodejs\npx.cmd",
        "$env:LocalAppData\Programs\nodejs\npx.cmd"
    )) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

function Find-Npm {
    foreach ($c in @(
        (Get-Command npm.cmd -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
        (Get-Command npm     -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
        "$env:ProgramFiles\nodejs\npm.cmd",
        "$env:LocalAppData\Programs\nodejs\npm.cmd"
    )) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

Write-Host ""
Write-Host "Broken Key Remapper Pro - MCP Setup"
Write-Host "====================================="
Write-Host ""

# --- Step 1: Verify Node.js is installed ---
$npm = Find-Npm
$npx = Find-Npx
if (-not $npm) {
    Write-Host "ERROR: Node.js / npm not found." -ForegroundColor Red
    Write-Host ""
    Write-Host "  1. Download Node.js LTS from:  https://nodejs.org/"
    Write-Host "  2. Run the installer (defaults are fine)."
    Write-Host "  3. CLOSE and REOPEN PowerShell."
    Write-Host "  4. Run this script again."
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host "Found npm : $npm"
Write-Host "Found npx : $npx"
Write-Host ""

# --- Step 2: Install the package locally into mcp-server\ ---
Write-Host "Installing @modelcontextprotocol/server-filesystem into mcp-server\ ..."
Write-Host "(This downloads ~2 MB once. Subsequent runs are instant.)"
Write-Host ""

New-Item -ItemType Directory -Force -Path $McpDir | Out-Null

# Write a minimal package.json so npm install works cleanly
$pkgJson = Join-Path $McpDir "package.json"
if (-not (Test-Path $pkgJson)) {
    Set-Content -LiteralPath $pkgJson -Encoding UTF8 -Value @'
{
  "name": "brokenkey-mcp",
  "version": "1.0.0",
  "private": true,
  "description": "Local MCP server dependencies for Broken Key Remapper Pro"
}
'@
}

$npmArgs = "install @modelcontextprotocol/server-filesystem --save-exact --no-audit --no-fund"

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $npm
$psi.Arguments = $npmArgs
$psi.WorkingDirectory = $McpDir
$psi.UseShellExecute = $false
$proc = [System.Diagnostics.Process]::Start($psi)
$proc.WaitForExit(180000) | Out-Null

if ($proc.ExitCode -ne 0) {
    Write-Host ""
    Write-Host "ERROR: npm install failed (exit code $($proc.ExitCode))." -ForegroundColor Red
    Write-Host ""
    Write-Host "Common causes:"
    Write-Host "  - No internet access.  Connect to the internet and retry."
    Write-Host "  - Corporate proxy.     Run:  npm config set proxy http://proxy:port"
    Write-Host "  - Antivirus blocking.  Temporarily disable AV during install."
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 1
}

# --- Step 3: Locate the installed binary ---
$bin1 = Join-Path $McpDir "node_modules\.bin\mcp-server-filesystem.cmd"
$bin2 = Join-Path $McpDir "node_modules\.bin\mcp-server-filesystem"
$bin3 = Join-Path $McpDir "node_modules\@modelcontextprotocol\server-filesystem\dist\index.js"

$found = $false
foreach ($b in @($bin1, $bin2, $bin3)) {
    if (Test-Path $b) {
        Write-Host ""
        Write-Host "Package installed at: $b" -ForegroundColor Green
        $found = $true
        break
    }
}

if (-not $found) {
    Write-Host "WARNING: Could not find the binary after install - check mcp-server\node_modules\." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Done! MCP server is ready."
Write-Host ""
Write-Host "The bridge (McpBridge.ps1 / Start-MCP-Server.bat) will now use"
Write-Host "the local install in mcp-server\ and will NOT need to download"
Write-Host "anything at runtime."
Write-Host ""
Read-Host "Press Enter to exit"
