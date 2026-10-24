# Windows 收集器（FR-48、ADR-0011）

Windows PC 用和 Mac 相同的 Python 程式（`collector/usage_collector`，只用標準函式庫），以「工作排程器」每 5 分鐘統計這台電腦上 Claude Code 與 Codex CLI 的 Token。平台差異集中在 `collector/usage_collector/system.py`。

- **預設只統計 Token、不收集額度、不上傳任何東西**。額度 % 是整個帳號的數字，Mac 已經在收集（ADR-0011 第 2 節）。
- 統計結果在 `%LOCALAPPDATA%\AIUsageMonitor\history.sqlite3`。要在 Mac 的面板看到這台 PC 的數字，需要第二層（多裝置合併，FR-49）：安裝排程後執行 `windows\set-tier2.ps1`，見 [docs/tier2-setup.md](tier2-setup.md)。
- 不讀 `auth.json`、`.credentials.json`、瀏覽器 cookie；對話紀錄只透過白名單欄位讀取（和 Mac 相同，README「隱私與安全」）。

## 需要

- Windows 10 或 11
- Python 3.10 以上：從 [python.org](https://www.python.org/downloads/windows/) 安裝，勾選「py launcher」；安裝完成的畫面按「Disable path length limit」（見「限制」的長路徑）。Microsoft Store 版的 Python 沒有固定的 `pythonw.exe` 路徑，不建議。
- Claude Code 或 Codex CLI 在這台電腦上用過（有對話紀錄）

## 安裝

1. 取得這個 repo（`git clone` 或下載 ZIP 解壓縮），位置之後不要移動（排程會記住路徑）。
2. 開啟 PowerShell（不需要系統管理員），執行：

   ```powershell
   cd <repo>\collector
   powershell -ExecutionPolicy Bypass -File windows\install-task.ps1
   ```

   - 建立排程 `\AIUsageMonitor\Collector`：每 5 分鐘、登入時各執行一次，只在你登入時以你的身分執行，不存密碼、不提高權限。
   - 以 `pythonw.exe -X utf8 -m usage_collector --tokens-only` 執行（不跳出視窗；檔案一律 UTF-8），收集器把自己降到「低於正常」的優先順序。
   - 日誌：`%LOCALAPPDATA%\AIUsageMonitor\collector.log`。
3. 第一次會整理過去的紀錄，每次最多讀 64 MB 或 15 秒，紀錄多時要跑幾輪（每 5 分鐘一輪）。

### 選項

| 參數 | 作用 |
|---|---|
| `-Python C:\…\python.exe` | 指定 Python（預設：`py -3` 找到的，再退回 PATH 的 `python`） |
| `-WithQuota` | 另外收集額度（執行 `claude -p /usage`、`codex app-server`），**只寫在本機** `usage.json`、不上傳。安裝時找到的 `claude`／`codex` 路徑寫進 `config.json`。Windows 的 Python 沒有時區資料庫時，Claude 額度的重置時間以本機時區解讀（可另裝 `py -m pip install tzdata` 取得精確時區） |

再執行一次 `install-task.ps1` 會以新的設定取代舊的排程。

### 紀錄資料夾

預設 `%USERPROFILE%\.claude` 與 `%USERPROFILE%\.codex`。改過位置時，環境變數 `CLAUDE_CONFIG_DIR`、`CODEX_HOME`，或 `%LOCALAPPDATA%\AIUsageMonitor\config.json` 的 `claude_config_dir`、`codex_home` 優先（同 ADR-0009 第 3 節）。

## 移除

```powershell
powershell -ExecutionPolicy Bypass -File windows\uninstall-task.ps1
```

只移除排程；`%LOCALAPPDATA%\AIUsageMonitor` 保留，不需要時自行刪除。

## 在 PC 上手動確認（第一次安裝後）

| # | 步驟 | 預期 |
|---|---|---|
| W-1 | 執行 `install-task.ps1` | 印出「已安裝排程」；沒有紅字錯誤 |
| W-2 | 「工作排程器」→「工作排程器程式庫」→ `AIUsageMonitor` → `Collector` | 觸發程序：每 5 分鐘＋登入時；動作：`pythonw.exe`，引數含 `--tokens-only` |
| W-3 | 等 5 分鐘，或在工作上按右鍵「執行」 | 「上次執行結果」為「作業順利完成 (0x0)」；執行時沒有跳出任何視窗 |
| W-4 | 開 `%LOCALAPPDATA%\AIUsageMonitor` | 有 `history.sqlite3`；`collector.log` 沒有錯誤（可能是空的） |
| W-5 | 檢查統計（PowerShell）：`py -X utf8 -c "import sqlite3,os; c=sqlite3.connect(os.path.expandvars(r'%LOCALAPPDATA%\AIUsageMonitor\history.sqlite3')); print(c.execute('select provider, sum(input_tokens+output_tokens) from daily_tokens group by provider').fetchall()); print(dict(c.execute('select key, value from meta where key like ?', ('first_scan%',)).fetchall()))"` | 用過的服務有數字；首次掃描完成後 `first_scan_done` 為 `1` |
| W-6 | 用 Claude Code 或 Codex CLI 做一次對話，等下一輪 | W-5 的數字增加 |
| W-7 | 「工作管理員」→「詳細資料」，排程執行時看 `pythonw.exe` | 「基本優先順序」為「低於正常」 |
| W-8 | 帳號名稱含中文的使用者（若有）重複 W-1～W-5 | 同上（路徑與日誌以 UTF-8 處理） |
| W-9 | （選用）`install-task.ps1 -WithQuota` | `usage.json` 出現且有額度；`collector.log` 沒有錯誤；沒有任何上傳 |
| W-10 | 執行 `uninstall-task.ps1` | 排程消失；資料夾保留 |

## 限制

- 只在使用者登入時執行（不存密碼）；登出或關機時不統計，下次登入後補上新紀錄（讀取位置記在資料庫）。
- 排程的 Python 路徑固定為安裝時找到的那一個；升級 Python（路徑改變）後重新執行 `install-task.ps1`。
- 長路徑：Claude Code 的紀錄路徑包含專案資料夾的完整路徑（`%USERPROFILE%\.claude\projects\<整個專案路徑>\…`），深層的專案很容易超過 260 個字元。沒有開啟 Windows 的長路徑支援（python.org 安裝程式最後的「Disable path length limit」，或群組原則「啟用 Win32 長路徑」）時，這些紀錄檔讀不到、**不會記錄在日誌**，Token 會少算。
- 對話紀錄的符號連結：Windows 版也不跟隨（列舉時略過連結）；Windows 沒有 `O_NOFOLLOW`，開檔時改以「開啟後的檔案和列舉到的是同一個（磁碟區序號＋檔案索引）」確認。
