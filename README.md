# LangHelper

**Version 2.1.0** | English | [繁體中文](README.zh-tw.md)

A DeepL-style **Ctrl+C, Ctrl+C** clipboard translator for Windows, powered by a
modular [prompt.md](prompt.md) and — by default — **the GitHub Copilot seat you
already have**. Independent four-panel windows let you edit the source, keep
the original clipboard snapshot, and view the translation separately from
notes. Choose a provider/model and re-translate manually; typing or changing
features does not automatically send a request.

Defaults: VS Code, Sonnet 5.5, multiple windows and automatic copying of the
main translation. No AutoHotkey, SQLite or Azure setup is required.

See [CHANGELOG.md](CHANGELOG.md) for version history and major changes.

## Install

The installer copies the bundled Bridge into your VS Code user extensions
folder; no extension build is required.

```powershell
cd C:\path\to\LangHelper
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -NoStartup
```

`install.ps1` copies the bridge extension into `~\.vscode\extensions`, creates
`langhelper.ini` from the template, and registers LangHelper to start with
Windows when run **without** `-NoStartup`. The command above skips adding or
changing the startup entry; it does not remove an existing one. An existing
INI is kept unchanged, so review it when upgrading from the Foundry version.
`-Uninstall` removes the Bridge and startup entry, but keeps local settings,
history and logs.

Then:

1. Press **Ctrl+Shift+P**, enter **Developer: Reload Window**, and press Enter.
   On upgrade, do this in **all** VS Code windows that loaded an old Bridge.
2. Run the command **LangHelper: Test Copilot Connection** once and approve the
   permission prompt.
3. Double-click [LangHelper.cmd](LangHelper.cmd). A green "H" appears in the tray.
4. Select text anywhere in Windows and press **Ctrl+C, Ctrl+C**.

### Requirements

| | |
|---|---|
| Windows PowerShell 5.1 | Ships with Windows. |
| VS Code + GitHub Copilot | For `vscode`. Model availability, quota and extension access depend on your account and organization. |
| GitHub Copilot CLI *(optional)* | Only for the `copilot-cli` fallback, which works with VS Code closed. |

```
Ctrl+C, Ctrl+C
   │
   ▼
langhelper-tray.ps1  ──WM_CLIPBOARDUPDATE ×2 + Ctrl held──►  translator window
       │
       └── trigger / Re-translate ──►  langhelper.ps1
                                    │  loads prompt.md or PromptFile
                                    │  assembles features for modular prompts only
                                    │  injects <clipboard>…</clipboard>
                                    ▼
                           %LOCALAPPDATA%\LangHelper\bridge\requests\*.json
                                    │
                                    ▼
                        LangHelper Bridge (VS Code extension)
                                    │  vscode.lm.selectChatModels({vendor:'copilot'})
                                    ▼
                           bridge\responses\*.json
                                    │
                                    ▼
                             result panel + clipboard
```

## Backends

Set `Provider=` in `langhelper.ini`, or switch it from the tray menu.

| Provider | Behavior | Usage | Needs |
|---|---|---|---|
| `vscode` *(default)* | Direct Language Model API request, no CLI fallback | Copilot plan/model limits apply | Running VS Code with the Bridge installed and authorized |
| `copilot-cli` | Noninteractive CLI request, usually more overhead | CLI usage and account limits apply | Installed, signed-in Copilot CLI and an explicit CLI model ID |
| `auto` | Tries the provider suggested by the heartbeat, then the other on failure | Depends on the provider that answers | Compatible model selection and a working provider |

VS Code is recommended for everyday use. CLI has additional agent overhead;
speed and usage depend on the model, input and account limits.

The VS Code provider does **not** create a Copilot Chat / Agent window
conversation. Results appear in LangHelper; **LangHelper: Show Bridge Log**
shows request status/model IDs, while JSONL history stores successful
translations. The CLI provider does not create a VS Code chat either.

The UI reports the provider that answered and any fallback. Model IDs can
differ between providers.

## Files

| File | Role |
|---|---|
| [prompt.md](prompt.md) | LLM prompt spec — Core block + every `[FEATURE: NAME]` block. Edit freely; the backend re-reads it on every call. |
| [langhelper-tray.ps1](langhelper-tray.ps1) | Tray icon, double-copy detection and independent four-panel translation windows. Windows PowerShell + WinForms. |
| [langhelper-common.ps1](langhelper-common.ps1) | Shared INI validation, prompt inspection, result splitting and bridge transport. |
| [LangHelper.cmd](LangHelper.cmd) | Launches the tray app windowless. |
| [langhelper.ps1](langhelper.ps1) | Assembles the prompt and sends it to the selected provider (`vscode` / `copilot-cli`). |
| [vscode-extension/](vscode-extension) | LangHelper Bridge — answers requests with `vscode.lm`, the Copilot models VS Code already has. Plain CommonJS, no build step. |
| [install.ps1](install.ps1) | Installs the bridge extension, seeds `langhelper.ini`, and toggles start-with-Windows. |
| [langhelper.ini.example](langhelper.ini.example) | Tracked template for `langhelper.ini`. |
| `langhelper.ini` | Your local settings. Git-ignored; the tray app rewrites it as you change options. |
| `logs/langhelper_YYYYMM.log` | Auto-created. One file per month; the profile path is collapsed to `%USERPROFILE%`. |
| `%LOCALAPPDATA%\LangHelper\` | Auto-created. `history.jsonl`, `last-result.txt`, and the `bridge\` folder shared with the extension. |

## Run the backend directly

```powershell
"早安" | Out-File -Encoding UTF8 -NoNewline "$env:TEMP\lh_in.txt"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\langhelper.ps1 `
    -Provider vscode -Model claude-sonnet-5.5 `
    -InputFile "$env:TEMP\lh_in.txt" -OutputFile "$env:TEMP\lh_out.txt" -Verbose
Get-Content "$env:TEMP\lh_out.txt" -Raw
```

This makes a real Copilot request using the bundled prompt. The backend script
does **not** read `langhelper.ini`: pass `-PromptFile`, `-Features` and `-Model`
explicitly to reproduce the tray settings. `-Verbose` prints which provider
answered; `-PassThru` returns provider/model metadata as well as writing the
output file. Add `-DryRun` to inspect the assembled prompt without a model call.

## Optional: Copilot CLI

So translations keep working with VS Code closed:

```powershell
npm install -g @github/copilot --registry https://packagefeedproxy.microsoft.io/npm/
copilot            # sign in once, then /exit
```

This is **not offline translation**: CLI still needs internet and its own
Copilot sign-in. On Microsoft-managed devices, the install command uses CFS
because public package registries are blocked.

In a translation window, choose `copilot-cli`, enter a CLI model ID (check
`/model` in the CLI), and click **Re-translate**. Switching the tray default to
CLI clears `Model` to avoid carrying a VS Code-only ID into CLI; enter a model
and use **Save as defaults**. `auto` can attempt CLI fallback, but its UI catalog
comes from VS Code, so configure explicit CLI mode for use with VS Code closed.

## Auto-start on login

`install.ps1` writes a `LangHelper` entry under
`HKCU:\Software\Microsoft\Windows\CurrentVersion\Run` pointing at
[LangHelper.cmd](LangHelper.cmd). Pass `-NoStartup` to skip it, or
`-Uninstall` to remove it along with the bridge extension.

## Daily use

1. Launch [LangHelper.cmd](LangHelper.cmd). A green "H" appears in the tray.
2. Select any text anywhere in Windows → press **Ctrl+C, Ctrl+C**.
3. The **translator window** opens:
   - **Source** is editable; typing never sends a translation automatically.
   - **Original clipboard snapshot** stays unchanged when Source is edited.
   - **Translation** contains the first fenced block (or the first Markdown
     section body); **Notes / back-translation** contains the remaining output.
   - Select a **Provider** and **Model**, then click **Re-translate** (Alt+R).
     **Refresh models** queries VS Code without sending a completion.
     Changing Provider cancels that window's current translation. Changing the
     model or features takes effect on the next manual translation.
   - **Configure features** applies to modular prompts only. Raw external prompts
     show "使用外部 prompt，Features 不適用" and disable feature configuration.
   - The status shows live elapsed time, actual provider/model and fallback.
   - Every successful result is appended to
     `%LOCALAPPDATA%\LangHelper\history.jsonl`, including model and elapsed time.
4. **Copy result** (Alt+C) copies only Translation, not Notes.
   `AutoCopyResult=1` does this automatically after success. With multiple
   windows, the last successful completion overwrites the clipboard.
   **Esc** closes this window and cancels its job; the tray keeps running.

`SingleWindow=0` (default) creates a new window per trigger. Each window has its
own source, model selection and job. `SingleWindow=1` reuses the most recent
window. Provider/feature changes in one window do not change other windows.
**Save as defaults** persists the current window's provider/model/features for
new windows. Tray **Reload config (new windows)** does not disturb existing jobs.

Launch with [LangHelper.cmd](LangHelper.cmd), or:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\langhelper-tray.ps1
```

A launch from PowerShell 7 is redirected to Windows PowerShell 5.1 to avoid
WinForms compilation differences. To restart, choose tray **Exit**, then launch
[LangHelper.cmd](LangHelper.cmd) again. Closing a translation window is not the
same as exiting the tray application.

### How the trigger works

There is no keyboard hook. The tray app registers a Win32 clipboard listener
(`AddClipboardFormatListener`) and treats *two clipboard updates inside
`DoubleCopyMs`, with Ctrl still held* as the trigger. The Ctrl check is what
keeps apps that write the clipboard twice on their own from opening the window
by accident.

## Features (defined in [prompt.md](prompt.md))

| Tag | What it does |
|---|---|
| `POLISH` | Adds `## Polished (English)` with a professional rewrite. |
| `BILINGUAL_EN_ZHTW` | Forces both `## English` and `## 繁體中文 (zh-TW)` sections. Combines with POLISH to also produce polished versions of each. |
| `GLOSSARY` | 3–8 key terms with usage notes. |
| `TONE_VARIANTS` | Formal / Friendly / Concise rewrites. |
| `REPLY` | Two reply drafts (short + detailed). |
| `SUMMARY` | TL;DR (+ key points if source is long). |
| `TECHNICAL` | Preserves code, identifiers, paths, error messages. |
| `BACK_TRANSLATE` | Back-translation sanity check + drift notes. |
| `ROMANIZE` | Pinyin / Romaji / Revised Romanization for CJK. |

> **Note — external prompt files disable features.** If `langhelper.ini` sets a
> `PromptFile=` that points to a file without the recognized fenced `## Core`
> block containing the clipboard placeholder (e.g. a
> `SKILL.md` / `TeamsPrompt.md`), LangHelper runs in **raw/skill mode**: the
> whole file is used verbatim and the **Features selection is ignored**. Clear
> `PromptFile=` to return to the modular [prompt.md](prompt.md) where the
> feature checkboxes take effect.

## Settings (`langhelper.ini`)

`install.ps1` creates `langhelper.ini`; to do it by hand:

```powershell
Copy-Item langhelper.ini.example langhelper.ini
```

Every key has a built-in default. Invalid settings produce an explicit error.
Edit settings by hand, then tray → **Reload config (new windows)**.
**Save as defaults** preserves the comments and layout of the INI template.

| Key | Values | Default | What it does |
|---|---|---|---|
| `Provider` | `auto` / `vscode` / `copilot-cli` | `vscode` | Provider for new windows. |
| `Features` | comma-separated tags | `POLISH,BILINGUAL_EN_ZHTW` | Enabled blocks for modular prompts only; raw prompts ignore this setting. |
| `Model` | one model ID/family or empty | `claude-sonnet-5.5` | Explicit Sonnet 5.5 selection. An unavailable VS Code model is an error, not a silent substitution. CLI requires an explicit ID in its window. |
| `DoubleCopyMs` | milliseconds | `700` | How close together the two clipboard updates must be to count as a double copy. |
| `MinChars` / `MaxChars` | positive integers | `1` / `8000` | Double-copy input below `MinChars` is ignored; above `MaxChars` it is truncated with a warning. These are trigger limits, not limits on manually edited Source or the tray Translate command. |
| `TimeoutSec` | seconds, 1–3600 | `120` | Translation timeout for either provider. |
| `AutoCopyResult` | `0` / `1` | `1` | Automatically copies only the main translation. |
| `AlwaysOnTop` | `0` / `1` | `1` | Keeps the translator window above other windows. |
| `PromptFile` | file path or empty | *(empty)* | External prompt/spec. Without a recognized modular Core block it runs raw/skill mode and **ignores `Features`**. |
| `SingleWindow` | `0` / `1` | `0` | Multiple independent windows, or reuse the most recent window. |

Azure settings (`Endpoint`, `EntraSubscription`, `EntraTenant`, `AzureConfigDir`,
`ReasoningEffort`), `AutoTranslate`, `SaveHistory`, `ShowPicker` and `ShowPreview`
are no longer used and are removed when settings are saved. Successful results
always append to JSONL history; there is no SQLite dependency. A specified
missing `PromptFile` is an error rather than falling back to the bundled prompt.
Personal prompt paths belong in the ignored local INI, not the shared template.

LangHelper does not maintain its own credential/token cache: `vscode` uses
VS Code's Copilot authentication and `copilot-cli` uses the CLI's. Those hosts
manage their own sign-in state.

### External prompt example

Set a personal prompt path in the ignored local INI:

```ini
[LangHelper]
Provider=vscode
Model=claude-sonnet-5.5
PromptFile=C:\path\to\TeamsPrompt.md
AutoCopyResult=1
SingleWindow=0
```

Save, then choose **Reload config (new windows)** and open a new window.
Existing windows retain their prompt/settings. In raw mode, the file is used
as instructions, leading YAML frontmatter is stripped, and clipboard text is
added as data. Referenced sibling files are not loaded automatically.

## Choosing a model

The default request is Sonnet 5.5 (`claude-sonnet-5.5`). Availability depends on
your Copilot account and organization. The VS Code dropdown displays the actual
catalog returned by `vscode.lm.selectChatModels({vendor:'copilot'})`; IDs, names
and families are not guessed. If Sonnet 5.5 is unavailable, choose an available
model explicitly. The status reports the returned model ID.

**Provider default** sends no explicit model and uses the extension's
`langhelper.model` setting (also Sonnet 5.5 by default). An unavailable explicit
extension default is still an error. Clearing that VS Code setting allows the
first available model.

CLI has no verified machine-readable catalog in the installed version. Its
model field accepts a manually entered CLI ID, never a copied VS Code list.
CLI results label the model as **requested, not verified**. Use the CLI's `/model`
command to check its offerings. `auto` uses the VS Code catalog and may fail if
the same selected ID is not supported by CLI; failures are reported, not hidden.

## Tray menu

- **Open translator window** — editable blank window, without spending quota.
  Double-clicking the tray icon does this too.
- **Translate clipboard now** — translates without the hotkey.
- **Provider (new windows) ▸** — changes the default backend; saved to the INI.
- **Show last result** — re-opens the previous translation.
- **Open history** — opens `%LOCALAPPDATA%\LangHelper\history.jsonl`.
- **Open log** — opens this month's `logs/langhelper_YYYYMM.log`.
- **Edit langhelper.ini** / **Reload config (new windows)**.
- **Exit**.

## Smoke test (no API spend)

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

You should see the Core block, both FEATURE blocks, and the clipboard text
wrapped in `<clipboard>…</clipboard>`.

Drop `-DryRun` and add `-Verbose` to make the real call and see which provider
answered.

## How features are wired

Both the backend and the tray app discover features by scanning the markdown for
`[FEATURE: NAME]`, so adding one takes a single edit:

1. Add a new fenced block to [prompt.md](prompt.md) starting with
   `[FEATURE: MY_FEATURE]`.
2. Tray → **Reload config (new windows)**.

Open a new window and use **Configure features** to see the new checkbox.

## Regression tests (no model spend)

```powershell
node --test .\tests\bridge.test.js
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\ui.tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\backend.tests.ps1
```

These test model discovery/selection/cancellation with a mocked VS Code API,
and real WinForms controls with a fake backend. They do not authenticate or
send prompts to Copilot.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Bridge offline / stale / model lookup failed | Install the current Bridge with `install.ps1 -NoStartup`, reload VS Code, then **LangHelper: Test Copilot Connection**. |
| Requested model unavailable | Refresh the model list and choose an available model. Sonnet 5.5 is not guaranteed for every account. No silent model substitution is performed. |
| `VS Code has not been granted permission to use Copilot` | Run **LangHelper: Test Copilot Connection** and approve the prompt. It only asks once. |
| `No GitHub Copilot language model is available` | Sign in to Copilot in VS Code. **LangHelper: Show Bridge Log** has the detail. |
| Translations suddenly take 30 s | The bridge went down and `auto` fell back to `copilot-cli`. Run with `-Verbose` to confirm, then reload VS Code. |
| The result is the source text, unchanged | For a modular prompt, enable `BILINGUAL_EN_ZHTW` and re-translate. For a raw external prompt, adjust that prompt instead; Features are ignored. |
| Ctrl+C, Ctrl+C does nothing | Copy twice *faster* than `DoubleCopyMs`, and keep Ctrl held for the second press — the Ctrl check is what filters out apps that write the clipboard on their own. Raise `DoubleCopyMs` if you need more slack. |
| Two tray icons | Only one instance can run; the second exits with a message. Check `LangHelper.cmd` is not also in the Startup folder from an old install. |
| Empty / garbled CJK output | Confirm [prompt.md](prompt.md) is saved as UTF-8 (no BOM). |
| Features do not apply / expected modular prompt runs raw | Check the fenced `## Core` block and clipboard placeholder, or clear `PromptFile` to use the bundled modular prompt. |
| Need to see what happened | Tray → **Open log**, or VS Code → **LangHelper: Show Bridge Log**. Review error content before sharing logs. |

## Privacy

JSONL history contains source text and full results. Logs replace the Windows
profile path with `%USERPROFILE%`, but errors can include other paths or content.
Review both before sharing. No automatic history or log retention is provided.

## Publishing a release (maintainers)

Pull requests and pushes to `main` run the CI workflow, which validates
PowerShell syntax, the bridge extension, prompt assembly, Bridge regression
tests and Windows PowerShell 5.1 UI/backend tests.

To publish, create and push a semantic-version tag from a tested `main` commit:

```powershell
git switch main
git pull --ff-only
git tag -a v2.1.0 -m "LangHelper v2.1.0"
git push origin v2.1.0
```

The release workflow validates the tag, re-runs the checks, packages the scripts
and the bridge extension, generates a SHA-256 checksum, and creates GitHub
release notes. Pre-release tags such as `v2.1.0-beta.1` are automatically marked
as GitHub pre-releases.
