# Changelog

本文件整理 LangHelper 的主要改版里程碑，依日期由新到舊排列。

版號定義：
- **1.0.0**：已有 Git tag `v1.0.0`。
- **1.5.0**：Azure AI Foundry 遷移版，依專案決定追溯定版。
- **2.0.0**：來自上游的 VS Code Bridge／Copilot 版本，包含 2026-08-19 重建及 2026-08-31 後續修正。
- **2.1.0**：本次 Copilot 與四區 UI 整合版，Bridge manifest 已為 `2.1.0`。

### 歷史版號整理

歷史階段依「新增功能提升 minor、修正提升 patch、架構重建提升 major」的邏輯追溯定版：

| 日期 | 階段 | 版號 | 理由 |
|---|---|---|---|
| 2026-06-17～06-18 | 初始版本 | `0.1.0` | 第一個可用原型，尚未進入正式 1.0。 |
| 2026-07-09 | SQLite 翻譯歷史 | `0.2.0` | 原型階段新增歷史儲存與搜尋。 |
| 2026-07-10～07-16 | 外部 prompt 與進階 UI | `1.1.0` | 1.0 後新增 prompt、結果分區及視窗控制功能。 |
| 2026-07-17 | 開機啟動選項 | `1.2.0` | 新增使用者可選的啟動功能，不只是錯誤修正。 |
| 2026-09-14 | Foundry 登入設定隔離 | `1.5.1` | 視為 1.5 路線的登入可靠性修正；雖新增設定，主要目的是避免既有流程被其他登入操作影響。 |

`1.3.x`、`1.4.x` 不必為了連號而補造；Foundry 遷移依已決定的里程碑直接使用 `1.5.0`。
Foundry 的 `1.5.1` 與上游 `2.0.0` 是分開演進的路線，因此日期較晚不代表應改成 2.x。

## 2.1.0 — 2026-10-12

### UI 與操作
- 以 PowerShell／WinForms 恢復四區介面：可編輯原文、唯讀剪貼簿快照、翻譯主文、Notes／回譯。
- 原文可修改，按 **Re-translate** 才重新送出；修改文字或 Features 不自動翻譯。
- 加入執行中計時，完成後顯示耗時、實際 Provider／模型及回退狀態。
- 恢復單／多視窗切換：`SingleWindow=0` 預設多視窗，`1` 重用最近的視窗。
- 每個視窗獨立保存輸入、模型與翻譯工作；重譯、切換 Provider 或關閉視窗不取消其他視窗的工作。
- 主文與 Notes 分開顯示；手動複製與自動複製只取主文。

### Copilot 與模型
- 預設 `Provider=vscode`、`Model=claude-sonnet-5.5`。
- UI 透過 Bridge 查詢當下可用的 VS Code Copilot 模型，提供模型選單及重新整理。
- 指定模型不可用時明確報錯，不再默默改用其他模型。
- Bridge 回傳實際模型資訊；CLI 僅手動輸入模型 ID，並標示為「指定值、未驗證」。
- 保留 `copilot-cli` 與 `auto`，回退後顯示實際 Provider。
- 新版 Bridge 在多個 VS Code 視窗間採單一服務者，避免重複消耗翻譯請求。

### 設定與資料
- 重整 INI 範本，加入 `SingleWindow`，預設 `AutoCopyResult=1`。
- 保留外部 `PromptFile`；raw prompt 模式顯示「使用外部 prompt，Features 不適用」，停用 Features 設定。
- 指定 prompt 檔案不存在、模型清單格式錯誤或設定值無效時，明確提示。
- 移除 Azure 設定、`AutoTranslate`、`SaveHistory`、`ShowPicker`、`ShowPreview`。
- 維持上游 JSONL 歷史，成功翻譯寫入原文、完整結果、實際 Provider、模型及耗時，不重新引入 SQLite。
- **Save as defaults** 儲存目前視窗的 Provider／模型／Features，作為新視窗預設；保留範本註解。

### 修正與驗證
- 修正 Windows PowerShell 5.1 的非 ASCII 標點編碼問題，PowerShell 7 啟動時轉用 Windows PowerShell 5.1。
- 啟動或執行失敗時釋放單例鎖，避免無托盤圖示卻顯示「已在執行」。
- 修正 CLI 提示文字的引號傳遞，限制工具使用並處理 timeout／取消。
- 補強模型查詢期間的取消，避免取消後仍送出生成請求；原文 Enter 可插入換行。
- `auto` 無法取得模型清單時可使用已儲存的明確 ID，並提示 CLI 相容性尚未驗證。
- CLI 啟動腳本使用 UTF-8 標準輸入保留多行、引號與特殊字元；prompt reminder 保留條件式輸出規則。
- 新增 Bridge、WinForms UI、INI、後端與 CLI 參數回歸測試；更新 CI 與 release 打包檔案清單。
- Release 打包前執行 Bridge／UI／後端回歸測試，並包含中英文 README 與改版紀錄。
- Bridge 心跳時間戳記正規化為 UTC，避免本地時區導致心跳誤判為過期。
- 補強 Bridge owner.json 鎖機制，自動復原毀損或過期的鎖檔案，避免 VS Code 異常後無限期處於 Standby。
- Bridge 寫入回應後再次確認取消標記，避免非同步寫入期間到達的取消請求遺留未處理回應。
- 精簡 README，更新安裝、模型選擇、多視窗、外部 prompt、歷史與隱私說明。

## 1.5.1 — 2026-09-14：Foundry 登入設定隔離

此項屬原 Foundry 路線，與同期上游 Copilot 路線分開演進。

- 新增 `AzureConfigDir`，讓 LangHelper 使用獨立 Azure CLI 登入設定目錄。
- 可選擇共用一般 Azure CLI profile，或使用 `%LOCALAPPDATA%\LangHelper\azure`。
- 減少日常 `az login`／`az logout` 對 LangHelper 指定訂閱登入狀態的干擾。
- 更新設定範本與登入文件。

依據：commit `83372af`。

## 2.0.0（來自上游）— 2026-08-19～2026-08-31

### 2026-08-19：Copilot 重建

- 從 Azure AI Foundry 改為 GitHub Copilot。
- 新增 VS Code Bridge，透過 `vscode.lm` 使用 VS Code 已登入的 Copilot 模型。
- 新增 `vscode`、`copilot-cli`、`auto` Provider；CLI 作為可在 VS Code 關閉時使用的替代方式。
- 以本機 JSON 請求／回應檔案及 heartbeat 連接托盤程式與 Bridge。
- AutoHotkey UI 改為 Windows PowerShell／WinForms，利用剪貼簿監聽偵測 Ctrl+C、Ctrl+C。
- SQLite 歷史改為 `%LOCALAPPDATA%\LangHelper\history.jsonl`。
- 移除 Azure CLI、Entra token 快取與 Azure endpoint／登入設定需求。
- 新增安裝腳本及 CMD 啟動器；更新 CI 與發布打包方式。

依據：上游 commit `021425b`；Bridge manifest `2.0.0`。

### 2026-08-31：同版本後續修正

- 修正 TextBox 更新與捲動，避免前一次較長文字的畫面殘留。
- 調整 prompt reminder，只要求已啟用功能的輸出段落，避免雙語功能誤帶潤飾要求。
- 加入對應的 CI 檢查。

依據：上游 commit `42906b4`；統一歸入 `2.0.0`，不另外編為 `2.0.1`。

## 1.5.0 — 2026-08-02～2026-08-03：Foundry 遷移與可靠性修正

- 原 GitHub Models 後端改為 Azure AI Foundry chat completions。
- 採用 Entra ID，透過 Azure CLI 取得 token，並以 Windows DPAPI 加密快取。
- 模型選單改由 INI 的 deployment 清單提供，不假設 Azure 已部署固定模型。
- 改善未受信任輸入、歷史搜尋 wildcard escaping、日誌設定遮蔽及暫存檔隔離。
- 同步多個視窗的模型選擇，降低同時翻譯時資料互相覆蓋的風險。
- 本機 INI 不再追蹤，改提供共用範本；加強 AutoHotkey 驗證與發布檢查。
- 上游於 2026-08-03 合併此階段變更。

依據：commits `0795872`、`d8a7885`、`112d0c3`、`31dc2e2`、`68db25e`；上游合併 commit `5ca4b0a`。

## 1.2.0 — 2026-07-17：開機啟動選項

- 新增隨 Windows 啟動的切換功能。

依據：commit `8869040`。

## 1.1.0 — 2026-07-10～2026-07-16：外部 prompt 與進階 UI

- 支援外部 skill／prompt 檔案，包含 raw prompt 模式。
- 翻譯結果分為主文與 Notes／回譯。
- 加入單／多視窗及打字自動翻譯切換。
- 加入歷史刪除功能，修正後合併至上游。

依據：commits `bf86411`、`82f251d`；上游合併 commit `1203eff`。

## 1.0.0 — 2026-07-10

- 第一個有 Git tag 的版本：`v1.0.0`。
- 使用 AutoHotkey 前端、PowerShell 後端與 GitHub Models CLI。
- 支援模組化 prompt、功能設定、模型選擇與翻譯歷史。
- 新增 CI 自動驗證與 tag 驅動的發布流程，包含 ZIP 打包及 SHA-256 校驗。

依據：tag `v1.0.0` 指向 commit `c1a72d9`。

## 0.2.0 — 2026-07-09：翻譯歷史

- 新增可搜尋的翻譯歷史與 SQLite 儲存。
- 將本機 SQLite 資料庫排除於版本控制之外。

依據：commits `9062d16`、`7bc203a`、`0515c4f`。

## 0.1.0 — 2026-06-17～2026-06-18：初始版本

- 建立 Ctrl+C、Ctrl+C 剪貼簿翻譯流程。
- 以 AutoHotkey UI、PowerShell 及 GitHub Models 組合翻譯。
- 改善單視窗重用、介面布局、狀態色彩與即時字數顯示。
- 加入 GitHub Models 前置檢查與設定保存。

依據：commits `16beacd`、`c0450f6`、`7c5a52d`、`f5750d4`。
