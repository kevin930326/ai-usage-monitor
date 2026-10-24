# 解除安裝

每一部分可以分開移除。預設**只移除程式與排程、保留資料**（額度歷史、Token 統計、設定），要連資料一起清掉時另外做最後一步。

## Mac 選單列 App 與內建收集器

```bash
curl -fsSL https://github.com/kevin930326/ai-usage-monitor/releases/latest/download/install.sh | bash -s -- --uninstall
```

- 停用 App 內建的收集器（SMAppService，「系統設定 › 一般 › 登入項目與延伸功能」的「AI 用量」會消失），再把 App 移到垃圾桶。
- 停用失敗時不會移走任何東西（結束碼 5），可以先打開 App 到「設定 › 背景收集器」按「停用」再重跑。
- 不想用指令：打開 App →「設定 › 背景收集器」→「停用」，結束 App，再把「應用程式」裡的「AI 用量」丟到垃圾桶。**只丟 App 不先停用**時，背景項目會留到下次登入才失效。

連資料一起移除（移到垃圾桶，不是直接刪除）：

```bash
curl -fsSL https://github.com/kevin930326/ai-usage-monitor/releases/latest/download/install.sh | bash -s -- --uninstall --purge
```

`--purge` 把 `~/Library/Application Support/AIUsageMonitor`（usage.json、history.sqlite3、config.json）與 `~/Library/Logs/AIUsageMonitor` 移到垃圾桶。`install-launchd.sh` 的收集器還在用這個資料夾時會拒絕，先照下一節移除它。

## launchd 收集器（`collector/scripts/install-launchd.sh` 安裝的）

```bash
collector/scripts/uninstall-launchd.sh
```

移除 `~/Library/LaunchAgents/io.github.kevin930326.ai-usage-monitor.plist` 並停止排程；額度歷史會詢問是否一併刪除（預設保留），usage.json、設定與日誌保留。

從原始碼裝的 Mac App（`scripts/install-mac-app.sh`）：結束 App，把「應用程式」裡的「AI 用量」丟到垃圾桶即可（開發版不含內建收集器）。

## iPhone 與 Apple Watch

1. 在 iPhone 上長按「AI 用量」→「移除 App」（Keychain 裡的讀取密鑰會一起移除）；手錶 App 隨 iPhone App 移除。
2. 在 Mac 上停止每 6 天自動重新安裝：

   ```bash
   scripts/uninstall-reinstall-launchd.sh
   ```

   `config.json` 的 `development_team`、`iphone_udid`，以及 `~/Library/Caches/AIUsageMonitor/DerivedData`（建置產物）保留，不需要時自行刪除。
3. 捷徑 App 裡的「重新啟動用量監看」自動化自行刪除。

## 中繼（Cloudflare Worker）

中繼在你自己的 Cloudflare 帳號裡，要你自己刪：

```bash
cd relay
npx wrangler delete --config wrangler.local.toml      # scripts/setup-relay.sh 部署的；手動部署的用 npx wrangler delete
npx wrangler kv namespace list                         # 找到 USAGE_KV 的 id
npx wrangler kv namespace delete --namespace-id <id>
```

再讓 Mac 停止上傳、清掉 Mac 上的密鑰：

```bash
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d.pop("relay_url", None); open(p, "w").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")' \
  "$HOME/Library/Application Support/AIUsageMonitor/config.json"
security delete-generic-password -s AIUsageMonitor-relay-write -a default
security delete-generic-password -s AIUsageMonitor-relay-read -a default   # setup-relay.sh 或 setup-iphone.sh 存的
rm -f relay/wrangler.local.toml
```

## Windows PC

```powershell
& ([scriptblock]::Create((irm https://github.com/kevin930326/ai-usage-monitor/releases/latest/download/install.ps1))) -Uninstall
```

移除工作排程 `\AIUsageMonitor\Collector` 與 `%LOCALAPPDATA%\AIUsageMonitor\app`；`%LOCALAPPDATA%\AIUsageMonitor` 裡的 history.sqlite3、config.json、collector.log 保留，不需要時自行刪除。從 repo 安裝的用 `collector\windows\uninstall-task.ps1`（見 [windows.md](windows.md#移除)）。用 winget 裝的 Python 不會被移除（`winget uninstall Python.Python.3.13`）。

## 會留下什麼

| 位置 | 內容 | 誰會清 |
|---|---|---|
| `~/Library/Application Support/AIUsageMonitor` | usage.json、history.sqlite3、config.json、service-status.json | `install.sh --uninstall --purge`，或自行刪除 |
| `~/Library/Logs/AIUsageMonitor` | 收集器、重新安裝的日誌 | 同上 |
| `~/Library/Caches/AIUsageMonitor` | iPhone App 的建置產物 | 自行刪除 |
| Keychain `AIUsageMonitor-relay-write`、`AIUsageMonitor-relay-read` | 中繼的寫入與讀取密鑰 | 見「中繼」 |
| App 的設定（UserDefaults） | 面板卡片順序、外觀等 | `defaults delete io.github.kevin930326.AIUsageMenuBar` |
| `%LOCALAPPDATA%\AIUsageMonitor`（PC） | history.sqlite3、config.json、collector.log | 自行刪除 |

收集器從不修改 Claude Code、Codex CLI 的設定與登入資訊；移除本專案不影響它們。
