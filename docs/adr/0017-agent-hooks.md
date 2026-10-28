# ADR-0017：用 hook 取得 AI 的確切狀態

- 狀態：**已接受**（2026-10-28；Fable 5.1 對抗式審查 12 項全部處理，見 PR）
- 日期：2026-10-28
- 相關：[ADR-0016](0016-mascot-character.md)（角色；本 ADR 取代它「看紀錄資料夾修改時間判斷工作中」的作法，沒接 hook 時才退回）、[ADR-0009](0009-local-history-and-token-stats.md)（本機紀錄）、[ADR-0015](0015-windows-desktop-app.md)（Windows 版，第 4 部分接上同一套）
- 設計來源：工作資料夾 `design/mascot2-TASK.md` 第 1、2 部分；`design/mascot/RESEARCH-2026-10-28.md`

## 背景

ADR-0016 的角色只能從 `~/.claude/projects`、`~/.codex/sessions` 的修改時間猜「AI 在工作」：分不出「等你批准」「做完了」「出錯了」，也不知道有幾個工作階段。使用者要的是瀏海直接告訴他「哪個 AI 需要你」。

本 ADR 決定**怎麼拿到狀態**（hook、傳送、安裝、狀態規則）；瀏海與選單列**怎麼顯示**（需要你的提示、完成通知、工作階段列表）是工作資料夾 `design/mascot2-TASK.md` 第 2 部分的另一個 PR。這個 PR 只把工作中與睡覺接上角色。

Claude Code 與 Codex 都有官方的 hook：在固定的時間點執行一個指令，事件內容以 JSON 從標準輸入傳入。這是唯一不讀對話紀錄就能知道確切狀態的方法。

### 官方文件（2026-10-28 查閱，不憑記憶）

**Claude Code**（code.claude.com/docs/en/hooks）

- 設定：`~/.claude/settings.json` 的 `hooks.<事件>` 是 matcher 群組陣列，每組 `{"matcher": "...", "hooks": [{"type": "command", "command": "...", "timeout": 秒}]}`；沒有 `args` 時指令經過 shell。
- 共同欄位：`session_id`、`transcript_path`、`cwd`、`hook_event_name`、`permission_mode` 等。
- 事件（本 ADR 用到的）：`SessionStart`（`source`：startup／resume／clear／compact／fork）、`SessionEnd`（`reason`：clear／resume／logout／prompt_input_exit／other）、`UserPromptSubmit`（含 `prompt`）、`PreToolUse`／`PostToolUse`／`PostToolUseFailure`（含 `tool_name`、`tool_input`、`tool_response`）、`PermissionRequest`、`Notification`（`notification_type`：permission_prompt、idle_prompt、elicitation_dialog、agent_needs_input 等，另有 `message`、`title`）、`Stop`（含 `last_assistant_message`）、`StopFailure`（`error`：rate_limit、overloaded、authentication_failed…）、`SubagentStop`、`PreCompact`。
- 標準輸出：`UserPromptSubmit`、`SessionStart` 等事件的標準輸出**會加進 Claude 的上下文**；結束碼 2 會擋住提示或工具。使用者中斷時**不會**觸發 `Stop`。
- 互動模式下，在使用者接受資料夾信任前不會執行任何 hook。

**Codex**（learn.chatgpt.com/docs/hooks，原 developers.openai.com/codex/hooks）

- 預設開啟（`[features] hooks = false` 可關；`codex_hooks` 是舊名）。設定可放 `~/.codex/hooks.json` 或 `~/.codex/config.toml` 的 `[hooks]`，多個來源會**疊加**、不互相覆蓋。JSON 形狀與 Claude Code 相同。
- 事件：`SessionStart`、`SessionEnd`、`SubagentStart`、`SubagentStop`、`PreToolUse`、`PermissionRequest`、`PostToolUse`、`PreCompact`、`PostCompact`、`UserPromptSubmit`、`Stop`、`Interrupt`（**沒有** Notification，也沒有 API 錯誤事件）。共同欄位多一個 `model`，與回合有關的事件有 `turn_id`。
- `Stop`、`SubagentStop` 結束碼 0 時若有輸出必須是 JSON；**沒有輸出算成功**。`SessionEnd`、`Interrupt` 的逾時預設 1 秒、最多 3 秒。
- **非受管理的 hook 要先在 Codex 的 `/hooks` 審查並信任才會執行**，信任綁在 hook 內容的雜湊，改了要重新信任。

## 決定

### 1. hook 程式（`aum-hook`）

- Swift 命令列程式，隨 App 打包在 `AI Usage Monitor.app/Contents/Helpers/aum-hook`，用 `Foundation` 與 `CryptoKit`，沒有其他相依。啟動到結束目標 < 50 ms（量測方法與數字見 PR）。
- 第一個參數是 AI（`claude` 或 `codex`），從標準輸入讀事件（最多 1 MB，超過就丟掉）。
- **只取**下列欄位，其餘立刻丟掉、不存、不轉傳：
  - AI（來自參數，不信任輸入）；
  - 事件類型（`hook_event_name`，只接受白名單內的名稱）；
  - 需要你的種類（`need`）：Claude 的 `notification_type` 對到 `permission`（permission_prompt）、`question`（elicitation_dialog、agent_needs_input）、`idle`（idle_prompt）；`PreToolUse` 的工具若是 `AskUserQuestion` 記為 `question`、`ExitPlanMode` 記為 `plan`（**只傳種類，不傳工具名稱**）；`PermissionRequest` 記為 `permission`。Codex 沒有 Notification，官方文件也沒說 `request_user_input` 會觸發 PreToolUse：程式照樣認這個名字（對不到就當一般工具），但 Codex 的「問你問題」目前**沒有可靠的訊號**，列在實機確認清單；
  - 是否來自子代理（`sub`，輸入有 `agent_id` 時為 true；只記有沒有，不記 ID 或代理種類）；
  - 工作階段 ID：`SHA-256(本機鹽 ‖ session_id)` 的前 16 個十六進位字元；原始 ID 不離開 hook；
  - 時間（hook 自己的時鐘，毫秒）；
  - 工作目錄的**資料夾名稱**（`cwd` 的最後一段，去掉控制字元、最多 48 字）：只給畫面用，App 只放在記憶體，不寫磁碟、不寫日誌、不上傳。
- `prompt`、`tool_input`、`tool_response`、`message`、`last_assistant_message`、`transcript_path`、完整的 `cwd` **一律不讀進任何變數以外的地方**：解析後只挑上面幾個欄位。
- **標準輸出與標準錯誤都不印任何東西**；任何錯誤（解析失敗、鹽不存在、socket 不存在、送不出去）都 exit 0，不擋 AI。
- App 沒在跑（鹽或 socket 不存在、連線被拒）時立刻結束；連線與送出各有 100 ms 上限，不會卡住 AI。
- 設定檔裡的指令結尾是 `2>/dev/null || true`：App 被移動或刪掉後，找不到程式時也沒有輸出、結束碼 0（見「影響」）。
- 不連網路：只連本機 Unix socket。
- 程式本身：關掉標準輸出與標準錯誤（導到 `/dev/null`）、忽略 SIGPIPE、`alarm(1)` 到時直接 `_exit(0)`；標準輸入是終端機時不等。
- 實測（`scripts/measure-hook-latency.sh`，Debug 版、100 次）：App 沒在跑時中位數約 4 ms，App 在聽時約 4.5 ms，最大都在 10 ms 內（偶爾一次 40 ms 左右）。

### 2. 傳送：Unix socket

- 位置：`~/Library/Application Support/AIUsageMonitor/agent/hook.sock`。`agent/` 資料夾權限 0700，socket 0600；鹽 `agent/salt`（32 個隨機位元組）0600，App 啟動時建立。測試與截圖時這些都在暫存資料夾（`AI_USAGE_MONITOR_HOME`）。
- 每次連線送一行 JSON（最多 1 KB）：`{"v":1,"ai":"claude","ev":"Stop","need":"","sub":false,"sid":"0123456789abcdef","t":1761650000000,"dir":"my-project"}`，送完就關。`ev` 是官方的事件名稱。App 只收**標準寫法**：解析後重新編碼必須和收到的一字不差（鍵的順序、沒有空白、整數），`1.0`、`1e3`、重複鍵都不收，Swift 與 C# 一樣嚴格。
- App 端：只接受同一個使用者（`getpeereid` 的 uid 與自己相同）的連線；每個連線最多讀 1 KB、250 ms（連線改回阻塞模式，由讀取逾時把關）；格式不對、欄位不在白名單、版本不認得就**丟掉**，不當機、不寫日誌內容（只計數）。接受連線後每條各自在並行佇列讀（同時最多 32 條，再多的直接關掉），backlog 128；解析好的事件才回到主執行緒。
- 每秒最多處理 40 個「只代表還在跑」的事件（一般工具的前後、子代理、壓縮），其餘丟掉：塞假事件不會吃滿 CPU。決定狀態的事件（開始、結束、送出提示、需要你、通知、停止、出錯、中斷）稀少又關鍵，**永遠不丟**——子代理多時正常使用一秒也可能超過 40 個，丟掉 Stop 會讓狀態卡在工作中。
- App 結束（含被 SIGTERM 終止）時移除 socket；hook 看到沒有 socket 或連線被拒就立刻結束。
- 最壞情況：同一使用者底下的其他程式可以送假事件，讓角色顯示錯的狀態（例如假的「需要你」）；或開很多連線佔滿同時讀取的名額，讓真的事件被關掉（hook 照樣安靜結束，狀態因此過時）。它拿不到任何資料（socket 是單向的，App 不回傳東西），也不能讓 App 去做任何事（沒有批准功能，見「不做」）。同一使用者的程式本來就能直接改 AI 的設定檔，所以不再加防護。

### 3. 安裝與移除

- 設定的「AI 狀態」區塊（瀏海面板之後）有 Claude Code 與 Codex 兩列：按鈕旁邊一直寫著會改的檔案（`~/.claude/settings.json`、`~/.codex/hooks.json`）與加上的事件，按鈕依狀態是「連接」「修好／移除」或「移除」。
- 每個 hook 項目：`{"hooks": [{"type": "command", "command": "'<App>/Contents/Helpers/aum-hook' claude 2>/dev/null || true", "timeout": 3}]}`（不設 matcher；路徑用單引號包起來，經 shell 也安全；逾時 3 秒是 Codex `SessionEnd`、`Interrupt` 的上限）。
- 設定檔是符號連結（例如 dotfiles 管理）時，讀、備份、寫都對連結指向的檔案做：原子寫入會把連結本身換成一般檔案，讀到的權限也會是連結的 0755。
- 修改前先把原檔複製成 `<檔名>.aum-backup-<年月日-時分秒>`（放在真正的檔案旁邊；同一秒第二次加序號，不覆蓋舊備份；建立時就用原檔的權限）；每個設定檔只留最新的 3 份我們的備份（設定檔可能有金鑰，副本不無限累積）。以原子方式寫入並保留原檔權限。檔案不是合法 JSON、或 `hooks` 不是物件時**不改**，只提示。
- **只合併自己的項目**：我們的項目以指令裡的 `Contents/Helpers/aum-hook` 認出；別人的 matcher 群組與 hook 一律保留，同一事件可以和其他瀏海 App 的 hook 共存；重複按「連接」不會加第二份。保留原本的鍵順序（自己寫的有序 JSON 解析器），只動 `hooks` 底下我們的項目。
- 移除只刪自己的項目；某個事件因此變空時刪掉該事件鍵，`hooks` 變空時刪掉 `hooks` 鍵。
- 偵測：App 啟動與打開設定時檢查——hook 指向的路徑不是目前的 App（App 被移動）或缺事件時，顯示「需要修好」與一鍵修好按鈕。
- Codex：寫入後提示「在 Codex 裡執行 `/hooks` 信任這個 hook」；`config.toml` 有 `[features] hooks = false` 時提示 hook 被關掉了。
- 測試全部用暫存資料夾裡的假設定檔；安裝邏輯接受設定檔路徑當參數，不碰真的 `~/.claude`、`~/.codex`。

### 4. 每個工作階段的狀態與彙總（共用邏輯）

狀態：

| 狀態 | 進入的事件 |
|---|---|
| 工作中 `working` | `UserPromptSubmit`、`PreToolUse`（一般工具）、`PostToolUse`、`PostToolUseFailure`；`SubagentStart`／`SubagentStop`／`PreCompact` 與子代理（`sub`）的工具事件只在工作中或需要你時算工作中，不把完成、等你、出錯改回工作中（主回合 Stop 之後背景子代理還會送事件） |
| 需要你 `needsYou`（附種類：權限／問問題／批准計畫） | `PermissionRequest`；`Notification` 的 permission_prompt、elicitation_dialog、agent_needs_input；`PreToolUse` 的問問題與批准計畫 |
| 完成未看 `done` | `Stop`（從工作中或需要你結束） |
| 出錯 `error` | `StopFailure` |
| 等你下一個指令 `waiting` | `SessionStart`（工作中時不變：回合中途自動壓縮也會送 `source=compact`）；`Interrupt`；看過的 `done`；`Notification` 的 idle_prompt（若原本是工作中） |
| 閒置 `idle` | `waiting` 超過「睡覺」分鐘數（同 ADR-0016 的設定） |

- `SessionEnd` 移除該工作階段。
- **看過**：使用者展開瀏海或點角色時，所有 `done` 變 `waiting`；`error` 看過後也變 `waiting`。
- 太久沒有事件：`working` 超過 20 分鐘沒有事件（例如被使用者中斷，Claude Code 不會送 Stop）變 `waiting`；`needsYou` 超過 60 分鐘沒有事件（例如直接關掉終端機，沒送 SessionEnd）變 `waiting`；任何狀態超過 12 小時沒有事件（AI 當掉）移除。App 有工作階段時每分鐘檢查一次。
- 同時最多記 32 個工作階段，超過時丟掉最久沒事件的（防假事件塞爆記憶體）。
- 彙總（瀏海與角色看的那一個）：**需要你 > 出錯 > 工作中 > 完成未看 > 等你 > 閒置**；同等級取最近的事件。
- 這套規則放在 `UsageKit/AgentSessions.swift` 與 `UsageCore/AgentSessions.cs`，`fixtures/agent/cases.json` → `golden.json` 兩邊跑同一份（同 ADR-0016 的作法）。
- 角色的「工作中」與睡覺（`AgentSessions.activity`）**逐個 AI** 決定：有 hook 工作階段的 AI 照 hook（只有 `working` 算工作中；`needsYou` 算醒著；`done`、`error`、`waiting` 進入後還沒超過睡覺分鐘數算醒著，超過就可以睡——完成未看的標記保留，只是不讓角色一直撐著不睡），沒有的 AI 照 ADR-0016 的修改時間判斷；所有 AI 都閒置才睡。

### 5. 隱私

- 磁碟上只有鹽與 socket；事件只在記憶體。日誌只寫計數（收到幾筆、丟掉幾筆，App 結束時一行），不寫欄位內容；連接失敗的日誌只寫是哪個 AI，不寫路徑。
- 資料夾名稱只給畫面用（展開瀏海的「AI 工作階段」列表）；不進 usage.json、歷史、中繼、日誌，也**不進系統通知**：通知中心會把通知內容存在磁碟上，所以通知只寫哪個 AI、要你做什麼（允許、回答、確認計畫、完成），識別碼是隨機值。
- 工作階段 ID 是加鹽雜湊，換鹽（重裝或刪除 `agent/`）後無法和舊的對應。

### 6. 瀏海上的呈現（mascot2 第 2 部分）

- **需要你**：瀏海外框琥珀色（收合、展開都在，靜止不重畫），角色舉手（新模式 `raise`，優先於工作中與睡覺；收合的迷你角色也舉手）；兩個以上的工作階段時迷你角色旁顯示數量（數字，不是狀態點）。展開時若有需要你的，右邊直接切到「AI 工作階段」分頁：AI、資料夾名稱、狀態文字、多久，需要你的排最前面，最多列 4 個。
- **完成**：一個回合變成 `done` 的那一刻，展開時排隊揮手；收著時瀏海鼓一下、迷你角色揮手（狀態機事件 `cheer`，兩邊 golden）。完成未看、額度正常時角色開心（^ ^），展開或點角色才變回平常。
- **出錯**：角色難過，看過後回到額度的表情。額度偏高、用完、過期的表情優先於「完成未看」的開心，但不優先於出錯。
- **等你下指令**：收合的瀏海每 7 秒沿外框淡淡亮一次（1.6 秒，只在亮的時候每秒重畫 20 次）；設定可關，靜音、勿擾、動畫「關閉」時不亮。
- **系統通知**：需要你超過 N 秒（預設 20）、跑超過 N 分鐘（預設 3；從不在跑進入工作中時記回合開始，需要你之後繼續不算新回合）的回合完成；0 表示關閉。判斷（`AgentSessions.notices`、`nextNoticeCheck`）在共用邏輯並有 golden；App 只去重、照下一次檢查時間排一個計時器，不輪詢。走通知中心（遵守專注模式）；靜音與勿擾時不送也不補送。點通知會展開瀏海並保持展開。
- 動畫程度「簡單」「關閉」時角色姿勢不變（同 ADR-0016），外框、數量與列表照常。

## 不做

- **不在瀏海上批准或拒絕指令。** 理由：(1) 要批准就得讓 hook 等 App 回覆，hook 會變成會卡住 AI 的雙向通道，違反「任何錯誤都不擋 AI」；(2) 同一使用者的任何程式都能連到 socket，批准功能會讓假事件變成假批准，最壞情況從「顯示錯」變成「替你按允許」；(3) Claude Code 與 Codex 自己的權限畫面會顯示完整的指令內容，瀏海為了隱私刻意不拿這些內容，沒有資訊就不該讓人做決定。
- 不讀對話紀錄（`transcript_path`）判斷狀態。
- 不在 hook 裡做網路請求、不寫檔。

## 考慮過的選項

- **繼續只看修改時間**：分不出需要你、完成、出錯，不採用（保留為退回機制）。
- **HTTP hook（Claude Code 的 `type: "http"`）**：要開本機連接埠，任何本機程式（含瀏覽器頁面）都可能連到；Codex 也不支援。不採用。
- **hook 寫檔、App 監看資料夾**：會在磁碟留下事件紀錄，違反隱私底線。不採用。
- **用 shell 腳本當 hook**：啟動要經過 shell、`jq` 不一定有、要自己處理 JSON 跳脫；不如打包一個小程式。
- **Codex 改寫 `config.toml`**：TOML 合併容易弄壞使用者的檔案；`hooks.json` 是官方支援、會和其他來源疊加的位置。（只逐行看 `[features]` 的 `hooks`／`codex_hooks` 是否為 false，用來提示。）
- **用 `JSONSerialization` 改設定檔**：會打亂使用者檔案的鍵順序與格式；自己寫一個保留順序的小解析器（`OrderedJSON`），只動 `hooks` 底下我們的項目。

## 影響

- 使用者要按一次「連接」；Codex 另外要在 `/hooks` 信任一次。
- App 被移動後 hook 指向舊路徑。Claude Code 經 `sh -c` 執行指令，結束碼非 0 也非 2 時會在**對話裡**顯示 hook error 與標準錯誤的第一行（2026-10-28 官方文件），所以指令結尾加上 `2>/dev/null || true`：找不到程式時什麼都不做、不擋 AI，App 下次啟動時顯示「需要修好」。修好會改變指令，Codex 要再到 `/hooks` 信任一次。（考慮過讓指令指向資料夾裡固定位置的符號連結，搬 App 就不必修；但多一個要維護的連結，App 被刪掉時連結也會留著，先不採用。）
- Windows（第 4 部分）用同一套事件、狀態與 golden，傳送改用 Windows 的 AF_UNIX socket 或具名管道（另寫 ADR，尚未寫）。指令**不能**照搬 `'<路徑>' claude`：Claude Code 在 Windows 沒有 Git Bash 時用 PowerShell，這種寫法是語法錯誤；Windows 改用官方的 exec 形式（`"command": "<exe>", "args": ["claude"]`，不經 shell），`isOurs` 也要同時看 `command` 與 `args`。
