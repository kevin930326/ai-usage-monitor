# 開發流程

本專案採用簡化的 GitHub Flow，每個功能都經過 Issue → 分支 → PR → 合併。

## 1. 里程碑

| 版本 | 內容 | 對應需求 | 狀態 |
|---|---|---|---|
| v0.1 | Mac 收集器：終端機印出統一格式 JSON | FR-1 ~ FR-3 | ✅ 已發布 v0.1.0 |
| v0.2 | launchd 排程 + 中繼 API + 本機 usage.json | FR-4 ~ FR-6, FR-13, FR-14, FR-20 | ✅ 已發布 v0.2.0 |
| v0.3 | iOS App 主畫面顯示用量 | FR-7 | ✅ 已發布 v0.3.0 |
| v0.4 | Live Activity + 更新按鈕（含 Apple Watch 版面） | FR-8, FR-9, FR-11, FR-12, FR-15 ~ FR-17, FR-26, FR-27 | ✅ 已發布（併入 v0.5.0） |
| v0.5 | 捷徑 Intent + 自動化 | FR-10 | ✅ 已發布 v0.5.0 |
| v0.6 | iPhone 主畫面／鎖定畫面小工具 | FR-31, FR-32 | 🔀 已合併到 main（#32），未發版 |
| v1.0 | 文件、截圖、Demo GIF、隱私章節 | NFR-6 | 🔀 已合併到 main（#64、#88），未發版 |
| v1.1 | 用完時間預測、門檻通知 | FR-18, FR-19 | ↪️ 改在 Mac 實作：FR-18 併入 v1.5（FR-38），FR-19 併入 v1.8；iPhone 端未做 |
| v1.2 | Mac 選單列 App + 桌面小工具（桌面小工具 v1.5 移除，FR-24 不做） | FR-21 ~ FR-24, NFR-7 | ✅ 預覽版隨 v0.5.0 發布；之後由 v1.5～v1.8 改版 |
| v1.3 | Mac 面板動態／3D 視覺 | FR-25, NFR-8 | ↪️ 依 ADR-0010 分散到 v1.5～v1.8 各階段 |
| v1.4 | Apple Watch 錶面複雜功能 + 手錶 App | FR-28 ~ FR-30 | 🧪 預覽版隨 v0.5.0 發布，尚未在實機驗證 |
| v1.5 | Mac 面板第一階段：卡片式面板、雙圓環圖示、設定視窗、用得太快、更新按鈕 | FR-33 ~ FR-36, FR-38, FR-50 | 🔀 已合併到 main（#44），未發版 |
| v1.6 | 額度歷史與第一層：建議接下來用、重置時間軸、本週額度走勢、額度消耗、歷史設定 | FR-37, FR-39 ~ FR-42, FR-46 | 🔀 已合併到 main（#53），未發版 |
| v1.7 | 這台 Mac 的 Token 統計：收集器讀對話紀錄、統計卡片、完整統計視窗 | FR-43, FR-44 | 🔀 已合併到 main（#58、#59、#60），未發版 |
| v1.8 | 服務狀態、通知、右鍵選單與快捷鍵 | FR-19, FR-45, FR-47 | 🔀 已合併到 main（#61），未發版；通知、右鍵選單與快捷鍵待實機確認 |
| v1.9 | 安裝、配對與外觀：外觀設定、Mac 一鍵安裝與內建收集器、首次設定精靈、iPhone 配對與 `setup-iphone.sh`、一鍵部署中繼 | FR-51 ~ FR-56 | 🔀 已合併到 main（#81、#83～#87、#89），未發版；待實機確認（手動測試清單第 11～14 節）；中繼的短碼端點（#86）要重新部署中繼才有 |
| v2.0 | 多裝置 Token 合併（中繼 D1）、Windows 收集器與一行安裝 | FR-48, FR-49, FR-57 | 📬 PR 已開（#71、#73），待實機確認（PC 上的 W-1～W-10）；PC 以短碼加入第二層之後再做 |
| v1.10 | Codex 重置次數卷：收集器讀張數與到期時間、Mac 面板與 iPhone 主畫面顯示、Mac 到期通知 | FR-58, FR-59 | 📬 PR 已開（#94）；iPhone 要重新部署中繼才有 |

✅ 已發布　🔀 已合併、未發版　📬 PR 已開、未合併　🧪 待實機驗證　↪️ 範圍併入其他里程碑　⏳ 未開始。v1.5～v2.0 與 v1.10 的細節見[需求文件 3.7 節](01-requirements.md#37-里程碑mac-面板統計與安裝)。

## 2. 分支

- `main`：永遠可運作，只接受 PR 合併。
- `feat/<簡述>`、`fix/<簡述>`、`docs/<簡述>`：從 `main` 開出，一個分支對應一個 Issue。

## 3. Commit 訊息（Conventional Commits）

```
<type>(<scope>): <摘要>

feat(collector): add Claude usage provider
fix(relay): reject requests without bearer token
docs: add architecture diagram
```

`type`：`feat` `fix` `docs` `refactor` `test` `chore`
`scope`：`collector` `relay` `ios` `watch` `mac` `kit` `docs`

## 4. Pull Request

- 標題同 commit 格式，內文連結 Issue（`Closes #N`）。
- 使用 PR 模板，勾選測試與安全檢查。
- 開 PR 前：`scripts/verify-all.sh` 全部通過，再以 `scripts/codex-review.sh` 審查並寫 triage，PR 內文附 triage 摘要（見 `.claude/skills/codex-review/SKILL.md`）。
- 合併方式：Squash merge，保持 `main` 歷史乾淨。

## 5. 發版

每個里程碑完成後：更新 `CHANGELOG.md` → 打 tag `vX.Y.0` → 建立 GitHub Release。

## 6. 安全檢查（每次 push 前）

- `git diff --staged` 確認沒有 token、密鑰、個人帳號資訊。
- 新的設定檔先寫 `.example` 版本，真實檔案加入 `.gitignore`。
