---
name: ai-usage-monitor-design
description: AI Usage Monitor 的設計與識別規則：服務識別色、原創服務圖示（Claude 八芒星、Codex 六瓣雲）的精確定義、不收錄官方 logo、各平台資料過期門檻、不能更改的識別字（Bundle ID、App Group、小工具 kind、Keychain），以及 UI 驗證方式。修改 apple/ 下任何畫面、顏色、圖示、Live Activity、小工具、錶面複雜功能、Info.plist／project.yml 識別字，或新增服務時先讀這份。
---

# AI Usage Monitor 設計規則

修改 iPhone、Live Activity、Mac、Apple Watch 任何畫面前先讀完。規則的程式來源寫在每節最後，兩邊不一致時以程式為準並回頭更新這份文件。

## 1. 顏色（FR-16）

| 用途 | 深色外觀 | 淺色外觀 |
|---|---|---|
| Claude 識別色 | `#D97757` | `#B4532F` |
| Codex 識別色 | `#5CC2B1` | `#237A6B` |
| 剩餘 < 20% 的進度條（critical） | `#FF453A` | `#D70015` |
| 提示文字（資料已過期、服務錯誤） | `#FF9F0A` | `#A65200` |
| 資料過期時的進度條 | 系統灰色 `Color.gray` | 同左 |

- 進度條：一般為服務識別色；剩餘 < 20% 改紅色；資料過期一律灰色（灰色優先於紅色）。
- **文字一律 primary／secondary**，不用顏色表示狀態；顏色只用在進度條、服務圖示與提示文字。文字對比度 ≥ 4.5:1，圖形 ≥ 3:1（`UsagePaletteTests` 會檢查）。
- 黑底場合（動態島、手錶錶面）固定用深色值：`UsageColors.providerMark(_:)`。
- 不要在畫面裡寫死色碼，一律用 `UsageColors`（SwiftUI）或 `UsagePalette`（數值）。

來源：`apple/UsageKit/Sources/UsageKit/UsagePalette.swift`、`apple/UsageKit/Sources/UsageKitUI/UsageColors.swift`。

## 2. 服務圖示

動態島精簡版與圓形錶面複雜功能用圖示區分服務（空間不夠放名稱）。兩個圖示都是**原創**，定義在 `viewBox 0 0 24 24`，實作為 UsageKitUI 的 `ProviderIcon`（`ClaudeIconShape`、`CodexIconShape`），三個平台共用。

### Claude：八芒星

長短交錯的八芒星，實心填色，另加 **0.7 寬、圓角接合（round join）** 的同色描邊：

```
M12.00 1.00 L13.65 8.03 L17.80 6.20 L15.97 10.35 L23.00 12.00 L15.97 13.65 L17.80 17.80 L13.65 15.97
L12.00 23.00 L10.35 15.97 L6.20 17.80 L8.03 13.65 L1.00 12.00 L8.03 10.35 L6.20 6.20 L10.35 8.03Z
```

### Codex：六瓣圓雲，中間鏤空 `>_`

- 實心形狀是 7 個圓的聯集：中心圓 (12,12) 半徑 8.0；6 個外圓半徑 4.0，圓心
  (12.00,5.00)、(18.06,8.50)、(18.06,15.50)、(12.00,19.00)、(5.94,15.50)、(5.94,8.50)。
- 以筆劃 `M8 9l3 3-3 3M12.6 15.2h3.8`（線寬 2.3、圓頭、圓角）挖空，**鏤空處透出背景**（不是畫上背景色）。

### 繪製規則

- 圖示是單一 `Shape`，以目前的 `foregroundStyle` 填色（template）。全彩時套 `UsageColors.providerMark`，資料過期時套灰色。
- 錶面上加 `.widgetAccentable()`，讓單色／主題色錶面由系統換色；鏤空要維持透明。
- 只有圖示、沒有文字的地方要有 `accessibilityLabel`（「Claude」「Codex」）。`ProviderIcon` 已內建，不要拿掉。
- 目前尺寸：動態島精簡版 18pt、圓形複雜功能 13pt。縮小前要重新驗證（見第 6 節）。
- 新增服務時要設計新的原創圖示並寫進本節；`ProviderIcon` 對未知服務暫時畫圓形。

## 3. 不收錄官方 logo

repo 內**不收錄** Anthropic、Claude、OpenAI、Codex 的官方 logo、商標圖或其描摹，包括 SVG、PNG、SF Symbols 以外的圖片資源。上面兩個圖示是原創造型，不要改成接近官方 logo 的形狀。

## 4. 資料過期門檻（FR-11）

| 平台 | 門檻 | 常數 |
|---|---|---|
| iPhone App、Live Activity、Mac 選單列與桌面小工具 | 30 分鐘 | `UsageSnapshot.staleAfter` |
| Apple Watch App 與錶面複雜功能 | 45 分鐘 | `UsageSnapshot.watchStaleAfter` |

手錶較長是因為背景重新整理約每 30 分鐘一次，且時間由 watchOS 決定（見 `apple/WatchApp/README.md`）。Timeline 的重新整理時間點要用和畫面相同的門檻。

## 5. 不能更改的識別字

改了會讓已安裝的 App 失去資料、Keychain 中的密鑰、使用者已加入的小工具與錶面複雜功能，或讓收集器找不到密鑰。

| 類別 | 值 |
|---|---|
| iOS App Bundle ID | `io.github.kevin930326.AIUsageMonitor` |
| Live Activity 擴充 | `io.github.kevin930326.AIUsageMonitor.UsageWidget` |
| Mac 選單列 App | `io.github.kevin930326.AIUsageMenuBar` |
| Mac 桌面小工具 | `io.github.kevin930326.AIUsageMenuBar.UsageDesktopWidget` |
| watchOS App | `io.github.kevin930326.AIUsageMonitor.watchkitapp` |
| 錶面複雜功能 | `io.github.kevin930326.AIUsageMonitor.watchkitapp.UsageComplications` |
| App Group | `group.io.github.kevin930326.AIUsageMonitor` |
| 小工具 kind | Mac `UsageDesktopWidget`、手錶 `UsageComplication` |
| iOS／watchOS Keychain | service `io.github.kevin930326.AIUsageMonitor`，account `relay-read-token` |
| Mac Keychain（收集器） | 寫入密鑰 service `AIUsageMonitor-relay-write`，account `default`；讀取密鑰 service `AIUsageMonitor-relay-read` |

另外：本機快照路徑 `~/Library/Application Support/AIUsageMonitor/usage.json` 與環境變數 `AI_USAGE_MONITOR_HOME` 由收集器與 `UsageFileLocator` 共用，兩邊要一起改。

## 6. UI 驗證方式

改了畫面就要實際看過，不能只靠編譯通過。

1. **一次跑完測試與建置**：`scripts/verify-all.sh`（含 Release 不含 Debug 字串的檢查）。
2. **iPhone／動態島**：在 iPhone Pro 模擬器（有動態島）安裝 Debug 版，以示範模式啟動：
   ```bash
   SIMCTL_CHILD_AUM_DEMO=normal xcrun simctl launch booted io.github.kevin930326.AIUsageMonitor
   ```
   回到主畫面，卡片會縮成動態島精簡版。情境：`normal`（Claude 最吃緊）、`codex`（Codex 最吃緊）、`stale`、`error`、`reset`、`used`。
   - `xcrun simctl io screenshot` **拍不到動態島內容**，要用模擬器控制工具的截圖。
   - 深色、淺色各拍一次：`xcrun simctl ui booted appearance dark|light`。
3. **手錶複雜功能**：錶面無法以程式設定，改用 Debug 的 `AUM_RENDER=1` 以 ImageRenderer 輸出：
   ```bash
   SIMCTL_CHILD_AUM_DEMO=normal SIMCTL_CHILD_AUM_RENDER=1 xcrun simctl launch <手錶 UDID> io.github.kevin930326.AIUsageMonitor.watchkitapp
   xcrun simctl get_app_container <手錶 UDID> io.github.kevin930326.AIUsageMonitor.watchkitapp data
   ```
   `Documents/` 下有 `complication-circular.png`（深色）、`-circular-light.png`（淺色背景）、`-circular-tinted.png`（模擬單色／主題色：只用 alpha 再套主題色）。
4. **Mac**：`AUM_DEMO_PANEL=1` 把面板放進一般視窗；`AUM_RENDER_DIR=<資料夾>` 輸出桌面小工具 PNG（見 `apple/MacMenuBar/README.md`）。
5. **檢查重點**：在實際尺寸（不是放大圖）下確認八芒星八個角都看得到、雲朵中間的 `>_` 可辨認；主題色模擬中鏤空處透出背景；深色與淺色都清楚。
6. 截圖放在 `docs/screenshots/`，PR 描述附上前後對照。截圖前確認畫面上沒有中繼網址或密鑰。
7. 示範模式、截圖工具與 `AUM_*` 環境變數都要包在 `#if DEBUG` 裡。
