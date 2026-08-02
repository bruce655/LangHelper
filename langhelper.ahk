#Requires AutoHotkey v2.0
#SingleInstance Force
; ============================================================================== 
;  LangHelper — Ctrl+C, Ctrl+C clipboard translator
;  Pairs with prompt.md and langhelper.ps1 (which posts to the Azure AI Foundry
;  /chat/completions endpoint).
; ============================================================================== 

; --- Paths --------------------------------------------------------------------
ScriptDir  := A_ScriptDir
IniPath    := ScriptDir "\langhelper.ini"
PromptPath := ScriptDir "\prompt.md"
PsPath     := ScriptDir "\langhelper.ps1"
HistoryPsPath := ScriptDir "\langhelper-history.ps1"
HistoryDbPath := ScriptDir "\langhelper_history.sqlite"
LogDir     := ScriptDir "\logs"

; Survives across runs, so it belongs beside the token cache rather than in
; %TEMP%, which Storage Sense clears.
LocalAppDir := EnvGet("LOCALAPPDATA") "\LangHelper"
if !DirExist(LocalAppDir)
    try DirCreate(LocalAppDir)
LastResultPath := LocalAppDir "\last-result.txt"

; One file per month, resolved on every write so a long-running instance rolls
; over at the month boundary instead of growing without bound.
CurrentLogPath() {
    global LogDir
    if !DirExist(LogDir)
        try DirCreate(LogDir)
    return LogDir "\langhelper_" FormatTime(, "yyyyMM") ".log"
}

Log(msg) {
    line := FormatTime(, "yyyy-MM-dd HH:mm:ss") "  " msg "`r`n"
    try FileAppend(line, CurrentLogPath(), "UTF-8")
}
Log("=== LangHelper start ===")

; --- Catalog of features (NAME, Label) — must match prompt.md ----------------
FeatureCatalog := [
    ["POLISH",            "Polish (professional rewrite)"],
    ["BILINGUAL_EN_ZHTW", "Bilingual (English + 繁體中文)"],
    ["GLOSSARY",          "Glossary / term explanation"],
    ["TONE_VARIANTS",     "Tone variants (formal/friendly/concise)"],
    ["REPLY",             "Reply drafts (chat/email)"],
    ["SUMMARY",           "TL;DR / summary"],
    ["TECHNICAL",         "Technical (preserve code/identifiers)"],
    ["BACK_TRANSLATE",    "Back-translation sanity check"],
    ["ROMANIZE",          "Romanization (Pinyin/Romaji/RR)"]
]

; "(omit)" leaves reasoning_effort out of the request entirely, which is what
; non-reasoning deployments require. "none" is only accepted by gpt-5.1 and later.
ReasoningCatalog := ["(omit)", "none", "minimal", "low", "medium", "high"]

ReasoningLabel(value) {
    return Trim(value) = "" ? "(omit)" : Trim(value)
}

; Deployment names are per-resource, so the ini is the only source of truth for
; the picker. This is just the last-resort value when `Model=` is absent/blank.
DefaultModel := "gpt-5.4-mini"

; --- Settings (loaded from INI with defaults) --------------------------------
; PromptFile: optional path to an external prompt/spec file (e.g. a SKILL.md /
;             TeamsPrompt.md). Empty means use the bundled prompt.md.
; Endpoint:   Foundry resource URL, e.g. https://my-res.openai.azure.com
; EntraSubscription / EntraTenant: pin which az account the token comes from.
;             Subscription wins; the CLI rejects both at once.
; ReasoningEffort: none/minimal/low/medium/high for reasoning models; empty omits
;             the field.
; Model:      comma-separated deployment names. The first one is the active
;             model, the rest fill the picker.
Settings := Map(
    "Features",          IniRead(IniPath, "LangHelper", "Features",          "POLISH"),
    "Model",             IniRead(IniPath, "LangHelper", "Model",             DefaultModel),
    "Endpoint",          IniRead(IniPath, "LangHelper", "Endpoint",          ""),
    "EntraSubscription", IniRead(IniPath, "LangHelper", "EntraSubscription", ""),
    "EntraTenant",       IniRead(IniPath, "LangHelper", "EntraTenant",       ""),
    "ReasoningEffort",   IniRead(IniPath, "LangHelper", "ReasoningEffort",   ""),
    "PromptFile",        IniRead(IniPath, "LangHelper", "PromptFile",        ""),
    "AutoTranslate",     IniRead(IniPath, "LangHelper", "AutoTranslate",     "0"),
    "SaveHistory",       IniRead(IniPath, "LangHelper", "SaveHistory",       "1"),
    "SingleWindow",      IniRead(IniPath, "LangHelper", "SingleWindow",      "1")
)

ModelCatalog := ParseModelCatalog(Settings["Model"])
Settings["Model"] := ModelCatalog[1]

; The picker is exactly what the ini lists: a hardcoded name that isn't deployed
; on your own Foundry resource would only 404.
ParseModelCatalog(raw) {
    global DefaultModel
    list := []
    for part in StrSplit(raw, ",") {
        name := Trim(part)
        if (name = "" || HasModel(list, name))
            continue
        list.Push(name)
    }
    return list.Length ? list : [DefaultModel]
}

HasModel(list, name) {
    for m in list
        if (m = name)
            return true
    return false
}

; The active model is written back first so it survives a restart. ModelCatalog
; itself is never reordered at runtime -- open windows map dropdown index to it.
ModelIniValue() {
    global Settings, ModelCatalog
    out := Settings["Model"]
    for m in ModelCatalog
        if (m != Settings["Model"])
            out .= "," m
    return out
}

SaveSettings() {
    global Settings, IniPath
    IniWrite Settings["Features"],       IniPath, "LangHelper", "Features"
    IniWrite ModelIniValue(),            IniPath, "LangHelper", "Model"
    IniWrite Settings["Endpoint"],       IniPath, "LangHelper", "Endpoint"
    IniWrite Settings["EntraSubscription"], IniPath, "LangHelper", "EntraSubscription"
    IniWrite Settings["EntraTenant"],     IniPath, "LangHelper", "EntraTenant"
    IniWrite Settings["ReasoningEffort"], IniPath, "LangHelper", "ReasoningEffort"
    IniWrite Settings["PromptFile"],     IniPath, "LangHelper", "PromptFile"
    IniWrite Settings["AutoTranslate"],  IniPath, "LangHelper", "AutoTranslate"
    IniWrite Settings["SaveHistory"],    IniPath, "LangHelper", "SaveHistory"
    IniWrite Settings["SingleWindow"],   IniPath, "LangHelper", "SingleWindow"
}

; --- Tray menu ---------------------------------------------------------------
BuildTrayMenu()

BuildTrayMenu() {
    global Settings, ModelCatalog, ReasoningCatalog, PromptPath, LogDir
    tray := A_TrayMenu
    tray.Delete()
    tray.Add("LangHelper", (*) => 0)
    tray.Disable("LangHelper")
    tray.Add()
    tray.Add("Open translator window…", (*) => OpenSettings())

    modelMenu := Menu()
    for m in ModelCatalog {
        modelMenu.Add(m, ChooseModel)
        if (m = Settings["Model"])
            modelMenu.Check(m)
    }
    tray.Add("Model", modelMenu)

    reasonMenu := Menu()
    for r in ReasoningCatalog {
        reasonMenu.Add(r, ChooseReasoning)
        if (r = ReasoningLabel(Settings["ReasoningEffort"]))
            reasonMenu.Check(r)
    }
    tray.Add("Reasoning", reasonMenu)

    tray.Add()
    tray.Add("Open prompt.md",   (*) => Run('"' PromptPath '"'))
    tray.Add("Show last result", (*) => ShowLastResult())
    tray.Add("Search history...", (*) => ShowHistoryWindow())
    tray.Add("Open log file",    (*) => Run('"' CurrentLogPath() '"'))
    tray.Add("Open log folder",  (*) => Run('"' LogDir '"'))
    tray.Add("Dry-run on clipboard (preview prompt)", (*) => DryRunOnClipboard())
    tray.Add()
    tray.Add("Reload script", (*) => Reload())
    tray.Add("Exit",          (*) => ExitApp())

    A_IconTip := "LangHelper — Ctrl+C, Ctrl+C to translate`nFeatures: " Settings["Features"] "`nModel: " Settings["Model"]
}

; Only safe for values that cannot contain a double quote (paths, ini config).
; cmd.exe does not honour the backtick, so a quote here would end the argument
; and let `&` start a new command -- untrusted text must travel by file.
PsArg(value) {
    return '"' StrReplace(value, '"', '`"') '"'
}

; The log is the first thing users paste when asking for help. Account
; identifiers and the prompt path are masked outright; the rest of the command
; line stays readable because it is what makes the log worth reading, but the
; profile prefix is collapsed so the user name does not ride along in it.
RedactArgs(line) {
    static UserProfile := EnvGet("USERPROFILE")
    line := RegExReplace(line, 'i)(-(?:Endpoint|EntraSubscription|EntraTenant|PromptFile))\s+"[^"]*"', '$1 "***"')
    return UserProfile != "" ? StrReplace(line, UserProfile, "%USERPROFILE%") : line
}

RunHistoryCommand(args, outPath := "") {
    global HistoryPsPath
    tmpErr := A_Temp "\langhelper_history_err.txt"
    try FileDelete tmpErr
    cmdLine := 'cmd.exe /c powershell.exe -NoProfile -ExecutionPolicy Bypass -File ' PsArg(HistoryPsPath) ' ' args ' 1>nul 2> "' tmpErr '"'
    Log("History command: " cmdLine)
    exitCode := RunWait(cmdLine, , "Hide")
    err := FileExist(tmpErr) ? Trim(FileRead(tmpErr, "UTF-8"), " `t`r`n") : ""
    if (exitCode != 0)
        return { error: (err != "" ? err : "History command exited with code " exitCode), output: "", exit: exitCode }
    output := (outPath != "" && FileExist(outPath)) ? FileRead(outPath, "UTF-8") : ""
    return { error: "", output: output, exit: exitCode }
}

RecordHistory(sourceText, resultText, features, model) {
    global HistoryDbPath
    tmpBase := A_Temp "\langhelper_history_" A_TickCount
    srcPath := tmpBase "_source.txt"
    resPath := tmpBase "_result.txt"
    try {
        FileAppend(sourceText, srcPath, "UTF-8")
        FileAppend(resultText, resPath, "UTF-8")
        args := '-Action Insert -DbPath ' PsArg(HistoryDbPath)
            . ' -SourceFile ' PsArg(srcPath)
            . ' -ResultFile ' PsArg(resPath)
            . ' -Features ' PsArg(features)
            . ' -Model ' PsArg(model)
        result := RunHistoryCommand(args)
        if (result.error != "")
            Log("History insert failed: " result.error)
    } finally {
        try FileDelete srcPath
        try FileDelete resPath
    }
}

SearchHistory(query, limit := 80) {
    global HistoryDbPath
    outPath := A_Temp "\langhelper_history_search.txt"
    queryPath := A_Temp "\langhelper_history_query.txt"
    try FileDelete outPath
    try FileDelete queryPath
    FileAppend(query, queryPath, "UTF-8")
    args := '-Action Search -DbPath ' PsArg(HistoryDbPath)
        . ' -QueryFile ' PsArg(queryPath)
        . ' -Limit ' limit
        . ' -OutputFile ' PsArg(outPath)
    try {
        return RunHistoryCommand(args, outPath)
    } finally {
        try FileDelete queryPath
    }
}

GetHistoryItem(id) {
    global HistoryDbPath
    srcPath := A_Temp "\langhelper_history_detail_source.txt"
    resPath := A_Temp "\langhelper_history_detail_result.txt"
    try FileDelete srcPath
    try FileDelete resPath
    args := '-Action Get -DbPath ' PsArg(HistoryDbPath)
        . ' -Id ' id
        . ' -SourceOut ' PsArg(srcPath)
        . ' -ResultOut ' PsArg(resPath)
    result := RunHistoryCommand(args)
    if (result.error != "")
        return { error: result.error, source: "", result: "" }
    sourceText := FileExist(srcPath) ? FileRead(srcPath, "UTF-8") : ""
    resultText := FileExist(resPath) ? FileRead(resPath, "UTF-8") : ""
    return { error: "", source: sourceText, result: resultText }
}

DeleteHistoryItem(id) {
    global HistoryDbPath
    args := '-Action Delete -DbPath ' PsArg(HistoryDbPath) ' -Id ' id
    return RunHistoryCommand(args)
}

ClearHistory() {
    global HistoryDbPath
    args := '-Action Clear -DbPath ' PsArg(HistoryDbPath)
    return RunHistoryCommand(args)
}

HexToText(hex) {
    hex := Trim(hex)
    if (hex = "")
        return ""
    byteCount := Floor(StrLen(hex) / 2)
    buf := Buffer(byteCount)
    Loop byteCount {
        byteValue := Integer("0x" SubStr(hex, (A_Index - 1) * 2 + 1, 2))
        NumPut("UChar", byteValue, buf, A_Index - 1)
    }
    return StrGet(buf, byteCount, "UTF-8")
}

PreviewText(text, maxLen := 140) {
    preview := Trim(StrReplace(StrReplace(text, "`r", " "), "`n", " "))
    while InStr(preview, "  ")
        preview := StrReplace(preview, "  ", " ")
    if (StrLen(preview) > maxLen)
        return SubStr(preview, 1, maxLen - 3) "..."
    return preview
}

ResultColumnForHeading(heading) {
    lower := StrLower(heading)
    if (InStr(heading, "繁體中文") || InStr(heading, "中文") || InStr(lower, "zh-tw"))
        return "Chinese"
    if (InStr(lower, "polished") || InStr(heading, "潤飾"))
        return "Polished"
    if (InStr(lower, "english"))
        return "English"
    return "Other"
}

SplitResultColumns(resultText) {
    columns := Map("English", "", "Chinese", "", "Polished", "", "Other", "")
    current := "Other"
    foundHeading := false
    Loop Parse resultText, "`n", "`r" {
        line := A_LoopField
        if (RegExMatch(line, "^\s*##\s+(.+?)\s*$", &match)) {
            current := ResultColumnForHeading(match[1])
            foundHeading := true
            continue
        }
        if (Trim(line) = "")
            continue
        columns[current] .= (columns[current] = "" ? "" : "`n") line
    }
    if (!foundHeading && columns["Other"] = "")
        columns["Other"] := resultText
    return columns
}

ShowHistoryWindow() {
    g := Gui("+Resize +MinSize860x520", "LangHelper History")
    g.BackColor := "F4F5F7"
    g.SetFont("s10", "Segoe UI")
    g.MarginX := 16, g.MarginY := 14

    g.SetFont("s14 Bold", "Segoe UI")
    titleText := g.Add("Text", "xm ym c111827 BackgroundTrans", "History")
    g.SetFont("s9 Norm", "Segoe UI")
    statusText := g.Add("Text", "xm y+4 w820 c6B7280 BackgroundTrans", "Search source or result text")
    searchEdit := g.Add("Edit", "xm y+12 w640 h26")
    searchBtn := g.Add("Button", "x+8 yp w90 h26 Default", "Search")
    openBtn := g.Add("Button", "x+8 yp w110 h26", "Open")
    lv := g.Add("ListView", "xm y+12 w840 h380 Grid", ["Time", "Source", "English", "Chinese", "Polished", "Other"])
    copyBtn := g.Add("Button", "xm y+10 w140", "Copy result")
    rerunBtn := g.Add("Button", "x+8 yp w150", "Re-run source")
    deleteBtn := g.Add("Button", "x+8 yp w130", "Delete selected")
    clearBtn := g.Add("Button", "x+8 yp w110", "Clear all")
    closeBtn := g.Add("Button", "x+408 yp w120", "Close")

    rowIds := []

    SetStatus(msg, color := "6B7280") {
        statusText.SetFont("c" color)
        statusText.Value := msg
    }

    LoadRows(*) {
        rowIds := []
        lv.Delete()
        result := SearchHistory(searchEdit.Value, 100)
        if (result.error != "") {
            SetStatus(result.error, "DC2626")
            return
        }
        rows := StrSplit(Trim(result.output, "`r`n"), "`n", "`r")
        sep := Chr(31)
        count := 0
        for row in rows {
            if (Trim(row) = "")
                continue
            fields := StrSplit(row, sep)
            if (fields.Length < 4)
                continue
            rowIds.Push(fields[1])
            sourceText := HexToText(fields[3])
            resultText := HexToText(fields[4])
            split := SplitResultColumns(resultText)
            lv.Add(""
                , fields[2]
                , PreviewText(sourceText, 120)
                , PreviewText(split["English"], 120)
                , PreviewText(split["Chinese"], 120)
                , PreviewText(split["Polished"], 120)
                , PreviewText(split["Other"], 120))
            count += 1
        }
        lv.ModifyCol(1, 135)
        lv.ModifyCol(2, 210)
        lv.ModifyCol(3, 180)
        lv.ModifyCol(4, 180)
        lv.ModifyCol(5, 180)
        lv.ModifyCol(6, 220)
        SetStatus(count " item(s)", "059669")
    }

    GetSelectedId() {
        row := lv.GetNext()
        if (!row || row > rowIds.Length)
            return 0
        return rowIds[row]
    }

    OpenSelected(*) {
        id := GetSelectedId()
        if (!id) {
            SetStatus("Select a history item first.", "D97706")
            return
        }
        item := GetHistoryItem(id)
        if (item.error != "") {
            SetStatus(item.error, "DC2626")
            return
        }
        ShowHistoryDetail(item.source, item.result)
    }

    CopySelectedResult(*) {
        id := GetSelectedId()
        if (!id) {
            SetStatus("Select a history item first.", "D97706")
            return
        }
        item := GetHistoryItem(id)
        if (item.error != "") {
            SetStatus(item.error, "DC2626")
            return
        }
        A_Clipboard := item.result
        SetStatus("Result copied to clipboard.", "2563EB")
    }

    RerunSelected(*) {
        id := GetSelectedId()
        if (!id) {
            SetStatus("Select a history item first.", "D97706")
            return
        }
        item := GetHistoryItem(id)
        if (item.error != "") {
            SetStatus(item.error, "DC2626")
            return
        }
        ShowTranslatorWindow(item.source, true)
    }

    DeleteSelected(*) {
        id := GetSelectedId()
        if (!id) {
            SetStatus("Select a history item first.", "D97706")
            return
        }
        if (MsgBox("Delete the selected history item? This cannot be undone.", "LangHelper", 0x4 | 0x30) != "Yes")
            return
        result := DeleteHistoryItem(id)
        if (result.error != "") {
            SetStatus(result.error, "DC2626")
            return
        }
        LoadRows()
        SetStatus("Item deleted.", "2563EB")
    }

    ClearAll(*) {
        if (MsgBox("Delete ALL history items? This cannot be undone.", "LangHelper", 0x4 | 0x30) != "Yes")
            return
        result := ClearHistory()
        if (result.error != "") {
            SetStatus(result.error, "DC2626")
            return
        }
        LoadRows()
        SetStatus("History cleared.", "2563EB")
    }

    Layout(clientW := 0, clientH := 0) {
        if (clientW <= 0 || clientH <= 0)
            g.GetClientPos(, , &clientW, &clientH)
        margin := 16
        width := Max(760, clientW - margin * 2)
        titleText.Move(margin, 14, width)
        statusText.Move(margin, 44, width)
        searchW := Max(360, width - 230)
        searchEdit.Move(margin, 76, searchW, 26)
        searchBtn.Move(margin + searchW + 8, 76, 90, 26)
        openBtn.Move(margin + searchW + 106, 76, 110, 26)
        actionY := clientH - margin - 30
        lv.Move(margin, 114, width, Max(200, actionY - 124))
        copyBtn.Move(margin, actionY, 140, 30)
        rerunBtn.Move(margin + 150, actionY, 150, 30)
        deleteBtn.Move(margin + 310, actionY, 130, 30)
        clearBtn.Move(margin + 448, actionY, 110, 30)
        closeBtn.Move(margin + width - 120, actionY, 120, 30)
    }

    searchBtn.OnEvent("Click", LoadRows)
    searchEdit.OnEvent("Change", (*) => SetTimer(LoadRows, -350))
    lv.OnEvent("DoubleClick", OpenSelected)
    openBtn.OnEvent("Click", OpenSelected)
    copyBtn.OnEvent("Click", CopySelectedResult)
    rerunBtn.OnEvent("Click", RerunSelected)
    deleteBtn.OnEvent("Click", DeleteSelected)
    clearBtn.OnEvent("Click", ClearAll)
    closeBtn.OnEvent("Click", (*) => g.Destroy())
    g.OnEvent("Escape", (*) => g.Destroy())
    g.OnEvent("Close", (*) => g.Destroy())
    g.OnEvent("Size", (guiObj, minMax, width, height) => (minMax = -1 ? 0 : Layout(width, height)))

    g.Show("w940 h560 Center")
    Layout()
    LoadRows()
}

ShowHistoryDetail(sourceText, resultText) {
    g := Gui("+Resize +MinSize760x520", "LangHelper History Item")
    g.BackColor := "F4F5F7"
    g.SetFont("s10", "Segoe UI")
    g.MarginX := 16, g.MarginY := 14
    g.SetFont("s10 Bold", "Segoe UI")
    sourceHdr := g.Add("Text", "xm ym c374151 BackgroundTrans", "Source")
    g.SetFont("s10 Norm", "Segoe UI")
    sourceEdit := g.Add("Edit", "xm y+6 w780 h160 ReadOnly +Wrap", sourceText)
    g.SetFont("s10 Bold", "Segoe UI")
    resultHdr := g.Add("Text", "xm y+12 c374151 BackgroundTrans", "Result")
    g.SetFont("s10 Norm", "Segoe UI")
    resultEdit := g.Add("Edit", "xm y+6 w780 h220 ReadOnly +Wrap", resultText)
    copySourceBtn := g.Add("Button", "xm y+10 w130", "Copy source")
    copyResultBtn := g.Add("Button", "x+8 yp w130", "Copy result")
    rerunBtn := g.Add("Button", "x+8 yp w130", "Re-run")
    closeBtn := g.Add("Button", "x+252 yp w120 Default", "Close")

    Layout(clientW := 0, clientH := 0) {
        if (clientW <= 0 || clientH <= 0)
            g.GetClientPos(, , &clientW, &clientH)
        margin := 16
        width := Max(620, clientW - margin * 2)
        sourceHdr.Move(margin, 14, width)
        sourceH := Max(120, Round(clientH * 0.28))
        sourceEdit.Move(margin, 40, width, sourceH)
        resultY := 40 + sourceH + 16
        resultHdr.Move(margin, resultY, width)
        resultY += 26
        actionY := clientH - margin - 30
        resultEdit.Move(margin, resultY, width, Max(140, actionY - resultY - 10))
        copySourceBtn.Move(margin, actionY, 130, 30)
        copyResultBtn.Move(margin + 138, actionY, 130, 30)
        rerunBtn.Move(margin + 276, actionY, 130, 30)
        closeBtn.Move(margin + width - 120, actionY, 120, 30)
    }

    copySourceBtn.OnEvent("Click", (*) => A_Clipboard := sourceText)
    copyResultBtn.OnEvent("Click", (*) => A_Clipboard := resultText)
    rerunBtn.OnEvent("Click", (*) => ShowTranslatorWindow(sourceText, true))
    closeBtn.OnEvent("Click", (*) => g.Destroy())
    g.OnEvent("Escape", (*) => g.Destroy())
    g.OnEvent("Close", (*) => g.Destroy())
    g.OnEvent("Size", (guiObj, minMax, width, height) => (minMax = -1 ? 0 : Layout(width, height)))
    g.Show("w860 h620 Center")
    Layout()
}

ShowLastResult() {
    global LastResultPath
    if (!FileExist(LastResultPath)) {
        MsgBox("No translation has been run yet.", "LangHelper", 64)
        return
    }
    txt := FileRead(LastResultPath, "UTF-8")
    ShowOutputViewer("Last translation result", txt)
}

ChooseModel(item, *) {
    global Settings, TranslatorWindows
    Settings["Model"] := item
    SaveSettings()
    BuildTrayMenu()
    ; Every open window translates with its own dropdown and writes that value
    ; back, so any window left stale would silently undo this choice.
    for win in TranslatorWindows
        try win.setModel.Call(item)
    TrayTip("LangHelper", "Model set to " item, 0x1)
}

ChooseReasoning(item, *) {
    global Settings
    Settings["ReasoningEffort"] := (item = "(omit)") ? "" : item
    SaveSettings()
    BuildTrayMenu()
    TrayTip("LangHelper", "Reasoning effort: " item, 0x1)
}

OpenSettings() {
    text := ""
    try text := A_Clipboard
    ShowTranslatorWindow(text, false)
}

; --- Single active translator window -----------------------------------------
ActiveTranslator := ""

; Every open window, not just the reuse target: with SingleWindow=0 there can be
; several, and all of them need to follow a tray model change.
TranslatorWindows := []

UnregisterTranslator(g) {
    global TranslatorWindows
    Loop TranslatorWindows.Length
        if (TranslatorWindows[A_Index].gui = g) {
            TranslatorWindows.RemoveAt(A_Index)
            return
        }
}

; --- Double-Ctrl+C trigger ---------------------------------------------------
LastCopyTick := 0

~^c:: {
    global LastCopyTick
    now := A_TickCount
    if (now - LastCopyTick < 400) {
        LastCopyTick := 0
        SetTimer(() => TriggerTranslation(false), -100)
    } else {
        LastCopyTick := now
    }
}

DryRunOnClipboard() {
    SetTimer(() => TriggerTranslation(true), -10)
}

TriggerTranslation(dryRun) {
    global Settings
    Sleep 50
    text := ""
    try text := A_Clipboard
    Log("Trigger fired (dryRun=" dryRun ", clipboard length=" StrLen(text) ")")
    if (Trim(text) = "") {
        MsgBox("Clipboard is empty. Select text and press Ctrl+C, Ctrl+C.", "LangHelper", 48)
        return
    }

    if (dryRun) {
        ToolTip("LangHelper: building prompt…")
        result := CallBackend(text, Settings["Features"], Settings["Model"], true)
        ToolTip()
        if (result.error != "") {
            MsgBox("LangHelper error:`n`n" result.error, "LangHelper", 16)
            return
        }
        ShowOutputViewer("Assembled prompt (dry-run)", result.output)
        return
    }

    ShowTranslatorWindow(text, true)
}

; --- Backend call (AHK -> PowerShell -> chat completions API) ---------------
CallBackend(text, features, model, dryRun) {
    global PsPath, Settings
    ; Unique per call: another window can start a translation while this one sits
    ; in RunWait, and shared names would let the two clobber each other's files.
    static callSeq := 0
    callSeq += 1
    tmpBase := A_Temp "\langhelper_" A_TickCount "_" callSeq
    tmpIn  := tmpBase "_in.txt"
    tmpOut := tmpBase "_out.txt"
    tmpErr := tmpBase "_err.txt"
    try {
        FileAppend(text, tmpIn, "UTF-8")

        psArgs := '-NoProfile -ExecutionPolicy Bypass -File "' PsPath '"'
            . ' -Features "' features '"'
            . ' -Model "'    model    '"'
            . ' -InputFile "'  tmpIn  '"'
            . ' -OutputFile "' tmpOut '"'
        if (Trim(Settings["Endpoint"]) != "")
            psArgs .= ' -Endpoint ' PsArg(Trim(Settings["Endpoint"]))
        if (Trim(Settings["EntraSubscription"]) != "")
            psArgs .= ' -EntraSubscription ' PsArg(Trim(Settings["EntraSubscription"]))
        else if (Trim(Settings["EntraTenant"]) != "")
            psArgs .= ' -EntraTenant ' PsArg(Trim(Settings["EntraTenant"]))
        ; Non-reasoning deployments reject the field, so only send it when set.
        if (Trim(Settings["ReasoningEffort"]) != "")
            psArgs .= ' -ReasoningEffort "' Trim(Settings["ReasoningEffort"]) '"'
        if (Trim(Settings["PromptFile"]) != "")
            psArgs .= ' -PromptFile ' PsArg(Settings["PromptFile"])
        if (dryRun)
            psArgs .= ' -DryRun'

        cmdLine := 'cmd.exe /c powershell.exe ' psArgs ' 1>> "' tmpErr '" 2>&1'
        Log("Running: " RedactArgs(cmdLine))
        exitCode := -1
        try {
            exitCode := RunWait(cmdLine, , "Hide")
        } catch as e {
            return { error: "RunWait failed: " e.Message, output: "", exit: -1 }
        }

        out := FileExist(tmpOut) ? FileRead(tmpOut, "UTF-8") : ""
        err := FileExist(tmpErr) ? FileRead(tmpErr, "UTF-8") : ""

        out := RTrim(out, " `t`r`n")
        err := Trim(err, " `t`r`n")

        if (exitCode != 0 && out = "")
            return { error: (err != "" ? err : "PowerShell exited with code " exitCode), output: "", exit: exitCode }
        if (out = "" && err != "")
            return { error: err, output: "", exit: exitCode }
        return { error: "", output: out, exit: exitCode }
    } finally {
        for f in [tmpIn, tmpOut, tmpErr]
            try FileDelete f
    }
}

; --- Combined translator window (source + features + result, live) ----------
FormatFeatures(featStr) {
    global FeatureCatalog
    if (Trim(featStr) = "")
        return "(default — Polish)"
    parts := []
    for item in FeatureCatalog {
        for f in StrSplit(featStr, ",")
            if (Trim(f) = item[1]) {
                parts.Push(item[2])
                break
            }
    }
    out := ""
    for i, p in parts
        out .= (i = 1 ? "" : ", ") p
    return out = "" ? featStr : out
}

; --- Split model output: first fenced code block vs the rest -----------------
; Returns an object with .code (the primary result) and .notes (extra content).
;   * Skill mode (TeamsPrompt.md etc.): .code = text of the first fenced code
;     block, .notes = everything else.
;   * Modular mode (prompt.md): output has no code fence but uses "## ..."
;     section headings. .code = the first section's body, .notes = the
;     remaining sections (kept with their headings).
;   * Plain text (no fence, no headings): .code = "", .notes = full text.
SplitResult(text) {
    fence := Chr(96) Chr(96) Chr(96)            ; three backticks
    pat   := "s)" fence "[^\r\n]*\R(.*?)\R" fence
    if (RegExMatch(text, pat, &m)) {
        code  := Trim(m[1], " `t`r`n")
        notes := Trim(StrReplace(text, m[0], "", , , 1), " `t`r`n")
        return { code: code, notes: notes }
    }

    ; No fenced block: split on Markdown "## " section headings if present.
    if (RegExMatch(text, "m)^##[ \t]")) {
        firstBody := ""
        rest := ""
        section := 0                            ; 0 = preamble, 1 = first section, 2+ = rest
        for line in StrSplit(text, "`n", "`r") {
            if (RegExMatch(line, "^##[ \t]")) {
                section += 1
                if (section >= 2)
                    rest .= (rest = "" ? "" : "`n") line
                continue                        ; drop the first heading line from the top box
            }
            if (section <= 1)
                firstBody .= (firstBody = "" ? "" : "`n") line
            else
                rest .= (rest = "" ? "" : "`n") line
        }
        firstBody := Trim(firstBody, " `t`r`n")
        rest := Trim(rest, " `t`r`n")
        if (rest != "")
            return { code: firstBody, notes: rest }
    }

    return { code: "", notes: text }
}

; --- Normalize line endings to CRLF so Win32 Edit controls (and pasted text)
;     render line breaks. Model output often uses lone LF, which Edit ignores.
ToCRLF(text) {
    return StrReplace(StrReplace(text, "`r`n", "`n"), "`n", "`r`n")
}

; --- Whether a prompt file is "modular" (prompt.md-style with feature blocks).
;     Mirrors langhelper.ps1: a file containing the clipboard marker is modular,
;     so features still apply. Non-modular files (SKILL.md / TeamsPrompt.md) run
;     in raw/skill mode where the Features selection is ignored.
IsModularPromptFile(path) {
    if (Trim(path) = "" || !FileExist(path))
        return false
    try {
        content := FileRead(path, "UTF-8")
    } catch {
        return false
    }
    return InStr(content, "{{PASTE_CLIPBOARD_HERE}}") > 0
}

ShowTranslatorWindow(sourceText, autoRun) {
    global FeatureCatalog, ModelCatalog, Settings, LastResultPath, ActiveTranslator, TranslatorWindows

    ; Reuse the existing window when Single-window mode is on and one is open.
    if (Settings["SingleWindow"] != "0" && IsObject(ActiveTranslator)) {
        try {
            ActiveTranslator.update.Call(sourceText, autoRun)
            return
        } catch {
            ActiveTranslator := ""
        }
    }

    selectedFeatures := Settings["Features"]
    chooseIdx := 1
    Loop ModelCatalog.Length
        if (ModelCatalog[A_Index] = Settings["Model"]) {
            chooseIdx := A_Index
            break
        }

    g := Gui("+Resize +MinSize760x620", "LangHelper")
    g.BackColor := "F4F5F7"
    g.SetFont("s10", "Segoe UI")
    g.MarginX := 16, g.MarginY := 14

    ; --- Header --------------------------------------------------------------
    g.SetFont("s16 Bold", "Segoe UI")
    titleText := g.Add("Text", "x16 y14 c111827 BackgroundTrans", "LangHelper")
    g.SetFont("s9 Norm", "Segoe UI")
    subtitleText := g.Add("Text", "x16 y40 c6B7280 BackgroundTrans", "Clipboard translator · Ctrl+C, Ctrl+C to translate")
    singleChecked := (Settings["SingleWindow"] != "0") ? " Checked" : ""
    singleWinChk := g.Add("CheckBox", "x600 y14 w236 Right" singleChecked, "Single window (reuse)")
    autoChecked := (Settings["AutoTranslate"] = "1" || StrLower(Settings["AutoTranslate"]) = "true") ? " Checked" : ""
    autoChk := g.Add("CheckBox", "x600 y38 w236 Right" autoChecked, "Auto-translate while typing")

    ; --- Source + model row --------------------------------------------------
    g.SetFont("s10 Bold", "Segoe UI")
    sourceHdr := g.Add("Text", "x16 y66 c374151 BackgroundTrans", "Source")
    g.SetFont("s9 Norm", "Segoe UI")
    charCount := g.Add("Text", "x620 y68 w180 c9CA3AF Right BackgroundTrans", StrLen(sourceText) " chars")
    g.SetFont("s9 Norm", "Segoe UI")
    modelHdr := g.Add("Text", "x16 y90 c6B7280 BackgroundTrans", "Model")
    ddModel := g.Add("DropDownList", "x64 y86 w320 Choose" chooseIdx, ModelCatalog)

    ; --- Input ---------------------------------------------------------------
    g.SetFont("s10 Norm", "Segoe UI")
    inputEdit := g.Add("Edit", "x16 y118 w820 h120 +Wrap", sourceText)

    ; --- Snapshot ------------------------------------------------------------
    g.SetFont("s9 Norm", "Segoe UI")
    snapshotHdr := g.Add("Text", "x16 y246 c9CA3AF BackgroundTrans", "Original clipboard snapshot")
    snapshotEdit := g.Add("Edit", "x16 y266 w820 h56 ReadOnly +Wrap c6B7280", sourceText)

    ; --- Feature summary -----------------------------------------------------
    g.SetFont("s10 Bold", "Segoe UI")
    featureHdr := g.Add("Text", "x16 y332 c374151 BackgroundTrans", "Features")
    g.SetFont("s9 Norm", "Segoe UI")
    featuresLabel := g.Add("Text", "x84 y334 w560 c4B5563 BackgroundTrans", FormatFeatures(selectedFeatures))
    cfgBtn := g.Add("Button", "x654 y328 w182 h28", "&Configure features...")

    ; An external prompt file only disables features when it runs in raw/skill
    ; mode. A modular file (prompt.md-style, with the clipboard marker) still
    ; honours features, so treat it the same as the default.
    usingPromptFile := (Trim(Settings["PromptFile"]) != "" && FileExist(Settings["PromptFile"]) && !IsModularPromptFile(Settings["PromptFile"]))
    if (usingPromptFile) {
        promptFileName := ""
        SplitPath(Settings["PromptFile"], &promptFileName)
        cfgBtn.Enabled := false
        featuresLabel.SetFont("cD97706")
        featuresLabel.Value := "Ignored — external prompt file in use (" promptFileName ")"
    }

    ; --- Status --------------------------------------------------------------
    statusText := g.Add("Text", "x16 y366 w820 c059669 BackgroundTrans", "Ready")

    ; --- Result --------------------------------------------------------------
    g.SetFont("s10 Bold", "Segoe UI")
    resultHdr := g.Add("Text", "x16 y392 c374151 BackgroundTrans", "Translation")
    g.SetFont("s9 Norm", "Segoe UI")
    resultHint := g.Add("Text", "x110 y394 w330 c9CA3AF BackgroundTrans", "Code block — Copy result copies this")
    shortcutHint := g.Add("Text", "x430 y394 w406 c9CA3AF Right BackgroundTrans", "Alt+R re-translate · Alt+C copy · Esc close")
    g.SetFont("s10 Norm", "Segoe UI")
    resultEdit := g.Add("Edit", "x16 y416 w820 h110 ReadOnly +Wrap")

    ; --- Notes ---------------------------------------------------------------
    g.SetFont("s9 Norm", "Segoe UI")
    notesHdr := g.Add("Text", "x16 y532 c9CA3AF BackgroundTrans", "Notes & back-translation")
    g.SetFont("s10 Norm", "Segoe UI")
    notesEdit := g.Add("Edit", "x16 y552 w820 h90 ReadOnly +Wrap")

    ; --- Actions -------------------------------------------------------------
    rerunBtn := g.Add("Button", "x16 y636 w150 h30 Default", "&Re-translate")
    copyBtn  := g.Add("Button", "x176 y636 w140 h30", "&Copy result")
    historyBtn := g.Add("Button", "x326 y636 w110 h30", "&History")
    saveHistChecked := (Settings["SaveHistory"] != "0") ? " Checked" : ""
    saveHistChk := g.Add("CheckBox", "x446 y641 w150" saveHistChecked, "Save to history")
    closeBtn := g.Add("Button", "x716 y636 w120 h30", "&Close")

    state := { running: false, restartRequested: false, seq: 0 }

    GetSelected() {
        return selectedFeatures
    }

    SetStatus(msg, color) {
        statusText.SetFont("c" color)
        statusText.Value := msg
    }

    SetReadyStatus(msg := "Ready") {
        SetStatus(msg, "059669")
    }

    UpdateCharCount(*) {
        charCount.Value := StrLen(inputEdit.Value) " chars"
    }

    SetResultPlaceholder(msg) {
        resultEdit.Value := msg
        notesEdit.Value  := ""
    }

    SetBusy(busy) {
        inputEdit.Enabled := !busy
        rerunBtn.Enabled := !busy
        copyBtn.Enabled  := !busy
        ddModel.Enabled  := !busy
        cfgBtn.Enabled   := (!busy && !usingPromptFile)
    }

    Layout(clientW := 0, clientH := 0) {
        if (clientW <= 0 || clientH <= 0) {
            g.GetClientPos(, , &clientW, &clientH)
        }

        margin := 16
        rowGap := 8
        width := clientW - (margin * 2)
        if (width < 420)
            width := 420

        y := 14
        titleText.Move(margin, y)
        singleWinChk.Move(margin + width - 236, y, 236)
        autoChk.Move(margin + width - 236, y + 26, 236)
        y += 26
        subtitleText.Move(margin, y)
        y += 26

        sourceHdr.Move(margin, y)
        charCount.Move(margin + width - 180, y + 2, 180)
        y += 22

        modelHdr.Move(margin, y + 2)
        ddModel.Move(margin + 48, y - 2, Min(360, width - 48))
        y += 30

        inputH := Max(80, Round(clientH * 0.14))
        inputEdit.Move(margin, y, width, inputH)
        y += inputH + rowGap

        snapshotHdr.Move(margin, y)
        y += 20
        snapshotH := Max(44, Round(clientH * 0.07))
        snapshotEdit.Move(margin, y, width, snapshotH)
        y += snapshotH + 10

        featureHdr.Move(margin, y)
        cfgW := 182
        cfgBtn.Move(margin + width - cfgW, y - 4, cfgW, 28)
        featuresLabel.Move(margin + 68, y + 2, width - cfgW - 76)
        y += 34

        statusText.Move(margin, y, width)
        y += 26

        resultHdr.Move(margin, y)
        resultHint.Move(margin + 94, y + 2, Min(330, width - 260))
        shortcutHint.Move(margin + width - 350, y + 2, 350)
        y += 24

        btnH := 30
        actionY := clientH - margin - btnH
        ; Split the remaining vertical space: code block on top, notes below.
        notesHdrH := 20
        available := actionY - y - rowGap - notesHdrH - rowGap
        if (available < 160)
            available := 160
        resultH := Max(80, Round(available * 0.42))
        resultEdit.Move(margin, y, width, resultH)
        y += resultH + rowGap

        notesHdr.Move(margin, y)
        y += notesHdrH
        notesH := actionY - y - rowGap
        if (notesH < 80)
            notesH := 80
        notesEdit.Move(margin, y, width, notesH)

        rerunBtn.Move(margin, actionY, 150, btnH)
        copyBtn.Move(margin + 160, actionY, 140, btnH)
        historyBtn.Move(margin + 310, actionY, 110, btnH)
        saveHistChk.Move(margin + 430, actionY + 5, 150)
        closeBtn.Move(margin + width - 120, actionY, 120, btnH)
    }

    DoTranslate(seq) {
        if (seq != state.seq)
            return
        if (state.running) {
            state.restartRequested := true
            return
        }

        textToTranslate := Trim(inputEdit.Value)
        if (textToTranslate = "") {
            SetStatus("Input is empty", "9CA3AF")
            SetResultPlaceholder("Input is empty. Paste or type text to translate.")
            return
        }

        feat := GetSelected()
        modl := ModelCatalog[ddModel.Value]
        Settings["Features"] := feat
        Settings["Model"]    := modl
        SaveSettings()
        BuildTrayMenu()

        state.running := true
        state.restartRequested := false
        SetBusy(true)
        SetStatus("Translating with " modl " (" (feat = "" ? "default" : feat) ")...", "D97706")
        SetResultPlaceholder("Translating...")
        SetTimer(() => RunOnce(textToTranslate, feat, modl, seq), -10)
    }

    RunOnce(textToTranslate, feat, modl, seq) {
        startTick := A_TickCount
        Log("Window translate  features=[" feat "]  model=" modl "  inputLen=" StrLen(textToTranslate))
        result := CallBackend(textToTranslate, feat, modl, false)
        Log("Window backend returned  exit=" result.exit "  outLen=" StrLen(result.output))
        state.running := false
        SetBusy(false)

        if (state.restartRequested || seq != state.seq) {
            SetTimer(() => DoTranslate(state.seq), -10)
            return
        }

        if (result.error != "") {
            SetStatus("Error: see Open log file in tray", "DC2626")
            resultEdit.Value := ToCRLF(result.error)
            notesEdit.Value  := ""
            return
        }
        if (result.output = "") {
            SetStatus("Empty response", "9CA3AF")
            SetResultPlaceholder("The model returned an empty response.")
            return
        }
        split := SplitResult(result.output)
        if (split.code != "") {
            resultEdit.Value := ToCRLF(split.code)
            notesEdit.Value  := ToCRLF(split.notes)
            A_Clipboard      := ToCRLF(split.code)
        } else {
            resultEdit.Value := ToCRLF(result.output)
            notesEdit.Value  := ""
            A_Clipboard      := ToCRLF(result.output)
        }
        try FileDelete LastResultPath
        ; Best-effort cache: a locked-down or missing LOCALAPPDATA must not take
        ; the translation down with it.
        try FileAppend(result.output, LastResultPath, "UTF-8")
        if (saveHistChk.Value)
            SetTimer(() => RecordHistory(textToTranslate, result.output, feat, modl), -10)
        elapsed := (A_TickCount - startTick) / 1000
        SetStatus("Done. Translation copied to clipboard. " Format("{:.3f}", elapsed) "s", "059669")
    }

    DebouncedTranslate(*) {
        if (!autoChk.Value)
            return
        state.seq += 1
        mySeq := state.seq
        SetTimer(() => DoTranslate(mySeq), -700)
    }

    ForceTranslate(*) {
        state.seq += 1
        DoTranslate(state.seq)
    }

    OnAutoToggle(*) {
        Settings["AutoTranslate"] := autoChk.Value ? "1" : "0"
        SaveSettings()
        if (autoChk.Value)
            ForceTranslate()
    }

    OnSaveHistoryToggle(*) {
        Settings["SaveHistory"] := saveHistChk.Value ? "1" : "0"
        SaveSettings()
        SetStatus(saveHistChk.Value ? "Translations are saved to history." : "History saving is off for new translations.", "2563EB")
    }

    OnSingleToggle(*) {
        global ActiveTranslator
        Settings["SingleWindow"] := singleWinChk.Value ? "1" : "0"
        SaveSettings()
        ; Turning single-window on makes this window the reuse target;
        ; turning it off stops future triggers from reusing it.
        if (singleWinChk.Value)
            ActiveTranslator := winRef
        else if (IsObject(ActiveTranslator) && ActiveTranslator.gui = g)
            ActiveTranslator := ""
    }

    OpenFeatureConfig(*) {
        cfg := Gui("+Owner" g.Hwnd " +ToolWindow", "Configure Features")
        cfg.BackColor := "F4F5F7"
        cfg.SetFont("s10", "Segoe UI")
        cfg.MarginX := 16, cfg.MarginY := 14
        cfg.SetFont("s12 Bold", "Segoe UI")
        cfg.Add("Text", "xm c1F2937 BackgroundTrans", "Configure features")
        cfg.SetFont("s9 Norm", "Segoe UI")
        cfg.Add("Text", "xm y+2 c6B7280 BackgroundTrans", "Changes apply when you click Save")
        cfg.SetFont("s10 Norm", "Segoe UI")
        cfg.Add("Text", "xm y+10 c374151 BackgroundTrans", "Quick presets")

        presetDefault  := cfg.Add("Button", "xm y+6 w150", "Default (Polish)")
        presetBilingual := cfg.Add("Button", "x+8 w200", "Bilingual + Polish")
        presetClear    := cfg.Add("Button", "x+8 w120", "Clear all")

        grp := cfg.Add("GroupBox", "xm y+12 w760 h248", "Available features")

        enabledNow := Map()
        for f in StrSplit(selectedFeatures, ",")
            if (Trim(f) != "")
                enabledNow[Trim(f)] := true

        cfgBoxes := Map()
        for i, item in FeatureCatalog {
            name := item[1], label := item[2]
            if (i = 1) {
                opts := "x36 y+28 w340 v" name
            } else if (Mod(i, 2) = 1) {
                opts := "xm y+10 x36 w340 v" name
            } else {
                opts := "x+36 yp w340 v" name
            }
            if (enabledNow.Has(name))
                opts .= " Checked"
            cfgBoxes[name] := cfg.Add("CheckBox", opts, label)
        }

        cfg.SetFont("s9 Norm", "Segoe UI")
        previewHdr := cfg.Add("Text", "xm y+14 c6B7280 BackgroundTrans", "Selected:")
        previewText := cfg.Add("Text", "x+8 yp w690 c4B5563 BackgroundTrans", FormatFeatures(selectedFeatures))

        UpdatePreview(*) {
            names := []
            for item in FeatureCatalog {
                n := item[1]
                if (cfgBoxes[n].Value)
                    names.Push(n)
            }
            joined := ""
            for i, n in names
                joined .= (i = 1 ? "" : ",") n
            previewText.Value := FormatFeatures(joined)
        }

        ApplyPreset(list) {
            active := Map()
            for n in list
                active[n] := true
            for item in FeatureCatalog {
                n := item[1]
                cfgBoxes[n].Value := active.Has(n) ? 1 : 0
            }
            UpdatePreview()
        }

        SaveCfg(*) {
            names := []
            for item in FeatureCatalog {
                n := item[1]
                if (cfgBoxes[n].Value)
                    names.Push(n)
            }
            joined := ""
            for i, n in names
                joined .= (i = 1 ? "" : ",") n
            selectedFeatures := joined
            featuresLabel.Value := FormatFeatures(selectedFeatures)
            Settings["Features"] := selectedFeatures
            SaveSettings()
            BuildTrayMenu()
            cfg.Destroy()
            ForceTranslate()
        }

        for item in FeatureCatalog
            cfgBoxes[item[1]].OnEvent("Click", UpdatePreview)

        presetDefault.OnEvent("Click",  (*) => ApplyPreset(["POLISH"]))
        presetBilingual.OnEvent("Click", (*) => ApplyPreset(["POLISH", "BILINGUAL_EN_ZHTW"]))
        presetClear.OnEvent("Click",    (*) => ApplyPreset([]))

        saveBtn   := cfg.Add("Button", "xm y+16 w120 Default", "&Save")
        cancelBtn := cfg.Add("Button", "x+10 w120", "&Cancel")
        saveBtn.OnEvent("Click", SaveCfg)
        cancelBtn.OnEvent("Click", (*) => cfg.Destroy())
        cfg.OnEvent("Escape", (*) => cfg.Destroy())
        cfg.OnEvent("Close",  (*) => cfg.Destroy())
        cfg.Show()
    }

    inputEdit.OnEvent("Change", DebouncedTranslate)
    inputEdit.OnEvent("Change", UpdateCharCount)
    autoChk.OnEvent("Click", OnAutoToggle)
    saveHistChk.OnEvent("Click", OnSaveHistoryToggle)
    singleWinChk.OnEvent("Click", OnSingleToggle)
    cfgBtn.OnEvent("Click", OpenFeatureConfig)
    ddModel.OnEvent("Change", DebouncedTranslate)

    rerunBtn.OnEvent("Click", ForceTranslate)
    copyBtn.OnEvent("Click", (*) => (
        A_Clipboard := resultEdit.Value,
        SetStatus("Result copied to clipboard.", "2563EB")
    ))
    historyBtn.OnEvent("Click", (*) => ShowHistoryWindow())

    g.OnEvent("Size", (guiObj, minMax, width, height) => (
        minMax = -1 ? 0 : Layout(width, height)
    ))

    UpdateWindow(newText, doAutoRun) {
        inputEdit.Value := newText
        snapshotEdit.Value := newText
        UpdateCharCount()
        SetReadyStatus()
        SetResultPlaceholder("Result will appear here after translation.")
        g.Show()
        WinActivate("ahk_id " g.Hwnd)
        inputEdit.Focus()
        if (doAutoRun && Trim(newText) != "") {
            state.seq += 1
            DoTranslate(state.seq)
        }
    }

    DestroyWindow(*) {
        global ActiveTranslator
        UnregisterTranslator(g)
        if (IsObject(ActiveTranslator) && ActiveTranslator.gui = g)
            ActiveTranslator := ""
        g.Destroy()
    }

    SyncModelChoice(name) {
        Loop ModelCatalog.Length
            if (ModelCatalog[A_Index] = name) {
                ddModel.Value := A_Index
                return
            }
    }

    closeBtn.OnEvent("Click", DestroyWindow)
    g.OnEvent("Escape", DestroyWindow)
    g.OnEvent("Close",  DestroyWindow)

    winRef := { gui: g, update: UpdateWindow, setModel: SyncModelChoice }
    TranslatorWindows.Push(winRef)
    ActiveTranslator := winRef

    g.Show("w900 h700 Center")
    Layout()
    inputEdit.Focus()
    SetResultPlaceholder("Result will appear here after translation.")

    if (autoRun && Trim(inputEdit.Value) != "") {
        state.seq += 1
        DoTranslate(state.seq)
    }
}

; --- Simple read-only viewer (dry-run / last result) ------------------------
ShowOutputViewer(title, text) {
    g := Gui("+Resize +AlwaysOnTop", title)
    g.SetFont("s10", "Consolas")
    g.MarginX := 10, g.MarginY := 10
    g.Add("Edit", "xm ym w760 h480 ReadOnly +Wrap", text)
    copyBtn  := g.Add("Button", "xm y+10 w160", "Copy to clipboard")
    closeBtn := g.Add("Button", "x+10  w120 Default", "Close")
    copyBtn.OnEvent("Click", (*) => (A_Clipboard := text, ToolTip("Copied ✓"), SetTimer(() => ToolTip(), -1200)))
    closeBtn.OnEvent("Click", (*) => g.Destroy())
    g.OnEvent("Escape", (*) => g.Destroy())
    g.OnEvent("Close",  (*) => g.Destroy())
    g.Show()
}

TrayTip("LangHelper", "Ready. Press Ctrl+C, Ctrl+C on any selection.", 0x1)
