#Requires AutoHotkey v2.0

; HTTP client for the local MCP bridge (McpBridge.ps1 / Start-MCP-Server.bat).

class McpClient {
    static baseUrl := "http://127.0.0.1:8766"
    static lastError := ""
    static timeoutMs := 10000

    static SetBaseUrl(url) {
        url := Trim(url)
        if (url = "")
            url := "http://127.0.0.1:8766"
        if !InStr(url, "://")
            url := "http://" url
        this.baseUrl := RTrim(url, "/")
    }

    static Ping() {
        this.lastError := ""
        try {
            req := ComObject("WinHttp.WinHttpRequest.5.1")
            req.Open("GET", this.baseUrl "/health", false)
            ; Force a direct (no-proxy) connection. On PCs with a system/WinHTTP
            ; proxy configured, localhost can otherwise be routed through the
            ; proxy and fail with 0x80072EFD (ERROR_WINHTTP_CANNOT_CONNECT).
            try req.SetProxy(1)
            req.SetTimeouts(3000, 3000, 3000, 3000)
            req.Send()
            if (req.Status != 200) {
                this.lastError := "HTTP " req.Status
                return false
            }
            return InStr(req.ResponseText, '"ok":true') > 0
        } catch as e {
            this.lastError := e.Message
            return false
        }
    }

    static ReadTextFile(relativePath := "learned_words.txt") {
        this.lastError := ""
        rel := Trim(relativePath)
        if (rel = "")
            rel := "learned_words.txt"
        body := '{"path":"' this._JsonEscape(rel) '"}'
        try {
            req := ComObject("WinHttp.WinHttpRequest.5.1")
            req.Open("POST", this.baseUrl "/read", false)
            ; Force a direct (no-proxy) connection for localhost - see Ping().
            try req.SetProxy(1)
            req.SetTimeouts(this.timeoutMs, this.timeoutMs, this.timeoutMs, this.timeoutMs)
            req.SetRequestHeader("Content-Type", "application/json")
            req.Send(body)
            if (req.Status != 200) {
                this.lastError := "HTTP " req.Status " — is Start-MCP-Server.bat running?"
                return ""
            }
            resp := req.ResponseText
            if RegExMatch(resp, '"content"\s*:\s*"((?:\\.|[^"\\])*)"', &m)
                return this._JsonUnescape(m[1])
            if RegExMatch(resp, '"error"\s*:\s*"((?:\\.|[^"\\])*)"', &e)
                this.lastError := this._JsonUnescape(e[1])
            else
                this.lastError := "Empty MCP response"
            return ""
        } catch as ex {
            this.lastError := ex.Message
            return ""
        }
    }

    static StartServer() {
        bat := A_ScriptDir "\Start-MCP-Server.bat"
        if !FileExist(bat) {
            MsgBox "Start-MCP-Server.bat was not found next to the script.", "MCP Server", "IconX"
            return false
        }
        try {
            Run('"' bat '"', A_ScriptDir, "Max")
            return true
        } catch as e {
            MsgBox "Could not start MCP server:`n" e.Message, "MCP Server", "IconX"
            return false
        }
    }

    static StatusText() {
        if this.Ping()
            return "MCP bridge ready at " this.baseUrl
        if (this.lastError != "")
            return "MCP offline — " this.lastError
        return "MCP offline — run Setup MCP Server"
    }

    static _JsonEscape(s) {
        s := StrReplace(s, "\", "\\")
        s := StrReplace(s, '"', '\"')
        return s
    }

    static _JsonUnescape(s) {
        s := StrReplace(s, '\n', "`n")
        s := StrReplace(s, '\r', "`r")
        s := StrReplace(s, '\t', "`t")
        s := StrReplace(s, '\"', '"')
        s := StrReplace(s, '\\', '\')
        return s
    }
}
