# LangHelper

**版本 2.1.0** | [English](README.md) | 繁體中文

Windows 剪貼簿翻譯工具，提供類似 DeepL 的 **Ctrl+C、Ctrl+C** 操作，
以模組化 [prompt.md](prompt.md) 為基礎，預設使用**你已有的 GitHub Copilot 帳號方案**。
獨立的四區翻譯視窗可編輯原文、保留原始剪貼簿快照，並將翻譯主文與 Notes 分開顯示。
你可以選擇 Provider／模型，再手動重新翻譯；修改文字或 Features 不會自動送出請求。

預設使用 VS Code、Sonnet 5.5、多視窗，以及自動複製翻譯主文。
不需要安裝 AutoHotkey、SQLite 或設定 Azure。

主要改版紀錄請見 [CHANGELOG.md](CHANGELOG.md)。

## 安裝

安裝程式會將附帶的 Bridge 複製至 VS Code 使用者擴充功能目錄，不需要建置擴充功能。

```powershell
cd C:\path\to\LangHelper
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -NoStartup
```

[install.ps1](install.ps1) 會將 Bridge 複製至 `~\.vscode\extensions`，
並依範本建立 `langhelper.ini`。執行時**不加** `-NoStartup`，會設定隨 Windows 啟動。
上述命令會略過新增或修改開機啟動項目，但不會移除既有項目。
既有 INI 不會被覆寫，從 Foundry 版本升級時請自行檢查設定。
`-Uninstall` 會移除 Bridge 與開機啟動項目，但保留本機設定、歷史與日誌。

接著：

1. 按 **Ctrl+Shift+P**，輸入 **Developer: Reload Window**，再按 Enter。
   升級時，所有載入舊 Bridge 的 VS Code 視窗都需要重新載入。
2. 執行 **LangHelper: Test Copilot Connection**，並允許授權提示。
3. 雙擊 [LangHelper.cmd](LangHelper.cmd)，系統匣會出現綠色「H」圖示。
4. 在 Windows 任意程式選取文字，按 **Ctrl+C、Ctrl+C**。

### 系統需求

| 項目 | 說明 |
|---|---|
| Windows PowerShell 5.1 | Windows 內建。 |
| VS Code + GitHub Copilot | 使用 `vscode` Provider 時需要。模型、配額及擴充功能存取權限依帳號與組織而定。 |
| GitHub Copilot CLI（選用） | 僅 `copilot-cli` 替代方式需要，可在 VS Code 關閉時使用。 |

```text
Ctrl+C、Ctrl+C
   │
   ▼
langhelper-tray.ps1 ──兩次 WM_CLIPBOARDUPDATE + 按住 Ctrl──► 翻譯視窗
       │
       └── 觸發／Re-translate ──► langhelper.ps1
                                  │ 載入 prompt.md 或 PromptFile
                                  │ 僅模組化 prompt 會組合 Features
                                  │ 插入 <clipboard>…</clipboard>
                                  ▼
                         %LOCALAPPDATA%\LangHelper\bridge\requests\*.json
                                  │
                                  ▼
                       LangHelper Bridge（VS Code 擴充功能）
                                  │ vscode.lm.selectChatModels({vendor:'copilot'})
                                  ▼
                         bridge\responses\*.json
                                  │
                                  ▼
                            結果區 + 剪貼簿
```

## 後端

在 `langhelper.ini` 設定 `Provider=`，或從系統匣選單切換。

| Provider | 行為 | 用量 | 需求 |
|---|---|---|---|
| `vscode`（預設） | 直接呼叫 Language Model API，不回退至 CLI | 適用 Copilot 方案／模型限制 | VS Code 執行中，且 Bridge 已安裝並授權 |
| `copilot-cli` | 非互動式 CLI 請求，通常有較多額外處理 | 適用 CLI 用量與帳號限制 | 已安裝並登入 Copilot CLI，且明確指定 CLI 模型 ID |
| `auto` | 先嘗試 heartbeat 建議的 Provider，失敗後嘗試另一個 | 依實際回應的 Provider 而定 | 相容的模型選擇與可用的 Provider |

日常使用建議選擇 VS Code。CLI 有額外的 agent 處理成本；
速度與用量依模型、輸入內容及帳號限制而定。

VS Code Provider **不會**建立 Copilot Chat／Agent 視窗對話。
結果顯示在 LangHelper；**LangHelper: Show Bridge Log** 可查看請求狀態與模型 ID，
JSONL 歷史則記錄成功的翻譯。CLI Provider 也不會建立 VS Code 對話。

UI 會顯示實際回應的 Provider 及是否發生回退。不同 Provider 的模型 ID 可能不同。

## 檔案

| 檔案 | 用途 |
|---|---|
| [prompt.md](prompt.md) | LLM 提示詞規格，包含 Core 與各個 `[FEATURE: NAME]` 區塊。可自行修改；每次呼叫都會重新讀取。 |
| [langhelper-tray.ps1](langhelper-tray.ps1) | 系統匣圖示、雙重複製偵測與獨立四區翻譯視窗，使用 Windows PowerShell + WinForms。 |
| [langhelper-common.ps1](langhelper-common.ps1) | 共用 INI 驗證、prompt 檢查、結果分區及 Bridge 傳輸。 |
| [LangHelper.cmd](LangHelper.cmd) | 不顯示命令列視窗的系統匣啟動器。 |
| [langhelper.ps1](langhelper.ps1) | 組合 prompt 並傳送至指定 Provider（`vscode`／`copilot-cli`）。 |
| [vscode-extension/](vscode-extension) | LangHelper Bridge，以 `vscode.lm` 呼叫 VS Code 已有的 Copilot 模型。使用 CommonJS，不需要建置。 |
| [install.ps1](install.ps1) | 安裝 Bridge、建立 INI，並控制隨 Windows 啟動。 |
| [langhelper.ini.example](langhelper.ini.example) | 納入版本控制的 INI 範本。 |
| `langhelper.ini` | 本機設定，不納入 Git；系統匣程式會在變更選項時更新。 |
| `logs/langhelper_YYYYMM.log` | 自動建立，每月一份；使用者 profile 路徑會替換為 `%USERPROFILE%`。 |
| `%LOCALAPPDATA%\LangHelper\` | 自動建立，存放 `history.jsonl`、`last-result.txt` 與供擴充功能共用的 `bridge\` 目錄。 |

## 直接執行後端

```powershell
"早安" | Out-File -Encoding UTF8 -NoNewline "$env:TEMP\lh_in.txt"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\langhelper.ps1 `
    -Provider vscode -Model claude-sonnet-5.5 `
    -InputFile "$env:TEMP\lh_in.txt" -OutputFile "$env:TEMP\lh_out.txt" -Verbose
Get-Content "$env:TEMP\lh_out.txt" -Raw
```

此命令會使用內建 prompt 發出真正的 Copilot 請求。
後端腳本**不會**讀取 `langhelper.ini`；若要重現系統匣設定，
請明確傳入 `-PromptFile`、`-Features` 與 `-Model`。
`-Verbose` 顯示實際回應的 Provider；`-PassThru` 除了寫入輸出檔案，也會回傳 Provider／模型資訊。
加入 `-DryRun` 可檢查組合後的 prompt，不呼叫模型。

## 選用：Copilot CLI

若希望 VS Code 關閉後仍能翻譯：

```powershell
npm install -g @github/copilot --registry https://packagefeedproxy.microsoft.io/npm/
copilot            # 登入一次，然後輸入 /exit
```

這**不是離線翻譯**：CLI 仍需要網路及自己的 Copilot 登入狀態。
Microsoft 管理的裝置會封鎖公開套件來源，因此安裝命令使用 CFS。

所有 CLI 啟動方式（原生執行檔與 PowerShell／CMD 啟動腳本）均透過 UTF-8 標準輸入
接收 prompt，保留多行文字與引號，並避免 Windows 命令列長度限制。
CLI 必須支援管線輸入及 `--silent` 純回應輸出；LangHelper 不會猜測或刪除翻譯中的頁尾標籤。

在翻譯視窗選擇 `copilot-cli`，輸入 CLI 模型 ID（可在 CLI 用 `/model` 查詢），
再按 **Re-translate**。
將系統匣預設 Provider 切換至 CLI 時會清空 `Model`，避免沿用僅適用 VS Code 的 ID；
請輸入模型並按 **Save as defaults**。
`auto` 可以嘗試回退至 CLI，但 UI 模型清單來自 VS Code；
若清單無法載入，`auto` 會沿用已儲存的明確模型 ID，並提示 CLI 相容性尚未驗證；
沒有儲存 ID 時會報錯。若要在 VS Code 關閉時選擇 CLI ID，請明確設定 CLI 模式。

## 登入 Windows 時自動啟動

[install.ps1](install.ps1) 會在
`HKCU:\Software\Microsoft\Windows\CurrentVersion\Run`
寫入指向 [LangHelper.cmd](LangHelper.cmd) 的 `LangHelper` 項目。
使用 `-NoStartup` 可略過此步驟；`-Uninstall` 則會連同 Bridge 一起移除此項目。

## 日常使用

1. 啟動 [LangHelper.cmd](LangHelper.cmd)，系統匣會出現綠色「H」。
2. 在 Windows 任意程式選取文字，按 **Ctrl+C、Ctrl+C**。
3. **翻譯視窗**開啟：
   - **Source**：可編輯原文；Enter 插入換行，輸入文字不會自動翻譯。
     傳送原文與歷史會保留開頭縮排及尾端空白；純空白輸入會被拒絕。
     WinForms 顯示時會將換行正規化為 Windows CRLF。
   - **Original clipboard snapshot**：原始剪貼簿快照，不隨 Source 編輯而改變。
   - **Translation**：第一個 fenced 區塊，或第一個 Markdown 段落區段的內文。
     **Notes / back-translation**：其餘輸出。
   - 選擇 **Provider** 與 **Model**，再按 **Re-translate**（Alt+R）。
     **Refresh models** 只查詢 VS Code 模型清單，不送出生成請求。
     切換 Provider 會取消該視窗目前的翻譯；模型或 Features 變更於下次手動翻譯生效。
   - **Configure features** 僅適用模組化 prompt。
     raw 外部 prompt 會顯示「使用外部 prompt，Features 不適用」，並停用功能設定。
   - 狀態列顯示即時計時、實際 Provider／模型及回退狀態。
   - 每次成功翻譯都會附加至 `%LOCALAPPDATA%\LangHelper\history.jsonl`，
     包含模型與耗時。
4. **Copy result**（Alt+C）只複製 Translation，不包含 Notes。
   `AutoCopyResult=1` 會在成功後自動複製；多視窗時，最後成功完成的結果會覆寫剪貼簿。
   剪貼簿忙碌會短暫重試；仍失敗時保留已完成的翻譯，狀態列會提示使用 **Copy result**。
   **Esc** 關閉目前視窗並取消它的工作，系統匣程式仍繼續執行。

`SingleWindow=0`（預設）會在每次觸發時建立新視窗，各自保留原文、模型選擇與工作。
`SingleWindow=1` 則重用最近的視窗。
單一視窗的 Provider／Features 變更不影響其他視窗。
**Save as defaults** 將目前視窗的 Provider／模型／Features 儲存為新視窗預設。
系統匣的 **Reload config (new windows)** 不會干擾既有工作。

可使用 [LangHelper.cmd](LangHelper.cmd)，或執行：

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\langhelper-tray.ps1
```

從 PowerShell 7 啟動時會轉用 Windows PowerShell 5.1，以避免 WinForms 編譯差異。
若要重新啟動，先從系統匣選擇 **Exit**，再啟動 [LangHelper.cmd](LangHelper.cmd)。
關閉翻譯視窗不等於結束系統匣程式。

CMD 啟動器使用 `-DetachConsole` 分離 PowerShell console，搭配隱藏視窗，
避免持續顯示終端機工作列圖示。直接從 PowerShell 啟動仍保留 console 方便除錯，
翻譯視窗不會被隱藏。

### 觸發原理

程式不使用鍵盤 hook。系統匣程式透過 `AddClipboardFormatListener` 註冊 Win32 剪貼簿監聽，
將 **`DoubleCopyMs` 內發生兩次剪貼簿更新，且 Ctrl 仍被按住**視為觸發條件。
Ctrl 檢查可避免其他程式自行連續更新剪貼簿時誤開翻譯視窗。

## Features（定義於 [prompt.md](prompt.md)）

| 標籤 | 功能 |
|---|---|
| `POLISH` | 加入 `## Polished (English)`，提供專業潤飾。 |
| `BILINGUAL_EN_ZHTW` | 要求同時輸出 `## English` 與 `## 繁體中文 (zh-TW)`；搭配 POLISH 可產生各語言的潤飾版本。 |
| `GLOSSARY` | 3～8 個關鍵詞及使用說明。 |
| `TONE_VARIANTS` | 正式／友善／精簡語氣改寫。 |
| `REPLY` | 兩份回覆草稿：簡短版與詳細版。 |
| `SUMMARY` | TL;DR；原文較長時加入重點。 |
| `TECHNICAL` | 保留程式碼、識別名稱、路徑與錯誤訊息。 |
| `BACK_TRANSLATE` | 回譯檢查與語意偏移說明。 |
| `ROMANIZE` | 中日韓文字的拼音／羅馬字／修訂式羅馬字轉寫。 |

> **注意：非模組化的外部 prompt 不套用 Features。**
> 若 `langhelper.ini` 的 `PromptFile=` 指向的檔案，不包含可辨識且帶有剪貼簿佔位符的
> fenced `## Core` 區塊（例如一般的 `SKILL.md`／`TeamsPrompt.md`），
> LangHelper 會使用 **raw／skill 模式**：直接使用檔案內容，**忽略 Features 選擇**。
> 清空 `PromptFile=` 可回到內建的模組化 [prompt.md](prompt.md)，讓功能選項生效。

## 設定（`langhelper.ini`）

[install.ps1](install.ps1) 會建立 INI；也可手動執行：

```powershell
Copy-Item langhelper.ini.example langhelper.ini
```

每個設定都有內建預設值，無效設定會明確報錯。
手動修改後，從系統匣選擇 **Reload config (new windows)**。
**Save as defaults** 會保留 INI 範本的註解與布局。

| 設定 | 可用值 | 預設 | 說明 |
|---|---|---|---|
| `Provider` | `auto`／`vscode`／`copilot-cli` | `vscode` | 新視窗使用的 Provider。 |
| `Features` | 以逗號分隔的標籤 | `POLISH,BILINGUAL_EN_ZHTW` | 僅模組化 prompt 使用，raw prompt 忽略此設定。 |
| `Model` | 單一模型 ID／family，或留空 | `claude-sonnet-5.5` | 明確指定 Sonnet 5.5。VS Code 模型不可用會報錯，不默默替換；CLI 視窗需要明確輸入 ID。 |
| `DoubleCopyMs` | 毫秒 | `700` | 兩次剪貼簿更新可視為雙重複製的最大間隔。 |
| `MinChars`／`MaxChars` | 正整數 | `1`／`8000` | 雙重複製輸入少於 MinChars 時忽略，多於 MaxChars 時截斷並警告。只限制快捷鍵觸發，不限制手動編輯 Source 或系統匣翻譯命令。 |
| `TimeoutSec` | 秒，1～3600 | `120` | 兩種 Provider 的翻譯逾時時間。 |
| `AutoCopyResult` | `0`／`1` | `1` | 成功後自動複製翻譯主文。 |
| `AlwaysOnTop` | `0`／`1` | `1` | 翻譯視窗保持在其他視窗上方。 |
| `PromptFile` | 檔案路徑或留空 | 留空 | 外部 prompt／規格；沒有可辨識的模組化 Core 時，以 raw／skill 模式執行並忽略 Features。 |
| `SingleWindow` | `0`／`1` | `0` | 使用多個獨立視窗，或重用最近的視窗。 |

Azure 設定（`Endpoint`、`EntraSubscription`、`EntraTenant`、`AzureConfigDir`、
`ReasoningEffort`），以及 `AutoTranslate`、`SaveHistory`、`ShowPicker`、`ShowPreview`
已不再使用，儲存設定時會移除。
成功結果一律附加至 JSONL 歷史，不依賴 SQLite。
指定的 `PromptFile` 不存在時會報錯，不回退至內建 prompt。
個人 prompt 路徑請放在不納入 Git 的本機 INI，不要寫入共用範本。

LangHelper 不自行維護憑證／token 快取：
`vscode` 使用 VS Code 的 Copilot 驗證，`copilot-cli` 使用 CLI 的驗證，
登入狀態由各自的宿主管理。

### 外部 prompt 範例

在不納入 Git 的本機 INI 設定個人 prompt 路徑：

```ini
[LangHelper]
Provider=vscode
Model=claude-sonnet-5.5
PromptFile=C:\path\to\TeamsPrompt.md
AutoCopyResult=1
SingleWindow=0
```

儲存後選擇 **Reload config (new windows)**，再開啟新視窗。
既有視窗保留原本的 prompt／設定。
raw 模式會將檔案當作指令，移除開頭的 YAML frontmatter，再將剪貼簿文字加入為資料。
不會自動載入 prompt 引用的同目錄檔案。

## 選擇模型

預設請求 Sonnet 5.5（`claude-sonnet-5.5`），是否可用依 Copilot 帳號與組織而定。
VS Code 下拉選單顯示 `vscode.lm.selectChatModels({vendor:'copilot'})`
實際回傳的清單，不猜測 ID、名稱或 family。
若 Sonnet 5.5 不可用，請明確選擇其他可用模型。狀態列會顯示回傳的模型 ID。

**Provider default** 不明確指定模型，而使用擴充功能的 `langhelper.model`
設定（預設也為 Sonnet 5.5）。擴充功能指定的預設模型不可用時仍會報錯。
清空此 VS Code 設定後，才會使用第一個可用模型。

**Provider default** 僅適用於 `vscode`。`auto` 必須指定模型 ID，
避免空模型讓 CLI 回退必定失敗；指定 ID 仍需同時受兩個 Provider 支援。

目前安裝的 CLI 版本沒有已驗證的機器可讀模型清單。
CLI 模型欄位接受手動輸入的 CLI ID，不會套用 VS Code 清單。
CLI 結果會將模型標示為**指定值、未驗證**，可用 CLI 的 `/model` 查看模型。
`auto` 使用 VS Code 清單；若 CLI 不支援相同 ID，可能失敗，錯誤會明確顯示。

## 系統匣選單

- **Open translator window**：開啟可編輯的空白視窗，不消耗模型配額；雙擊系統匣圖示也可開啟。
- **Translate clipboard now**：不透過快捷鍵，直接翻譯剪貼簿。
- **Provider (new windows) ▸**：變更新視窗預設後端並存入 INI。
- **Show last result**：重新開啟上次翻譯。
- **Open history**：開啟 `%LOCALAPPDATA%\LangHelper\history.jsonl`。
- **Open log**：開啟本月的 `logs/langhelper_YYYYMM.log`。
- **Edit langhelper.ini**／**Reload config (new windows)**：編輯／重新載入設定。
- **Exit**：結束系統匣程式。

## 基本檢查（不消耗 API 用量）

```powershell
"這個 bug 我看一下，應該是 race condition 造成的。" |
    Out-File -Encoding UTF8 -NoNewline "$env:TEMP\lh_in.txt"

powershell -NoProfile -ExecutionPolicy Bypass `
    -File .\langhelper.ps1 `
    -Features "POLISH,BILINGUAL_EN_ZHTW" `
    -InputFile  "$env:TEMP\lh_in.txt" `
    -OutputFile "$env:TEMP\lh_out.txt" `
    -DryRun

Get-Content "$env:TEMP\lh_out.txt" -Raw
```

輸出應包含 Core 區塊、兩個 FEATURE 區塊，以及由 `<clipboard>…</clipboard>` 包住的剪貼簿文字。
移除 `-DryRun` 並加入 `-Verbose`，即可真正呼叫模型並查看實際回應的 Provider。

## 如何新增 Features

後端與系統匣程式都會掃描 Markdown 的 `[FEATURE: NAME]`，因此只需修改一份 prompt：

1. 在 [prompt.md](prompt.md) 新增以 `[FEATURE: MY_FEATURE]` 開頭的 fenced 區塊。
2. 從系統匣選擇 **Reload config (new windows)**。

開啟新視窗，再按 **Configure features**，即可看到新增的核取方塊。

## 回歸測試（不消耗模型用量）

```powershell
node --test .\tests\bridge.test.js
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\ui.tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\backend.tests.ps1
```

測試使用模擬 VS Code API 驗證模型查詢／選擇／取消，
並搭配假的後端驗證真正的 WinForms 控制項，不會登入或傳送 prompt 至 Copilot。

## 疑難排解

| 狀況 | 處理方式 |
|---|---|
| Bridge offline／stale／模型查詢失敗 | 執行 `install.ps1 -NoStartup` 安裝目前的 Bridge，重新載入 VS Code，再執行 **LangHelper: Test Copilot Connection**。 |
| 指定模型不可用 | 重新整理模型清單並選擇可用模型。不是每個帳號都有 Sonnet 5.5；程式不會默默替換模型。 |
| `VS Code has not been granted permission to use Copilot` | 執行 **LangHelper: Test Copilot Connection** 並允許授權提示，只需授權一次。 |
| `No GitHub Copilot language model is available` | 在 VS Code 登入 Copilot；詳細資訊見 **LangHelper: Show Bridge Log**。 |
| 翻譯突然耗時 30 秒 | 可能是 Bridge 中斷，使 `auto` 回退至 `copilot-cli`；以 `-Verbose` 確認後重新載入 VS Code。 |
| 結果與原文相同 | 模組化 prompt 請啟用 `BILINGUAL_EN_ZHTW` 並重譯；raw 外部 prompt 則需要調整 prompt，Features 不適用。 |
| Ctrl+C、Ctrl+C 沒有反應 | 兩次複製間隔須小於 DoubleCopyMs，第二次仍需按住 Ctrl；此檢查可排除程式自行更新剪貼簿。需要較寬鬆的時間可提高 DoubleCopyMs。 |
| 出現兩個系統匣圖示 | 程式只允許單一執行個體，第二個會顯示訊息後結束。請檢查舊安裝是否仍在 Startup 資料夾放有啟動器。 |
| 中日韓輸出空白／亂碼 | 確認 [prompt.md](prompt.md) 以 UTF-8（無 BOM）儲存。 |
| Features 無效／模組化 prompt 被當成 raw | 檢查 fenced Core 區塊與剪貼簿佔位符，或清空 PromptFile 使用內建模組化 prompt。 |
| 想查看執行過程 | 系統匣 → **Open log**，或 VS Code → **LangHelper: Show Bridge Log**；分享前先檢查錯誤內容。 |

## 隱私

JSONL 歷史包含原文與完整翻譯結果。
日誌會將 Windows 使用者 profile 路徑替換為 `%USERPROFILE%`，
但錯誤仍可能包含其他路徑或內容，分享前請檢查歷史與日誌。
程式不會自動清理或限制歷史／日誌的保留時間。

Bridge 請求依呼叫端的逾時設定加入 UTC `expiresAt` 期限。
已過期的排隊請求會被捨棄並記錄日誌，不會呼叫模型。
不含此欄位的舊請求以檔案修改時間加五分鐘判定過期；取消請求不受年齡限制，仍會處理。

## 發布版本（維護者）

Pull request 與推送至 `main` 會觸發 CI workflow，
驗證 PowerShell 語法、Bridge 擴充功能、prompt 組合、
Bridge 回歸測試及 Windows PowerShell 5.1 UI／後端測試。

發布時，從已測試的 `main` commit 建立並推送語意化版本 tag：

```powershell
git switch main
git pull --ff-only
git tag -a v2.1.0 -m "LangHelper v2.1.0"
git push origin v2.1.0
```

Release workflow 會驗證 tag、重新執行檢查、打包腳本與 Bridge、
產生 SHA-256 校驗值，以及建立 GitHub release notes。
像 `v2.1.0-beta.1` 的預先發行 tag 會自動標示為 GitHub pre-release。
Tag 的核心版號必須與 Bridge manifest 版號一致，不一致會在打包前中止。
