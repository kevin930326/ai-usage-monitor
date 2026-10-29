# ADR-0013：下載與安裝（三層：Mac、加 iPhone、加 PC）

- 狀態：**已採用**（2026-10-24 提議，同日由使用者採用）
- 日期：2026-10-24
- 相關需求：FR-4、FR-20、FR-50、FR-53、FR-55、FR-57（本 ADR 新增）、NFR-1、NFR-3、NFR-6、NFR-9
- 相關：[ADR-0001](0001-cloudflare-worker-relay.md)（中繼）、[ADR-0006](0006-claude-usage-via-cli.md)、[ADR-0007](0007-codex-usage-via-app-server.md)（收集器怎麼拿用量）、[ADR-0008](0008-mac-panel-layout.md) 第 8 節（App 不連網）、[ADR-0011](0011-multi-device-usage.md)（第二層）、[ADR-0012](0012-iphone-pairing.md)（配對：一次性短碼、到期、嘗試次數與密鑰保存方式）

## 背景

目前的安裝要 clone repo、自己有 Python 3、跑 `collector/scripts/install-launchd.sh` 與 `scripts/install-mac-app.sh`（後者還要 Xcode）。目標是讓別人（以及重裝時的自己）用最少的步驟裝好：

| 層 | 內容 | 目標 |
|---|---|---|
| 第 0 層 | 只用 Mac：收集器＋選單列 App | 下載 → 打開 → 完成；不用終端機、不用自己裝 Python |
| 第 1 層 | 加 iPhone：部署自己的中繼、配對 | 一個腳本部署中繼；QR／短碼配對；iPhone App 的建置與安裝盡量自動 |
| 第 2 層 | 加 PC：Windows 收集器＋第二層 Token 合併 | PowerShell 一行安裝；以 `scripts/relay-device.sh` 產生的裝置密鑰加入（以短碼加入之後再做） |

不能繞過的限制：沒有付費 Apple Developer 帳號 → Mac App 無法公證（Gatekeeper 會擋）、iPhone App 無法上架或 TestFlight；Claude Code／Codex 由使用者自己登入；不幫別人代管中繼（ADR-0001、BACKLOG 第 6 節）。

## 決定摘要

| # | 題目 | 決定 |
|---|---|---|
| 1 | Mac 發布格式 | **兩者都提供**：`.dmg`（第 0 層，不用終端機）與一行安裝指令（`install.sh`，給會用終端機的人與更新） |
| 2 | 收集器放進 App | **(a) 內嵌 python-build-standalone**（固定版本＋SHA-256，精簡後約 27 MB、壓縮後約 10 MB），與 Windows 共用同一份 Python 程式 |
| 3 | 背景執行 | App 以 `SMAppService.agent` 註冊 App 內的 LaunchAgent；**ad-hoc 簽署可行**（原型驗證，見第 3 節）。偵測到舊的 `install-launchd.sh` 安裝時**不註冊**，只提示遷移，由使用者按下 |
| 4 | 原則修訂 | 放寬「App 不負責安裝」：App 可以註冊／解除自己內建的收集器、以內建收集器寫 `config.json` 的路徑與服務欄位。**維持**：App 不連網、不持有密鑰、不讀憑證與對話內容 |
| 5 | 更新 | 今晚不做自動更新；重新下載 `.dmg` 或重跑一行安裝指令。未來選項：收集器（已會連網）查 GitHub 最新版本寫入本機檔案，App 只顯示 |
| 6 | iPhone 安裝 | **主要：用自己的 Apple ID 經 Xcode 安裝**（`scripts/setup-iphone.sh` 自動化＋既有的每週自動重裝）；**輕量：Scriptable 小工具**；SideStore／AltStore 只列為未驗證的替代 |
| 7 | 發布流程 | `.github/workflows/release.yml`：打 `v*` tag 時建置 Mac（.dmg、.zip、SHA256SUMS）與 Windows（.zip）並建立**草稿** Release；`workflow_dispatch` 只產出 artifact（今晚只驗證這個，不打 tag） |

## 1. Mac App 的發布格式

### 選項

| | A. `.dmg`（拖進「應用程式」） | B. 一行安裝指令（`curl … \| bash`） |
|---|---|---|
| 步驟 | 下載 → 打開 .dmg → 拖到「應用程式」→ 打開 → 被擋 → 「系統設定 › 隱私權與安全性」按「強制打開」→ 輸入密碼 → 再打開一次 | 終端機貼一行 → 輸入 y 確認 → 完成（App 自動打開） |
| Gatekeeper | 瀏覽器下載的檔案帶 `com.apple.quarantine`，未公證的 App 第一次打開一定被擋（原型的 ad-hoc App 以 `spctl -a -t exec` 評估為 `rejected`）。macOS 15 起 Finder 的「右鍵 › 打開」不再能略過，只能到系統設定按「強制打開」 | `curl` 與 `ditto` 不會加隔離屬性，Gatekeeper 不檢查這個 App，打開時不跳警告 |
| 需要終端機 | 否 | 是 |
| 驗證完整性 | 使用者可以自己比對 SHA-256（Release 頁附 `SHA256SUMS`），實際上很少人做 | 腳本內固定版本與 SHA-256，下載後比對，不符就停止 |
| 更新 | 重新下載、拖進去取代 | 重跑同一行 |

**為什麼終端機下載不跳 Gatekeeper**：Gatekeeper 只檢查帶隔離屬性的檔案。隔離屬性是「會下載檔案的 App」（Safari、Chrome、Mail、AirDrop…）依 `LSFileQuarantineEnabled` 自己加上的；`curl`、`ditto`、`tar` 不會加。所以以 `curl` 下載、`ditto` 解壓的 App 沒有隔離屬性，打開時不經過 Gatekeeper 的評估，也就不會出現「無法驗證開發者」。

**風險**：這等於使用者把「這個 App 可不可以信任」的判斷交給這一行指令與它的下載來源，沒有 Apple 的任何檢查。來源（GitHub 帳號、Release 檔案、腳本）被竄改時，惡意程式會直接執行、沒有任何警告。緩解：

1. 一行指令只指向 **GitHub 上固定 tag 的 `install.sh`**（`…/releases/download/vX.Y.Z/install.sh`），不用 `latest`，不經過短網址或第三方網域。
2. `install.sh` 內寫死該版本 zip 的 SHA-256（發布流程產生），下載後比對；不符就停止、不安裝。SHA-256 與 zip 在同一個來源，所以它保護的是「傳輸與快取的完整性」，不能防止 Release 本身被替換；這一點寫進 README。
3. 文件同時提供「先下載、看過內容再執行」的兩步驟版本，以及可選的 `gh attestation verify`（發布流程產生 GitHub 的建置來源證明，第 7 節）。
4. 腳本不使用 `sudo`；只寫 `/Applications`（或 `AUM_INSTALL_DIR`）與使用者自己的資料夾。

### 決定

**兩者都提供**。第 0 層的目標是「不需要終端機」，只有 `.dmg` 做得到；一行指令步驟最少、可以重跑來更新，也讓 App 內嵌的 Python 不帶隔離屬性（見第 3 節「隔離屬性與內嵌的 Python」）。README 先列 `.dmg`，附「強制打開」的圖解；一行指令放在下一小節並寫清楚上面的風險。

## 2. 收集器放進 App

### 選項

| | (a) 內嵌獨立的 Python | (b) 以 Swift 重寫 Mac 端收集器 | (c) 要求使用者自備 `python3` |
|---|---|---|---|
| 第 0 層「不用自己裝 Python」 | ✅ | ✅ | ❌（乾淨的 Mac 沒有 python3；`/usr/bin/python3` 只是安裝 Command Line Tools 的提示） |
| 與 Windows 共用程式 | ✅ 同一份 `usage_collector`（FR-48） | ❌ 兩份實作：Claude／Codex 的解析、Token 統計白名單、歷史資料庫、上傳都要寫兩次，任何格式變更（ADR-0006、0007、0009）兩邊一起改 | ✅ |
| 維護成本 | 每次發布前更新固定版本（一行），跑既有的 217 個收集器測試 | 高：約 2,200 行 Python＋217 個測試要重寫並長期維持一致 | 低，但要處理各種 Python 版本與安裝方式（Homebrew、pyenv、python.org） |
| App 大小 | 目前 4.5 MB → 約 32 MB（壓縮後下載約 15 MB） | 約 5 MB | 4.5 MB |
| 安全更新 | 由我們發布：python-build-standalone 每週有新版，發布前更新；App 不自動更新（第 5 節），舊版的 Python 不會自己修補 | 只依賴系統框架，由 macOS 更新 | 由使用者自己的 Python 負責 |

### 大小量測（2026-10-24，python-build-standalone `20261013`，CPython 3.13.16，`aarch64-apple-darwin-install_only_stripped`）

| | 解壓後 | 壓縮 |
|---|---|---|
| 原始 | 65 MB | 25.3 MB（.tar.gz） |
| 精簡後（刪 `include`、`share`、tcl/tk、`idlelib`、`tkinter`、`turtledemo`、`ensurepip`、`pydoc_data`、`pip`、`libpython3.13.dylib`、`config-3.13-darwin`、`__pycache__`） | **27 MB** | **10.4 MB**（zip） |
| 收集器 `usage_collector` | 0.3 MB | — |

- 精簡後的 Python 跑完收集器全部 217 個測試（`-B`，不寫 `.pyc`），`ssl`（OpenSSL 3.5.9）與 `sqlite3`（3.53.1）都可用，預設就讀到系統的 128 張根憑證（另外在 LaunchAgent 設 `SSL_CERT_FILE=/etc/ssl/cert.pem` 以免版本改變）。
- `bin/python3.13` 是靜態連結（只連系統的 libz、libedit、ncurses、CoreFoundation、SystemConfiguration），不需要 `libpython3.13.dylib`。
- 目前的 App 只建置 arm64（Xcode 27 的標準架構；macOS 27 起只支援 Apple 晶片），內嵌的 Python 也只放 arm64。Intel Mac（macOS 14～26）本來就跑不了這個 App；要支援時再加 x86_64 版（約 +27 MB，用 `lipo` 合併或分兩個下載）。

### 決定

**(a) 內嵌 python-build-standalone**：只有它同時做到「不用自己裝 Python」與「Mac／Windows 共用一份程式」。大小增加約 10 MB 下載量，可以接受。

- 版本與 SHA-256 寫死在 `scripts/fetch-python-runtime.sh`（從 astral-sh/python-build-standalone 的 GitHub Release 下載，與 Release 的 `SHA256SUMS` 比對），不在建置時取「最新」。
- 放在 `Contents/Resources/python/`，`usage_collector` 放進它的 `site-packages`，不依賴工作目錄；執行時用 `-I -B`（隔離模式、不寫 `.pyc`：寫入 App 內會讓簽章失效）。
- 整個 App 重新 ad-hoc 簽署（`codesign --force --deep -s -`）。
- 開發版（`scripts/install-mac-app.sh`、Xcode）**不含**內建的 Python：沒有內建收集器時 App 照舊用 `install-launchd.sh` 的收集器，行為與現在相同。

## 3. 背景執行：SMAppService

### 做法

- App 內放 `Contents/Library/LaunchAgents/io.github.kevin930326.AIUsageMenuBar.collector.plist`：`BundleProgram`＝`Contents/Resources/python/bin/python3.13`（App 內的相對路徑）、參數 `-I -B -m usage_collector --write-local --upload --quiet --agent app`、`StartInterval` 300、`RunAtLoad`、`ProcessType Background`、`SSL_CERT_FILE`。label 與舊的 `io.github.kevin930326.ai-usage-monitor` 不同。
- App 以 `SMAppService.agent(plistName:)` 的 `register()`／`unregister()`／`status` 管理。
- 日誌：LaunchAgent 不能寫 `~`，收集器在 `--agent app` 時自己把 stderr 接到 `~/Library/Logs/AIUsageMonitor/collector.log`（與舊安裝同一個檔案）。
- 「更新」按鈕（FR-50）的 `launchctl kickstart` 改為踢目前在用的 label（內建或舊的）。

### 最小原型（2026-10-24，macOS 27.0.1，`scripts/prototypes/smappservice/build-and-run.sh`）

ad-hoc 簽署（`Signature=adhoc`、`TeamIdentifier=not set`）的 `AUMProbe.app`，放在暫存資料夾（不在「應用程式」），內建一個每 10 秒寫一行時間的 LaunchAgent：

| 測試 | 結果 |
|---|---|
| `register()` | 成功，`status` 立刻是 `enabled`（不需要使用者先到「登入項目」允許；系統通知「已加入背景項目」） |
| agent 是否執行 | 25 秒內執行 3 次（`launchctl print` 顯示 `program identifier = Contents/Resources/agent.sh`、`parent bundle identifier` 為 App） |
| App 改版後重新 ad-hoc 簽署（cdhash 改變），不重新註冊 | 照常執行、`status` 仍是 `enabled` |
| App 搬到別的資料夾 | **不再執行**（launchd 記的是舊路徑，`last exit code = 78: EX_CONFIG`），`status` 仍回報 `enabled`；再呼叫一次 `register()` 也不會修好 |
| 搬家後 `unregister()` → `register()` | 恢復執行 |
| `unregister()` | 成功，`launchctl print` 找不到這個 label，`status` = `notRegistered` |

結論與因應：

1. **ad-hoc 簽署可行**，第 0 層不需要付費帳號就能有背景收集器。
2. App 不能只看 `status`：每次啟動比對 launchd 記錄的程式路徑是否在目前的 App 裡（`launchctl print` 的 `bundle path`／`program`，或 agent 最近一次的結束碼 78），不對就 `unregister()` 再 `register()`。`install.sh` 一律裝到同一個路徑，避免這種情況。
3. 使用者可以在「系統設定 › 一般 › 登入項目與延伸功能」把它關掉，這時 `status` 是 `requiresApproval`：精靈與設定顯示「需要在登入項目允許」與打開該頁的按鈕（`SMAppService.openSystemSettingsLoginItems()`）。

### 隔離屬性與內嵌的 Python

以 `.dmg` 安裝時整個 App（包含內嵌的 `python3.13`）都帶隔離屬性。使用者按「強制打開」核准的是 App 本身；由 launchd 直接執行的內嵌 Python 是否也被放行，今晚無法驗證（需要在系統設定按「強制打開」，不能代替使用者按）。保守做法：

- App 啟動時檢查內嵌 Python 是否仍帶 `com.apple.quarantine`；帶著時**不自動移除**，在精靈的「背景執行」步驟說明原因，由使用者按「允許內建收集器執行」才移除 App 自己資料夾內的隔離屬性（使用者已經核准過這個 App）。
- 一行安裝指令沒有這個問題（沒有隔離屬性）。
- 列入實機確認：`.dmg` 安裝 → 強制打開 → 不按按鈕時收集器是否能執行。

另外 App 從 `.dmg` 或「下載」直接執行時會被 App Translocation 搬到隨機的唯讀路徑（`/AppTranslocation/`），在那裡註冊的 agent 之後會失效（同上表「搬到別的資料夾」）：App 偵測到時不註冊，精靈第一步請使用者把 App 拖到「應用程式」再打開。

### 與舊的 `install-launchd.sh` 並存、偵測與遷移

| 情況 | App 的行為 |
|---|---|
| `~/Library/LaunchAgents/io.github.kevin930326.ai-usage-monitor.plist` 存在，或 `launchctl print gui/<uid>/io.github.kevin930326.ai-usage-monitor` 成功 | **不註冊內建收集器**（避免每 5 分鐘跑兩次、重複上傳、兩個程序同時寫 `history.sqlite3`）。設定與精靈顯示「正在使用 install-launchd.sh 安裝的收集器。可以改用 App 內建的收集器」＋「改用內建收集器」按鈕 |
| 使用者按「改用內建收集器」 | 1) `launchctl bootout` 舊的 label；2) 舊 plist 移到垃圾桶（可放回）；3) `register()` 內建的；4) `kickstart` 立即執行一次。資料夾、`config.json`、Keychain 的中繼密鑰都沿用，不需要重新設定 |
| 遷移後想回到舊安裝 | 設定按「停用內建收集器」，再執行 `collector/scripts/install-launchd.sh` |
| 兩個都在（例如遷移後又跑了舊的安裝腳本） | 內建收集器每次執行先檢查舊 plist；存在就記一行日誌並結束、不收集（`--agent app`）。舊的安裝腳本也印出提示 |
| 沒有舊安裝、有內嵌 Python、App 在「應用程式」資料夾、還沒註冊 | 首次打開時**自動註冊**（第 0 層「打開就完成」），並以內建收集器偵測 claude／codex 的路徑與登入狀態寫進 `config.json`（與 `install-launchd.sh` 相同的規則） |

兩個收集器同時寫 `history.sqlite3` 時 SQLite 的鎖可以保證不損壞，但會重複記錄與重複上傳；所以重點是「不同時存在」，不是加鎖。

### 解除安裝

- App 設定：「停用內建收集器」＝`unregister()`；資料不刪。
- `install.sh --uninstall`：先執行 `AIUsageMenuBar.app/Contents/MacOS/AIUsageMenuBar --unregister-collector`（App 解除註冊後立即結束），再把 App 移到垃圾桶；`--purge` 另外把資料夾與日誌移到垃圾桶。Keychain 的中繼密鑰只列出刪除指令，不自動刪。
- 直接把 App 丟到垃圾桶而沒先停用：launchd 之後找不到程式（`EX_CONFIG`），不會執行；「登入項目」可能留下一筆，到系統設定移除。寫進 `docs/uninstall.md`。

## 4. 修訂 App 的原則

| 原則（ADR-0008 第 8 節、README「隱私與安全」） | 修訂後 |
|---|---|
| App 不負責安裝 | **放寬**：App 可以註冊／解除自己 App 內的收集器（SMAppService），可以執行內建收集器的設定指令（偵測 claude／codex 路徑與登入狀態，寫 `config.json` 的 `claude_path`、`codex_path`、`enabled_providers`），可以在使用者按下時遷移舊安裝、移除自己 App 內的隔離屬性 |
| App 不連網 | **維持**：選單列 App 的 Swift 程式沒有任何網路請求；連網的仍只有收集器（Python，即使放在 App 內，也是另一個由 launchd 執行的程序）。配對（ADR-0012）不經過 App |
| App 不持有密鑰 | **維持**：中繼的讀寫密鑰只存在 Keychain，由終端機的設定腳本寫入、收集器讀取；App 不讀、不顯示、不產生密鑰。設定精靈只顯示「中繼：已設定／沒有設定」（看 `config.json` 的網址欄位是否存在） |
| App 不讀憑證與對話內容 | **維持**：精靈檢查 Claude Code／Codex 只執行 `claude auth status --json`、`codex login status` 看結束碼與登入方式，不讀 `auth.json`、Keychain 的憑證或對話紀錄 |

## 5. 更新

- **今晚不做自動更新**（App 不連網）。
- 使用者更新：重新下載 `.dmg` 拖進去取代；或重跑一行安裝指令（同一路徑覆蓋，舊版移到垃圾桶）。內建收集器的註冊跟著路徑，不需要重新註冊；App 啟動時仍會檢查（第 3 節）。資料與設定不受影響。
- 未來選項：

| | 做法 | 取捨 |
|---|---|---|
| 收集器查版本（建議） | 收集器每天一次查 GitHub 的最新 Release 版本號，寫入本機 `update.json`；App 只顯示「有新版本」與重跑指令的按鈕 | App 仍不連網；只多一個 GitHub API 請求（列入 README 的網路請求表）；不自動下載 |
| Sparkle | App 內建更新框架（EdDSA 簽署的 appcast） | App 要連網，違反第 4 節；仍無法公證 |
| Homebrew cask | `brew install --cask` | 未公證的 App 在 cask 的規範中越來越受限；要另外維護 tap |

## 6. iPhone：沒有付費帳號時的安裝方式

| | Xcode＋自己的 Apple ID（`scripts/setup-iphone.sh`） | SideStore／AltStore 側載 IPA | Scriptable 輕量版 |
|---|---|---|---|
| 需要 | Mac、Xcode、免費 Apple ID、iPhone 開發者模式、USB 或同一網路 | 電腦上的 AltServer（AltStore）或一次性的配對檔（SideStore）、免費 Apple ID、開發者模式、我們發布 IPA | App Store 的 Scriptable（免費），不用開發者模式 |
| 7 天限制 | 有；既有的 `scripts/reinstall-ios.sh`＋`install-reinstall-launchd.sh` 每 6 天自動重裝 | 有；SideStore 可在手機上自己續簽（需要定期連到配對的 VPN／Wi-Fi），AltStore 要電腦上的 AltServer | **沒有** |
| Live Activity／動態島 | ✅ | 預期可用（ActivityKit 不需要特別的權限），未驗證 | ❌ |
| 主畫面／鎖定畫面小工具 | ✅ | ⚠️ 側載工具會把 bundle ID 與 App Group 加上 Team ID 後綴，App 寫死的 App Group（`group.io.github.kevin930326.AIUsageMonitor`）與共用 Keychain 會對不上，小工具可能拿不到資料；要改成執行時讀 entitlements 才能支援 | ✅（Scriptable 自己的小工具，畫面較簡單） |
| 手錶 | ✅（另外用 Xcode 裝） | ❌（手錶 App 不在 IPA 內） | ❌ |
| 免費帳號的 App ID 限制 | 每 7 天 10 個 App ID；App＋小工具擴充＝2 個 | 同左，AltStore／SideStore 本身也佔一個 | 不佔 |

**決定**：

- 主要方式：**Xcode＋自己的 Apple ID**，由 `scripts/setup-iphone.sh` 自動化（檢查 Xcode 與 xcodegen、從 Xcode 的帳號找 Team ID、`xcrun devicectl` 找手機、建置與安裝、可選擇設定每週自動重裝）。只有這個能用到全部功能，且 7 天限制已有自動重裝處理。
- 輕量方式：**Scriptable 小工具**（文件附腳本，讀同一個中繼的讀取密鑰），給沒有 Xcode、不想開開發者模式的人；沒有 Live Activity。
- SideStore／AltStore：寫進文件作為「未驗證」的替代，今晚不發布 IPA（發布 IPA 也需要先改 App Group 的處理）。

## 7. 發布流程

`.github/workflows/release.yml`：

| 觸發 | 做什麼 |
|---|---|
| push tag `v*` | Mac：xcodegen、`scripts/build-release.sh`（Release 建置、內嵌 Python、ad-hoc 簽署、.zip、.dmg、`SHA256SUMS`、寫入 SHA-256 的 `install.sh`）；Windows：收集器＋PowerShell 腳本的 .zip（`collector/windows/` 存在時）；Windows App 的自含式 zip（x64、ARM64）與 `SHA256SUMS-windows`（ADR-0015，`windows` job）；產生建置來源證明（`actions/attest-build-provenance`）；以 `gh release create --draft` 建立**草稿** Release 並上傳檔案（要人到 GitHub 按發布） |
| `workflow_dispatch` | 同樣的建置，只上傳成 workflow artifact，不建立 Release、不產生證明 |
| `pull_request`（發布相關檔案改動時） | 同樣的建置與檢查，不上傳產出；刪除 artifact 的 job 上傳一個假的 artifact 再刪掉（乾跑） |

- 權限：預設 `contents: read`；只有建立草稿 Release 的 job 有 `contents: write`（以及證明需要的 `id-token: write`、`attestations: write`），只有刪除 artifact 的 job 有 `actions: write`。
- 第三方 action 固定到 commit SHA（供應鏈）。
- 今晚只寫 workflow，不打 tag、不建立 Release。這個 repo 是公開的，workflow artifact 任何登入 GitHub 的人都能下載，所以也不執行 `workflow_dispatch`；改以 `pull_request`（發布相關檔案改動時）跑同樣的建置與檢查、不上傳任何東西。
- 第一次發布：使用者決定直接打 tag 產生草稿 Release、看過再發布，不先跑 `workflow_dispatch`。
- **artifact 提前公開的時間縮短**（2026-10-29 修訂，winmascot-release 第 3 部分）：推 tag 時 `mac`、`windows` 兩個 job 把產出上傳成 workflow artifact，`draft-release` 再從那裡取檔建立草稿。
  repo 是公開的，artifact 任何登入 GitHub 的人都能下載，所以：
  - `delete-artifacts` job（`needs: [mac, windows, draft-release]`、`if: always()`）在草稿建立之後，以 `gh api` 刪除這次執行的所有 artifact，並再列一次確認沒有剩下（有剩下就失敗）。建置或建立草稿失敗、取消時也刪；所以 `draft-release` 失敗後只重跑失敗的 job 會找不到 artifact，要刪掉已建立的草稿（若有）後「Re-run all jobs」整個重來。
  - artifact 只保留 1 天（原本 14 天）：刪除的 job 失敗時，最多公開 1 天；這時到 Actions 頁面手動刪除。
  - 草稿 Release 的檔案只有 repo 的協作者看得到，按發布後才公開。
  - **仍有的公開時間窗**：artifact 從上傳完成起就能下載，到另一個建置 job 完成、草稿建好、`delete-artifacts` 執行後才刪；先完成的那邊（通常是 Windows）約公開十幾到幾十分鐘，後完成的約幾分鐘。
    接受這個窗：repo 與建置腳本都是公開的、產出只有 ad-hoc 簽署，窗內被拿到只是比發布早幾十分鐘拿到同樣的檔案，草稿看過才發布；而真正關掉窗的做法都有代價——
    上傳前加密要新增 repo 密鑰（不在這次的範圍）；改用 `actions/cache` 傳檔（沒有公開下載端點）是 best-effort、要另外刪 cache，列為之後可以做的改善。
  - **pull_request 乾跑**：建置照舊不上傳；`delete-artifacts` 上傳一個假的 `dry-run` artifact、找到它、刪掉、確認沒有剩下，驗證權限與 API 呼叫。fork 的 PR 沒有寫入權限，不跑這個 job。
  - 不採用「建置與建立草稿在同一個 job」：Mac 要 macOS runner、Windows 要 Windows runner，合不成一個 job；改成兩個 job 各自建立或更新草稿則要兩個 job 都有 `contents: write`，而且兩邊會搶著建立同一個 Release。
  - `workflow_dispatch` 的產出本來就是給人下載的 artifact，不刪（第 6 點：不執行）。

## 後果

- 第 0 層變成：下載 `.dmg` → 拖進「應用程式」→ 打開 →「強制打開」→ 完成（或一行指令）；收集器由 App 註冊，不需要 clone repo 或 Python。
- App 變大（約 4.5 → 32 MB）；每次發布要更新內嵌 Python 的版本並跑收集器測試。
- 新增：`scripts/fetch-python-runtime.sh`、`scripts/bundle-collector.sh`、`scripts/build-release.sh`、`scripts/install.sh`、`.github/workflows/release.yml`、App 的 `CollectorService`（偵測、註冊、遷移）、收集器的 `--agent app` 與 `setup` 指令。
- 既有的 `install-launchd.sh` 與 `install-mac-app.sh`（開發版）保留，行為不變；使用者目前的安裝不受影響，遷移只在使用者按下時進行。

## 使用者的決定（2026-10-24）

1. 採用這份 ADR。
2. 發布的 `.dmg`／`.zip` **只放 arm64** 的 Python，不打包 x86_64。
3. `.dmg` 安裝時「允許內建收集器執行」（移除 App 內的隔離屬性）**維持由使用者按**，首次打開時不自動移除。
4. 第一次發布直接打 `v*` tag 產生**草稿** Release，看過再按發布；**不執行** `workflow_dispatch`（理由見第 7 節；tag 建置的 artifact 仍會提前公開，見第 7 節的「注意」）。
5. Windows 的 `install.ps1` 訊息維持英文（Windows PowerShell 5.1 以 Latin-1 解碼 `irm` 下載的內容）。
6. `scripts/setup-relay.sh` 不建立 D1：第二層的 D1 照 `docs/tier2-setup.md` 另外建立。
