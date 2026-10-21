# Mac 選單列 App

直接讀取 Mac 收集器寫在本機的 `usage.json`，不經過網路，也不需要讀取密鑰。資料模型與顏色規則來自 [UsageKit](../UsageKit/)。

| 部分 | 內容 |
|---|---|
| 選單列 | 圓點 + 最吃緊額度的剩餘 %（FR-21）；圓點是該服務的識別色，剩餘 < 20% 轉紅，資料超過 30 分鐘未更新時轉灰（FR-16） |
| 面板 | 點選單列圖示打開：最吃緊的一項大字顯示、各服務各額度的進度條與重置倒數、更新時間（FR-22）；重置時間已過顯示「已重置」，過期資料轉灰並標示「資料已過期」 |
| 桌面小工具 | 小：最吃緊的一項；中：兩個服務並排（FR-24） |

面板的趨勢圖（FR-23）尚未實作，需要先決定歷史資料存放方式（ADR-0004）。

## 資料來源

讀取 `~/Library/Application Support/AIUsageMonitor/usage.json`，規則與收集器相同：設定環境變數 `AI_USAGE_MONITOR_HOME` 時改讀該資料夾。收集器以「寫暫存檔再改名」更新檔案，App 監看所在資料夾（改名後監看檔案本身會失效）。另有每 60 秒的計時器重新判斷過期與重置；只有在監看失效時（資料夾還不存在，或被刪除後重建）才改為每 60 秒讀檔，並在資料夾出現後重新監看。

App 不開沙盒，才能讀取 `~/Library/Application Support`。桌面小工具必須在沙盒中執行，讀不到這個資料夾，所以 App 讀到新資料時會複製一份到 App Group 容器（`~/Library/Group Containers/group.io.github.kevin930326.AIUsageMonitor/usage.json`）給小工具。

- App Group 需要以 Apple 帳號（Team）簽署。App 只有在自己帶有該 App Group entitlement 時才寫入；以「Sign to Run Locally」建置時不寫入（macOS 15 對未授權存取群組容器會跳出詢問），小工具顯示「範例資料 · 未連結 App Group」。
- 收集器每 5 分鐘寫一次，若每次都要求小工具重新整理，一天約 288 次，超過 WidgetKit 的每日預算（約 40～70 次）。App 最短每 25 分鐘才重新整理一次，一天最多 58 次；數字變動最多晚 25 分鐘反映。數字沒變時也每 25 分鐘一次（避免小工具上的資料時間超過 30 分鐘而誤顯示過期）。小工具的時間軸每 15 分鐘一筆，另在重置與過期時間點各加一筆。

## 建置

```bash
brew install xcodegen
cd apple/MacMenuBar
xcodegen generate
open AIUsageMenuBar.xcodeproj
```

預設以「Sign to Run Locally」（`CODE_SIGN_IDENTITY = -`）簽署，不需要 Apple 帳號。要讓桌面小工具讀到真實資料，需以自己的 Team 簽署並為兩個 target 加入 App Group。在 Xcode 的 Signing & Capabilities 加入的設定會在下次 `xcodegen generate` 時被覆寫，請改在 `project.yml` 設定（`AIUsageMenuBar` 需要新增 `entitlements` 區塊，小工具在既有的 `properties` 加一行）：

```yaml
    entitlements:
      path: AIUsageMenuBar/AIUsageMenuBar.entitlements
      properties:
        com.apple.security.application-groups: [group.io.github.kevin930326.AIUsageMonitor]
```

並把 `CODE_SIGN_IDENTITY` 改為 `Apple Development`、`CODE_SIGN_STYLE` 改為 `Automatic`，再以 `DEVELOPMENT_TEAM=<你的 Team ID> xcodegen generate` 產生專案。

命令列建置：

```bash
xcodebuild -project AIUsageMenuBar.xcodeproj -scheme AIUsageMenuBar -destination 'platform=macOS' build
```

## 開發用

Debug 版本支援下列環境變數。用 `open` 啟動時環境變數不會傳進 App，要直接執行 bundle 內的執行檔：

| 變數 | 作用 |
|---|---|
| `AI_USAGE_MONITOR_HOME` | 改讀這個資料夾的 `usage.json`；設定時不會寫入 App Group |
| `AUM_DEMO_PANEL=1` | 另開一般視窗顯示面板（選單列面板無法以程式打開，截圖用） |
| `AUM_RENDER_DIR` | 把小工具兩種尺寸輸出成 `widget-small.png`、`widget-medium.png` |

```bash
AI_USAGE_MONITOR_HOME=/tmp/aum-fixture AUM_DEMO_PANEL=1 \
  ./build/Debug/AIUsageMenuBar.app/Contents/MacOS/AIUsageMenuBar
```

App 會在 stderr 印出實際讀取的路徑與每次讀到的 `updated_at`。
