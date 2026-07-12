# MCP HTTP bridge for Broken Key Remapper Pro
# Spawns @modelcontextprotocol/server-filesystem (npx/uvx) and exposes HTTP read API.
param(
    [string]$RootDir = $PSScriptRoot,
    [int]$Port = 8766
)

$ErrorActionPreference = "Stop"
$RootDir = (Resolve-Path $RootDir).Path

# Path to a diagnostics log so npx / network failures are visible on other PCs.
$script:StderrLog = Join-Path $RootDir "mcp-stderr.log"
try { Set-Content -LiteralPath $script:StderrLog -Value "" -Encoding UTF8 } catch {}

# Tracks whether the MCP server initialized. When false, the bridge still
# serves HTTP and answers /read by reading files directly from disk.
$script:McpReady = $false

function Write-Log([string]$Msg) {
    $line = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + " | MCP bridge | " + $Msg
    Write-Host $line
    try { Add-Content -LiteralPath $script:StderrLog -Value $line -Encoding UTF8 } catch {}
}

function Resolve-NpxPath {
    $candidates = @(
        (Get-Command npx.cmd -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
        (Get-Command npx -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
        "$env:ProgramFiles\nodejs\npx.cmd",
        "${env:ProgramFiles(x86)}\nodejs\npx.cmd",
        "$env:LocalAppData\Programs\nodejs\npx.cmd"
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    $where = (& where.exe npx.cmd 2>$null | Select-Object -First 1)
    if ($where -and (Test-Path -LiteralPath $where)) { return $where.Trim() }
    return $null
}

function Resolve-UvxPath {
    $candidates = @(
        (Get-Command uvx -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
        "$env:USERPROFILE\.local\bin\uvx.exe",
        "$env:LocalAppData\Programs\uv\uvx.exe"
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Find-McpLauncher {
    $npx = Resolve-NpxPath
    if ($npx) {
        return @{
            File   = $npx
            Args   = "-y @modelcontextprotocol/server-filesystem `"$RootDir`""
            Detail = "npx @modelcontextprotocol/server-filesystem"
        }
    }
    $uvx = Resolve-UvxPath
    if ($uvx) {
        return @{
            File   = $uvx
            Args   = "mcp-server-filesystem `"$RootDir`""
            Detail = "uvx mcp-server-filesystem"
        }
    }
    throw "Install Node.js (npx) from https://nodejs.org/ - required for MCP mode."
}

function Start-McpProcess([hashtable]$Launcher) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Launcher.File
    $psi.Arguments = $Launcher.Args
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.WorkingDirectory = $RootDir

    $proc = [System.Diagnostics.Process]::Start($psi)
    # Capture the MCP server's stderr to mcp-stderr.log so npm/network errors
    # (e.g. first-run download failures behind a proxy/firewall) are visible.
    Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -MessageData $script:StderrLog -Action {
        if ($EventArgs.Data) {
            try { Add-Content -LiteralPath $Event.MessageData -Value $EventArgs.Data -Encoding UTF8 } catch {}
        }
    } | Out-Null
    $proc.BeginErrorReadLine()
    Start-Sleep -Milliseconds 1200
    return $proc
}

function Send-McpLine([System.Diagnostics.Process]$Proc, [string]$Json) {
    $Proc.StandardInput.WriteLine($Json)
    $Proc.StandardInput.Flush()
}

function Read-McpLine([System.Diagnostics.Process]$Proc, [int]$TimeoutMs = 15000) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($Proc.StandardOutput.Peek() -ge 0) {
            return $Proc.StandardOutput.ReadLine()
        }
        Start-Sleep -Milliseconds 30
    }
    return $null
}

function Handle-ServerMessage([System.Diagnostics.Process]$Proc, [string]$Line) {
    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }
    try { $obj = $Line | ConvertFrom-Json } catch { return $null }

    if ($obj.PSObject.Properties.Name -contains "id" -and $obj.PSObject.Properties.Name -contains "method") {
        $id = [int]$obj.id
        $method = [string]$obj.method
        switch ($method) {
            "roots/list" {
                Send-McpLine $Proc ('{"jsonrpc":"2.0","id":' + $id + ',"result":{"roots":[{"uri":"file:///' + ($RootDir -replace '\\','/') + '","name":"app"}]}}')
            }
            default {
                Send-McpLine $Proc ('{"jsonrpc":"2.0","id":' + $id + ',"result":{}}')
            }
        }
        return $null
    }
    return $obj
}

function Wait-McpResponse([System.Diagnostics.Process]$Proc, [int]$Id, [int]$TimeoutMs = 20000) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        $line = Read-McpLine $Proc 500
        if ($null -eq $line) { continue }
        $obj = Handle-ServerMessage $Proc $line
        if ($null -eq $obj) { continue }
        if ($obj.PSObject.Properties.Name -contains "id" -and [int]$obj.id -eq $Id) {
            return $obj
        }
    }
    throw "Timed out waiting for MCP response id=$Id"
}

function Initialize-Mcp([System.Diagnostics.Process]$Proc) {
    $initJson = @'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{"roots":{"listChanged":true}},"clientInfo":{"name":"BrokenKeyRemapper","version":"2.1.0"}}}
'@.Trim()
    Send-McpLine $Proc $initJson
    # Allow a generous window: on a fresh PC, npx must download the
    # @modelcontextprotocol/server-filesystem package before the server responds.
    $init = Wait-McpResponse $Proc 1 90000
    if ($init.error) { throw "MCP initialize failed: $($init.error.message)" }
    Send-McpLine $Proc '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    Start-Sleep -Milliseconds 400

    $drainUntil = [DateTime]::UtcNow.AddMilliseconds(1500)
    while ([DateTime]::UtcNow -lt $drainUntil) {
        if ($Proc.StandardOutput.Peek() -ge 0) {
            $line = $Proc.StandardOutput.ReadLine()
            Handle-ServerMessage $Proc $line | Out-Null
        } else {
            Start-Sleep -Milliseconds 50
        }
    }
}

function Invoke-McpReadTextFile([System.Diagnostics.Process]$Proc, [string]$RelativePath, [ref]$NextId) {
    $path = $RelativePath.Trim().Replace("\", "/")
    if ($path -match '\.\.') { throw "Path traversal not allowed" }

    foreach ($toolName in @("read_text_file", "read_file")) {
        $id = $NextId.Value
        $NextId.Value = $id + 1
        $req = '{"jsonrpc":"2.0","id":' + $id + ',"method":"tools/call","params":{"name":"' + $toolName + '","arguments":{"path":"' + ($path -replace '"','\"') + '"}}}'
        Send-McpLine $Proc $req
        try {
            $resp = Wait-McpResponse $Proc $id 25000
        } catch {
            continue
        }
        if ($resp.error) { continue }
        if ($resp.result.content -is [System.Array] -and $resp.result.content.Count -gt 0) {
            $text = $resp.result.content[0].text
            if ($text) { return [string]$text }
        }
        if ($resp.result.text) { return [string]$resp.result.text }
    }

    $full = Join-Path $RootDir ($path -replace '/', [IO.Path]::DirectorySeparatorChar)
    if (Test-Path -LiteralPath $full -PathType Leaf) {
        Write-Log "MCP tool call unavailable - direct read fallback: $path"
        return [IO.File]::ReadAllText($full, [Text.Encoding]::UTF8)
    }
    throw "MCP read failed for '$RelativePath'"
}

function Send-HttpJson([System.Net.HttpListenerResponse]$Response, [int]$StatusCode, [string]$Json) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = "application/json; charset=utf-8"
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

function Escape-JsonString([string]$s) {
    if ($null -eq $s) { return "" }
    return ($s -replace '\\', '\\\\' -replace '"', '\"' -replace "`r", '\r' -replace "`n", '\n' -replace "`t", '\t')
}

$launcher = Find-McpLauncher
Write-Log "Root: $RootDir"
Write-Log "Launcher: $($launcher.Detail)"
Write-Log "NPX: $($launcher.File)"
Write-Log "HTTP: http://127.0.0.1:$Port/health"

# Start the MCP server and try to initialize it. If this fails (e.g. the
# @modelcontextprotocol/server-filesystem package can't be downloaded on a
# fresh PC that is offline or behind a proxy/firewall), we DO NOT abort.
# Instead we keep running and serve /read straight from disk. This guarantees
# the HTTP listener always comes up so the AutoHotkey client never sees
# ERROR_WINHTTP_CANNOT_CONNECT (0x80072EFD).
$mcpProc = $null
try {
    $mcpProc = Start-McpProcess $launcher
    if ($mcpProc.HasExited) {
        throw "MCP server process exited immediately (exit code $($mcpProc.ExitCode)). See mcp-stderr.log."
    }
    Initialize-Mcp $mcpProc
    $script:McpReady = $true
    Write-Log "MCP server initialized - using MCP tools for reads."
} catch {
    $script:McpReady = $false
    Write-Log "WARNING: MCP init failed - falling back to direct disk reads. Reason: $($_.Exception.Message)"
    Write-Log "This is usually caused by npx being unable to download @modelcontextprotocol/server-filesystem (offline / proxy / firewall)."
    try { if ($mcpProc -and !$mcpProc.HasExited) { $mcpProc.Kill() } } catch {}
    $mcpProc = $null
}
$requestId = 10

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
Write-Log "Listening on port $Port"

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $req = $ctx.Request
        $res = $ctx.Response
        $path = $req.Url.AbsolutePath.TrimEnd("/")
        if (-not $path) { $path = "/" }

        try {
            if ($path -eq "/health") {
                $mode = if ($script:McpReady) { "mcp" } else { "direct" }
                Send-HttpJson $res 200 ('{"ok":true,"mode":"' + $mode + '","root":"' + (Escape-JsonString $RootDir) + '"}')
                continue
            }

            if ($path -eq "/read" -and $req.HttpMethod -eq "POST") {
                $reader = New-Object System.IO.StreamReader($req.InputStream, $req.ContentEncoding)
                $body = $reader.ReadToEnd()
                $reader.Close()
                $payload = $body | ConvertFrom-Json
                $rel = [string]$payload.path
                if ([string]::IsNullOrWhiteSpace($rel)) { $rel = "learned_words.txt" }

                if ($script:McpReady -and $mcpProc -and !$mcpProc.HasExited) {
                    $text = Invoke-McpReadTextFile $mcpProc $rel ([ref]$requestId)
                } else {
                    # MCP is not available - read directly from disk.
                    $safe = $rel.Trim().Replace("\", "/")
                    if ($safe -match '\.\.') { throw "Path traversal not allowed" }
                    $full = Join-Path $RootDir ($safe -replace '/', [IO.Path]::DirectorySeparatorChar)
                    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "File not found: $rel" }
                    $text = [IO.File]::ReadAllText($full, [Text.Encoding]::UTF8)
                }
                Send-HttpJson $res 200 ('{"ok":true,"path":"' + (Escape-JsonString $rel) + '","content":"' + (Escape-JsonString $text) + '"}')
                continue
            }

            Send-HttpJson $res 404 ('{"ok":false,"error":"not found"}')
        } catch {
            Send-HttpJson $res 500 ('{"ok":false,"error":"' + (Escape-JsonString $_.Exception.Message) + '"}')
        }
    }
} finally {
    Write-Log "Shutting down..."
    try { $listener.Stop() } catch {}
    if ($mcpProc) {
        try { $mcpProc.StandardInput.Close() } catch {}
        try { if (!$mcpProc.HasExited) { $mcpProc.Kill() } } catch {}
    }
}
