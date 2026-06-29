#Requires AutoHotkey v2.0

; llama-server HTTP client — model stays loaded in a background process (fast repeat calls).

class LlamaEngine {
    static API_VERSION := "b9835-server"
    static Loaded := false
    static LoadError := ""
    static serverPid := 0
    static port := 8765
    static host := "127.0.0.1"
    static llamaDir := ""
    static serverExe := ""
    static modelPath := ""
    static lastPrompt := ""

    static Init(modelPath := "", llamaDir := "", nCtx := 512, nThreads := 0) {
        this.Shutdown()

        if (llamaDir = "")
            llamaDir := this.ResolveLlamaDir()
        if (modelPath = "")
            modelPath := this.ResolveModelPath()

        this.llamaDir := llamaDir
        this.modelPath := modelPath
        this.serverExe := this.ResolveServerExe(llamaDir)

        if !FileExist(this.serverExe) {
            this.LoadError := "llama-server.exe not found"
            return false
        }
        if !FileExist(modelPath) {
            this.LoadError := "Model not found: " modelPath
            return false
        }

        if (nThreads <= 0)
            nThreads := Max(1, EnvGet("NUMBER_OF_PROCESSORS") + 0)

        args := Format(
            '-m "{1}" --host {2} --port {3} -c {4} -t {5} --parallel 1 --cont-batching',
            modelPath, this.host, this.port, nCtx, nThreads)

        try {
            Run('"' this.serverExe '" ' args, this.llamaDir, "Hide", &pid)
            this.serverPid := pid
        } catch as e {
            this.LoadError := "Could not start llama-server: " e.Message
            return false
        }

        if !this._WaitReady(45000) {
            this.LoadError := "llama-server did not start in time"
            this.Shutdown()
            return false
        }

        this.Loaded := true
        this.LoadError := ""
        return true
    }

    static ResolveServerExe(llamaDir) {
        for path in [llamaDir "\llama-server.exe", A_ScriptDir "\llama-server.exe", A_ScriptDir "\llama\llama-server.exe"] {
            if FileExist(path)
                return path
        }
        return A_ScriptDir "\llama\llama-server.exe"
    }

    static ResolveLlamaDir() {
        for dir in [A_ScriptDir "\llama", A_ScriptDir] {
            if FileExist(dir "\llama-server.exe") || FileExist(dir "\llama.dll")
                return dir
        }
        return A_ScriptDir "\llama"
    }

    static ResolveModelPath() {
        for path in [A_ScriptDir "\smolm-135m.gguf", A_ScriptDir "\llama\smolm-135m.gguf"] {
            if FileExist(path)
                return path
        }
        return A_ScriptDir "\smolm-135m.gguf"
    }

    static Complete(prompt, maxTokens := 1) {
        if !this.Loaded
            return ""

        body := '{"prompt":"' this._JsonEscape(prompt)
            . '","n_predict":' maxTokens
            . ',"temperature":0.05,"top_k":10,"top_p":0.85'
            . ',"cache_prompt":true,"stop":["\n"," ","\t","."]}'

        try {
            resp := this._Post("/completion", body, 2500)
        } catch as e {
            this.LoadError := e.Message
            return ""
        }

        text := this._ExtractContent(resp)
        if (text = "" && InStr(resp, '"content"'))
            text := this._JsonField(resp, "content")

        text := Trim(text, "`r`n `t")
        text := RegExReplace(text, "`n.*", "")
        this.lastPrompt := prompt
        return text
    }

    static _WaitReady(timeoutMs) {
        deadline := A_TickCount + timeoutMs
        while (A_TickCount < deadline) {
            try {
                this._Get("/health")
                return true
            } catch {
                try {
                    this._Post("/completion", '{"prompt":"hi","n_predict":1,"temperature":0.1}')
                    return true
                }
            }
            Sleep 400
        }
        return false
    }

    static _Get(path) {
        req := ComObject("WinHttp.WinHttpRequest.5.1")
        req.Open("GET", "http://" this.host ":" this.port path, false)
        req.Send()
        if (req.Status != 200)
            throw Error("HTTP " req.Status)
        return req.ResponseText
    }

    static _Post(path, body, timeoutMs := 8000) {
        req := ComObject("WinHttp.WinHttpRequest.5.1")
        req.Open("POST", "http://" this.host ":" this.port path, false)
        req.SetTimeouts(timeoutMs, timeoutMs, timeoutMs, timeoutMs)
        req.SetRequestHeader("Content-Type", "application/json")
        req.Send(body)
        if (req.Status != 200)
            throw Error("HTTP " req.Status " " SubStr(req.ResponseText, 1, 120))
        return req.ResponseText
    }

    static _ExtractContent(json) {
        if RegExMatch(json, '"content"\s*:\s*"((?:\\.|[^"\\])*)"', &m)
            return this._JsonUnescape(m[1])
        if RegExMatch(json, '"content"\s*:\s*"([^"]*)"', &m2)
            return m2[1]
        return ""
    }

    static _JsonField(json, key) {
        if RegExMatch(json, '"' key '"\s*:\s*"((?:\\.|[^"\\])*)"', &m)
            return this._JsonUnescape(m[1])
        return ""
    }

    static _JsonEscape(s) {
        s := StrReplace(s, "\", "\\")
        s := StrReplace(s, '"', '\"')
        s := StrReplace(s, "`r", "")
        s := StrReplace(s, "`n", "\n")
        s := StrReplace(s, "`t", "\t")
        return s
    }

    static _JsonUnescape(s) {
        s := StrReplace(s, '\n', "`n")
        s := StrReplace(s, '\t', "`t")
        s := StrReplace(s, '\"', '"')
        s := StrReplace(s, '\\', '\')
        return s
    }

    static Shutdown() {
        if this.serverPid {
            try ProcessClose(this.serverPid)
            catch
                try Run(A_ComSpec ' /c taskkill /PID ' this.serverPid ' /F', , "Hide")
            this.serverPid := 0
        }
        this.Loaded := false
    }

    static StatusText() {
        if this.Loaded
            return "llama-server on port " this.port
        if (this.LoadError != "")
            return this.LoadError
        return "not running"
    }
}
