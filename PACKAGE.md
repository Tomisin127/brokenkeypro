# Packaging Broken Key Remapper Pro for Production

## Can you ship a single EXE?

**Partially yes.** The script already has Ahk2Exe directives at the top of `keymapperV2.ahk`. You can compile it to one executable, but **AI and dictionaries still need companion files** unless you bundle them separately.

## Recommended production layout

```
BrokenKeyRemapper/
  BrokenKeyRemapper.exe      ← compiled from keymapperV2.ahk
  english_words.txt          ← dictionary (~300k words)
  english_bigrams.txt        ← optional bigram data
  learned_words.txt          ← created/updated at runtime
  Start-MCP-Server.bat       ← optional MCP filesystem bridge
  McpBridge.ps1              ← MCP HTTP bridge (used by batch file)
  McpClient.ahk              ← included by keymapperV2.ahk
  llama/
    llama-server.exe
    llama.dll
    ggml*.dll
  smolm-135m.gguf            ← or any .gguf model (select in Settings)
```

User config lives in `%AppData%\BrokenKeyRemapper\` (config.ini, stats, debug.log).

## Build steps (Ahk2Exe)

1. Install [AutoHotkey v2](https://www.autohotkey.com/)
2. Install Ahk2Exe (included with AHK v2 installer)
3. Compile `keymapperV2.ahk`:
   - Base file: `keymapperV2.ahk`
   - Add `#Include` files automatically: `LlamaEngine.ahk`, `McpClient.ahk`, `I18n.ahk`
   - Icon: `BrokenKeyRemapper.ico` (if present)
4. Copy the folder layout above next to the EXE
5. Run `Setup-AI.ps1` once on the target machine **or** ship the `llama/` folder + model pre-downloaded

## What NOT to embed in the EXE

- **llama-server + model (~150MB+)** — too large; ship alongside or run Setup-AI.ps1
- **english_words.txt** — can use `FileInstall` (already wired via `ResolveBundledDataPath`) but increases EXE size; sibling file is fine

## First-run for end users

1. Double-click `BrokenKeyRemapper.exe` or `RunRemapper.bat`
2. Enter **Gumroad license key** (internet required; one key = one PC)
3. If AI desired: run `Setup-AI.ps1` once, or use **Settings → Setup AI**
4. F12 to enable mapping

## Licensing (Gumroad)

Activation is enforced in `License.ahk` before the app loads:

- **API:** `https://api.gumroad.com/v2/licenses/verify`
- **Product ID:** set in `License.ahk` (`GUMROAD_PRODUCT_ID`)
- **Device binding:** stable fingerprint (volume serial + machine hash) sent as `fingerprint`
- **Storage:** `%AppData%\BrokenKeyRemapper\license.txt`
- **Tray:** License... to view status or change key

Every launch re-verifies the saved key online (offline = cannot run).

## Distribution packs

| Script | Output |
|--------|--------|
| `Create-Portable-Pack.ps1` | `dist\BrokenKeyRemapper-Portable.zip` for Gumroad |
| `Create-Portable-Pack.ps1 -CompileExe` | Same + compiled EXE if Ahk2Exe is installed |
| `Install.ps1` | Installs to `%LocalAppData%\Programs\BrokenKeyRemapper` + shortcuts |
| `installer.iss` | Compile with Inno Setup → `dist\BrokenKeyRemapper-Setup.exe` |

```powershell
powershell -ExecutionPolicy Bypass -File Create-Portable-Pack.ps1
powershell -ExecutionPolicy Bypass -File Create-Portable-Pack.ps1 -CompileExe
```

## AutoHotInterception (advanced)

[AutoHotInterception](https://github.com/evilC/AutoHotInterception) intercepts keyboards at the HID driver level. It requires a separate driver install and is **not integrated** into this tool. Use it only if you need hardware-level remapping beyond standard AHK hotkeys.

## MCP (advanced personalization)

Two modes are available in **Settings**:

| Mode | Setting | How it works |
|------|---------|--------------|
| **Simple** | Inject learned_words.txt | Reads `learned_words.txt` from disk on each AI call and injects top words into the prompt. |
| **MCP** | Enable MCP for learned_words.txt | Starts a local MCP filesystem server; the app calls `read_file` via HTTP bridge and sends tool definitions to llama-server. |

If MCP is enabled but the bridge is offline, the app falls back to simple injection (when that option is also enabled).

### Prerequisites

| Component | Required for | Download |
|-----------|--------------|----------|
| **AutoHotkey v2** | Running the app | https://www.autohotkey.com/ |
| **llama-server + model** | AI predictions | Run `Setup-AI.ps1` or **Settings → Setup AI** (~150 MB) |
| **Node.js (npx)** | MCP mode only | https://nodejs.org/ — first MCP start auto-downloads the MCP filesystem package |

### One-click MCP server

1. Install **Node.js LTS** if you do not have `npx` (see table above)
2. **Settings → Setup MCP** (or double-click `Start-MCP-Server.bat`)
3. Keep the console window open — HTTP API at `http://127.0.0.1:8766`
4. In Settings: enable **Enable MCP for learned_words.txt**, click **Test**, then **Save**

- `Start-MCP-Server.bat` — launches the bridge
- `McpBridge.ps1` — HTTP wrapper around `@modelcontextprotocol/server-filesystem`
- `McpClient.ahk` — HTTP client used by the remapper

### config.ini keys

```ini
[Settings]
AILearnedContext=1    ; simple injection (0|1)
AIMcpEnabled=0        ; MCP mode (0|1)
AIMcpUrl=http://127.0.0.1:8766
```
