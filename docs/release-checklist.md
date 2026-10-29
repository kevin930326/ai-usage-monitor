# 第一次發布的檢查清單

第一次以 `.github/workflows/release.yml` 發布時照這份做（ADR-0013 第 7 節、ADR-0015）。之後的發布可以照同樣的步驟，略過標「第一次」的項目。
**發布一律由人操作**：打 tag、按發布都要使用者自己做；自動化（包含 Claude）不打 tag、不建立或發布 Release。

## 1. 發布前決定（第一次）

- [ ] **artifact 提前公開（縮短，接受剩下的窗）**：`release.yml` 的 `delete-artifacts` job 在草稿建立後刪除這次執行的 artifact（失敗時也刪），artifact 只保留 1 天；pull_request 時以假的 artifact 乾跑。上傳到刪除之間（約十幾到幾十分鐘）artifact 仍可被下載，ADR-0013 第 7 節說明為什麼可以接受；確認接受後打勾。
- [ ] **Windows App 沒有程式碼簽章**：第一次打開會出現 SmartScreen「Windows 已保護您的電腦」，要按「其他資訊」→「仍要執行」。確認 README 的說明可以接受，或先取得簽章憑證（不在這份清單的範圍）。
- [ ] **Windows App 階段 1 已在實機確認**（ADR-0015）：至少在一台 Windows 11（x64）上解壓、打開、看到懸浮圓環與通知區域圖示、讀到收集器的 `usage.json`。ARM64 沒有實機時，在發布說明寫明「未在實機驗證」。
- [ ] **Mac App 的「強制打開」**：App 只有 ad-hoc 簽署（ADR-0013 第 1 節），第一次打開要在「系統設定 › 隱私權與安全性」按「強制打開」；README 的說明與實際畫面一致。

## 2. 版本號

- [ ] 決定版本號 `X.Y.Z`（Releases 上目前是 v0.5.0，只有原始碼）。
- [ ] `apple/MacMenuBar/project.yml`、`apple/iOSApp/project.yml`、`apple/WatchApp/project.yml` 的 `MARKETING_VERSION` 改成 `X.Y.Z`（三個一致；`build-release.sh` 預設讀 Mac 的）。
- [ ] Windows App 不用改：`scripts/package-windows-app.py` 以 `-p:Version=X.Y.Z` 建置，並檢查組件版本與 tag 相同。
- [ ] `CHANGELOG.md`：`## [Unreleased]` 改成 `## [X.Y.Z] - YYYY-MM-DD`，上面留一個空的 `## [Unreleased]`。
- [ ] README（英文與 `README.zh-TW.md`）裡「還沒有發布含 `.dmg` 與 `install.sh` 的版本」的提醒移除或改寫。
- [ ] 以上走一般的 PR 流程（verify-all、codex-review、CI）合併到 `main`。

## 3. 打 tag 之前

- [ ] `main` 的 CI 全綠，包含 `release.yml` 在 pull_request 的乾跑（Mac 建置與檢查、Windows 打包與啟動檢查）。
- [ ] 本機 `scripts/verify-all.sh` 通過。
- [ ] 可選：本機先打包一次確認大小與內容（只寫 `build/`，不上傳）：

  ```bash
  scripts/build-release.sh --version X.Y.Z
  ```

  ```bash
  python3 scripts/package-windows-app.py --version X.Y.Z --out build/release/windows
  ```

## 4. 打 tag（使用者）

- [ ] 在 `main` 的最新 commit 打 `vX.Y.Z` 並推上去。
- [ ] 等 `release` workflow 完成：`mac`、`windows`、`draft-release`、`delete-artifacts` 四個 job 都成功；這次執行的 Actions 頁面下方「Artifacts」是空的。
- [ ] `draft-release` 失敗時：先刪掉已建立的草稿（若有），再按「Re-run all jobs」整個重來；只重跑失敗的 job 會因 artifact 已刪而再失敗。

## 5. 檢查草稿 Release

- [ ] 檔案齊全：
  - Mac：`AIUsageMenuBar-X.Y.Z.zip`、`AIUsageMenuBar-X.Y.Z.dmg`、`install.sh`、`SHA256SUMS`
  - Windows 收集器：`AIUsageMonitor-collector-X.Y.Z.zip`、`install.ps1`（列在 `SHA256SUMS`）
  - Windows App：`AIUsageMonitor-windows-x64-X.Y.Z.zip`、`AIUsageMonitor-windows-arm64-X.Y.Z.zip`、`SHA256SUMS-windows`
- [ ] 下載後比對 SHA-256：

  ```bash
  shasum -a 256 -c SHA256SUMS
  ```

  ```bash
  shasum -a 256 -c SHA256SUMS-windows
  ```

- [ ] 建置來源證明（需要 `gh` 2.49 以上）：

  ```bash
  gh attestation verify AIUsageMenuBar-X.Y.Z.dmg --repo kevin930326/ai-usage-monitor
  ```

  Windows 的兩個 zip 也各驗一次。
- [ ] `install.sh` 裡的 `ZIP_SHA256` 等於 zip 的 SHA-256（workflow 已檢查，再看一眼）。
- [ ] Windows App 的 zip 裡只有 `AIUsageMonitor/` 一個資料夾，沒有 `.pdb`、測試組件（`*Tests.dll`、`xunit*`）；`AIUsageMonitor.exe` 的「內容 › 產品版本」是 `X.Y.Z`。
- [ ] 實際安裝一次：
  - Mac：從 `.dmg` 拖進「應用程式」、打開、完成設定精靈，選單列出現雙圓環、收集器開始寫 `usage.json`。
  - Mac 一行指令：在另一個使用者帳號或測試機跑 `install.sh`（Release 上的網址）。
  - Windows：解壓 zip、打開 `AIUsageMonitor.exe`（SmartScreen 見第 1 節），設定與記錄寫在 `%LOCALAPPDATA%\AIUsageMonitor\`（`windows-app.json`、`logs\windows-app.log`）。
- [ ] 發布說明：寫上主要變更（從 CHANGELOG 複製）、未在實機驗證的項目（Apple Watch、Windows ARM64 等）、SmartScreen 與「強制打開」的說明連結。

## 6. 發布（使用者）

- [ ] 在 GitHub 草稿上按「Publish release」。
- [ ] README 的 `vX.Y.Z` 範例網址可以實際下載（`releases/download/vX.Y.Z/install.sh`、`install.ps1`）。

## 7. 發布之後

- [ ] 中繼（Cloudflare Worker）**不隨 Release 部署**：有改到 `relay/` 時，另外照 `docs/tier2-setup.md` 部署。
- [ ] `delete-artifacts` 失敗過的話：到那次執行的 Actions 頁面確認 artifact 已刪（1 天後也會自動過期）。
- [ ] 把這次發布遇到的問題寫回這份清單。
