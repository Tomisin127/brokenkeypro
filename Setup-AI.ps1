# Downloads llama.cpp b9835 CPU binaries + SmolLM-135M for Broken Key Remapper Pro.
# Uses llama-server.exe (model stays loaded = fast AI).
# Run:  powershell -ExecutionPolicy Bypass -File Setup-AI.ps1
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$LlamaDir = Join-Path $Root "llama"
$Tag = "b9835"
$ZipName = "llama-$Tag-bin-win-cpu-x64.zip"
$ZipUrl = "https://github.com/ggml-org/llama.cpp/releases/download/$Tag/$ZipName"
$ModelUrl = "https://huggingface.co/mradermacher/SmolLM-135M-GGUF/resolve/main/SmolLM-135M.Q8_0.gguf"
$ModelName = "smolm-135m.gguf"

New-Item -ItemType Directory -Force -Path $LlamaDir | Out-Null

Write-Host "Downloading llama.cpp $Tag Windows CPU binaries..."
$zipPath = Join-Path $env:TEMP $ZipName
Invoke-WebRequest -Uri $ZipUrl -OutFile $zipPath -UseBasicParsing
Expand-Archive -Path $zipPath -DestinationPath $LlamaDir -Force

# Release zips often unpack into a subfolder — flatten DLLs into llama\
Get-ChildItem $LlamaDir -Recurse -Include llama-server.exe,llama.dll,ggml*.dll | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $LlamaDir $_.Name) -Force
}

Write-Host "Downloading model (~140 MB)..."
$modelPath = Join-Path $Root $ModelName
Invoke-WebRequest -Uri $ModelUrl -OutFile $modelPath -UseBasicParsing

Write-Host ""
Write-Host "Done."
Write-Host "  DLLs : $LlamaDir"
Write-Host "  Model: $modelPath"
Write-Host "Run RunRemapper.bat — AI starts automatically via llama-server."