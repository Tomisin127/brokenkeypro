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
#Include "I18n.ahk"

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
    global AI_MODEL, AI_ENABLED, AI_CTX, AI_THREADS, AI_PORT
    if !AI_ENABLED
        return false

    if (AI_MODEL = "")
        AI_MODEL := LlamaEngine.ResolveModelPath()

    LlamaEngine.port := AI_PORT
    ok := LlamaEngine.Init(AI_MODEL, "", AI_CTX, AI_THREADS)
    if !ok
        LogMsg("AI init failed: " LlamaEngine.LoadError)
    else
        LogMsg("AI ready: " LlamaEngine.StatusText() " (warmup done)")
    return ok
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

BuildAIPrompt(ctx, allowedLetters, rejectedChar := "") {
    recent := ctx.recentText
    if (StrLen(recent) > 300)
        recent := SubStr(recent, -300)
    opts := ArrayJoin(allowedLetters, ", ")
    prompt := "You complete English words one letter at a time.`n"
        . "Session: " recent "`n"
    if (ctx.prevWord != "")
        prompt .= "Previous word: " ctx.prevWord "`n"
    if (ctx.prefix != "")
        prompt .= "Partial word: " ctx.prefix "`n"
    else if (ctx.prevWord != "")
        prompt .= "New word after: " ctx.prevWord "`n"
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

CallAI(prompt) {
    global stats, AI_ENABLED, AI_MAX_TOKENS
    if (!AI_ENABLED || !LlamaEngine.Loaded)
        return ""

    result := LlamaEngine.Complete(prompt, AI_MAX_TOKENS)
    snippet := StrReplace(SubStr(result, 1, 40), "`n", " ")
    if (result != "") {
        stats["ai_calls"] += 1
        LogMsg("AI ok: [" snippet "]")
    } else
        LogMsg("AI empty/timeout for: " SubStr(prompt, 1, 80))
    return result
}

GetTypingContext() {
    global charBuffer
    return {
        prefix: GetCurrentPrefix(),
        prevWord: GetPreviousWord(),
        recentText: RTrim(charBuffer),
        recentWords: GetRecentWords(8)
    }
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

GetLearnedLetterScores(prefix, allowedLetters) {
    global userLearned, wordTrie
    scores := Map()
    for word, freq in userLearned {
        if !wordTrie.IsCompleteWord(word)
            continue
        if (prefix != "" && SubStr(word, 1, StrLen(prefix)) != prefix)
            continue
        ch := SubStr(word, StrLen(prefix) + 1, 1)
        if (ch = "" || !RegExMatch(ch, "[a-z]"))
            continue
        for , letter in allowedLetters {
            if (StrLower(ch) = StrLower(letter))
                scores[letter] := scores.Get(letter, 0) + (freq * 3.0)
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

    if (StrLen(ctx.prefix) >= 3 && bestScore < AI_SCORE_THRESHOLD * 1.5)
        return { use: true, rejected: "" }

    return { use: false, rejected: "" }
}

ApplyAISuggestion(scores, &source, ctx, allowedLetters, rejectedChar := "") {
    aiText := CallAI(BuildAIPrompt(ctx, allowedLetters, rejectedChar))
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

    for letter, s in GetLearnedLetterScores(prefix, allowedLetters)
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
    ranked := []
    for , letter in outs {
        score := pred.scores.Get(letter, 0)
        score += ScoreCandidate(prefix, letter, prev)
        score += GetDoubleLetterBoost(prefix, letter)
        score += GetDictionaryLetterScore(prefix, letter) * 3.0
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

    DICT_PATH   := ResolveBundledDataPath("english_words.txt")
    BIGRAM_PATH := ResolveBundledDataPath("english_bigrams.txt")

    if !FileExist(INI_PATH) {
        FileAppend("; Broken Key Remapper Pro configuration`n[Settings]`nHudEnabled=1`nAIEnabled=1`n`n[Remaps]`n", INI_PATH, "UTF-8")
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
    GuiObj.Show("w580 h520 Center")
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
        if (word != "" && RegExMatch(word, "^[a-z']+$")) {
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
    if (word = "" || StrLen(word) < 2 || !RegExMatch(word, "^[a-z']+$"))
        return
    try FileAppend(word . A_Tab . freq . "`n", LEARN_PATH, "UTF-8")
}


; =============================================================================
;  SETTINGS / STATS
; =============================================================================
LoadSettings() {
    global hudEnabled, AI_ENABLED, AI_CTX, AI_THREADS, uiLang, AI_PORT
    try hudEnabled := IniRead(INI_PATH, "Settings", "HudEnabled", "1") = "1"
    try AI_ENABLED := IniRead(INI_PATH, "Settings", "AIEnabled", "1") = "1"
    try AI_CTX := Integer(IniRead(INI_PATH, "Settings", "AIContext", "512"))
    try AI_THREADS := Integer(IniRead(INI_PATH, "Settings", "AIThreads", "0"))
    try AI_PORT := Integer(IniRead(INI_PATH, "Settings", "AIPort", "8765"))
    try uiLang := IniRead(INI_PATH, "Settings", "UILanguage", "en")
}

SaveSettings() {
    global hudEnabled, AI_ENABLED, uiLang
    IniWrite(hudEnabled ? "1" : "0", INI_PATH, "Settings", "HudEnabled")
    IniWrite(AI_ENABLED ? "1" : "0", INI_PATH, "Settings", "AIEnabled")
    IniWrite(uiLang, INI_PATH, "Settings", "UILanguage")
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
    GuiObj.MarginY := 18
    GuiObj.SetFont("s11 cWhite", "Segoe UI")
    GuiObj.BackColor := 0x1E3A8A

    OnMessage(0x14, PaintGradient)
    GuiObj.OnEvent("Size", (*) => DllCall("InvalidateRect", "Ptr", GuiObj.Hwnd, "Ptr", 0, "Int", 1))

    GuiObj.SetFont("s16 Bold cWhite", "Segoe UI")
    GuiObj.AddText("x20 y16 w400 h28 BackgroundTrans vTxtTitle", "  " T("app_title"))
    GuiObj.SetFont("s9 cD0E4FF", "Segoe UI")
    GuiObj.AddText("x20 y46 w400 h18 BackgroundTrans vTxtSubtitle", "  " T("subtitle"))

    GuiObj.SetFont("s9 cWhite", "Segoe UI")
    GuiObj.AddText("x340 y18 w80 h20 Right BackgroundTrans vTxtLangLbl", T("lang_lbl"))
    langLabels := []
    chooseIdx := 1
    for i, opt in LangOptions() {
        langLabels.Push(opt.label)
        if (opt.code = uiLang)
            chooseIdx := i
    }
    langDd := GuiObj.AddDropDownList("x420 y14 w140 vLangSelect Choose" chooseIdx, langLabels)
    langDd.OnEvent("Change", OnLanguageChanged)

    GuiObj.SetFont("s10 Norm cWhite", "Segoe UI")
    GuiObj.AddText("x20 y72 w540 h20 BackgroundTrans vTxtMappingHdr", T("mapping_hdr"))

    lv := GuiObj.AddListView("x20 y94 w540 h200 vLVRemapList -Multi Background0xFFFFFF c333333"
        , [T("col_pressable"), T("col_outputs"), T("col_current"), T("col_vk"), T("col_sc"), T("col_uses")])
    lv.Opt("+Grid")

    GuiObj.SetFont("s9 cBlack", "Segoe UI")
    btnY := 306
    btn := GuiObj.AddButton("x20 y" btnY " w120 h36 vBtnAdd", T("btn_add"))
    btn.OnEvent("Click", AddOrEditMapping)
    btn := GuiObj.AddButton("x148 y" btnY " w110 h36 vBtnRemove", T("btn_remove"))
    btn.OnEvent("Click", RemoveSelected)
    btn := GuiObj.AddButton("x266 y" btnY " w110 h36 vBtnClear", T("btn_clear"))
    btn.OnEvent("Click", ClearAll)
    btn := GuiObj.AddButton("x384 y" btnY " w85 h36 vBtnExport", T("btn_export"))
    btn.OnEvent("Click", ExportConfig)
    btn := GuiObj.AddButton("x477 y" btnY " w83 h36 vBtnImport", T("btn_import"))
    btn.OnEvent("Click", ImportConfig)

    GuiObj.SetFont("s10 cWhite", "Segoe UI")
    GuiObj.AddText("x20 y358 w120 h28 BackgroundTrans vTxtModeLbl", T("mode_lbl"))
    GuiObj.SetFont("s11 Bold cWhite", "Segoe UI")
    GuiObj.AddText("x144 y356 w260 h30 vModeText Background0xC81E1E Center 0x200", T("mode_normal"))

    chk := GuiObj.AddCheckbox("x20 y386 w420 h22 cWhite vChkHud Checked" (hudEnabled ? "1" : "0"), T("chk_hud"))
    chk.OnEvent("Click", ToggleHudEnabled)

    GuiObj.SetFont("s9 cBlack", "Segoe UI")
    btn := GuiObj.AddButton("x20 y416 w200 h42 vToggleBtn Default", T("btn_toggle"))
    btn.OnEvent("Click", ToggleMode)
    btn := GuiObj.AddButton("x230 y416 w165 h42 vBtnWizard", T("btn_wizard"))
    btn.OnEvent("Click", RunWizard)
    btn := GuiObj.AddButton("x405 y416 w155 h42 vBtnStats", T("btn_stats"))
    btn.OnEvent("Click", ShowStats)

    GuiObj.SetFont("s8 c1E3A8A", "Segoe UI")
    GuiObj.AddText("x20 y448 w540 h18 BackgroundTrans vAIText c90EE90", "  AI: …")

    GuiObj.AddText("x20 y468 w540 h40 BackgroundTrans vTxtHotkeys", T("hotkeys"))

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

GetCurrentPrefix() {
    global charBuffer
    i := StrLen(charBuffer)
    while i > 0 {
        ch := SubStr(charBuffer, i, 1)
        if !RegExMatch(ch, "[a-z']")
            break
        i--
    }
    return SubStr(charBuffer, i + 1)
}

GetPreviousWord() {
    global charBuffer
    buf := StrLower(charBuffer)
    prefix := GetCurrentPrefix()
    temp := RTrim(SubStr(buf, 1, StrLen(buf) - StrLen(prefix)))
    i := StrLen(temp)
    while (i > 0) {
        ch := SubStr(temp, i, 1)
        if RegExMatch(ch, "[a-z]") {
            startEnd := i
            while (i > 0 && RegExMatch(SubStr(temp, i, 1), "[a-z']"))
                i--
            return SubStr(temp, i + 1, startEnd - i)
        }
        i--
    }
    return ""
}

LearnIfWordCompleted() {
    global wordTrie, learnedPending, userLearned
    word := GetCurrentPrefix()
    if (word = "" || StrLen(word) < 2 || !RegExMatch(word, "^[a-z']+$") || StrLen(word) > 30)
        return
    if !wordTrie.IsCompleteWord(word)
        return
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
        badge.Opt("+Background0x16A34A")
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
            if (GetDictionaryLetterScore(ctx.prefix, best) < 0) {
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
    } else {
        ib := InputBox('Output for "' host '" (comma separated for multiple)',
                       "Output", "w400")
        if (ib.Result != "OK")
            return
        val := Trim(ib.Value)
    }

    if (val = "")
        remaps.Delete(host)
    else
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
    static keys := [
        "a","b","c","d","e","f","g","h","i","j","k","l","m","n","o","p","q","r","s","t","u","v","w","x","y","z",
        "0","1","2","3","4","5","6","7","8","9",
        "Space","Enter","Tab","Esc","Backspace","Delete","Insert","Home","End","PgUp","PgDn",
        "Up","Down","Left","Right",
        "F1","F2","F3","F4","F5","F6","F7","F8","F9","F10","F11","F12",
        "-","=","[","]","\",";","'","``",",",".","/"
    ]

    result    := ""
    destroyed := false

    g := Gui("+AlwaysOnTop +ToolWindow", title)
    g.SetFont("s10", "Segoe UI")
    g.BackColor := 0xEFF6FF
    g.Add("Text", "x14 y14 w280 c1E3A8A", title)
    g.Add("DropDownList", "x14 y42 w260 vSelectedKey Choose1 Sort", keys)
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
    static keys := [
        "a","b","c","d","e","f","g","h","i","j","k","l","m","n","o","p","q","r","s","t","u","v","w","x","y","z",
        "0","1","2","3","4","5","6","7","8","9",
        "Space","Enter","Tab",
        "-","=","[","]","\",";","'","``",",",".","/"
    ]
    outputs := []

    Loop {
        result    := ""
        destroyed := false

        g := Gui("+AlwaysOnTop +ToolWindow", title)
        g.SetFont("s10", "Segoe UI")
        g.BackColor := 0xEFF6FF
        g.Add("Text", "x14 y14 w300 c1E3A8A",
              title "`n(Pick one, then optionally add more.)")
        g.Add("DropDownList", "x14 y56 w280 vSelectedOutput Choose1 Sort", keys)
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