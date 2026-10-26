# 維運 runbook

長期使用時偶爾才會遇到、但做錯會讓數字重複或密鑰外流的情況（[ADR-0014](adr/0014-long-term-operation.md)「使用者的決定」）。每一節都是照順序做的步驟；指令在 repo 根目錄執行。

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
- 換新密鑰之前，兩台電腦用同一把密鑰上傳時會互相覆蓋同一個 `device_id` 的數字，其他電腦看到的合計會來回跳；所以第 2、3 步要盡早做。舊電腦若忘了停用，換新密鑰後它連續收到兩次 401 就會自己停止上傳。

### 1-2. 新電腦另立身分

新電腦以新名稱出現在裝置切換中（例如舊電腦還要繼續用，或想分開看兩台的數字）。

1. 新增身分，在新電腦設定：

   ```bash
   scripts/relay-device.sh add <新名稱>
   collector/scripts/set-tier2.sh            # 在新電腦執行，貼上新密鑰
   ```

2. 處理舊身分：
   - **新電腦的 `history.sqlite3` 是從舊電腦搬來的**：新身分會把搬來的舊紀錄重新上傳一次，舊身分必須連資料一起刪，否則同一批紀錄會算兩次：

     ```bash
     scripts/relay-device.sh revoke <舊的 device_id> --delete-data
     ```

   - **新電腦從空的資料庫開始**（沒有搬資料）且舊電腦不再使用：`scripts/relay-device.sh revoke <舊的 device_id>`（不加 `--delete-data`），舊電腦過去的數字照算、標「已撤銷」。
   - 舊電腦還要繼續用：不撤銷，兩台各自上傳。這時新電腦的資料庫**不能**是從舊電腦搬來的（同上，會重複），請先依設定的「清除歷史」或刪掉新電腦的 `history.sqlite3` 從頭統計。

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
3. 確認 Mac 的 Keychain 是新密鑰（不會印出密鑰；有輸出 `200` 就對了）：

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' "$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/Library/Application Support/AIUsageMonitor/config.json")))["relay_url"])')/usage" \
     -H "Authorization: Bearer $(security find-generic-password -s AIUsageMonitor-relay-read -a default -w)"
   ```

4. 其他 iPhone 重新配對：`scripts/setup-iphone.sh --pair-only qr`，iPhone 設定按「掃描 QR 碼」。
5. Apple Watch：打開手錶 App，它會向 iPhone 要新的設定（iPhone 必須已完成第 4 步）。
6. Mac 的第二層下載用的是同一個 Keychain 項目，第 2 步已經更新，不必再做什麼。

遺失的是 **Mac** 時另外要做：

- 撤銷它的寫入密鑰（第二層）：`scripts/relay-device.sh revoke <device_id>`（要連它的數字一起刪就加 `--delete-data`），見 [tier2-setup.md](tier2-setup.md)「換新或撤銷密鑰」。
- 換掉 `/usage` 的寫入密鑰 `WRITE_TOKEN`：依第 2 步的寫法，把 `READ_TOKEN` 換成 `WRITE_TOKEN`、Keychain 的 service 換成 `AIUsageMonitor-relay-write`，在還在用的那台 Mac 執行。
- 讀取密鑰也存在那台 Mac 的 Keychain，一併依上面的步驟換新。
