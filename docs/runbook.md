# 維運 runbook

長期使用時偶爾才會遇到、但做錯會讓數字重複、密鑰外流或資料遺失的情況（[ADR-0014](adr/0014-long-term-operation.md)「使用者的決定」）。每一節都是照順序做的步驟；指令在 repo 根目錄執行。

## 1. 換電腦（D-2）

移轉輔助程式、Time Machine 還原或手動複製會把三樣東西一起搬到新電腦：`history.sqlite3`（含本機的 `device_id` 與上傳進度）、Keychain 裡的寫入密鑰（`AIUsageMonitor-device-key`），以及 `config.json`。沒有第二層（只有一台 Mac）時不必做任何事；有第二層時先決定新電腦要**沿用舊電腦的身分**，還是**另立新身分**。

### 1-1. 沿用同一個身分（一般的換機，建議）

新電腦接手舊電腦的 `device_id` 與過去的數字，中繼上不會多出一台。

1. 新電腦裝好 App（或 `collector/scripts/install-launchd.sh`），等收集器跑過一輪（`~/Library/Logs/AIUsageMonitor/collector.log` 有新的一行）。
2. 舊電腦停止上傳：`collector/scripts/set-tier2.sh --disable`。不再使用舊電腦時，依 [uninstall.md](uninstall.md) 解除安裝，並刪掉它的寫入密鑰：

   ```bash
   security delete-generic-password -s AIUsageMonitor-device-key
   ```

3. 查出這台電腦在中繼上的 `device_id`，換新密鑰（`device_id` 與資料不變，舊密鑰立即失效）：

   ```bash
   scripts/relay-device.sh list
   scripts/relay-device.sh rotate <device_id>
   ```

4. 在新電腦執行 `collector/scripts/set-tier2.sh`，貼上剛才印出的新密鑰與 `READ_TOKEN`。
5. 確認：新電腦的 `(cd collector && python3 -m usage_collector.token_sync status)` 顯示 `upload_status` 為 `ok`；`scripts/relay-device.sh list` 的「最後上傳」在 10 分鐘內更新。

- **不要** `revoke` 這個 `device_id`：新舊電腦用的是同一個身分，撤銷會連新電腦一起停用。
- 新電腦的收集器會發現資料庫是從別台電腦搬來的（硬體指紋不同），在第 4 步之前**自動暫停第二層上傳**，統計卡片顯示「歷史資料是從另一台電腦搬來的，已暫停上傳」；第 4 步的 `set-tier2.sh` 改記新電腦的指紋並恢復。所以搬完之後不會用舊身分互相覆蓋，但要做完第 3、4 步，新電腦的數字才會上傳。
- 舊電腦若忘了停用，換新密鑰後它連續收到兩次 401 就會自己停止上傳。
- 硬體指紋只在第二層第一次上傳時記下：升級到有這個檢查的版本之前就已經搬過的，偵測不到，照上面的步驟處理即可。重灌 Windows 會換掉 MachineGuid，從備份還原資料庫後也會被當成搬來的，同樣重新執行 `set-tier2.ps1` 就恢復。

### 1-2. 新電腦另立身分

新電腦以新名稱出現在裝置切換中（例如舊電腦還要繼續用，或想分開看兩台的數字）。新身分只能從**沒有舊電腦資料**的狀態開始：本機的 `history.sqlite3` 記著舊電腦的身分（`meta.relay_device_ids`，App 的「清除歷史」不會清掉它），搬來的 Claude／Codex 對話紀錄也會被首次掃描再算一次。

1. 確認新電腦沒有舊電腦的資料。用移轉輔助程式或 Time Machine 搬過的，依序：
   1. 在新電腦執行 `collector/scripts/set-tier2.sh --disable`：搬來的設定與密鑰會讓新電腦用舊電腦的身分上傳（收集器偵測到搬來的資料庫會先自動暫停，這一步確保它不會恢復）。
   2. 刪掉或移走搬來的 `~/.claude/projects` 與 `~/.codex/sessions`（舊電腦還有一份，那些用量由舊電腦上傳）。
   3. 刪掉整個 `~/Library/Application Support/AIUsageMonitor/history.sqlite3`（連同 `-wal`、`-shm`；不是「清除歷史」）。收集器下一輪建立新檔。

   搬了資料又不想刪：不要另立身分，改用 1-1。
2. 新增身分，在新電腦設定：

   ```bash
   scripts/relay-device.sh add <新名稱>
   collector/scripts/set-tier2.sh            # 在新電腦執行，貼上新密鑰
   ```

3. 處理舊身分：
   - 舊電腦還要繼續用：不撤銷，兩台各自上傳。
   - 舊電腦不再使用：`scripts/relay-device.sh revoke <舊的 device_id>`（**不加** `--delete-data`），舊電腦過去的數字照算、標「已撤銷」。

### 1-3. Windows PC

步驟相同，指令換成 PowerShell 的 `windows\set-tier2.ps1`（`-Disable` 停止上傳）；資料庫在 `%LOCALAPPDATA%\AIUsageMonitor\history.sqlite3`，寫入密鑰在 Windows 認證管理員的 `AIUsageMonitor/device-key`。

## 2. 手機或手錶遺失（D-3）

iPhone 與 Apple Watch 共用同一把讀取密鑰（`READ_TOKEN`，[ADR-0012](adr/0012-iphone-pairing.md)）：撿到的人能讀用量與第二層的每日加總，不能寫入。遺失一台就換掉這把密鑰，其他裝置重新配對。

1. 先用「尋找」把遺失的裝置標為遺失或清除（密鑰存在它的 Keychain 裡）。
2. 產生新的讀取密鑰，同時寫進中繼與 Mac 的 Keychain（密鑰只經過標準輸入，不出現在程序參數或 shell 歷史紀錄）：

   ```bash
   cd relay
   NEW=$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')
   printf '%s' "$NEW" | npx wrangler secret put READ_TOKEN
   printf 'add-generic-password -U -s AIUsageMonitor-relay-read -a default -w %s\n' "$NEW" | security -i
   unset NEW
   cd ..
   ```

   用 `scripts/setup-relay.sh` 部署的中繼，`wrangler secret put` 要加 `--config wrangler.local.toml`。`wrangler secret put` 送出後立即生效，不必重新部署：遺失的裝置從此讀不到（401）。
3. 確認 Mac 的 Keychain 是新密鑰（輸出 `200` 就對了）。授權標頭由 shell 內建的 `printf` 經標準輸入交給 `curl`，密鑰不出現在程序參數：

   ```bash
   URL=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/Library/Application Support/AIUsageMonitor/config.json")))["relay_url"])')
   printf 'Authorization: Bearer %s\n' "$(security find-generic-password -s AIUsageMonitor-relay-read -a default -w)" \
     | curl -s -o /dev/null -w '%{http_code}\n' -H @- "$URL/usage"
   ```

4. 其他 iPhone 重新配對：`scripts/setup-iphone.sh --pair-only qr`，iPhone 設定按「掃描 QR 碼」。
5. Apple Watch：打開手錶 App，它會向 iPhone 要新的設定（iPhone 必須已完成第 4 步）。
6. Mac 的第二層下載用的是同一個 Keychain 項目，第 2 步已經更新，不必再做什麼。

遺失的是 **Mac** 時另外要做：

- 撤銷它的寫入密鑰（第二層）：`scripts/relay-device.sh revoke <device_id>`（要連它的數字一起刪就加 `--delete-data`），見 [tier2-setup.md](tier2-setup.md)「換新或撤銷密鑰」。
- 換掉 `/usage` 的寫入密鑰 `WRITE_TOKEN`：依第 2 步的寫法，把 `READ_TOKEN` 換成 `WRITE_TOKEN`、Keychain 的 service 換成 `AIUsageMonitor-relay-write`，在還在用的那台 Mac 執行。
- 讀取密鑰也存在那台 Mac 的 Keychain，一併依上面的步驟換新。

## 3. 資料庫損毀，從每週備份還原（D-1）

收集器發現 `history.sqlite3` 損毀時（連續約 1 小時寫不進去，而且 `quick_check` 也失敗），已經把舊檔改名為 `history.corrupt-<時間>.sqlite3` 保留、建立新檔重新記錄，面板底部提示 7 天。新檔從那一刻開始；要找回之前的額度歷史與個人紀錄，用 `backups/` 的每週備份（最多 2 份，最舊約 2 週前）。最後一次備份到損毀之間的額度歷史找不回來；Token 統計可以在還原後用設定的「清除並重新掃描」從對話紀錄重建。

1. 停止收集器（換檔時不能有程序在寫）：
   - App 內建的收集器：設定 →「背景收集器」→「停用」。
   - `install-launchd.sh` 裝的：

     ```bash
     launchctl bootout "gui/$(id -u)/io.github.kevin930326.ai-usage-monitor"
     ```

   - 再從選單列結束 App（它開著面板時也會開啟資料庫）。
2. 選一份備份，確認它完好（輸出 `ok`）：

   ```bash
   cd ~/Library/Application\ Support/AIUsageMonitor
   ls -l backups/
   sqlite3 backups/history-<日期>.sqlite3 "PRAGMA quick_check"
   ```

3. 把目前的檔案（損毀後新建的）連同 `-wal`、`-shm` 移開，換上備份：

   ```bash
   mkdir -p replaced && mv history.sqlite3 history.sqlite3-wal history.sqlite3-shm replaced/ 2>/dev/null
   cp backups/history-<日期>.sqlite3 history.sqlite3 && chmod 600 history.sqlite3
   ```

4. 重新啟動：App 設定的「背景收集器」按「啟用」；`install-launchd.sh` 裝的執行 `launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/io.github.kevin930326.ai-usage-monitor.plist`。打開 App。
5. 確認：5 分鐘內 `~/Library/Logs/AIUsageMonitor/collector.log` 沒有「略過額度歷史」，面板的本週走勢有備份時的資料。確認後可以刪掉 `replaced/` 與 `history.corrupt-*`。

- 第二層：還原後的上傳進度回到備份當時，收集器會把之後有變動的日子再上傳一次（覆蓋寫入，不會重複計算）。
- Windows PC：資料夾是 `%LOCALAPPDATA%\AIUsageMonitor`；停止與恢復排程用 `Disable-ScheduledTask -TaskPath '\AIUsageMonitor\' -TaskName Collector`／`Enable-ScheduledTask`（同樣的參數），確認備份可以用 `py -c "import sqlite3,sys;print(sqlite3.connect(sys.argv[1]).execute('PRAGMA quick_check').fetchone()[0])" <備份檔>`。
- 自動改名保留的舊檔不會自動修復；想自己試著救回資料時，可以用 `sqlite3 history.corrupt-<時間>.sqlite3 ".recover"` 輸出成 SQL（不保證完整）。
