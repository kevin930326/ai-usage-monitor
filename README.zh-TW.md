[English](README.md) | **繁體中文**

# AI Usage Monitor

[![CI](https://github.com/kevin930326/ai-usage-monitor/actions/workflows/ci.yml/badge.svg)](https://github.com/kevin930326/ai-usage-monitor/actions/workflows/ci.yml)

隨時查看 **Claude** 與 **Codex** 的剩餘使用額度（5 小時／每週）：iPhone 鎖定畫面的 Live Activity 與小工具、Apple Watch、Mac 選單列。Mac 面板另外顯示額度走勢、消耗熱力圖、這台 Mac 的 Token 統計與兩家服務的狀態。只用其中一個服務也可以。

> 目前的版本是 [1.0.0](CHANGELOG.md#100---2026-10-29)：Mac 的 `.dmg`／一行指令、Windows 收集器的一行指令與 Windows 桌面 App 的 zip 都在 [Releases](https://github.com/kevin930326/ai-usage-monitor/releases)。安裝見[安裝](#安裝)，各版本的變更見 [CHANGELOG](CHANGELOG.md)。

<!-- 同一排的圖以寬度算成等高（SOURCES.tsv 的尺寸 × 寬度）；用 width 不用 height，窄螢幕時換行而不是壓扁 -->
<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/mac-panel-top-dark.png">
    <img src="docs/images/mac-panel-top-light.png" width="281" alt="Mac 選單列面板的上半部：剩餘最少的額度、建議接下來用、各服務各額度的進度條與預期標記、Codex 的重置卷張數與最早到期日">
  </picture>
  &nbsp;&nbsp;
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/iphone-app-dark.png">
    <img src="docs/images/iphone-app-light.png" width="221" alt="iPhone App：剩餘最少的額度、各服務各額度的進度條與重置倒數">
  </picture>
</p>

<p align="center">
  <img src="docs/images/iphone-island.png" width="486" alt="動態島展開：剩餘最少的額度大字、兩個服務各額度的進度條與更新按鈕">
  &nbsp;&nbsp;
  <img src="docs/images/watch-app.png" width="159" alt="Apple Watch App：剩餘最少的額度與各額度進度條">
</p>

瀏海與角色（Mac）：滑鼠移到瀏海展開（上），平常收在瀏海兩旁（下）。

<p align="center">
  <img src="docs/images/mac-notch.png" width="580" alt="Mac 瀏海展開的面板：左邊是角色與等級、連續天數，右邊是 Claude 與 Codex 各額度的剩餘與重置時間">
</p>
<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/mac-notch-collapsed-dark.png">
    <img src="docs/images/mac-notch-collapsed-light.png" width="580" alt="收合的瀏海：左邊是迷你角色，右邊是剩最少額度的圓環與百分比">
  </picture>
</p>

<details>
<summary>看完整的 Mac 面板（接下來的重置、本週額度走勢、額度消耗、Token 統計、服務狀態）</summary>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/mac-panel-dark.png">
    <img src="docs/images/mac-panel-light.png" width="300" alt="Mac 選單列面板：剩餘最少的額度、建議接下來用、各額度進度條、接下來的重置、本週額度走勢、額度消耗、這台 Mac 的 Token 統計與服務狀態">
  </picture>
</p>

</details>

截圖都是示範資料（Debug 版的 `AUM_DEMO`／`scripts/make-demo-history.py`），不是真實用量；由 `scripts/update-readme-images.sh` 產生（來源見 `docs/images/SOURCES.tsv`）。

## 功能

| 平台 | 功能 |
|---|---|
| iPhone | 鎖定畫面與動態島的 Live Activity（剩餘最少的額度、各額度進度條、重置倒數、卡片上的「更新」按鈕）；捷徑動作「重新啟動用量監看」讓卡片整天顯示；主畫面小工具（小／中／大）與鎖定畫面小工具（圓形／矩形／單行）；過期資料轉灰、重置後顯示「已重置」；可切換顯示已用或剩餘 %；外觀設定（跟隨系統、淺色、深色，只套用到 App）與掃描 Mac 上的 QR 碼配對；主畫面的 Codex 區塊顯示重置次數卷的張數與最早到期日（要重新部署中繼） |
| Apple Watch | 手錶 App 與錶面複雜功能（圓形、矩形、單行）；智慧型堆疊顯示 iPhone 的 Live Activity；設定由 iPhone 傳過來，手錶不需要輸入 |
| Mac 選單列 | 選單列圖示（雙圓環）顯示剩餘最少的額度；卡片式面板：建議接下來用、各額度與「照目前速度」的預測、接下來的重置（8 小時時間軸與每週額度可撐到星期幾）、本週額度走勢、額度消耗熱力圖、這台 Mac 的 Token 統計（本週、單日最高、最長任務、連續天數、活動熱力圖；可切換是否含快取讀取）、服務狀態（分辨「服務異常」與「額度用完」）；完整統計視窗；Codex 重置次數卷的張數與到期日（滑鼠移上去列出每張）；通知（剩不到 20%、用得太快、額度重置、重置卷 3 天內到期；「剩不到 20%」與「重置卷快到期」預設開，其他預設關）；右鍵選單與全域快捷鍵；卡片可排序、收合、隱藏；外觀設定（跟隨系統、淺色、深色）；第一次打開時的設定精靈 |
| Mac 瀏海與角色 | 滑鼠移到瀏海展開成面板：左邊是角色（Claude 或 Codex）、右邊是兩個服務的額度；收合時瀏海兩旁是迷你角色與剩最少額度的圓環。角色的表情跟著額度與服務狀態，AI 正在跑時敲鍵盤、閒著久了睡覺，點、捏、繞圈有反應，等級隨每天的 Token 成長；沒有瀏海的螢幕在選單列中間畫一個 |
| Windows PC | 收集器統計這台 PC 的 Token；桌面 App 的懸浮圖示可選雙圓環或角色（和 Mac 瀏海同一個角色），點一下打開卡片式面板 |
| 收集器 | 每 5 分鐘執行 Claude Code 的 `/usage` 與 Codex CLI 的 `app-server` 取得額度，寫本機快照、額度歷史與 Token 統計，並上傳精簡快照到你自己的中繼。由 App 內建的背景收集器或 `install-launchd.sh` 裝的 launchd 工作執行，兩者不會同時跑 |

Token 統計：面板的統計卡片可切換全部、Claude、Codex，以及是否「含快取讀取」（預設不含；快取讀取是 AI 重複讀取的對話，通常佔總量的大部分）（左）；「完整統計」視窗看一整年、各模型與一天中的時段（右）。

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/mac-stats-switch-dark.gif">
    <img src="docs/images/mac-stats-switch-light.gif" width="265" alt="統計卡片依序切換全部、Claude、Codex：全部的熱力圖是藍色色階，Claude、Codex 用各自的識別色；Token 數以萬、億顯示">
  </picture>
  &nbsp;&nbsp;
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/mac-stats-window-dark.png">
    <img src="docs/images/mac-stats-window-light.png" width="432" alt="完整統計視窗：一年活動熱力圖（全部為藍色色階）、最近 30 天長條、各模型與一天中的時段">
  </picture>
</p>

外觀可選跟隨系統、淺色或深色（Mac 套用到面板、設定、完整統計與設定精靈；iPhone 只套用到 App 本身）：

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/mac-settings-appearance-dark.png">
    <img src="docs/images/mac-settings-appearance-light.png" width="440" alt="Mac 設定的「外觀」：跟隨系統、淺色、深色">
  </picture>
</p>

## 系統概觀

```
Mac 收集器 (Python)     ──POST──▶ Cloudflare Worker (KV) ◀──GET── iPhone App、小工具、Live Activity、Apple Watch
        │                                                              ▲
        ▼                                                    iOS 捷徑自動化：定時重開 Live Activity
本機 usage.json、history.sqlite3、service-status.json ◀──讀── Mac 選單列 App（不連網）
```

- **收集器不讀取任何服務的 token**：Claude 用量由未修改的 Claude Code 自己的 `/usage` 取得（[ADR-0006](docs/adr/0006-claude-usage-via-cli.md)），Codex 用量由 Codex CLI 自己的 `app-server` 取得（[ADR-0007](docs/adr/0007-codex-usage-via-app-server.md)）。
- 不需付費 Apple Developer 帳號：用「捷徑定時重開 + 按鈕手動更新」繞過 Live Activity 的 8 小時上限，免費 Apple ID 的 7 天簽署期限可用每週自動重裝處理。

## 文件

| 文件 | 內容 |
|---|---|
| [需求規格](docs/01-requirements.md) | 功能需求、非功能需求、範圍 |
| [系統架構](docs/02-architecture.md) | 元件、資料格式、失敗處理 |
| [開發流程](docs/03-development-workflow.md) | 里程碑、分支、commit、PR 規範 |
| [相關專案調查](docs/04-related-work.md) | 既有開源方案比較與本專案定位 |
| [手動測試清單](docs/manual-test-checklist.md) | 模擬器與實機的操作步驟與預期結果 |
| [解除安裝](docs/uninstall.md) | 各部分怎麼移除、哪些資料會留下 |
| [Windows 收集器](docs/windows.md) | Windows PC 的 Token 統計：安裝、移除、手動確認 |
| [第二層：多台電腦的 Token 合併](docs/tier2-setup.md) | 選用：D1、裝置密鑰、Mac 與 PC 的設定、換新與撤銷 |
| [維運 runbook](docs/runbook.md) | 換電腦、手機或手錶遺失時照順序做的步驟 |
| [架構決策紀錄 (ADR)](docs/adr/) | 重要技術選擇的理由 |
| [CHANGELOG](CHANGELOG.md) | 各版本的變更 |

## 專案結構

```
collector/   Mac 端用量收集器 (Python，只用標準函式庫)
relay/       Cloudflare Worker 中繼 API
apple/       UsageKit 共用套件、iOS App + Live Activity + 小工具、Mac 選單列 App、Apple Watch App
windows/     Windows 桌面 App（WPF：懸浮圓環與面板）與 C# 的 UsageCore，見 windows/README.md
fixtures/    三個元件測試共用的範例 usage.json；logic/ 是 Swift 與 C# 共用的計算 golden
scripts/     verify-all.sh、setup-relay.sh、setup-iphone.sh、install-mac-app.sh、build-release.sh、截圖與效能量測工具
docs/        需求、架構、ADR、手動測試清單、README 截圖
```

```bash
scripts/verify-all.sh              # 全部測試 + iOS／Mac／手錶的 Debug 與 Release 建置 + Release 不含 Debug 程式碼的檢查
SKIP_LINUX=1 scripts/verify-all.sh # 沒有 Docker 時略過 Linux 的 UsageKit 測試
SKIP_WINDOWS=1 scripts/verify-all.sh # 沒有 .NET SDK 時略過 Windows App 的測試與建置
```

## 安裝

分三層，需要哪一層裝到哪一層就好。只用 Claude 或只用 Codex 都可以。三層都**不需要付費 Apple Developer 帳號**，也不需要把資料交給別人：中繼用你自己的 Cloudflare 帳號（免費方案）。

| 層 | 看得到 | 需要 | 時間 |
|---|---|---|---|
| [0. 只有 Mac](#0-只有-mac) | Mac 選單列 | Mac（Apple 晶片）、已登入的 Claude Code 或 Codex CLI | 約 3 分鐘 |
| [1. 加上 iPhone](#1-加上-iphone) | iPhone 鎖定畫面、小工具、Apple Watch | 第 0 層、Cloudflare 帳號（免費）、Xcode、免費 Apple ID | 約 20 分鐘 |
| [2. 加上 PC](#2-加上-pc) | 這台 PC 的 Token 統計 | Windows 10／11 | 約 5 分鐘 |

先登入要監看的服務（至少一個）：Claude 在終端機執行 `claude` 並 `/login`；Codex 執行 `codex login`（用 ChatGPT 帳號登入；API key 登入看不到額度）。

### 0. 只有 Mac

**下載安裝**（不需要終端機、不需要自己裝 Python）：從 [Releases](https://github.com/kevin930326/ai-usage-monitor/releases) 下載 `AIUsageMenuBar-<版本>.dmg`，把「AI 用量」拖到「應用程式」，第一次打開時到「系統設定 › 隱私權與安全性」按「強制打開」（App 用 ad-hoc 簽署，沒有 Apple 公證，見 [ADR-0013](docs/adr/0013-download-and-install.md)）。

或用一行指令（會比對 SHA-256、裝到「應用程式」並打開，不會遇到 Gatekeeper 的「強制打開」）。指令指向固定版本（下面是 1.0.0；之後的版本把 `1.0.0` 換成 [Releases](https://github.com/kevin930326/ai-usage-monitor/releases) 上的版本號）：

```bash
curl -fsSL https://github.com/kevin930326/ai-usage-monitor/releases/download/v1.0.0/install.sh | bash
```

想先看過再執行：`curl -fsSLO https://github.com/kevin930326/ai-usage-monitor/releases/download/v1.0.0/install.sh`，看完 `install.sh` 再 `bash install.sh`。install.sh 裡寫死了該版本 zip 的 SHA-256，下載後比對、不符就停止；它與 zip 來自同一個 Release，保護的是下載與快取途中的完整性，**不能**防止 Release 本身被替換（[ADR-0013](docs/adr/0013-download-and-install.md#1-mac-app-的發布格式)）。

第一次打開會出現**設定精靈**，每一步顯示 ✅ 或要處理的事；需要指令時附「複製」按鈕。App 內建收集器（Python 已內嵌），會在背景每 5 分鐘收集一次；之後可以從「設定 › 一般 › 重新執行設定精靈」再打開。

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/mac-wizard-dark.png">
    <img src="docs/images/mac-wizard-light.png" width="300" alt="設定精靈：App 位置、背景收集器、Claude Code、Codex、通知、登入時開啟、外觀、在 iPhone 上看，每步顯示完成或需要處理">
  </picture>
</p>

**已經用 `collector/scripts/install-launchd.sh` 的人**：新版 App 偵測到舊的收集器時**不會**再註冊一個，只在設定精靈與「設定 › 背景收集器」顯示「可以改用 App 內建的收集器」；按下按鈕才遷移（先確認內建的能跑，才停用舊的；舊的 plist 移到垃圾桶）。不按就照舊運作。

**從原始碼安裝**（開發者）：需要 Xcode 與 Python 3.10 以上。

```bash
collector/scripts/install-launchd.sh   # 收集器（launchd）；細節見 collector/README.md
scripts/install-mac-app.sh             # 選單列 App（Release 建置，裝到「應用程式」）
```

### 1. 加上 iPhone

iPhone 不直接連 Mac，資料經過你自己的 Cloudflare Worker（中繼）；Mac 上傳、iPhone 讀取，兩把密鑰分開（[ADR-0001](docs/adr/0001-cloudflare-worker-relay.md)）。

第 1 層的腳本在原始碼裡（用 DMG 安裝的也需要這一步）。先取得原始碼並進入資料夾，之後的指令都在這個資料夾執行；Python 3 用 Xcode 附的即可：

```bash
git clone https://github.com/kevin930326/ai-usage-monitor.git
cd ai-usage-monitor
```

1. **部署中繼**（需要 Node.js 23.6 以上、免費的 Cloudflare 帳號；腳本會在 `relay/` 以 `npm ci` 安裝鎖定版本的 wrangler）：

   ```bash
   scripts/setup-relay.sh --dry-run   # 先看會做什麼
   scripts/setup-relay.sh             # 登入 Cloudflare → 建 KV → 部署 → 產生並設定兩把密鑰 → 寫收集器設定
   ```

   已經設定過中繼時會停下來、不覆蓋。手動步驟見 [relay/README.md](relay/README.md#部署)。

2. **安裝 iPhone App**（需要 Xcode、XcodeGen 與免費 Apple ID；先在 Xcode → Settings → Accounts 登入，用線連一次 iPhone 並按「信任」、打開「開發者模式」）：

   ```bash
   scripts/setup-iphone.sh --auto-reinstall   # 建置並安裝；免費 Apple ID 的簽署 7 天後失效，每 6 天自動重裝
   ```

3. **配對**：Mac 終端機顯示 QR 碼，iPhone 的設定按「掃描 QR 碼」，確認主機名稱就完成（QR 碼只含網址與讀取密鑰，按 Enter 後清除；[ADR-0012](docs/adr/0012-iphone-pairing.md)）。

   ```bash
   scripts/setup-iphone.sh --pair-only qr
   ```

   相機不方便時改用一次性短碼：`scripts/setup-iphone.sh --pair-only code`，在 iPhone 按「輸入短碼」（10 分鐘內有效，只能用一次；中繼要是 2026-10-24 之後部署的版本才有這個端點）。

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/iphone-settings-pairing-dark.png">
    <img src="docs/images/iphone-settings-pairing-light.png" width="221" alt="iPhone 設定：中繼網址與讀取密鑰，下方「從 Mac 配對」有「掃描 QR 碼」與「輸入短碼」">
  </picture>
</p>

鎖定畫面卡片要整天顯示，照 [apple/iOSApp/README.md](apple/iOSApp/README.md#捷徑讓卡片整天顯示) 設定捷徑自動化。手錶 App 在 `apple/WatchApp`（[README](apple/WatchApp/README.md)），以同樣方式建置安裝；打開手錶 App 時會向 iPhone 要中繼設定。細節與手動方式見 [apple/iOSApp/README.md](apple/iOSApp/README.md)。

### 2. 加上 PC

Windows 收集器統計這台 PC 上 Claude Code 與 Codex CLI 的 Token（預設不收集額度、不上傳）。開 PowerShell（不需要系統管理員）：

```powershell
irm https://github.com/kevin930326/ai-usage-monitor/releases/download/v1.0.0/install.ps1 | iex
```

之後的版本同樣換掉版本號；想先看過：`irm https://github.com/kevin930326/ai-usage-monitor/releases/download/v1.0.0/install.ps1 -OutFile install.ps1`，看完再執行。SHA-256 的保護範圍與 Mac 相同。

沒有 Python 時會詢問是否用 winget 安裝；下載的檔案比對 SHA-256 後才安裝。細節、選項與限制見 [docs/windows.md](docs/windows.md)。要在 Mac 的面板看到所有電腦的合計，另外設定第二層：見 [docs/tier2-setup.md](docs/tier2-setup.md)。

**在 PC 上看額度（Windows 桌面 App）**：收集器要以 `-WithQuota` 安裝（[docs/windows.md](docs/windows.md)），App 才有額度資料。桌面上會有和 Mac 選單列相同的雙圓環或角色（可拖動、貼邊、全螢幕時隱藏），點一下打開卡片式面板；App 只讀本機的 `usage.json`、不連網。安裝方式選一個：

- **下載 zip**（不需要 .NET）：從 [Releases](https://github.com/kevin930326/ai-usage-monitor/releases) 下載符合架構的 `AIUsageMonitor-windows-x64-1.0.0.zip`（ARM64 是 `-arm64-`），以 `Get-FileHash <zip> -Algorithm SHA256` 和 `SHA256SUMS-windows` 比對，解壓到固定的位置後打開 `AIUsageMonitor.exe`。沒有程式碼簽章，第一次打開會出現 SmartScreen，按「其他資訊」→「仍要執行」。
- **從 repo 的腳本安裝**（會自動比對 SHA-256、更新時再執行一次）：在 repo 資料夾執行 `powershell -ExecutionPolicy Bypass -File scripts\install-windows-app.ps1 -FromRelease`；不加 `-FromRelease` 則用 .NET 10 SDK 從原始碼建置。

細節與實機確認清單見 [windows/README.md](windows/README.md)（ADR-0015）。

### 解除安裝

見 [docs/uninstall.md](docs/uninstall.md)：Mac App、內建或 launchd 收集器、iPhone、中繼、PC，各自怎麼移除、哪些資料會留下。

## 隱私與安全

原則：

- 收集器**不讀取任何服務的 token**，token 只由各自的 CLI 在 Mac 上使用（NFR-1）。
- **離開這台 Mac 的使用者資料只有上傳到你自己中繼的用量快照**（方案名稱與各額度的百分比、重置時間，Codex 重置次數卷的張數與到期時間）。額度歷史、Token 統計、對話紀錄的任何內容、服務狀態都只留在本機。
  例外是你另外設定的[第二層](docs/tier2-setup.md)：每台電腦把每日 Token 加總（日期、服務、模型名稱、各種 Token 數、任務秒數）上傳到你自己中繼的 D1，Mac 再下載其他電腦的；不上傳每小時資料、任務次數、路徑、檔名、對話內容與 ID。沒有設定時不會上傳。
- 中繼的讀取與寫入密鑰分開（NFR-2）。所有網路請求都是 HTTPS，各 App 沒有 ATS 例外。

### 讀取的檔案與欄位

| 讀取者 | 檔案或來源 | 取用的內容 | 不取用（舉例） |
|---|---|---|---|
| 收集器 | `claude -p /usage`、`claude auth status` 的輸出 | 各額度的已用 %、重置時間；方案名稱 | email 等其餘輸出直接丟棄 |
| 收集器 | `codex app-server` 的 `account/rateLimits/read` 回應 | 各額度的已用 %、重置時間、方案名稱；重置次數卷的可用張數與各張到期時間 | 帳號 ID、點數餘額、重置卷的 id／標題／說明／取得時間等其餘欄位。收集器只讀、不使用重置卷（程式裡沒有使用卷的方法，測試會掃描確認） |
| 收集器 | `~/Library/Application Support/AIUsageMonitor/config.json` | 中繼網址、`claude`／`codex` 路徑、啟用的服務、對話紀錄資料夾 | — |
| 收集器 | Keychain `AIUsageMonitor-relay-write` | 中繼寫入密鑰（上傳時使用） | — |
| 收集器（只在設定第二層後） | Keychain `AIUsageMonitor-device-key`、`AIUsageMonitor-relay-read`（Windows：認證管理員 `AIUsageMonitor/device-key`，`set-tier2.ps1 -ReadKey` 時另有 `AIUsageMonitor/relay-read`） | 這台電腦的寫入密鑰；下載其他電腦資料用的讀取密鑰 | — |
| 收集器 | Claude Code 對話紀錄 `<claude>/projects/*/<uuid>.jsonl`、`…/<uuid>/subagents/*.jsonl` | assistant 行：`timestamp`、`message.id`、`requestId`、`message.model`、`message.usage` 的四種 Token 數、`isSidechain`；user 行：`timestamp`、`isMeta`、`isSidechain`、`message.content` **是否為** `tool_result`（只判斷型別） | 對話文字、`cwd`、`gitBranch`、附件、檔案快照、`lastPrompt`、`customTitle` |
| 收集器 | Codex 對話紀錄 `<codex>/sessions/YYYY/MM/DD/rollout-*.jsonl`、`<codex>/archived_sessions/rollout-*.jsonl` | `token_usage_record` 的 `response_id`、`usage`、`timestamp`；`token_count` 的 `info.total_token_usage`、`timestamp`；`turn_context` 的 `model`；`task_complete` 的 `turn_id`、開始與結束時間、`duration_ms` | `last_agent_message`、`cwd`、`workspace_roots`、`response_item` 的一切、`rate_limits` |
| 收集器 | `https://status.claude.com/api/v2/summary.json`、`https://status.openai.com/api/v2/summary.json`、`https://status.claude.com/api/v2/incidents/unresolved.json`、`https://status.openai.com/api/v2/incidents.json`（公開，不帶任何密鑰或 cookie） | 整體狀態、異常元件的名稱與狀態、未解決事件的名稱與影響程度（各最多 8 項、120 字）；影響這個服務的進行中事故另取事故頁連結（`https://status.claude.com/incidents/<id>`／`https://status.openai.com/incidents/<id>`）與開始時間（[ADR-0018](docs/adr/0018-quota-forecast-and-service-incidents.md) 第 4 節） | 事件內文與更新、其他連結 |
| Mac 選單列 App | `usage.json`、`history.sqlite3`、`service-status.json`（同一個資料夾） | 全部（都是收集器寫的、不含帳號資訊） | — |
| iPhone、小工具、手錶 | 你的中繼 `GET /usage` | 用量快照 | — |
| iPhone App | 相機（只在按「掃描 QR 碼」時，VisionKit） | 只認 `aiusage-pair:v1:` 開頭的配對 QR 碼（中繼網址與讀取密鑰） | 其他 QR 碼與畫面內容 |

對話紀錄的規則（[ADR-0009](docs/adr/0009-local-history-and-token-stats.md) 第 3 節）：只列舉上表的一般檔案，不跟隨符號連結；每一行先以位元組比對篩選，解析成 JSON 後**立刻**只取白名單欄位、不保留原始行；超過 4 MB 的行略過。資料庫的 `file_key` 只用檔名中的 UUID，不含專案資料夾名稱；模型名稱只收 `claude-`、`gpt-`、`codex-`、`o` 加數字開頭的，其他記為 `other`。例外只記錄類別名稱與檔案序號，不記錄檔名、路徑或行內容。限制：JSON 無法只解析部分欄位，篩選過的行仍會整行載入記憶體再丟棄。

**從不讀取**：`~/.codex/auth.json`、`~/.claude/.credentials.json`、Keychain 的 `Claude Code-credentials`、瀏覽器 cookie、`~/.claude.json`、`settings.json`、`config.toml`、`history.jsonl`、`tool-results/`、`~/.codex/*.sqlite`，以及上表以外的任何檔案。收集器有測試掃描原始碼確認不讀憑證，並確認檔案列舉只回傳上表的檔案。

### 寫入的檔案

| 寫入者 | 位置 | 內容 |
|---|---|---|
| 收集器 | `~/Library/Application Support/AIUsageMonitor/usage.json` | 最新快照（與上傳的內容相同，另有 `local_status`：只在本機顯示的提醒，例如損壞的歷史檔已改名、磁碟空間不足） |
| 收集器 | `~/Library/Application Support/AIUsageMonitor/history.sqlite3`（含 `-wal`、`-shm`，權限 `0600`） | 額度歷史：每 5 分鐘每個額度一筆「時間、服務、額度 id、已用 %、重置時間」與每次收集是否成功；Token 統計：每天／每小時 × 服務 × 模型的四種 Token 數（Codex 另有推理明細）、任務數與任務時間、個人紀錄、各紀錄檔讀到哪裡（以 UUID 識別）、已計入的訊息與任務 ID；隨機裝置 ID、裝置名稱固定為「這台 Mac」、保留期間。**不存**方案名稱、錯誤訊息、帳號資訊、對話內容、路徑或專案名稱。預設保留 1 年，35 天前的額度歷史降為每小時一筆 |
| 收集器 | `~/Library/Application Support/AIUsageMonitor/service-status.json`（`0600`） | 兩家狀態頁的精簡結果（見上表） |
| 收集器的安裝腳本 | `config.json`、`~/Library/LaunchAgents/io.github.kevin930326.ai-usage-monitor.plist` | 設定；launchd 排程 |
| App 內建的收集器（`usage_collector.setup`） | `config.json` | `claude`／`codex` 路徑、啟用的服務；在 App 註冊收集器或設定精靈按「重新檢查」時（內建收集器執行中）寫入，保留其他欄位 |
| `setup-relay.sh` | Keychain `AIUsageMonitor-relay-write`、`config.json`、`relay/wrangler.local.toml`（不進版控） | 中繼寫入密鑰；中繼網址；KV 的 id 與 Worker 名稱 |
| `set-relay.sh` | Keychain `AIUsageMonitor-relay-write`、`config.json` | 中繼寫入密鑰；中繼網址（不含密鑰） |
| 收集器 | `~/Library/Logs/AIUsageMonitor/collector.log`、`collector.log*.repeats.json`（Windows：`%LOCALAPPDATA%\AIUsageMonitor\collector.log`、`collector.log.repeats.json`） | 錯誤訊息（不含 token、Claude Code 的輸出或對話紀錄的內容）；`.repeats.json` 是同樣的訊息與時間，用來讓重複的錯誤每小時只記一行 |
| Mac 選單列 App | App 的 UserDefaults | 選單列圖示樣式與顯示的額度（`menuBar.*`）、面板設定（`panel.*`：卡片順序、收合、走勢與統計的範圍、統計是否含快取讀取）、通知開關（`notify.low`／`notify.tooFast`／`notify.reset`）、啟動時是否已詢問過通知權限（`notify.askedAtLaunch`）與已通知的事件鍵（`notify.sent`，保留 8 天）、快捷鍵（`hotKey.panel`）、「更新」觸發收集器的時間（`collector.kicks`）、外觀（`app.appearance`）、設定精靈是否已完成（`wizard.completed`） |
| Mac 選單列 App | `~/Library/Application Support/AIUsageMonitor/level.json`（`0600`；壞掉時改名為 `level.corrupt.json` 保留，只留最近一份） | 角色等級：每天的 Token 主數字（日期與數字，只增不減）、經驗值與等級。瀏海展開時與「清除歷史」之前更新；清除歷史不刪它，等級不會變低；存不進去時不清除（[ADR-0020](docs/adr/0020-mascot-level.md) 第 1 節） |
| Mac 選單列 App | `history.sqlite3` | 只在設定中改保留期間（`meta.retention_days`；延長時另記 `meta.token_days_from`，即還有每日 Token 的第一天），或確認「清除歷史」「縮短保留期間」「清除並重新掃描」後寫入；開啟資料庫時把檔案與 `-wal`、`-shm` 改回 `0600` |
| Mac 選單列 App | 你選擇的位置 | 「匯出額度 CSV」：每小時的額度歷史；「匯出 Token CSV」：每日 Token（日期、服務、模型、四種 Token、任務數與秒數） |
| Mac 選單列 App | 通知中心 | 通知內容（服務、額度名稱與剩餘 %）。「剩不到 20%」預設開，第一次打開 App 時由系統詢問是否允許；另外兩種只在你打開開關後 |
| Mac 選單列 App | 系統的登入項目（`SMAppService`） | 只在你打開「登入時自動打開」後；關掉開關即移除 |
| Mac 選單列 App | 系統的背景項目（`SMAppService.agent`） | App 內的 LaunchAgent `io.github.kevin930326.AIUsageMenuBar.collector`（內建收集器）。發布版第一次打開、沒有 `install-launchd.sh` 的舊收集器時註冊；有舊的時只在你按「改用內建收集器」後註冊並把舊的 plist 移到垃圾桶。開發版不註冊 |
| Mac 選單列 App | 標準錯誤輸出（stderr，不寫入檔案） | 讀取的資料夾路徑、資料時間、送出的通知種類與服務／額度 id、觸發收集器的結束碼；不含用量數字或帳號資訊 |
| 中繼（Cloudflare） | Worker KV `latest`、`pair`、`pair-fail:<雜湊前 16 字>`；secrets `READ_TOKEN`、`WRITE_TOKEN` | 最新一筆快照；配對短碼的 SHA-256 與到期時間、錯誤次數（10 分鐘後到期）；兩把密鑰 |
| iPhone | Keychain（`AfterFirstUnlockThisDeviceOnly`，不同步到 iCloud） | 中繼**讀取**密鑰；App 與小工具以 Keychain 群組共用同一個項目 |
| iPhone | App Group `group.io.github.kevin930326.AIUsageMonitor`：UserDefaults（`relayURL`、`displayMode`）與 `usage.json` | 中繼網址、顯示已用／剩餘；最後一份快照（小工具抓不到中繼時顯示） |
| iPhone | App 自己的 UserDefaults（`app.appearance`） | 外觀設定（不放 App Group、不同步到手錶） |
| iPhone | Live Activity 與小工具 | 各額度百分比、重置時間、方案、錯誤訊息；**鎖定時也看得到** |
| Apple Watch | Keychain（`AfterFirstUnlockThisDeviceOnly`）、UserDefaults（`relayURL`）、App Group 的 `usage.json` | 讀取密鑰、中繼網址、最新快照（給複雜功能，**錶面上隨時看得到**百分比） |
| Windows App | `%LOCALAPPDATA%\AIUsageMonitor\windows-app.json`、`logs\windows-app.log` | 顯示方式、圓環的額度／大小／透明度與每個螢幕的位置、外觀、「立即更新」觸發收集器的時間；錯誤的類型與位置（不含用量數字） |
| Windows App | `%LOCALAPPDATA%\AIUsageMonitor\level.json`（壞掉時改名為 `level.corrupt.json`，只留最近一份） | 角色等級（只算這台電腦）：每天的 Token 主數字、經驗值與等級；面板打開時讀 `history.sqlite3` 的 `record_days`（唯讀）後更新 |
| Windows App | `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` 的 `AIUsageMonitor` | 開機自動啟動（安裝時預設開；設定關掉即移除） |

iPhone 以 WatchConnectivity `sendMessage` 把中繼網址與讀取密鑰傳給開著的手錶 App，系統不保存訊息（FR-30）。寫入密鑰只存在 Mac 的 Keychain 與 Cloudflare，不會傳到 iPhone 或手錶。

### 網路請求

| 發出者 | 目的地 | 認證 | 傳送／取得的內容 | 時機 |
|---|---|---|---|---|
| Claude Code（由收集器執行） | Anthropic | Claude Code 自己處理，收集器不讀取、不持有 token | 取得 Claude 額度與方案名稱 | launchd 每 5 分鐘 |
| Codex CLI（由收集器執行） | OpenAI | Codex CLI 自己處理，收集器不讀取 `~/.codex/auth.json` | 取得 Codex 額度與方案名稱 | launchd 每 5 分鐘 |
| Mac 收集器 | 你的 Cloudflare Worker `POST /usage` | 寫入密鑰 | 用量快照（見下方） | 每 5 分鐘，有設定中繼時 |
| Mac／PC 收集器（只在設定第二層後） | 你的 Worker `POST /tokens/daily`、`GET /tokens/daily`（只在存了讀取密鑰的電腦：Mac，或以 `set-tier2.ps1 -ReadKey` 設定的 PC） | 這台電腦的寫入密鑰；讀取密鑰 | 上傳每日 Token 加總；下載其他電腦的（見 [docs/tier2-setup.md](docs/tier2-setup.md)） | 有變動時每小時一次＋日期改變後的第一輪；下載每小時一次 |
| Mac／PC 收集器（只在 `set-tier2.sh --agent-sync`／`set-tier2.ps1 -AgentSync` 打開後） | 你的 Worker `POST /agents/state`、`GET /agents/state`（[ADR-0019](docs/adr/0019-windows-agent-state-and-sync.md) 第 2 節） | 這台電腦的寫入密鑰；讀取密鑰 | 上傳每個 AI 的狀態、工作階段數與進入狀態的時間（沒有資料夾名稱、工作階段 ID 或任何內容）；下載其他電腦的，寫成 `agent-remote.json` | App 的彙總改變時（最短 1 分鐘一次）、沒變時每 10 分鐘，以及每 5 分鐘一輪 |
| Mac 收集器 | `status.claude.com`、`status.openai.com` | 無（只有固定的 User-Agent） | 取得公開的服務狀態，不送出任何使用者資料 | 至少間隔 4 分鐘 |
| iPhone App（含 Live Activity 的「更新」按鈕與捷徑） | 你的 Worker `GET /usage` | 讀取密鑰 | 取得快照 | 打開 App、回到前景、下拉、按卡片上的「更新」、捷徑自動化 |
| iPhone App | 你的 Worker `GET /agents/state` | 讀取密鑰 | 取得其他電腦的 AI 狀態（中繼設定 `AGENT_SYNC=on` 時才有） | 打開 App、回到前景、下拉更新 |
| iPhone 主畫面／鎖定畫面小工具 | 你的 Worker `GET /usage` | 讀取密鑰 | 取得快照 | 約每 25 分鐘（資料過期時每小時），受 WidgetKit 每日次數限制；按小工具上的「更新」 |
| iPhone App | 你的 Worker `POST /pair/claim` | 不需要密鑰（一次性短碼） | 送出短碼、取得讀取密鑰 | 只在你按「輸入短碼」時 |
| `setup-iphone.sh --pair code`（Mac） | 你的 Worker `POST /pair` | 寫入密鑰（從 Keychain 經標準輸入交給 curl） | 取得一次性短碼 | 只在你執行時 |
| `setup-relay.sh`（Mac） | Cloudflare（以 wrangler） | 你登入 Cloudflare 的 wrangler 帳號 | 建 KV、部署 Worker、設定兩把密鑰；確認網址回應 | 只在你執行時 |
| Apple Watch App | 你的 Worker `GET /usage` | 讀取密鑰 | 取得快照 | 打開 App、回到前景、背景重新整理（約每 30 分鐘） |
| Mac 選單列 App | App 本身不連網；按服務狀態的「狀態頁」時以預設瀏覽器打開 status.claude.com／status.openai.com，按「更新」時執行 `launchctl kickstart` 讓收集器立即執行 | — | — | 只在你按下時 |
| Windows App | 不連網、不持有密鑰（CI 以 `windows/tools/check-no-network.py` 檢查原始碼）；按「立即更新」時執行 `schtasks /Run` 讓收集器立即執行；點面板上的事故時用預設瀏覽器打開事故頁（只接受 `https://status.claude.com/incidents/…`、`https://status.openai.com/incidents/…`，App 本身不連線） | — | — | 只在你按下時 |
| Live Activity 畫面、錶面複雜功能 | 不連網 | — | 只讀 App 傳來的資料 | — |

上傳到 Worker 的快照只有：`schema_version`、`updated_at`，以及每個服務的方案名稱（如 Max、Team）、錯誤訊息（不含 token）、各額度的 id／名稱／已用 %／重置時間／是否隱藏與預測（`forecast`：預計用完的時間、是否不到 1 小時、比平常快幾倍）、公開狀態頁的進行中事故（`incidents`：最多 3 項，名稱／影響程度／事故頁連結／開始時間），以及 Codex 重置次數卷的張數與各張到期時間。不含 token、email、帳號 ID、對話內容、Token 統計或額度歷史（第二層的每日 Token 加總另存在 D1，欄位見 [docs/tier2-setup.md](docs/tier2-setup.md)）。Worker 會驗證格式並只保存上述欄位，其他欄位一律移除；只保存最新一筆（KV 的 `latest`），回應帶 `Cache-Control: no-store`。

Debug 版本的示範模式、截圖工具與環境變數覆寫（`AUM_*`）都以 `#if DEBUG` 排除，Release 版本不包含（`scripts/verify-all.sh` 會檢查 Release 執行檔中沒有這些字串；Swift 把 15 個位元組以內的字串直接編進指令、`strings` 看不到，所以另外以 `scripts/check-debug-env.py` 檢查原始碼：`"AUM_…"` 只能出現在 `#if DEBUG` 裡，`AUM_TESTING` 例外）。`AI_USAGE_MONITOR_HOME` 在 Release 也有效，與收集器相同，只影響讀取本機檔案的位置。

### 已知取捨

- 手錶的設定只在手錶 App 開啟、且 iPhone 在附近時同步。在 iPhone 改了網址或密鑰後，要打開一次手錶 App 才會套用。
- Mac 選單列 App 不開沙盒（需要讀取 `~/Library/Application Support`），以 Sign to Run Locally 簽署、未開 Hardened Runtime。它不連網，也不讀任何 token 或對話紀錄。
- Token 統計只算這台 Mac 的 Claude Code 與 Codex CLI；網頁、手機 App、其他電腦與雲端 session 不在內（面板標「這台 Mac」）。
- **WSL 裡的 AI 不會被偵測**：在 Windows 的 WSL（或虛擬機、容器）裡執行的 Claude Code、Codex 用的是 Linux 那側的設定檔與對話紀錄。設定裡的「連接」只改 Windows（或 Mac）本身的設定檔，App 也不去 WSL 裡偵測，所以 WSL 裡的 AI 不會出現在瀏海、圓環的 AI 狀態，預設也不算進 Token 統計；額度不受影響（額度以帳號計算）。見 [ADR-0019](docs/adr/0019-windows-agent-state-and-sync.md) 第 1 節。
- Spotlight：資料夾 `~/Library/Application Support/AIUsageMonitor`（`usage.json`、`history.sqlite3`）只有數字，但不需要被搜尋。建置資料夾（`build/`、`~/Library/Caches/AIUsageMonitor/DerivedData`）由各腳本放 `.metadata_never_index`，新版 macOS 不一定採用這個檔案；要確實排除，在「系統設定 → Spotlight → 搜尋隱私權」（或「Spotlight 隱私權」）加入 repo 的 `build/` 與上面兩個資料夾。

## 免責聲明

本專案為個人學習作品，與 Anthropic、OpenAI 無關。服務圖示為原創，不使用官方 logo。Claude 用量取自 Claude Code `/usage` 指令的輸出、Codex 用量取自 Codex CLI 使用的非公開介面、Token 統計取自兩者的本機對話紀錄格式，都**沒有文件保證**，可能隨時變更或失效。
