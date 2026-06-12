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

global boundHotkeys := Map()

; =============================================================================
;  PATHS & GLOBAL STATE
; =============================================================================
global APP_DIR        := A_AppData "\BrokenKeyRemapper"
global INI_PATH       := APP_DIR "\config.ini"
global LEARN_PATH     := APP_DIR "\learned.txt"
global STATS_PATH     := APP_DIR "\stats.ini"
global LOG_PATH       := APP_DIR "\debug.log"
global DICT_PATH      := A_Temp "\english_words.txt"
global BIGRAM_PATH    := A_Temp "\english_bigrams.txt"

; AI INTEGRATION
global AI_MODEL       := A_ScriptDir "\smolm-135m.gguf"
global AI_EXE         := A_ScriptDir "\llama-cli.exe"
global AI_TEMP        := A_Temp "\bkr_ai.txt"
global AI_ENABLED     := true
global AI_MIN_CONFIDENCE := 40
global AI_MAX_TOKENS  := 8

if !DirExist(APP_DIR)
    DirCreate(APP_DIR)

try FileInstall("english_words.txt",   DICT_PATH,   1)
try FileInstall("english_bigrams.txt", BIGRAM_PATH, 1)

global remapMode      := false
global isPaused       := false
global remaps         := Map()
global groups         := Map()
global currentIndex   := Map()
global traverseStack  := Map()

global charBuffer     := ""
global maxBuffer      := 400
global lastPrediction := { host: "", char: "", alts: [], pos: 0, ts: 0 }

global tabState := { prefix: "", words: [], pos: 0, lastWord: "", ts: 0 }

global sendingInternally := false
global learnedPending := Map()

global wordTrie       := ""
global unigrams       := Map()
global bigrams        := Map()
global totalUniFreq   := 0

global stats := Map("predictions",0,"corrections",0,"completions",0,"ai_calls",0,"session_start",A_TickCount)

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
;  AI FUNCTIONS
; =============================================================================
CallAI(prompt) {
    global AI_MODEL, AI_EXE, AI_TEMP, AI_MAX_TOKENS, stats, AI_ENABLED
    if (!AI_ENABLED || !FileExist(AI_EXE) || !FileExist(AI_MODEL))
        return ""

    if FileExist(AI_TEMP)
        FileDelete(AI_TEMP)

    cmd := '"' AI_EXE '" -m "' AI_MODEL '" -n ' AI_MAX_TOKENS ' --temp 0.1 -p "' prompt '" > "' AI_TEMP '" 2>&1'
    RunWait(A_ComSpec ' /c ' cmd, , "Hide")

    if !FileExist(AI_TEMP)
        return ""

    result := Trim(FileRead(AI_TEMP))
    FileDelete(AI_TEMP)
    result := RegExReplace(result, "`n.*", "")
    result := Trim(result, "`r`n `t")

    if (result != "")
        stats["ai_calls"] += 1
    return result
}

GetNextLetter(prefix) {
    if (r := GetTriePrediction(prefix)) && r.confidence >= 70
        return r.letter
    if (r := GetBigramPrediction(prefix)) && r.confidence >= 55
        return r.letter
    if (r := GetUnigramPrediction(prefix)) && r.confidence >= AI_MIN_CONFIDENCE
        return r.letter

    aiResult := CallAI("Finish this word:`n" prefix)
    if (aiResult != "" && StrLen(aiResult) > StrLen(prefix)) {
        nextChar := SubStr(aiResult, StrLen(prefix) + 1, 1)
        if RegExMatch(nextChar, "[a-zA-Z]")
            return nextChar
    }
    r := GetUnigramPrediction(prefix)
    return r ? r.letter : ""
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
    global wordTrie, totalUniFreq

    LogMsg("Startup - AI: " (FileExist(AI_MODEL) ? "loaded" : "not found"))

    if !FileExist(INI_PATH) {
        FileAppend("; Broken Key Remapper Pro configuration`n[Settings]`nHudEnabled=1`nAIEnabled=1`n`n[Remaps]`n", INI_PATH, "UTF-8")
    }

    wordTrie := Trie()

    LoadDictionaryIntoTrie()
    LoadBigramsFromTxt()
    LoadLearnedWords()
    LoadRemapsFromIni()
    LoadSettings()
    LoadStats()
    BuildGroupsFromRemaps()
    totalUniFreq := wordTrie.totalFreq

    BuildMainGui()
    BuildHud()
    BuildTrayMenu()

    Hotkey("F12", ToggleMode)
    Hotkey("F11", TogglePause)
    Hotkey("^F12", (*) => AddOrEditMapping())
    Hotkey("Tab", TabComplete, "Off")

    SetTimer(FlushLearnedWords, 30000)

    UpdateListView()
    UpdateModeDisplay()
    GuiObj.Show("w580 h540 Center")
}


; =============================================================================
;  REMAINING ORIGINAL FUNCTIONS
; =============================================================================
; Paste the rest of your original code here (Trie class, LoadDictionaryIntoTrie, PaintGradient, BuildMainGui, buffer functions, prediction engine, etc.)

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
    global wordTrie
    if !FileExist(LEARN_PATH)
        return
    try text := FileRead(LEARN_PATH, "UTF-8")
    catch
        return
    n := 0
    for , line in StrSplit(text, "`n", "`r") {
        parts := StrSplit(Trim(line), A_Tab)
        if parts.Length < 2
            continue
        word := StrLower(Trim(parts[1]))
        freq := IsInteger(parts[2]) ? Integer(parts[2]) : 1
        if word != "" {
            wordTrie.Insert(word, freq)
            n++
        }
    }
    LogMsg("Learned words loaded: " n)
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
    global hudEnabled, AI_ENABLED
    try hudEnabled := IniRead(INI_PATH, "Settings", "HudEnabled", "1") = "1"
    try AI_ENABLED := IniRead(INI_PATH, "Settings", "AIEnabled", "1") = "1"
}

SaveSettings() {
    IniWrite(hudEnabled ? "1" : "0", INI_PATH, "Settings", "HudEnabled")
    IniWrite(AI_ENABLED ? "1" : "0", INI_PATH, "Settings", "AIEnabled")
}

LoadStats() {
    global stats
    try {
        for , k in ["predictions", "corrections", "completions", "ai_calls"]
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

; GUI functions (BuildMainGui, AddFlatButton, BuildHud, etc.) are identical to your original
; ... (I kept them exactly as you provided, only changed version number and description)

BuildMainGui() {
    global GuiObj
    GuiObj := Gui("+Resize", "Broken Key Remapper Pro")
    GuiObj.MarginX := 20
    GuiObj.MarginY := 18
    GuiObj.SetFont("s11 cWhite", "Segoe UI")
    GuiObj.BackColor := 0x1E3A8A

    OnMessage(0x14, PaintGradient)
    GuiObj.OnEvent("Size", (*) => DllCall("InvalidateRect", "Ptr", GuiObj.Hwnd, "Ptr", 0, "Int", 1))

    GuiObj.SetFont("s16 Bold cWhite", "Segoe UI")
    GuiObj.AddText("x20 y16 w540 h28 BackgroundTrans", "  Broken Key Remapper Pro")
    GuiObj.SetFont("s9 cD0E4FF", "Segoe UI")
    GuiObj.AddText("x20 y46 w540 h18 BackgroundTrans", "  Smart predictive remapping + AI")

    GuiObj.SetFont("s10 Norm cWhite", "Segoe UI")
    GuiObj.AddText("x20 y82 w540 h20 BackgroundTrans", "Pressable Key  ->  Output Group (comma separated)")

    lv := GuiObj.AddListView("x20 y104 w540 h210 vLVRemapList -Multi Background0xFFFFFF c333333", ["Pressable", "Outputs", "Current", "VK", "SC", "Uses"])
    lv.Opt("+Grid")

    GuiObj.SetFont("s9 cBlack", "Segoe UI")
    btnY := 326
    AddFlatButton(20, btnY, 120, 36, "Add / Edit", AddOrEditMapping)
    AddFlatButton(148, btnY, 110, 36, "Remove", RemoveSelected)
    AddFlatButton(266, btnY, 110, 36, "Clear all", ClearAll)
    AddFlatButton(384, btnY, 85, 36, "Export", ExportConfig)
    AddFlatButton(477, btnY, 83, 36, "Import", ImportConfig)

    GuiObj.SetFont("s10 cWhite", "Segoe UI")
    GuiObj.AddText("x20 y378 w120 h28 BackgroundTrans", "Current mode:")
    GuiObj.SetFont("s11 Bold cWhite", "Segoe UI")
    GuiObj.AddText("x144 y376 w260 h30 vModeText Background0xC81E1E Center 0x200", "  NORMAL MODE")

    chk := GuiObj.AddCheckbox("x20 y406 w300 h22 cWhite vChkHud Checked" (hudEnabled ? "1" : "0"), "Show floating prediction HUD")
    chk.OnEvent("Click", (*) => (hudEnabled := GuiObj["ChkHud"].Value, SaveSettings(), hudEnabled ? "" : HideHud()))

    GuiObj.SetFont("s9 cBlack", "Segoe UI")
    AddFlatButton(20, 436, 200, 42, "Toggle Mapping (F12)", ToggleMode, true)
    AddFlatButton(230, 436, 165, 42, "Setup Wizard", RunWizard)
    AddFlatButton(405, 436, 155, 42, "Statistics", ShowStats)

    GuiObj.SetFont("s8 c1E3A8A", "Segoe UI")
    GuiObj.AddText("x20 y492 w540 h22 BackgroundTrans", "F12 toggle  -  F11 pause  -  Ctrl+F12 quick add  -  Ctrl+Shift+Z fix  -  Tab complete")

    GuiObj.OnEvent("Close",  (*) => OnExitApp())
    GuiObj.OnEvent("Escape", (*) => GuiObj.Minimize())
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
    A_IconTip := "Broken Key Remapper Pro"
    tray := A_TrayMenu
    tray.Delete()
    tray.Add("Show Window", (*) => GuiObj.Show())
    tray.Add("Toggle Mapping (F12)", ToggleMode)
    tray.Add("Pause (F11)", TogglePause)
    tray.Add()
    tray.Add("Statistics...", (*) => ShowStats())
    tray.Add("Setup Wizard", (*) => RunWizard())
    tray.Add()
    tray.Add("Exit", (*) => OnExitApp())
    tray.Default := "Show Window"
}


; =============================================================================
;  BUFFER & LEARNING (kept original)
; =============================================================================
CommitTraversal() {
    global traverseStack
    traverseStack := Map()
}

CommitChar(ch) {
    global charBuffer, maxBuffer, tabState
    CommitTraversal()
    charBuffer .= StrLower(ch)
    if StrLen(charBuffer) > maxBuffer
        charBuffer := SubStr(charBuffer, -maxBuffer)
    tabState.ts := 0
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
    global wordTrie, learnedPending
    word := GetCurrentPrefix()
    if (word = "" || StrLen(word) < 2 || !RegExMatch(word, "^[a-z']+$") || StrLen(word) > 30)
        return
    wordTrie.Insert(word, 1)
    learnedPending[word] := learnedPending.Get(word, 0) + 1
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
    global charBuffer, sendingInternally, tabState
    if sendingInternally
        return
    CommitTraversal()
    if StrLen(charBuffer) > 0
        charBuffer := SubStr(charBuffer, 1, -1)
    tabState.ts := 0
}

SafeBufferChar(ch) {
    global sendingInternally
    if sendingInternally
        return
    CommitChar(ch)
}

SafeWordBoundary(ch) {
    global charBuffer, sendingInternally, tabState
    if sendingInternally
        return
    CommitTraversal()
    LearnIfWordCompleted()
    charBuffer .= ch
    tabState.ts := 0
}


; =============================================================================
;  CORE LOGIC
; =============================================================================
ToggleMode(*) {
    global remapMode
    remapMode := !remapMode
    UpdateModeDisplay()
    ApplyRemapHotkeys()
    ShowHud(remapMode ? " Mapping ON" : " Mapping OFF", remapMode ? "Predicting from " groups.Count " key(s)" : "")
}

TogglePause(*) {
    global isPaused
    isPaused := !isPaused
    ShowHud(isPaused ? " Paused" : " Resumed", "")
}

UpdateModeDisplay() {
    badge := GuiObj["ModeText"]
    if remapMode {
        badge.Text := "  MAPPED MODE - ON"
        badge.Opt("+Background0x16A34A")
    } else {
        badge.Text := "  NORMAL MODE - OFF"
        badge.Opt("+Background0xC81E1E")
    }
    badge.Redraw()
    GuiObj["ToggleBtn"].Text := remapMode ? "Turn Mapping OFF (F12)" : "Turn Mapping ON (F12)"
}

ApplyRemapHotkeys() {
    global groups, remapMode, boundHotkeys

    for name, cb in boundHotkeys {
        try Hotkey(name, "Off")
    }

    if !remapMode
        return

    for host in groups {
        hk      := MapToValidHotkeyName(host)
        normKey := hk
        shftKey := "+" . hk

        if !boundHotkeys.Has(normKey)
            boundHotkeys[normKey] := SafeCall.Bind(SendPredictedOrLocked, host)
        if !boundHotkeys.Has(shftKey)
            boundHotkeys[shftKey] := SafeCall.Bind(CycleGroup, host)

        try Hotkey(normKey, boundHotkeys[normKey], "On")
        try Hotkey(shftKey, boundHotkeys[shftKey], "On")
    }

    if !boundHotkeys.Has("Tab")
        boundHotkeys["Tab"] := SafeCall.Bind(TabComplete, "")
    try Hotkey("Tab", boundHotkeys["Tab"], "On")
}

SafeCall(fn, arg, *) {
    try {
        if (arg = "")
            fn()
        else
            fn(arg)
    } catch as e {
        LogMsg("Hotkey error: " e.Message)
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
    global groups, isPaused, stats, lastPrediction, sendingInternally

    if isPaused {
        sendingInternally := true
        SendCased(host)
        sendingInternally := false
        CommitChar(host)
        return
    }

    CommitTraversal()
    outs   := groups.Get(host, [])
    prefix := GetCurrentPrefix()
    prev   := GetPreviousWord()

    if outs.Length = 0 {
        sendingInternally := true
        SendCased(host)
        sendingInternally := false
        CommitChar(host)
        return
    }

    ranked := []
    for , letter in outs
        ranked.Push({ ch: letter, score: ScoreCandidate(prefix, letter, prev) })

    ; AI Boost
    aiLetter := GetNextLetter(prefix)
    if (aiLetter != "") {
        for item in ranked {
            if (StrLower(item.ch) = StrLower(aiLetter)) {
                item.score += 0.8
                break
            }
        }
    }

    ; Sort
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

    best := ranked[1].ch

    out := best
    if (prefix = "" && ShouldAutoCap() && RegExMatch(out, "^[a-z]$"))
        out := StrUpper(out)

    sendingInternally := true
    SendCased(out)
    sendingInternally := false

    charBuffer .= StrLower(best)
    if StrLen(charBuffer) > maxBuffer
        charBuffer := SubStr(charBuffer, -maxBuffer)

    stats["predictions"] += 1
    lastPrediction := { host: host, char: best, alts: ranked, pos: 1, ts: A_TickCount }

    completions := wordTrie.TopCompletions(prefix . best, 3)
    cline := ""
    for , c in completions
        cline .= (cline = "" ? "" : "  -  ") . c.word

    ShowHud(" " host " -> " best . (ranked.Length > 1 ? "    [Shift+" host " cycles]" : ""),
            (aiLetter != "" ? "AI helped  " : "") . (cline = "" ? "" : "Tab: " cline))
}

; CycleGroup, TabComplete, MapToValidHotkeyName, SendCased, etc. remain exactly as in your original code
CycleGroup(host, *) {
    global groups, lastPrediction, charBuffer, sendingInternally
    outs := groups.Get(host, [])
    if (outs.Length = 0)
        return

    sameContext := (lastPrediction.host = host && A_TickCount - lastPrediction.ts < 30000 && lastPrediction.char != "" && SubStr(charBuffer, -1) = lastPrediction.char)

    if !sameContext {
        SendPredictedOrLocked(host)
        return
    }
    if (lastPrediction.alts.Length <= 1) {
        ShowHud(" " host " has only one option", "")
        return
    }

    lastPrediction.pos := Mod(lastPrediction.pos, lastPrediction.alts.Length) + 1
    nextChar := lastPrediction.alts[lastPrediction.pos].ch

    shiftHeld := GetKeyState("Shift", "P")

    sendingInternally := true
    if shiftHeld
        Send("{Shift up}")
    Send("{Backspace}")
    SendCased(nextChar)
    if shiftHeld
        Send("{Shift down}")
    sendingInternally := false

    if StrLen(charBuffer) > 0
        charBuffer := SubStr(charBuffer, 1, -1) . StrLower(nextChar)

    lastPrediction.char := nextChar
    lastPrediction.ts   := A_TickCount

    altList := ""
    Loop lastPrediction.alts.Length {
        a := lastPrediction.alts[A_Index].ch
        altList .= (A_Index = lastPrediction.pos) ? "[" a "]" : a
        if (A_Index < lastPrediction.alts.Length)
            altList .= " "
    }
    ShowHud(" Cycle " lastPrediction.pos "/" lastPrediction.alts.Length " -> " nextChar, altList)
}

TabComplete(*) {
    global wordTrie, stats, charBuffer, tabState, sendingInternally
    prefix := GetCurrentPrefix()
    if (prefix = "" || StrLen(prefix) < 2) {
        sendingInternally := true
        Send("{Tab}")
        sendingInternally := false
        return
    }

    now := A_TickCount
    cycling := (tabState.prefix = prefix && tabState.words.Length > 0 && (now - tabState.ts) < 3000 && tabState.lastWord != "")

    if cycling {
        prevWord := tabState.lastWord
        toRemove := StrLen(prevWord) - StrLen(prefix)
        sendingInternally := true
        if toRemove > 0 {
            Loop toRemove
                Send("{Backspace}")
            charBuffer := SubStr(charBuffer, 1, -toRemove)
        }
        sendingInternally := false
        tabState.pos := Mod(tabState.pos, tabState.words.Length) + 1
    } else {
        completions := wordTrie.TopCompletions(prefix, 5)
        if (completions.Length = 0) {
            sendingInternally := true
            Send("{Tab}")
            sendingInternally := false
            return
        }
        words := []
        for , c in completions {
            if c.word != prefix
                words.Push(c.word)
        }
        if (words.Length = 0) {
            sendingInternally := true
            Send("{Tab}")
            sendingInternally := false
            return
        }
        tabState.prefix := prefix
        tabState.words  := words
        tabState.pos    := 1
    }

    word := tabState.words[tabState.pos]
    rest := SubStr(word, StrLen(prefix) + 1)

    sendingInternally := true
    SendText(rest)
    sendingInternally := false

    charBuffer .= StrLower(rest)
    tabState.lastWord := word
    tabState.ts := now
    stats["completions"] += 1

    line := ""
    Loop tabState.words.Length {
        w := tabState.words[A_Index]
        line .= (A_Index = tabState.pos) ? "[" w "]" : w
        if (A_Index < tabState.words.Length)
            line .= "  "
    }
    ShowHud(" Tab " tabState.pos "/" tabState.words.Length " -> " word, "Press Tab again to try the next suggestion")
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
;  CONFIG + USER OPS (unchanged)
; =============================================================================



; ... (AddOrEditMapping, RemoveSelected, ClearAll, RunWizard, ExportConfig, ImportConfig, ShowStats, GetSinglePhysicalKey, SelectKeyFromDropdown, SelectOutputFromDropdown, UpdateListView, ArrayJoin, LogMsg, OnExitApp) 
; are exactly the same as in your original code. Copy them over if needed.


; =============================================================================
;  USER OPS
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
    global stats
    elapsedMin := Round((A_TickCount - stats["session_start"]) / 60000, 1)
    saved      := stats["predictions"] + stats["completions"] * 4
    msg :=  "Statistics`n`n"
        . "Predictions made:           " stats["predictions"] "`n"
        . "Word completions (Tab):     " stats["completions"] "`n"
        . "Corrections (Ctrl+Shift+Z): " stats["corrections"] "`n"
        . "Session time:               " elapsedMin " min`n`n"
        . "Estimated keystrokes saved: " saved
    SaveStats()
    MsgBox msg, "Statistics", "Iconi"
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
    LogMsg("Shutdown")
    ExitApp()
}