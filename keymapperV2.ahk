;@Ahk2Exe-SetName Broken Key Remapper Pro
;@Ahk2Exe-SetDescription Smart remapper for keyboards with broken keys (predictive + learning + AI)
;@Ahk2Exe-SetVersion 2.1.0
;@Ahk2Exe-SetCopyright 2025-2026
;@Ahk2Exe-AddResource BrokenKeyRemapper.ico

#SingleInstance Force
#Requires AutoHotkey v2.0
#Warn All, Off
#MaxThreadsPerHotkey 3
#MaxThreads 20

#Include "LlamaEngine.ahk"
#Include "McpClient.ahk"
#Include "I18n.ahk"
#Include "License.ahk"

global boundHotkeys := Map()

; =============================================================================
;  PATHS & GLOBAL STATE
; =============================================================================
global APP_DIR        := A_AppData "\BrokenKeyRemapper"
global INI_PATH       := APP_DIR "\config.ini"
global LEARN_PATH     := A_ScriptDir "\learned_words.txt"
global STATS_PATH     := APP_DIR "\stats.ini"
global LOG_PATH       := APP_DIR "\debug.log"
global DICT_PATH      := ""
global BIGRAM_PATH    := ""

; AI — llama-server.exe keeps model loaded (fast). See Setup-AI.ps1.
global AI_MODEL       := ""
global AI_ENABLED     := true
global AI_MIN_CONFIDENCE := 40
global AI_SCORE_THRESHOLD := 2.0
global REJECTION_AI_WINDOW_MS := 20000
global AI_MAX_TOKENS  := 8
global AI_CTX         := 512
global AI_THREADS     := 0
global AI_PORT        := 8765
global AI_LEARNED_CONTEXT := true
global AI_MCP_ENABLED   := false
global AI_MCP_URL       := "http://127.0.0.1:8766"
global AI_MODEL_PATH    := ""

if !DirExist(APP_DIR)
    DirCreate(APP_DIR)

global remapMode      := false
global remaps         := Map()
global groups         := Map()
global currentIndex   := Map()
global traverseStack  := Map()

global charBuffer     := ""
global maxBuffer      := 2000
global lastPrediction := { host: "", char: "", alts: [], pos: 0, ts: 0, prefix: "" }
global lastRejectedPrediction := { char: "", prefix: "", host: "", ts: 0 }

global sendingInternally := false
global learnedPending := Map()
global userLearned     := Map()
global predictionLock  := false

global wordTrie       := ""
global unigrams       := Map()
global bigrams        := Map()
global totalUniFreq   := 0

global stats := Map("predictions",0,"ai_calls",0,"session_start",A_TickCount)

global hudGui := "", hudVisible := false, hudEnabled := true, GuiObj := ""

global GRAD_TOP := 0x1E3A8A, GRAD_MID := 0x60A5FA, GRAD_BOTTOM := 0xF8FAFF


; Sorted dropdown lists — letters, numbers, F-keys, symbols, navigation.
OrganizedKeyList(outputOnly := false) {
    list := []
    Loop 26
        list.Push(Chr(A_Index + 96))
    Loop 10
        list.Push(String(A_Index - 1))
    Loop 12
        list.Push("F" A_Index)
    if outputOnly {
        for s in [":","@","#","$","%","^","&","*","(",")","+","-","=","_","[","]","\","|",";","'","``",",",".","/","<",">","?","!","~",'"']
            list.Push(s)
        list.Push("Tab")
        list.Push("Space")
    } else {
        for s in ["-","=","[","]","\",";","'","``",",",".","/"]
            list.Push(s)
        for k in ["Space","Enter","Tab","Esc","Backspace","Delete","Insert","Home","End","PgUp","PgDn","Up","Down","Left","Right"]
            list.Push(k)
    }
    return list
}


; =============================================================================
;  UTILITIES (Early)
; =============================================================================
LogMsg(msg) {
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") " | " msg "`n", LOG_PATH, "UTF-8")
}

ArrayJoin(arr, sep := ",") {
    if arr.Length = 0
        return ""
    out := arr[1]
    Loop arr.Length - 1
        out .= sep arr[A_Index + 1]
    return out
}

; Finds english_words.txt / english_bigrams.txt for dev (script dir), compiled
; (FileInstall -> temp), or sibling ..\keymapper\ when files live there.
ResolveBundledDataPath(fileName) {
    tempPath := A_Temp "\" fileName
    candidates := [
        A_ScriptDir "\" fileName,
        A_ScriptDir "\..\keymapper\" fileName,
        tempPath
    ]
    try FileInstall(fileName, tempPath, 1)
    for path in candidates {
        if FileExist(path) {
            if (path != tempPath && (!FileExist(tempPath) || FileGetTime(path) > FileGetTime(tempPath)))
                try FileCopy(path, tempPath, 1)
            return FileExist(tempPath) ? tempPath : path
        }
    }
    return tempPath
}

AddFlatButton(x, y, w, h, label, handler, primary := false) {
    global GuiObj
    opts := "x" x " y" y " w" w " h" h
    if primary
        opts .= " vToggleBtn Default"
    btn := GuiObj.AddButton(opts, label)
    btn.OnEvent("Click", handler)
    return btn
}


; =============================================================================
;  CONFIG & USER FUNCTIONS (moved early)
; =============================================================================
BuildGroupsFromRemaps() {
    global remaps, groups, currentIndex
    groups.Clear()
    currentIndex.Clear()
    for k, v in remaps {
        groups[k] := StrSplit(v, ",")
        currentIndex[k] := 1
    }
}

SaveRemapsToIni() {
    global INI_PATH, remaps
    try IniDelete(INI_PATH, "Remaps")
    for k, v in remaps
        IniWrite(v, INI_PATH, "Remaps", k)
}

LoadRemapsFromIni() {
    global INI_PATH, remaps
    if !FileExist(INI_PATH)
        return
    try data := IniRead(INI_PATH, "Remaps")
    catch
        return
    for , line in StrSplit(data, "`n") {
        if !InStr(line, "=")
            continue
        parts := StrSplit(line, "=", , 2)
        remaps[Trim(parts[1])] := Trim(parts[2])
    }
}

UpdateListView() {
    lv := GuiObj["LVRemapList"]
    lv.Delete()
    for host, outs in groups {
        curr := outs[currentIndex[host]]
        vk := "?", sc := "?"
        try vk := Format("vk{:02X}", GetKeyVK(host))
        try sc := Format("sc{:03X}", GetKeySC(host))
        lv.Add("", host, ArrayJoin(outs, ","), curr, vk, sc, "0")
    }
    lv.ModifyCol()
}

; =============================================================================
;  AI FUNCTIONS (llama.dll via LlamaEngine)
; =============================================================================
InitAI() {
    global AI_MODEL, AI_ENABLED, AI_CTX, AI_THREADS, AI_PORT, AI_MODEL_PATH
    if !AI_ENABLED
        return false

    if (AI_MODEL_PATH != "" && FileExist(AI_MODEL_PATH))
        AI_MODEL := AI_MODEL_PATH
    else if (AI_MODEL = "")
        AI_MODEL := LlamaEngine.ResolveModelPath()

    LlamaEngine.port := AI_PORT
    ok := LlamaEngine.Init(AI_MODEL, "", AI_CTX, AI_THREADS)
    if !ok
        LogMsg("AI init failed: " LlamaEngine.LoadError)
    else
        LogMsg("AI ready: " LlamaEngine.StatusText() " model=" AI_MODEL)
    return ok
}

RestartAI(*) {
    global AI_ENABLED
    if !AI_ENABLED
        return
    LlamaEngine.Shutdown()
    if InitAI()
        MsgBox "AI restarted successfully.", "AI", "Iconi T2"
    else
        MsgBox "AI restart failed: " LlamaEngine.LoadError, "AI", "IconX"
    UpdateAIStatus()
}

FormatLearnedRowsForPrompt(rows, maxLines := 20) {
    n := rows.Length
    Loop n - 1 {
        i := A_Index
        Loop n - i {
            j := A_Index
            if (rows[j].freq < rows[j + 1].freq) {
                tmp := rows[j]
                rows[j] := rows[j + 1]
                rows[j + 1] := tmp
            }
        }
    }
    out := ""
    Loop Min(maxLines, rows.Length) {
        out .= rows[A_Index].word "(" rows[A_Index].freq ") "
    }
    return Trim(out)
}

ParseLearnedRowsFromText(text, prefix := "") {
    rows := []
    for , line in StrSplit(text, "`n", "`r") {
        line := Trim(line)
        if (line = "" || RegExMatch(line, "^[;#]"))
            continue
        parts := StrSplit(line, A_Tab)
        if parts.Length < 2
            parts := StrSplit(line, ",")
        if parts.Length < 1
            continue
        word := StrLower(Trim(parts[1]))
        freq := (parts.Length >= 2 && IsInteger(parts[2])) ? Integer(parts[2]) : 1
        if (word = "" || !RegExMatch(word, "^[a-z0-9_'@.-]+$"))
            continue
        if (prefix != "" && SubStr(word, 1, StrLen(prefix)) != prefix && !InStr(word, prefix))
            continue
        rows.Push({ word: word, freq: freq })
    }
    return rows
}

ReadLearnedContextForPrompt(prefix := "", maxLines := 20) {
    global LEARN_PATH, AI_LEARNED_CONTEXT, userLearned
    if !AI_LEARNED_CONTEXT
        return ""

    ReloadLearnedWordsSnapshot()

    rows := []
    for word, freq in userLearned {
        if (prefix != "" && SubStr(word, 1, StrLen(prefix)) != prefix && !InStr(word, prefix))
            continue
        rows.Push({ word: word, freq: freq })
    }
    return FormatLearnedRowsForPrompt(rows, maxLines)
}

FetchLearnedViaMcp(prefix := "", maxLines := 20) {
    global AI_MCP_ENABLED, AI_MCP_URL, LEARN_PATH
    if !AI_MCP_ENABLED
        return { hint: "", ok: false, source: "" }

    McpClient.SetBaseUrl(AI_MCP_URL)
    raw := McpClient.ReadTextFile("learned_words.txt")
    if (raw = "") {
        LogMsg("MCP read failed: " McpClient.lastError)
        return { hint: "", ok: false, source: "mcp" }
    }

    rows := ParseLearnedRowsFromText(raw, prefix)
    hint := FormatLearnedRowsForPrompt(rows, maxLines)
    if (hint = "")
        hint := "(learned_words.txt is empty or has no matching entries)"
    return { hint: hint, ok: true, source: "mcp" }
}

ReloadLearnedWordsSnapshot() {
    global userLearned, LEARN_PATH
    if !FileExist(LEARN_PATH)
        return
    try text := FileRead(LEARN_PATH, "UTF-8")
    catch
        return
    for , line in StrSplit(text, "`n", "`r") {
        line := Trim(line)
        if (line = "" || RegExMatch(line, "^[;#]"))
            continue
        parts := StrSplit(line, A_Tab)
        if parts.Length < 2
            parts := StrSplit(line, ",")
        if parts.Length < 1
            continue
        word := StrLower(Trim(parts[1]))
        freq := (parts.Length >= 2 && IsInteger(parts[2])) ? Integer(parts[2]) : 1
        if (word != "" && RegExMatch(word, "^[a-z0-9_'@.-]+$"))
            userLearned[word] := freq
    }
}

UpdateAIStatus() {
    global AI_ENABLED, GuiObj
    if !IsObject(GuiObj)
        return
    try {
        if !AI_ENABLED {
            GuiObj["AIText"].Text := "  AI: disabled"
            GuiObj["AIText"].Opt("cAAAAAA")
        } else if LlamaEngine.Loaded {
            GuiObj["AIText"].Text := "  AI: " LlamaEngine.StatusText()
            GuiObj["AIText"].Opt("c90EE90")
        } else {
            GuiObj["AIText"].Text := "  AI: " LlamaEngine.StatusText()
            GuiObj["AIText"].Opt("cFFB347")
        }
    }
}

BuildAIPrompt(ctx, allowedLetters, rejectedChar := "", learnedHint := "", learnedSource := "") {
    global AI_MCP_ENABLED, AI_LEARNED_CONTEXT, LEARN_PATH
    recent := ctx.recentText
    if (StrLen(recent) > 300)
        recent := SubStr(recent, -300)
    opts := ArrayJoin(allowedLetters, ", ")
    prompt := "You complete text one letter at a time (English words, emails, URLs, names).`n"
        . "Session: " recent "`n"
    if (ctx.compound)
        prompt .= "Context: email/URL/compound text — ignore normal dictionary.`n"
    if (ctx.prevWord != "")
        prompt .= "Previous segment: " ctx.prevWord "`n"
    if (ctx.prefix != "")
        prompt .= "Partial segment: " ctx.prefix "`n"
    else if (ctx.prevWord != "")
        prompt .= "New segment after: " ctx.prevWord "`n"

    if AI_MCP_ENABLED {
        prompt .= "Personal vocabulary: use MCP read_file tool on learned_words.txt (latest file in app folder).`n"
        if (learnedHint != "" && learnedSource = "mcp")
            prompt .= "MCP read_file(learned_words.txt): " learnedHint "`n"
        else if (learnedHint != "" && learnedSource = "fallback")
            prompt .= "MCP unavailable — injected from disk instead: " learnedHint "`n"
        else
            prompt .= "Call read_file(path=`"learned_words.txt`") via MCP before answering if vocabulary is needed.`n"
    } else if AI_LEARNED_CONTEXT {
        if (learnedHint = "")
            learnedHint := ReadLearnedContextForPrompt(ctx.prefix, 20)
        if (learnedHint != "")
            prompt .= "User learned words (personal): " learnedHint "`n"
    }

    prompt .= "Choose exactly ONE letter from: " opts "`n"
    if (rejectedChar != "")
        prompt .= "Do NOT pick '" rejectedChar "' (user rejected it).`n"
    prompt .= "Answer:"
    return prompt
}

ExtractLetterFromAI(aiText, prefix, allowedLetters, rejectedChar := "") {
    aiText := StrLower(Trim(aiText, "`r`n `t.:;,!"))
    if (aiText = "")
        return ""

    if RegExMatch(aiText, "^[a-z]$") {
        for , letter in allowedLetters {
            if (StrLower(letter) = aiText && StrLower(letter) != StrLower(rejectedChar))
                return letter
        }
    }

    best := "", bestScore := -999.0
    for , letter in allowedLetters {
        ch := StrLower(letter)
        if (rejectedChar != "" && ch = StrLower(rejectedChar))
            continue
        if InStr(aiText, ch) {
            ds := GetDictionaryLetterScore(prefix, letter)
            if (ds > bestScore) {
                bestScore := ds
                best := letter
            }
        }
    }
    if (best != "")
        return best

    if (prefix != "" && StrLen(aiText) >= StrLen(prefix) && SubStr(aiText, 1, StrLen(prefix)) = StrLower(prefix)) {
        tail := SubStr(aiText, StrLen(prefix) + 1)
        if RegExMatch(tail, "[a-z]", &m) {
            for , letter in allowedLetters {
                if (StrLower(letter) = m[0] && StrLower(letter) != StrLower(rejectedChar))
                    return letter
            }
        }
    }
    return ""
}

PickBestDictLetter(prefix, allowedLetters, excludeChar := "") {
    best := "", bestScore := -999.0
    for , letter in allowedLetters {
        if (excludeChar != "" && StrLower(letter) = StrLower(excludeChar))
            continue
        ds := GetDictionaryLetterScore(prefix, letter)
        if (ds > bestScore) {
            bestScore := ds
            best := letter
        }
    }
    return bestScore >= 0 ? best : ""
}

McpReadFileForTools(relativePath) {
    global AI_MCP_URL
    McpClient.SetBaseUrl(AI_MCP_URL)
    return McpClient.ReadTextFile(relativePath)
}

ResolveLearnedHintForAI(ctx) {
    global AI_MCP_ENABLED, AI_LEARNED_CONTEXT
    if AI_MCP_ENABLED {
        mcp := FetchLearnedViaMcp(ctx.prefix, 20)
        if mcp.ok
            return { hint: mcp.hint, source: "mcp" }
        if AI_LEARNED_CONTEXT {
            fallback := ReadLearnedContextForPrompt(ctx.prefix, 20)
            if (fallback != "")
                LogMsg("MCP failed (" McpClient.lastError ") — using direct learned_words injection")
            return { hint: fallback, source: fallback != "" ? "fallback" : "" }
        }
        LogMsg("MCP failed (" McpClient.lastError ") — no fallback (injection disabled)")
        return { hint: "", source: "" }
    }
    if AI_LEARNED_CONTEXT
        return { hint: ReadLearnedContextForPrompt(ctx.prefix, 20), source: "inject" }
    return { hint: "", source: "" }
}

CallAI(prompt, useMcpTools := false) {
    global stats, AI_ENABLED, AI_MAX_TOKENS, AI_MCP_ENABLED
    if (!AI_ENABLED || !LlamaEngine.Loaded)
        return ""

    LlamaEngine.mcpToolsEnabled := useMcpTools && AI_MCP_ENABLED
    if LlamaEngine.mcpToolsEnabled {
        result := LlamaEngine.CompleteWithMcpTools(prompt, McpReadFileForTools, AI_MAX_TOKENS)
    } else {
        result := LlamaEngine.Complete(prompt, AI_MAX_TOKENS)
    }

    snippet := StrReplace(SubStr(result, 1, 40), "`n", " ")
    if (result != "") {
        stats["ai_calls"] += 1
        mode := LlamaEngine.mcpToolsEnabled ? "mcp" : "plain"
        LogMsg("AI ok (" mode "): [" snippet "]")
    } else
        LogMsg("AI empty/timeout for: " SubStr(prompt, 1, 80))
    return result
}

GetTypingContext() {
    global charBuffer
    return {
        prefix: GetSegmentPrefix(),
        prevWord: GetPreviousSegment(),
        recentText: RTrim(charBuffer),
        recentWords: GetRecentWords(8),
        compound: IsCompoundContext()
    }
}

GetSegmentPrefix() {
    global charBuffer
    buf := RTrim(charBuffer)
    i := StrLen(buf)
    while i > 0 {
        ch := SubStr(buf, i, 1)
        if !RegExMatch(ch, "[a-zA-Z0-9_-]")
            break
        i--
    }
    return StrLower(SubStr(buf, i + 1))
}

GetCurrentPrefix() {
    return GetSegmentPrefix()
}

IsCompoundContext() {
    global charBuffer
    tail := SubStr(charBuffer, -100)
    return (InStr(tail, "@") || InStr(tail, ".") || RegExMatch(tail, "\d[a-zA-Z]"))
}

GetPreviousSegment() {
    global charBuffer
    buf := StrLower(RTrim(charBuffer))
    prefix := GetSegmentPrefix()
    temp := SubStr(buf, 1, StrLen(buf) - StrLen(prefix))
    temp := RTrim(temp, "@./_- ")
    i := StrLen(temp)
    while i > 0 {
        ch := SubStr(temp, i, 1)
        if !RegExMatch(ch, "[a-zA-Z0-9_-]")
            break
        i--
    }
    return SubStr(temp, i + 1)
}

GetRecentWords(n := 5) {
    global charBuffer
    words := []
    buf := RTrim(StrLower(charBuffer))
    i := StrLen(buf)
    while (i > 0 && words.Length < n) {
        if RegExMatch(SubStr(buf, i, 1), "[a-z']") {
            end := i
            while (i > 0 && RegExMatch(SubStr(buf, i, 1), "[a-z']"))
                i--
            w := SubStr(buf, i + 1, end - i)
            if (w != "")
                words.InsertAt(1, w)
        } else
            i--
    }
    return words
}

GetLettersAfterPreviousWord(prevWord, allowedLetters) {
    global bigrams
    scores := Map()
    if (prevWord = "" || !bigrams.Has(prevWord))
        return scores
    for nextW, freq in bigrams[prevWord] {
        ch := SubStr(nextW, 1, 1)
        for , letter in allowedLetters {
            if (StrLower(ch) = StrLower(letter))
                scores[letter] := scores.Get(letter, 0) + freq
        }
    }
    return scores
}

GetLearnedLetterScores(prefix, allowedLetters, compound := false) {
    global userLearned, wordTrie
    scores := Map()

    dictBest := "", dictBestScore := -999.0
    for , letter in allowedLetters {
        ds := compound ? 0.0 : GetDictionaryLetterScore(prefix, letter)
        if (ds > dictBestScore) {
            dictBestScore := ds
            dictBest := letter
        }
    }

    for word, freq in userLearned {
        if (prefix != "" && SubStr(word, 1, StrLen(prefix)) != prefix)
            continue
        if (!compound && !wordTrie.IsCompleteWord(word) && !RegExMatch(word, "^[a-z0-9_'@.-]+$"))
            continue
        ch := SubStr(word, StrLen(prefix) + 1, 1)
        if (ch = "" || !RegExMatch(ch, "[a-z0-9]"))
            continue
        for , letter in allowedLetters {
            if (StrLower(ch) = StrLower(letter)) {
                boost := freq * 3.0
                if (!compound && dictBest != "" && dictBest != ch && dictBestScore > 0.5)
                    boost *= 0.3
                scores[letter] := scores.Get(letter, 0) + boost
            }
        }
    }
    return scores
}

GetDoubleLetterBoost(prefix, letter) {
    global wordTrie
    if (prefix = "" || StrLen(prefix) < 1)
        return 0.0
    if (StrLower(SubStr(prefix, -1)) != StrLower(letter))
        return 0.0
    node := wordTrie.GetNode(prefix . StrLower(letter))
    return node ? 0.85 : 0.0
}

; Fast trie lookup — invalid English continuations get a heavy penalty.
GetDictionaryLetterScore(prefix, letter) {
    global wordTrie, totalUniFreq
    cand := StrLower(prefix) . StrLower(letter)
    node := wordTrie.GetNode(cand)
    if !node
        return -10.0

    score := 0.0
    if node["end"]
        score += 1.5 + Min(0.5, node["freq"] / 50000.0)

    if totalUniFreq > 0 {
        subtree := wordTrie.GetSubtreeFreq(cand)
        score += Min(2.5, (subtree / totalUniFreq) * 60.0)
    }
    return score
}

BestDictionaryScore(prefix, allowedLetters) {
    best := -999.0
    for , letter in allowedLetters
        best := Max(best, GetDictionaryLetterScore(prefix, letter))
    return best
}

HasRecentRejectedPrediction(host, prefix) {
    global lastRejectedPrediction, REJECTION_AI_WINDOW_MS
    if (lastRejectedPrediction.char = "" || lastRejectedPrediction.host != host)
        return false
    if (A_TickCount - lastRejectedPrediction.ts > REJECTION_AI_WINDOW_MS)
        return false
    return (lastRejectedPrediction.prefix = prefix)
}

ClearRejectedPrediction() {
    global lastRejectedPrediction
    lastRejectedPrediction := { char: "", prefix: "", host: "", ts: 0 }
}

ShouldInvokeAI(ctx, allowedLetters, scores, bestScore, skipAI, host := "") {
    global AI_ENABLED, AI_SCORE_THRESHOLD
    if (skipAI || !AI_ENABLED || !LlamaEngine.Loaded)
        return { use: false, rejected: "" }

    rejected := ""
    if (host != "" && HasRecentRejectedPrediction(host, ctx.prefix)) {
        rejected := lastRejectedPrediction.char
        return { use: true, rejected: rejected }
    }

    bestDict := BestDictionaryScore(ctx.prefix, allowedLetters)
    if (bestDict < 0)
        return { use: true, rejected: "" }

    if (scores.Count = 0 || bestScore < AI_SCORE_THRESHOLD)
        return { use: true, rejected: "" }

    topLetter := "", topScore := -999.0
    for letter, s in scores {
        if (s > topScore) {
            topScore := s
            topLetter := letter
        }
    }
    if (topLetter != "" && GetDictionaryLetterScore(ctx.prefix, topLetter) < 0)
        return { use: true, rejected: "" }

    if (ctx.compound)
        return { use: true, rejected: "" }

    if (StrLen(ctx.prefix) >= 3 && bestScore < AI_SCORE_THRESHOLD * 1.5)
        return { use: true, rejected: "" }

    return { use: false, rejected: "" }
}

ApplyAISuggestion(scores, &source, ctx, allowedLetters, rejectedChar := "") {
    global AI_MCP_ENABLED
    learned := ResolveLearnedHintForAI(ctx)
    prompt := BuildAIPrompt(ctx, allowedLetters, rejectedChar, learned.hint, learned.source)
    aiText := CallAI(prompt, AI_MCP_ENABLED)
    aiLetter := ExtractLetterFromAI(aiText, ctx.prefix, allowedLetters, rejectedChar)

    if (aiLetter = "" && rejectedChar != "")
        aiLetter := PickBestDictLetter(ctx.prefix, allowedLetters, rejectedChar)

    if (aiLetter = "")
        return false

    for , letter in allowedLetters {
        if (StrLower(letter) = StrLower(aiLetter)) {
            boost := rejectedChar != "" ? 3.0 : 2.0
            scores[letter] := scores.Get(letter, 0) + boost
            source := "ai"
            return true
        }
    }
    return false
}

PickBestValidCandidate(ranked, prefix) {
    if (ranked.Length = 0)
        return ""
    for , item in ranked {
        if (GetDictionaryLetterScore(prefix, item.ch) >= 0)
            return item.ch
    }
    return ranked[1].ch
}

PredictNextLetters(ctx, allowedLetters, skipAI := false, host := "") {
    global wordTrie, bigrams, AI_ENABLED
    prefix := ctx.prefix
    prev := ctx.prevWord
    scores := Map()
    source := "fallback"

    for letter, s in GetLearnedLetterScores(prefix, allowedLetters, ctx.compound)
        scores[letter] := scores.Get(letter, 0) + s
    if scores.Count > 0
        source := "learned"

    trieScores := Map()
    if (prefix != "") {
        node := wordTrie.GetNode(prefix)
        if node {
            total := 0
            for , child in node["children"]
                total += child["freq"]
            for , letter in allowedLetters {
                ch := StrLower(letter)
                if node["children"].Has(ch) {
                    freq := node["children"][ch]["freq"]
                    if (total > 0)
                        trieScores[letter] := freq / total
                }
            }
        }
    }
    for letter, s in trieScores
        scores[letter] := scores.Get(letter, 0) + (s * 1.0)
    if (trieScores.Count > 0 && source = "fallback")
        source := "trie"

    bigramScores := Map()
    if (prev != "" && bigrams.Has(prev) && prefix != "") {
        for , letter in allowedLetters {
            bi := bigrams[prev].Get(prefix . StrLower(letter), 0)
            if (bi > 0)
                bigramScores[letter] := bi
        }
    } else if (prev != "") {
        for letter, s in GetLettersAfterPreviousWord(prev, allowedLetters)
            bigramScores[letter] := s
    }
    for letter, s in bigramScores
        scores[letter] := scores.Get(letter, 0) + (s / 500000.0)
    if (bigramScores.Count > 0)
        source := "bigram"

    for , letter in allowedLetters {
        dbl := GetDoubleLetterBoost(prefix, letter)
        if (dbl > 0)
            scores[letter] := scores.Get(letter, 0) + dbl
    }

    bestScore := 0.0
    for , s in scores
        bestScore := Max(bestScore, s)

    aiPlan := ShouldInvokeAI(ctx, allowedLetters, scores, bestScore, skipAI, host)
    if (aiPlan.use) {
        if ApplyAISuggestion(scores, &source, ctx, allowedLetters, aiPlan.rejected)
            ClearRejectedPrediction()
    }

    if (scores.Count = 0) {
        for , letter in allowedLetters
            scores[letter] := 0.01
        source := "fallback"
    }

    return { scores: scores, source: source }
}

RankCandidates(ctx, outs, skipAI := false, host := "") {
    prefix := ctx.prefix
    prev := ctx.prevWord
    pred := PredictNextLetters(ctx, outs, skipAI, host)
    dictMul := ctx.compound ? 0.4 : 3.0
    ranked := []
    for , letter in outs {
        score := pred.scores.Get(letter, 0)
        if !ctx.compound
            score += ScoreCandidate(prefix, letter, prev)
        score += GetDoubleLetterBoost(prefix, letter)
        score += GetDictionaryLetterScore(prefix, letter) * dictMul
        ranked.Push({ ch: letter, score: score, dict: GetDictionaryLetterScore(prefix, letter) })
    }
    n := ranked.Length
    Loop n - 1 {
        i := A_Index
        Loop n - i {
            j := A_Index
            if ranked[j].score < ranked[j + 1].score {
                tmp := ranked[j]
                ranked[j] := ranked[j + 1]
                ranked[j + 1] := tmp
            }
        }
    }
    return { ranked: ranked, source: pred.source }
}

SourceLabel(src) {
    switch src {
        case "learned": return "learned"
        case "trie": return "trie"
        case "bigram": return "bigram"
        case "ai": return "AI"
        case "dict": return "dict"
        default: return "fallback"
    }
}

GetTriePrediction(prefix) {
    global wordTrie
    node := wordTrie.GetNode(prefix)
    if !node || node["children"].Count = 0
        return {letter: "", confidence: 0}
    bestCh := "", bestFreq := 0, total := 0
    for ch, child in node["children"] {
        total += child["freq"]
        if child["freq"] > bestFreq {
            bestFreq := child["freq"]
            bestCh := ch
        }
    }
    return {letter: bestCh, confidence: total > 0 ? Round(bestFreq / total * 100) : 0}
}

GetBigramPrediction(prefix) {
    global bigrams
    prev := GetPreviousWord()
    if (prev = "" || !bigrams.Has(prev))
        return {letter: "", confidence: 0}
    node := wordTrie.GetNode(prefix)
    if !node
        return {letter: "", confidence: 0}
    bestCh := "", bestScore := 0, total := 0
    for ch, _ in node["children"] {
        score := bigrams[prev].Get(prefix . ch, 0)
        total += score
        if score > bestScore {
            bestScore := score
            bestCh := ch
        }
    }
    return {letter: bestCh, confidence: total > 0 ? Round(bestScore / total * 100) : 0}
}

GetUnigramPrediction(prefix) {
    return GetTriePrediction(prefix)
}


; =============================================================================
;  ENTRY POINT
; =============================================================================
Main()

Main() {
    global wordTrie, totalUniFreq, DICT_PATH, BIGRAM_PATH, AI_ENABLED

    CheckLicense()

    DICT_PATH   := ResolveBundledDataPath("english_words.txt")
    BIGRAM_PATH := ResolveBundledDataPath("english_bigrams.txt")

    if !FileExist(INI_PATH) {
        FileAppend("; Broken Key Remapper Pro configuration`n[Settings]`nHudEnabled=1`nAIEnabled=1`nAILearnedContext=1`nAIMcpEnabled=0`nAIMcpUrl=http://127.0.0.1:8766`n`n[Remaps]`n", INI_PATH, "UTF-8")
    }
    if !FileExist(LEARN_PATH)
        FileAppend("; word`tcount`n", LEARN_PATH, "UTF-8")

    wordTrie := Trie()

    LoadDictionaryIntoTrie()
    LoadBigramsFromTxt()
    LoadLearnedWords()
    LoadRemapsFromIni()
    LoadSettings()
    LoadStats()
    BuildGroupsFromRemaps()
    totalUniFreq := wordTrie.totalFreq

    if AI_ENABLED
        InitAI()
    LogMsg("Startup - dict: " DICT_PATH " - AI: " LlamaEngine.StatusText())

    BuildMainGui()
    BuildHud()
    BuildTrayMenu()
    UpdateAIStatus()

    Hotkey("F12", ToggleMode)
    Hotkey("^F12", (*) => AddOrEditMapping())

    SetTimer(FlushLearnedWords, 30000)

    UpdateListView()
    UpdateModeDisplay()
    ApplyLanguage()
    GuiObj.Show("w600 h560 Center")
}


; =============================================================================
;  REMAINING ORIGINAL FUNCTIONS
; =============================================================================

class Trie {
    __New() {
        this.root := Map("freq", 0, "end", false, "children", Map(), "word", "")
        this.totalFreq := 0
    }

    Insert(word, freq := 1) {
        global unigrams
        word := StrLower(word)
        if word = ""
            return
        node := this.root
        for , ch in StrSplit(word) {
            if !node["children"].Has(ch)
                node["children"][ch] := Map("freq", 0, "end", false, "children", Map(), "word", "")
            node := node["children"][ch]
        }
        node["end"]  := true
        node["word"] := word
        node["freq"] += freq
        this.totalFreq += freq
        unigrams[word] := node["freq"]
    }

    GetNode(prefix) {
        node := this.root
        for , ch in StrSplit(StrLower(prefix)) {
            if !node["children"].Has(ch)
                return false
            node := node["children"][ch]
        }
        return node
    }

    IsCompleteWord(word) {
        node := this.GetNode(word)
        return node && node["end"]
    }

    GetSubtreeFreq(prefix) {
        node := this.GetNode(prefix)
        return node ? this._SumNode(node) : 0
    }

    _SumNode(node) {
        sum := node["freq"]
        for , child in node["children"]
            sum += this._SumNode(child)
        return sum
    }

    GetSumBigramFreq(prev, prefix) {
        node := this.GetNode(prefix)
        return node ? this._SumBigram(prev, node, StrLower(prefix)) : 0
    }

    _SumBigram(prev, node, cur) {
        global bigrams
        sum := 0
        if node["end"]
            sum += bigrams.Get(prev, Map()).Get(cur, 0)
        for ch, child in node["children"]
            sum += this._SumBigram(prev, child, cur . ch)
        return sum
    }

    TopCompletions(prefix, limit := 5) {
        node := this.GetNode(prefix)
        if !node
            return []
        results := []
        this._Collect(node, &results)
        n := results.Length
        Loop n - 1 {
            i := A_Index
            Loop n - i {
                j := A_Index
                if results[j].freq < results[j + 1].freq {
                    tmp := results[j]
                    results[j] := results[j + 1]
                    results[j + 1] := tmp
                }
            }
        }
        out := []
        Loop Min(limit, results.Length)
            out.Push(results[A_Index])
        return out
    }

    _Collect(node, &results) {
        if node["end"] && node["word"] != ""
            results.Push({ word: node["word"], freq: node["freq"] })
        for , child in node["children"]
            this._Collect(child, &results)
    }
}


; =============================================================================
;  DICTIONARY / BIGRAM / LEARNED (kept original)
; =============================================================================
LoadDictionaryIntoTrie() {
    global wordTrie
    if !FileExist(DICT_PATH) {
        LogMsg("Dictionary missing: " DICT_PATH)
        return
    }
    try text := FileRead(DICT_PATH, "UTF-8")
    catch as e {
        LogMsg("Dict read failed: " e.Message)
        return
    }

    loaded := 0
    for , line in StrSplit(text, "`n", "`r") {
        line := Trim(line)
        if (line = "" || RegExMatch(line, "^[;#]"))
            continue
        parts := InStr(line, ",") ? StrSplit(line, ",") : StrSplit(line, A_Space)
        word  := StrLower(Trim(parts[1]))
        freq  := (parts.Length >= 2 && IsInteger(parts[2])) ? Integer(parts[2]) : 1
        if word != "" {
            wordTrie.Insert(word, freq)
            if Mod(++loaded, 5000) = 0
                ToolTip "Loading dictionary: " loaded " words"
        }
    }
    SetTimer(() => ToolTip(), -1500)
    LogMsg("Dictionary loaded: " loaded " words")
}

LoadBigramsFromTxt() {
    global bigrams
    if !FileExist(BIGRAM_PATH) {
        LogMsg("Bigram file missing - bigram prediction disabled")
        return
    }
    try text := FileRead(BIGRAM_PATH, "UTF-8")
    catch as e {
        LogMsg("Bigram read failed: " e.Message)
        return
    }

    loaded := 0
    for , line in StrSplit(text, "`n", "`r") {
        line := Trim(line)
        if line = ""
            continue
        parts := StrSplit(line, A_Tab)
        if parts.Length < 2
            continue
        words := StrSplit(parts[1], " ")
        if words.Length != 2
            continue
        prev  := StrLower(words[1])
        nextw := StrLower(words[2])
        freq  := Integer(parts[2])
        if !bigrams.Has(prev)
            bigrams[prev] := Map()
        bigrams[prev][nextw] := freq
        if Mod(++loaded, 50000) = 0
            ToolTip "Loading bigrams: " loaded " pairs"
    }
    SetTimer(() => ToolTip(), -1500)
    LogMsg("Bigrams loaded: " loaded " pairs")
}

LoadLearnedWords() {
    global wordTrie, userLearned, LEARN_PATH
    userLearned := Map()
    if !FileExist(LEARN_PATH)
        return
    try text := FileRead(LEARN_PATH, "UTF-8")
    catch
        return
    n := 0
    for , line in StrSplit(text, "`n", "`r") {
        line := Trim(line)
        if (line = "" || RegExMatch(line, "^[;#]"))
            continue
        parts := StrSplit(line, A_Tab)
        if parts.Length < 2
            parts := StrSplit(line, ",")
        if parts.Length < 1
            continue
        word := StrLower(Trim(parts[1]))
        freq := (parts.Length >= 2 && IsInteger(parts[2])) ? Integer(parts[2]) : 1
        if (word != "" && RegExMatch(word, "^[a-z0-9_'@.-]+$")) {
            boost := Max(freq, 1) * 50
            wordTrie.Insert(word, boost)
            userLearned[word] := userLearned.Get(word, 0) + freq
            n++
        }
    }
    LogMsg("Learned words loaded: " n " from " LEARN_PATH)
}

SaveLearnedWord(word, freq := 1) {
    word := StrLower(Trim(word))
    if (word = "" || StrLen(word) < 2 || !RegExMatch(word, "^[a-z0-9_'@.-]+$"))
        return
    try FileAppend(word . A_Tab . freq . "`n", LEARN_PATH, "UTF-8")
}


; =============================================================================
;  SETTINGS / STATS
; =============================================================================
LoadSettings() {
    global hudEnabled, AI_ENABLED, AI_CTX, AI_THREADS, uiLang, AI_PORT, AI_MODEL_PATH
    global AI_LEARNED_CONTEXT, AI_MCP_ENABLED, AI_MCP_URL
    try hudEnabled := IniRead(INI_PATH, "Settings", "HudEnabled", "1") = "1"
    try AI_ENABLED := IniRead(INI_PATH, "Settings", "AIEnabled", "1") = "1"
    try AI_LEARNED_CONTEXT := IniRead(INI_PATH, "Settings", "AILearnedContext", "1") = "1"
    try AI_MCP_ENABLED := IniRead(INI_PATH, "Settings", "AIMcpEnabled", "0") = "1"
    try AI_MCP_URL := IniRead(INI_PATH, "Settings", "AIMcpUrl", "http://127.0.0.1:8766")
    try AI_CTX := Integer(IniRead(INI_PATH, "Settings", "AIContext", "512"))
    try AI_THREADS := Integer(IniRead(INI_PATH, "Settings", "AIThreads", "0"))
    try AI_PORT := Integer(IniRead(INI_PATH, "Settings", "AIPort", "8765"))
    try AI_MODEL_PATH := IniRead(INI_PATH, "Settings", "AIModelPath", "")
    try uiLang := IniRead(INI_PATH, "Settings", "UILanguage", "en")
    McpClient.SetBaseUrl(AI_MCP_URL)
}

SaveSettings() {
    global hudEnabled, AI_ENABLED, uiLang, AI_MODEL_PATH, AI_LEARNED_CONTEXT, AI_MCP_ENABLED, AI_MCP_URL
    IniWrite(hudEnabled ? "1" : "0", INI_PATH, "Settings", "HudEnabled")
    IniWrite(AI_ENABLED ? "1" : "0", INI_PATH, "Settings", "AIEnabled")
    IniWrite(AI_LEARNED_CONTEXT ? "1" : "0", INI_PATH, "Settings", "AILearnedContext")
    IniWrite(AI_MCP_ENABLED ? "1" : "0", INI_PATH, "Settings", "AIMcpEnabled")
    IniWrite(AI_MCP_URL, INI_PATH, "Settings", "AIMcpUrl")
    IniWrite(AI_MODEL_PATH, INI_PATH, "Settings", "AIModelPath")
    IniWrite(uiLang, INI_PATH, "Settings", "UILanguage")
    McpClient.SetBaseUrl(AI_MCP_URL)
}

LoadStats() {
    global stats
    try {
        for , k in ["predictions", "ai_calls"]
            stats[k] := Integer(IniRead(STATS_PATH, "Stats", k, 0))
    }
}

SaveStats() {
    global stats
    for k, v in stats {
        if k = "session_start"
            continue
        try IniWrite(v, STATS_PATH, "Stats", k)
    }
}


; =============================================================================
;  GRADIENT + GUI (kept exactly as original)
; =============================================================================
PaintGradient(wParam, lParam, msg, hwnd) {
    global GuiObj, GRAD_TOP, GRAD_MID, GRAD_BOTTOM
    if !IsObject(GuiObj) || hwnd != GuiObj.Hwnd
        return

    hdc := wParam
    rect := Buffer(16, 0)
    DllCall("GetClientRect", "Ptr", hwnd, "Ptr", rect)
    w := NumGet(rect, 8,  "Int")
    h := NumGet(rect, 12, "Int")
    if (w <= 0 || h <= 0)
        return

    midY := h // 2
    DrawGradientRect(hdc, 0, 0, w, midY, GRAD_TOP, GRAD_MID)
    DrawGradientRect(hdc, 0, midY, w, h - midY, GRAD_MID, GRAD_BOTTOM)
    return 1
}

DrawGradientRect(hdc, x, y, w, h, color1, color2) {
    v := Buffer(32, 0)

    r1 := (color1 >> 16) & 0xFF
    g1 := (color1 >> 8)  & 0xFF
    b1 :=  color1        & 0xFF
    r2 := (color2 >> 16) & 0xFF
    g2 := (color2 >> 8)  & 0xFF
    b2 :=  color2        & 0xFF

    NumPut("Int",    x,         v,  0)
    NumPut("Int",    y,         v,  4)
    NumPut("UShort", r1 << 8,   v,  8)
    NumPut("UShort", g1 << 8,   v, 10)
    NumPut("UShort", b1 << 8,   v, 12)
    NumPut("UShort", 0,         v, 14)

    NumPut("Int",    x + w,     v, 16)
    NumPut("Int",    y + h,     v, 20)
    NumPut("UShort", r2 << 8,   v, 24)
    NumPut("UShort", g2 << 8,   v, 26)
    NumPut("UShort", b2 << 8,   v, 28)
    NumPut("UShort", 0,         v, 30)

    gRect := Buffer(8, 0)
    NumPut("UInt", 0, gRect, 0)
    NumPut("UInt", 1, gRect, 4)

    DllCall("msimg32\GradientFill", "Ptr", hdc, "Ptr", v.Ptr, "UInt", 2, "Ptr", gRect.Ptr, "UInt", 1, "UInt", 1)
}

BuildMainGui() {
    global GuiObj, hudEnabled, uiLang
    GuiObj := Gui("+Resize", T("app_title"))
    GuiObj.MarginX := 20
    GuiObj.MarginY := 16
    GuiObj.SetFont("s10 cWhite", "Segoe UI")
    GuiObj.BackColor := 0x0F172A

    OnMessage(0x14, PaintGradient)
    GuiObj.OnEvent("Size", (*) => DllCall("InvalidateRect", "Ptr", GuiObj.Hwnd, "Ptr", 0, "Int", 1))

    GuiObj.SetFont("s18 Bold cWhite", "Segoe UI Semibold")
    GuiObj.AddText("x24 y18 w420 h32 BackgroundTrans vTxtTitle", T("app_title"))
    GuiObj.SetFont("s9 cBFE8FF", "Segoe UI")
    GuiObj.AddText("x24 y50 w420 h18 BackgroundTrans vTxtSubtitle", T("subtitle"))

    GuiObj.SetFont("s9 cE0F2FE", "Segoe UI")
    GuiObj.AddText("x400 y22 w80 h20 Right BackgroundTrans vTxtLangLbl", T("lang_lbl"))
    langLabels := []
    chooseIdx := 1
    for i, opt in LangOptions() {
        langLabels.Push(opt.label)
        if (opt.code = uiLang)
            chooseIdx := i
    }
    langDd := GuiObj.AddDropDownList("x484 y18 w120 vLangSelect Choose" chooseIdx, langLabels)
    langDd.OnEvent("Change", OnLanguageChanged)

    GuiObj.AddText("x24 y78 w552 h22 BackgroundTrans vTxtMappingHdr cF0F9FF", "  " T("mapping_hdr"))

    lv := GuiObj.AddListView("x24 y102 w552 h210 vLVRemapList -Multi Background0xFFFFFF c1E293B"
        , [T("col_pressable"), T("col_outputs"), T("col_current"), T("col_vk"), T("col_sc"), T("col_uses")])
    lv.Opt("+Grid")

    GuiObj.SetFont("s9 c0F172A", "Segoe UI")
    btnY := 324
    btn := GuiObj.AddButton("x24 y" btnY " w118 h34 vBtnAdd", T("btn_add"))
    btn.OnEvent("Click", AddOrEditMapping)
    btn := GuiObj.AddButton("x148 y" btnY " w108 h34 vBtnRemove", T("btn_remove"))
    btn.OnEvent("Click", RemoveSelected)
    btn := GuiObj.AddButton("x262 y" btnY " w108 h34 vBtnClear", T("btn_clear"))
    btn.OnEvent("Click", ClearAll)
    btn := GuiObj.AddButton("x376 y" btnY " w92 h34 vBtnExport", T("btn_export"))
    btn.OnEvent("Click", ExportConfig)
    btn := GuiObj.AddButton("x474 y" btnY " w102 h34 vBtnImport", T("btn_import"))
    btn.OnEvent("Click", ImportConfig)

    GuiObj.SetFont("s10 cF0F9FF", "Segoe UI")
    GuiObj.AddText("x24 y372 w120 h26 BackgroundTrans vTxtModeLbl", T("mode_lbl"))
    GuiObj.SetFont("s11 Bold cWhite", "Segoe UI Semibold")
    GuiObj.AddText("x148 y370 w280 h32 vModeText Background0xDC2626 Center 0x200", T("mode_normal"))

    GuiObj.SetFont("s9 cE0F2FE", "Segoe UI")
    chk := GuiObj.AddCheckbox("x24 y408 w440 h22 cWhite vChkHud Checked" (hudEnabled ? "1" : "0"), T("chk_hud"))
    chk.OnEvent("Click", ToggleHudEnabled)

    GuiObj.SetFont("s10 c0F172A", "Segoe UI Semibold")
    btn := GuiObj.AddButton("x24 y438 w175 h40 vToggleBtn Default", T("btn_toggle"))
    btn.OnEvent("Click", ToggleMode)
    btn := GuiObj.AddButton("x206 y438 w130 h40 vBtnWizard", T("btn_wizard"))
    btn.OnEvent("Click", RunWizard)
    btn := GuiObj.AddButton("x342 y438 w100 h40 vBtnStats", T("btn_stats"))
    btn.OnEvent("Click", ShowStats)
    btn := GuiObj.AddButton("x448 y438 w128 h40 vBtnSettings", "Settings")
    btn.OnEvent("Click", ShowSettings)

    GuiObj.SetFont("s8 c7DD3FC", "Segoe UI")
    GuiObj.AddText("x24 y486 w552 h16 BackgroundTrans vAIText c90EE90", "  AI: …")
    GuiObj.AddText("x24 y504 w552 h36 BackgroundTrans vTxtHotkeys c94A3B8", T("hotkeys"))

    GuiObj.OnEvent("Close",  (*) => OnExitApp())
    GuiObj.OnEvent("Escape", (*) => GuiObj.Minimize())

    for i, opt in LangOptions() {
        if (opt.code = uiLang) {
            GuiObj["LangSelect"].Choose(i)
            break
        }
    }
}


BuildHud() {
    global hudGui
    hudGui := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20", "BKRHud")
    hudGui.BackColor := 0x0B1F3A
    hudGui.SetFont("s11 cWhite", "Consolas")
    hudGui.AddText("x12 y6 w360 h22 vHudLine1 BackgroundTrans")
    hudGui.AddText("x12 y28 w360 h18 vHudLine2 BackgroundTrans cAAC8FF")
    WinSetTransparent(230, hudGui)
}

ToggleHudEnabled(*) {
    global hudEnabled, GuiObj
    hudEnabled := GuiObj["ChkHud"].Value
    SaveSettings()
    if hudEnabled
        ShowHud(" " T("hud_on"), "")
    else
        HideHud()
}

ShowHud(line1, line2 := "") {
    global hudGui, hudVisible, hudEnabled
    if !hudEnabled
        return
    hudGui["HudLine1"].Text := line1
    hudGui["HudLine2"].Text := line2
    if !hudVisible {
        hudGui.Show("NoActivate x" (A_ScreenWidth - 400) " y" (A_ScreenHeight - 120) " w380 h54")
        hudVisible := true
    }
    SetTimer(HideHud, -2500)
}

HideHud(*) {
    global hudGui, hudVisible
    if hudVisible {
        try hudGui.Hide()
        hudVisible := false
    }
}

BuildTrayMenu() {
    A_IconTip := T("app_title")
    tray := A_TrayMenu
    tray.Delete()
    tray.Add(T("tray_show"), (*) => GuiObj.Show())
    tray.Add(T("tray_toggle"), ToggleMode)
    tray.Add()
    tray.Add(T("tray_stats"), (*) => ShowStats())
    tray.Add(T("tray_wizard"), (*) => RunWizard())
    tray.Add("License...", ShowLicenseInfo)
    tray.Add()
    tray.Add(T("tray_exit"), (*) => OnExitApp())
    tray.Default := T("tray_show")
}


; =============================================================================
;  BUFFER & LEARNING (kept original)
; =============================================================================
CommitTraversal() {
    global traverseStack
    traverseStack := Map()
}

CommitChar(ch) {
    global charBuffer, maxBuffer
    CommitTraversal()
    charBuffer .= StrLower(ch)
    if StrLen(charBuffer) > maxBuffer
        charBuffer := SubStr(charBuffer, -maxBuffer)
}

GetPreviousWord() {
    return GetPreviousSegment()
}

LearnIfWordCompleted() {
    global wordTrie, learnedPending, userLearned
    word := GetSegmentPrefix()
    if (word = "" || StrLen(word) < 2 || StrLen(word) > 40)
        return
    if IsCompoundContext() {
        SaveLearnedToken(word)
        return
    }
    if !RegExMatch(word, "^[a-z']+$") || !wordTrie.IsCompleteWord(word)
        return
    SaveLearnedToken(word)
}

SaveLearnedToken(word) {
    global wordTrie, learnedPending, userLearned
    word := StrLower(word)
    wordTrie.Insert(word, 50)
    learnedPending[word] := learnedPending.Get(word, 0) + 1
    userLearned[word] := userLearned.Get(word, 0) + 1
}

ShouldAutoCap() {
    global charBuffer
    txt := RTrim(charBuffer)
    if txt = ""
        return true
    last := SubStr(txt, -1)
    return (last = "." || last = "!" || last = "?")
}

FlushLearnedWords(*) {
    global learnedPending, LEARN_PATH
    if learnedPending.Count = 0
        return
    out := ""
    for word, freq in learnedPending
        out .= word . A_Tab . freq . "`n"
    try FileAppend(out, LEARN_PATH, "UTF-8")
    learnedPending := Map()
    TruncateLearnedIfHuge()
}

TruncateLearnedIfHuge() {
    global LEARN_PATH
    if !FileExist(LEARN_PATH) || FileGetSize(LEARN_PATH) < 500000
        return
    try {
        text := FileRead(LEARN_PATH, "UTF-8")
        lines := StrSplit(text, "`n", "`r")
        if lines.Length <= 5000
            return
        keep := ""
        start := lines.Length - 5000
        Loop 5000 {
            line := lines[start + A_Index]
            if line != ""
                keep .= line . "`n"
        }
        FileDelete(LEARN_PATH)
        FileAppend(keep, LEARN_PATH, "UTF-8")
    }
}


; =============================================================================
;  PASSIVE HOTKEYS (unchanged)
; =============================================================================
~a::SafeBufferChar("a")
~b::SafeBufferChar("b")
~c::SafeBufferChar("c")
~d::SafeBufferChar("d")
~e::SafeBufferChar("e")
~f::SafeBufferChar("f")
~g::SafeBufferChar("g")
~h::SafeBufferChar("h")
~i::SafeBufferChar("i")
~j::SafeBufferChar("j")
~k::SafeBufferChar("k")
~l::SafeBufferChar("l")
~m::SafeBufferChar("m")
~n::SafeBufferChar("n")
~o::SafeBufferChar("o")
~p::SafeBufferChar("p")
~q::SafeBufferChar("q")
~r::SafeBufferChar("r")
~s::SafeBufferChar("s")
~t::SafeBufferChar("t")
~u::SafeBufferChar("u")
~v::SafeBufferChar("v")
~w::SafeBufferChar("w")
~x::SafeBufferChar("x")
~y::SafeBufferChar("y")
~z::SafeBufferChar("z")

~0::SafeBufferChar("0")
~1::SafeBufferChar("1")
~2::SafeBufferChar("2")
~3::SafeBufferChar("3")
~4::SafeBufferChar("4")
~5::SafeBufferChar("5")
~6::SafeBufferChar("6")
~7::SafeBufferChar("7")
~8::SafeBufferChar("8")
~9::SafeBufferChar("9")

~,::SafeWordBoundary(",")
~.::SafeWordBoundary(".")
~;::SafeWordBoundary(";")
~!::SafeWordBoundary("!")
~?::SafeWordBoundary("?")
~/::SafeBufferChar("/")
~-::SafeBufferChar("-")
~=::SafeBufferChar("=")
~[::SafeBufferChar("[")
~]::SafeBufferChar("]")
~\::SafeBufferChar("\")
~'::SafeBufferChar("'")

~@::SafeCompoundBoundary("@")
~+;::SafeCompoundBoundary(":")

~Space::SafeWordBoundary(" ")
~Enter::SafeWordBoundary(" ")

~Backspace:: {
    global charBuffer, sendingInternally, lastPrediction, lastRejectedPrediction
    if sendingInternally
        return
    CommitTraversal()
    if StrLen(charBuffer) > 0 {
        removed := SubStr(charBuffer, -1)
        charBuffer := SubStr(charBuffer, 1, -1)
        if (lastPrediction.char != "" && StrLower(removed) = StrLower(lastPrediction.char)) {
            lastRejectedPrediction := {
                char: lastPrediction.char,
                prefix: lastPrediction.prefix,
                host: lastPrediction.host,
                ts: A_TickCount
            }
            LogMsg("Rejected prediction: " lastPrediction.char " at prefix '" lastPrediction.prefix "'")
        }
    }
}

SafeBufferChar(ch) {
    global sendingInternally
    if sendingInternally
        return
    CommitChar(ch)
}

SafeWordBoundary(ch) {
    global charBuffer, sendingInternally
    if sendingInternally
        return
    CommitTraversal()
    LearnIfWordCompleted()
    charBuffer .= ch
}

SafeCompoundBoundary(ch) {
    global charBuffer, sendingInternally
    if sendingInternally
        return
    CommitTraversal()
    LearnIfWordCompleted()
    charBuffer .= ch
}


; =============================================================================
;  CORE LOGIC
; =============================================================================
ToggleMode(*) {
    global remapMode
    remapMode := !remapMode
    UpdateModeDisplay()
    ApplyRemapHotkeys()
    ShowHud(remapMode ? T("mode_mapped") : T("mode_normal"), "")
}

UpdateModeDisplay() {
    badge := GuiObj["ModeText"]
    if remapMode {
        badge.Text := T("mode_mapped")
        badge.Opt("+Background0x059669")
    } else {
        badge.Text := T("mode_normal")
        badge.Opt("+Background0xC81E1E")
    }
    badge.Redraw()
    try GuiObj["ToggleBtn"].Text := remapMode ? T("btn_toggle_off") : T("btn_toggle")
}

ApplyRemapHotkeys() {
    global groups, remapMode, boundHotkeys

    for name, cb in boundHotkeys {
        try Hotkey(name, "Off")
    }
    boundHotkeys.Clear()

    if !remapMode
        return

    for host in groups {
        hk      := MapToValidHotkeyName(host)
        normKey := hk
        shftKey := "+" . hk

        boundHotkeys[normKey] := SafeCall.Bind(SendPredictedOrLocked, host)
        boundHotkeys[shftKey] := SafeCall.Bind(CycleGroup, host)

        try Hotkey(normKey, boundHotkeys[normKey], "On")
        try Hotkey(shftKey, boundHotkeys[shftKey], "On")
    }
}

SafeCall(fn, arg, *) {
    try {
        if (arg = "")
            fn()
        else
            fn(arg)
    } catch as e {
        LogMsg("Hotkey error: " e.Message " | " e.What)
    }
}


; =============================================================================
;  PREDICTION ENGINE WITH AI
; =============================================================================
ScoreCandidate(prefix, letter, prevWord) {
    global wordTrie, unigrams, totalUniFreq
    candidate := prefix . StrLower(letter)

    bigramScore := 0.0
    if (prevWord != "") {
        prevU := unigrams.Get(prevWord, 0)
        if (prevU > 0) {
            sumBi := wordTrie.GetSumBigramFreq(prevWord, candidate)
            if (sumBi > 0)
                bigramScore := sumBi / prevU
        }
    }

    subFreq      := wordTrie.GetSubtreeFreq(candidate)
    unigramScore := totalUniFreq > 0 ? subFreq / totalUniFreq : 0.0

    return (bigramScore * 1.0) + (unigramScore * 0.4)
}

SendPredictedOrLocked(host, *) {
    global groups, stats, lastPrediction, sendingInternally, charBuffer, predictionLock

    if predictionLock
        return
    predictionLock := true

    try {
        outs := groups.Get(host, [])
        if outs.Length = 0 {
            sendingInternally := true
            SendCased(host)
            sendingInternally := false
            CommitChar(host)
            return
        }

        CommitTraversal()
        ctx := GetTypingContext()
        result := RankCandidates(ctx, outs, false, host)
        ranked := result.ranked
        srcTag := SourceLabel(result.source)

        if (ranked.Length = 0) {
            best := outs[1]
            srcTag := "fallback"
        } else {
            best := ranked[1].ch
            if (!ctx.compound && GetDictionaryLetterScore(ctx.prefix, best) < 0) {
                validBest := PickBestValidCandidate(ranked, ctx.prefix)
                if (validBest != "" && validBest != best) {
                    best := validBest
                    srcTag := result.source = "ai" ? "AI" : "dict"
                }
            }
        }

        out := best
        if (ctx.prefix = "" && ShouldAutoCap() && RegExMatch(out, "^[a-z]$"))
            out := StrUpper(out)

        sendingInternally := true
        SendCased(out)
        sendingInternally := false

        charBuffer .= StrLower(best)
        if StrLen(charBuffer) > maxBuffer
            charBuffer := SubStr(charBuffer, -maxBuffer)

        stats["predictions"] += 1
        lastPrediction := {
            host: host,
            char: best,
            alts: ranked,
            pos: 1,
            ts: A_TickCount,
            prefix: ctx.prefix,
            source: srcTag
        }

        cycleHint := ranked.Length > 1 ? "  |  Shift+" host " " T("hud_cycle") : ""
        ShowHud(" " host " -> " out cycleHint, T("via") ": " srcTag)
    } catch as e {
        LogMsg("Predict error: " e.Message)
        try {
            outs := groups.Get(host, [])
            if outs.Length > 0 {
                sendingInternally := true
                SendCased(outs[1])
                sendingInternally := false
                charBuffer .= StrLower(outs[1])
            }
        }
    } finally {
        predictionLock := false
    }
}

EnsureCycleAlts(host) {
    global lastPrediction, groups
    outs := groups.Get(host, [])
    if (outs.Length = 0)
        return
    ctx := GetTypingContext()
    result := RankCandidates(ctx, outs, true)
    ranked := result.ranked
    if (ranked.Length = 0) {
        for , letter in outs
            ranked.Push({ ch: letter, score: 0 })
    }
    lastPrediction := {
        host: host,
        char: ranked[1].ch,
        alts: ranked,
        pos: 1,
        ts: A_TickCount,
        prefix: ctx.prefix,
        source: "cycle"
    }
}

CanCyclePrediction(host) {
    global lastPrediction, charBuffer
    if (lastPrediction.host != host || lastPrediction.alts.Length <= 1)
        return false
    if (A_TickCount - lastPrediction.ts > 60000)
        return false
    if (SubStr(charBuffer, -1) != lastPrediction.char)
        return false
    return true
}

CycleToNext(host) {
    global lastPrediction, charBuffer, sendingInternally
    if (lastPrediction.alts.Length <= 1) {
        ShowHud(" " host " — 1 option", "")
        return
    }

    lastPrediction.pos := Mod(lastPrediction.pos, lastPrediction.alts.Length) + 1
    nextChar := lastPrediction.alts[lastPrediction.pos].ch
    replacing := (SubStr(charBuffer, -1) = lastPrediction.char)

    shiftHeld := GetKeyState("Shift", "P")
    sendingInternally := true
    if replacing {
        if shiftHeld
            Send("{Shift up}")
        Send("{Backspace}")
    }
    SendCased(nextChar)
    if shiftHeld && replacing
        Send("{Shift down}")
    sendingInternally := false

    if replacing && StrLen(charBuffer) > 0
        charBuffer := SubStr(charBuffer, 1, -1) . StrLower(nextChar)
    else
        charBuffer .= StrLower(nextChar)

    lastPrediction.char := nextChar
    lastPrediction.ts   := A_TickCount

    altList := ""
    Loop lastPrediction.alts.Length {
        a := lastPrediction.alts[A_Index].ch
        altList .= (A_Index = lastPrediction.pos) ? "[" a "]" : a
        if (A_Index < lastPrediction.alts.Length)
            altList .= " "
    }
    ShowHud(" " lastPrediction.pos "/" lastPrediction.alts.Length " -> " nextChar, T("via") ": cycle")
}

CycleGroup(host, *) {
    global lastPrediction, charBuffer, sendingInternally
    if !CanCyclePrediction(host) {
        EnsureCycleAlts(host)
        if (lastPrediction.alts.Length = 0)
            return
        out := lastPrediction.alts[1].ch
        ctx := GetTypingContext()
        if (ctx.prefix = "" && ShouldAutoCap() && RegExMatch(out, "^[a-z]$"))
            out := StrUpper(out)
        sendingInternally := true
        SendCased(out)
        sendingInternally := false
        charBuffer .= StrLower(lastPrediction.alts[1].ch)
        lastPrediction.char := lastPrediction.alts[1].ch
        lastPrediction.pos := 1
        ShowHud(" Shift+" host " -> " out, T("via") ": cycle")
        return
    }
    CycleToNext(host)
}

MapToValidHotkeyName(key) {
    switch key {
        case "Minus":      return "-"
        case "Equal":      return "="
        case "LBracket":   return "["
        case "RBracket":   return "]"
        case "Backslash":  return "\"
        case "Semicolon":  return ";"
        case "Apostrophe": return "'"
        case "Comma":      return ","
        case "Period":     return "."
        case "Slash":      return "/"
        case "Esc":        return "Escape"
        default:           return key
    }
}

SendCased(char) {
    if (StrLen(char) = 1 && RegExMatch(char, "[a-zA-Z]")) {
        if GetKeyState("CapsLock", "T")
            SendText(StrUpper(char))
        else
            SendText(StrLower(char))
    } else {
        SendText(char)
    }
}


; =============================================================================
;  CONFIG + USER OPS
; =============================================================================

AddOrEditMapping(*) {
    msg := MsgBox(
        "Use dropdowns to pick keys?`n(Recommended if the broken character is hard to type)",
        "Add / Edit Mapping", "YesNoCancel Icon?")
    if (msg = "Cancel")
        return

    if (msg = "Yes")
        host := SelectKeyFromDropdown("1. Select the WORKING key")
    else
        host := GetSinglePhysicalKey("1. Press the WORKING key`n(Modifiers ignored)")
    if !host
        return

    if (msg = "Yes") {
        val := SelectOutputFromDropdown("2. Select OUTPUT character(s)")
        if (val = "")
            return
    } else {
        ib := InputBox('Output for "' host '" (comma separated for multiple)',
                       "Output", "w400")
        if (ib.Result != "OK")
            return
        val := Trim(ib.Value)
        if (val = "")
            return
    }

    remaps[host] := val

    SaveRemapsToIni()
    BuildGroupsFromRemaps()
    UpdateListView()
    ApplyRemapHotkeys()
}

RemoveSelected(*) {
    lv  := GuiObj["LVRemapList"]
    row := lv.GetNext(0, "F")
    if !row
        return
    key := lv.GetText(row, 1)
    remaps.Delete(key)
    SaveRemapsToIni()
    BuildGroupsFromRemaps()
    UpdateListView()
    ApplyRemapHotkeys()
}

ClearAll(*) {
    if MsgBox("Clear all mappings?", "Confirm", "YesNo Icon!") != "Yes"
        return
    remaps.Clear()
    SaveRemapsToIni()
    BuildGroupsFromRemaps()
    UpdateListView()
    ApplyRemapHotkeys()
}

RunWizard(*) {
    remaps.Clear()
    ib := InputBox("How many keys are broken?", "Setup Wizard")
    if (ib.Result != "OK" || !IsInteger(ib.Value))
        return
    count := Integer(ib.Value)
    Loop count {
        host := SelectKeyFromDropdown("Mapping " A_Index "/" count " - pick WORKING key")
        if !host
            return
        out := SelectOutputFromDropdown('Outputs for "' host '"')
        if (out = "")
            return
        remaps[host] := out
    }
    SaveRemapsToIni()
    BuildGroupsFromRemaps()
    UpdateListView()
    ApplyRemapHotkeys()
    MsgBox "Wizard complete!`nPress F12 to enable mapping.", "Done", "Iconi T4"
}

ExportConfig(*) {
    file := FileSelect("S 16", , "Export configuration", "Config (*.ini)")
    if file = ""
        return
    try FileCopy(INI_PATH, file, 1)
    MsgBox "Exported to:`n" file, "Export", "Iconi T3"
}

ImportConfig(*) {
    file := FileSelect(3, , "Import configuration", "Config (*.ini)")
    if file = ""
        return
    try {
        FileCopy(file, INI_PATH, 1)
        remaps.Clear()
        LoadRemapsFromIni()
        BuildGroupsFromRemaps()
        UpdateListView()
        ApplyRemapHotkeys()
        MsgBox "Imported!", "Import", "Iconi T2"
    } catch as e {
        MsgBox "Import failed: " e.Message, "Error", "IconX"
    }
}

ShowStats(*) {
    global stats, AI_ENABLED
    elapsedMin := Round((A_TickCount - stats["session_start"]) / 60000, 1)
    aiLine := AI_ENABLED
        ? (LlamaEngine.Loaded ? LlamaEngine.StatusText() : LlamaEngine.LoadError)
        : "disabled"
    msg :=  T("stats_title") "`n`n"
        . T("stats_predictions") ": " stats["predictions"] "`n"
        . T("stats_ai") ":          " stats["ai_calls"] "`n"
        . "AI status:    " aiLine "`n"
        . T("stats_session") ":      " elapsedMin " min"
    SaveStats()
    MsgBox msg, T("btn_stats"), "Iconi"
}

ShowSettings(*) {
    global AI_ENABLED, AI_LEARNED_CONTEXT, AI_MODEL_PATH, AI_MCP_ENABLED, AI_MCP_URL

    BrowseModel(*) {
        f := FileSelect(3, A_ScriptDir, "Select GGUF model", "Model (*.gguf)")
        if f != ""
            sg["EdModel"].Text := f
    }
    SettingsRestartAI(*) {
        global AI_MODEL_PATH
        AI_MODEL_PATH := sg["EdModel"].Text
        SaveSettings()
        LlamaEngine.Shutdown()
        InitAI()
        UpdateAIStatus()
        MsgBox "AI restarted.", "Settings", "Iconi T2"
    }
    SetupMcpServer(*) {
        if McpClient.StartServer() {
            MsgBox "MCP server window opened.`n`nKeep it running while MCP mode is enabled.`n`nURL: " sg["EdMcpUrl"].Text,
                "MCP Server", "Iconi T3"
        }
    }
    TestMcpConnection(*) {
        McpClient.SetBaseUrl(sg["EdMcpUrl"].Text)
        if McpClient.Ping() {
            MsgBox "MCP bridge is online.`n`n" McpClient.StatusText(), "MCP", "Iconi"
        } else {
            MsgBox "MCP bridge is not reachable.`n`n" McpClient.lastError
                . "`n`nClick Setup MCP first, or check the URL.", "MCP", "Icon!"
        }
    }
    SaveSettingsDlg(*) {
        global AI_ENABLED, AI_LEARNED_CONTEXT, AI_MODEL_PATH, AI_MCP_ENABLED, AI_MCP_URL
        AI_ENABLED := sg["ChkAI"].Value
        AI_LEARNED_CONTEXT := sg["ChkLearned"].Value
        AI_MCP_ENABLED := sg["ChkMcp"].Value
        AI_MCP_URL := Trim(sg["EdMcpUrl"].Text)
        AI_MODEL_PATH := sg["EdModel"].Text
        if (AI_MCP_URL = "")
            AI_MCP_URL := "http://127.0.0.1:8766"
        SaveSettings()
        McpClient.SetBaseUrl(AI_MCP_URL)
        if AI_ENABLED && !LlamaEngine.Loaded
            InitAI()
        UpdateAIStatus()
        if AI_MCP_ENABLED && !McpClient.Ping() {
            MsgBox "MCP mode saved, but the bridge is offline.`n`n"
                . "Use Setup MCP or enable Inject learned_words as fallback.",
                "Settings", "Icon!"
        }
        sg.Destroy()
    }

    sg := Gui("+AlwaysOnTop +ToolWindow", "Settings")
    sg.SetFont("s10", "Segoe UI")
    sg.BackColor := 0xF8FAFC
    sg.Add("Text", "x16 y12 w420 c0F172A", "AI & personalization settings")
    sg.Add("Checkbox", "x16 y36 w400 vChkAI Checked" (AI_ENABLED ? 1 : 0), "Enable AI (llama-server)")
    sg.Add("Checkbox", "x16 y60 w400 vChkLearned Checked" (AI_LEARNED_CONTEXT ? 1 : 0),
        "Inject learned_words.txt into AI prompts (simple)")
    sg.Add("Checkbox", "x16 y84 w400 vChkMcp Checked" (AI_MCP_ENABLED ? 1 : 0),
        "Enable MCP for learned_words.txt (advanced)")
    sg.Add("Text", "x16 y112 w420 c475569",
        "Simple: reads learned_words.txt from disk each AI call.`n"
        . "MCP: uses read_file via a local MCP filesystem server (more powerful).`n"
        . "If MCP fails, simple injection is used when both are enabled.")
    sg.Add("Text", "x16 y168 w80", "MCP URL:")
    sg.Add("Edit", "x16 y188 w248 vEdMcpUrl", AI_MCP_URL != "" ? AI_MCP_URL : "http://127.0.0.1:8766")
    sg.Add("Button", "x272 y186 w72", "Test").OnEvent("Click", TestMcpConnection)
    sg.Add("Button", "x350 y186 w74", "Setup MCP").OnEvent("Click", SetupMcpServer)
    sg.Add("Text", "x16 y224 w80", "Model (.gguf):")
    sg.Add("Edit", "x16 y244 w248 vEdModel ReadOnly", AI_MODEL_PATH != "" ? AI_MODEL_PATH : LlamaEngine.ResolveModelPath())
    sg.Add("Button", "x272 y242 w72", "Browse...").OnEvent("Click", BrowseModel)
    sg.Add("Button", "x16 y280 w100", "Restart AI").OnEvent("Click", SettingsRestartAI)
    sg.Add("Button", "x122 y280 w100", "Setup AI").OnEvent("Click", (*) => Run(A_ComSpec ' /c start powershell -ExecutionPolicy Bypass -File "' A_ScriptDir '\Setup-AI.ps1"'))
    sg.Add("Button", "x272 y280 w74 Default", "Save").OnEvent("Click", SaveSettingsDlg)
    sg.Add("Button", "x350 y280 w74", "Cancel").OnEvent("Click", (*) => sg.Destroy())
    sg.OnEvent("Close", (*) => sg.Destroy())
    sg.Show("w440 h330")
}

GetSinglePhysicalKey(prompt) {
    MsgBox prompt, "Press a key", "OK Iconi"
    ih := InputHook("L1 T15 E V")
    ih.KeyOpt("{All}", "E")
    for , mod in ["LCtrl","RCtrl","LAlt","RAlt","LShift","RShift","LWin","RWin"]
        ih.KeyOpt("{" mod "}", "-E")
    ih.Start()
    ih.Wait()
    if (ih.EndReason != "EndKey")
        return ""
    key := ih.EndKey
    block := ["LCtrl","RCtrl","LAlt","RAlt","LShift","RShift","LWin","RWin",
              "AppsKey","PrintScreen","Pause","ScrollLock"]
    for , b in block
        if (key = b)
            return ""
    return key
}


; -----------------------------------------------------------------------------
;  Dropdown helpers
;
;  FIX (the "Gui has no window" error): cache the HWND in a local variable
;  BEFORE the message-pump loop, and reference that local variable -- never
;  the destroyed Gui's .Hwnd property -- inside WinExist(). Also use a
;  `destroyed` flag so the OK/Cancel handlers cannot be re-entered.
; -----------------------------------------------------------------------------
SelectKeyFromDropdown(title) {
    keys := OrganizedKeyList(false)

    result    := ""
    destroyed := false

    g := Gui("+AlwaysOnTop +ToolWindow", title)
    g.SetFont("s10", "Segoe UI")
    g.BackColor := 0xF0F9FF
    g.Add("Text", "x14 y14 w300 c0F172A", title)
    g.Add("DropDownList", "x14 y42 w280 vSelectedKey Choose1", keys)
    g.Add("Button", "x14 y88 w80 Default", "OK").OnEvent("Click", OkClicked)
    g.Add("Button", "x102 y88 w80",         "Cancel").OnEvent("Click", CancelClicked)
    g.OnEvent("Close",  CancelClicked)
    g.OnEvent("Escape", CancelClicked)

    g.Show("AutoSize Center")
    hwnd := g.Hwnd                                  ; <-- cache BEFORE possible destroy

    while !destroyed && WinExist("ahk_id " hwnd)
        Sleep 30

    return result

    OkClicked(*) {
        if destroyed
            return
        try {
            g.Submit(0)
            result := g["SelectedKey"].Text
        }
        destroyed := true
        try g.Destroy()
    }
    CancelClicked(*) {
        if destroyed
            return
        destroyed := true
        try g.Destroy()
    }
}

SelectOutputFromDropdown(title) {
    keys := OrganizedKeyList(true)
    outputs := []

    Loop {
        result    := ""
        destroyed := false

        g := Gui("+AlwaysOnTop +ToolWindow", title)
        g.SetFont("s10", "Segoe UI")
        g.BackColor := 0xF0F9FF
        g.Add("Text", "x14 y14 w300 c0F172A",
              title "`n(Pick one, then optionally add more.)")
        g.Add("DropDownList", "x14 y56 w280 vSelectedOutput Choose1", keys)
        g.Add("Button", "x14 y100 w80 Default", "OK").OnEvent("Click", OkClicked)
        g.Add("Button", "x102 y100 w80",         "Cancel").OnEvent("Click", CancelClicked)
        g.OnEvent("Close",  CancelClicked)
        g.OnEvent("Escape", CancelClicked)

        g.Show("AutoSize Center")
        hwnd := g.Hwnd                              ; <-- cache BEFORE possible destroy

        while !destroyed && WinExist("ahk_id " hwnd)
            Sleep 30

        if (result = "")
            break

        outputs.Push(result)
        if MsgBox("So far: " ArrayJoin(outputs, ",") "`n`nAdd another?",
                  "Add More?", "YesNo Icon?") != "Yes"
            break

        OkClicked(*) {
            if destroyed
                return
            try {
                g.Submit(0)
                result := g["SelectedOutput"].Text
            }
            destroyed := true
            try g.Destroy()
        }
        CancelClicked(*) {
            if destroyed
                return
            destroyed := true
            try g.Destroy()
        }
    }

    return ArrayJoin(outputs, ",")
}



OnExitApp(*) {
    SaveStats()
    SaveSettings()
    LlamaEngine.Shutdown()
    LogMsg("Shutdown")
    ExitApp()
}