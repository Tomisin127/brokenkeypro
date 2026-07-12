#Requires AutoHotkey v2.0

; Gumroad license gate - one activation per device (fingerprint sent to Gumroad API).

global GUMROAD_PRODUCT_ID := "aNF2YKGdZYjLyDL2S4Ygjw=="
global GUMROAD_VERIFY_URL := "https://api.gumroad.com/v2/licenses/verify"
global LICENSE_DIR        := A_AppData "\BrokenKeyRemapper"
global LICENSE_FILE       := LICENSE_DIR "\license.txt"

CheckLicense() {
    if !DirExist(LICENSE_DIR)
        DirCreate(LICENSE_DIR)

    fingerprint := GetDeviceFingerprint()
    savedKey := ReadSavedLicense()

    if (savedKey != "") {
        result := ValidateLicenseOnline(savedKey, fingerprint, false)
        if (result.ok)
            return true
        if (result.reason = "offline") {
            MsgBox "Could not verify your license.`n`nAn internet connection is required to run Broken Key Remapper Pro.",
                "Activation Error", "IconX"
            ExitApp()
        }
        if MsgBox("License validation failed.`n`n" result.message "`n`nEnter a different license key?",
            "Activation Required", "YesNo Icon!") = "No"
            ExitApp()
    }

    return PromptForLicense(fingerprint)
}

ShowLicenseInfo(*) {
    fingerprint := GetDeviceFingerprint()
    savedKey := ReadSavedLicense()
    masked := savedKey != "" ? (SubStr(savedKey, 1, 4) "****" SubStr(savedKey, -4)) : "(none)"
    status := "Not activated"
    if (savedKey != "") {
        result := ValidateLicenseOnline(savedKey, fingerprint, false)
        status := result.ok ? "Active on this device" : result.message
    }
    choice := MsgBox(
        "License key: " masked "`n"
        . "Device ID: " fingerprint "`n"
        . "Status: " status "`n`n"
        . "Change license key?",
        "License", "YesNoCancel Iconi")
    if (choice = "Yes")
        PromptForLicense(fingerprint)
}

PromptForLicense(fingerprint) {
    if !IsSet(fingerprint) || (fingerprint = "")
        fingerprint := GetDeviceFingerprint()

    Loop {
        ib := InputBox(
            "Enter your Gumroad license key.`n`n"
            . "One purchase = one PC. Your device ID:`n" fingerprint,
            "Activation Required", "w420 h200")
        if (ib.Result != "OK")
            ExitApp()

        key := Trim(ib.Value)
        if (key = "") {
            MsgBox "License key cannot be empty.", "Activation", "Icon!"
            continue
        }

        result := ValidateLicenseOnline(key, fingerprint, false)
        if result.ok {
            SaveLicense(key)
            MsgBox "Activation successful!`n`nThis license is now bound to this device.", "Licensed", "Iconi"
            return true
        }

        if (result.reason = "offline") {
            MsgBox "Activation requires an internet connection.", "Activation Error", "IconX"
            ExitApp()
        }

        if MsgBox(result.message "`n`nTry again?", "Invalid License", "YesNo IconX") = "No"
            ExitApp()
    }
}

ReadSavedLicense() {
    if !FileExist(LICENSE_FILE)
        return ""
    try {
        return Trim(FileRead(LICENSE_FILE, "UTF-8"))
    } catch {
        return ""
    }
}

SaveLicense(key) {
    if !DirExist(LICENSE_DIR)
        DirCreate(LICENSE_DIR)
    try {
        FileDelete(LICENSE_FILE)
    } catch {
    }
    FileAppend(Trim(key), LICENSE_FILE, "UTF-8")
}

ValidateLicenseOnline(key, fingerprint, incrementUses := false) {
    key := Trim(key)
    if (key = "")
        return { ok: false, reason: "empty", message: "License key is empty." }

    body := "product_id=" EncodeURL(GUMROAD_PRODUCT_ID)
        . "&license_key=" EncodeURL(key)
        . "&increment_uses_count=" (incrementUses ? "true" : "false")
        . "&fingerprint=" EncodeURL(fingerprint)

    try {
        whr := ComObject("WinHttp.WinHttpRequest.5.1")
        whr.Open("POST", GUMROAD_VERIFY_URL, false)
        whr.SetTimeouts(15000, 15000, 15000, 15000)
        whr.SetRequestHeader("Content-Type", "application/x-www-form-urlencoded")
        whr.Send(body)
        response := whr.ResponseText

        if InStr(response, '"success":true')
            return { ok: true, reason: "ok", message: "Licensed." }

        msg := ParseGumroadError(response)
        if InStr(StrLower(msg), "already been activated") || InStr(StrLower(response), "fingerprint")
            msg := "This license is already activated on another device.`n`nOne license works on one PC only."

        return { ok: false, reason: "invalid", message: msg }
    } catch as e {
        return { ok: false, reason: "offline", message: e.Message }
    }
}

ParseGumroadError(json) {
    if RegExMatch(json, '"message"\s*:\s*"((?:\\.|[^"\\])*)"', &m)
        return JsonUnescape(m[1])
    if InStr(json, '"success":false')
        return "Invalid or expired license key."
    return "Activation failed."
}

GetDeviceFingerprint() {
    serial := 0
    root := EnvGet("SystemDrive") "\"
    if (root = "\")
        root := "C:\"
    try {
        DllCall("GetVolumeInformationW"
            , "WStr", root
            , "Ptr", 0, "UInt", 0, "UInt", 0, "UInt", 0
            , "UInt*", &serial
            , "Ptr", 0, "UInt", 0)
    } catch {
        serial := 0
    }
    raw := A_ComputerName "|" serial "|" A_UserName "|" (A_Is64bitOS ? "64" : "32")
    return "BKR-" HashFingerprint(raw)
}

HashFingerprint(s) {
    h := 2166136261
    Loop Parse s {
        h := Mod((h ^ Ord(A_LoopField)) * 16777619, 0x100000000)
    }
    return Format("{:08X}{:08X}", h, Mod(h * 2654435761, 0x100000000))
}

EncodeURL(str) {
    try {
        static doc := 0
        if !IsObject(doc) {
            doc := ComObject("htmlfile")
            doc.write("<meta http-equiv=`"x-ua-compatible`" content=`"IE=9`">")
        }
        return doc.parentWindow.encodeURIComponent(str)
    } catch {
        return ManualEncodeURL(str)
    }
}

ManualEncodeURL(str) {
    out := ""
    Loop Parse str {
        c := A_LoopField
        asc := Ord(c)
        if ((asc >= 48 && asc <= 57) || (asc >= 65 && asc <= 90) || (asc >= 97 && asc <= 122)
            || InStr("-_.~", c))
            out .= c
        else
            out .= Format("%{1:02X}", asc)
    }
    return out
}

JsonUnescape(s) {
    s := StrReplace(s, '\n', "`n")
    s := StrReplace(s, '\r', "`r")
    s := StrReplace(s, '\t', "`t")
    s := StrReplace(s, '\"', '"')
    s := StrReplace(s, '\\', '\')
    return s
}
