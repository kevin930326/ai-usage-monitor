# 開發流程

本專案採用簡化的 GitHub Flow，每個功能都經過 Issue → 分支 → PR → 合併。

## 1. 里程碑

| 版本 | 內容 | 對應需求 |
|---|---|---|
| v0.1 | Mac 收集器：終端機印出統一格式 JSON | FR-1 ~ FR-3 |
| v0.2 | launchd 排程 + 中繼 API + 本機 usage.json | FR-4 ~ FR-6, FR-13, FR-14, FR-20 |
| v0.3 | iOS App 主畫面顯示用量 | FR-7 |
| v0.4 | Live Activity + 更新按鈕 | FR-8, FR-9, FR-11, FR-12, FR-15 ~ FR-17, FR-26 |
| v0.5 | 捷徑 Intent + 自動化 | FR-10 |
| v1.0 | 文件、截圖、Demo GIF、隱私章節 | NFR-6 |
| v1.1 | 用完時間預測、門檻通知 | FR-18, FR-19 |
| v1.2 | Mac 選單列 App + 桌面小工具 | FR-21 ~ FR-24, NFR-7 |
| v1.3 | Mac 面板動態／3D 視覺 | FR-25, NFR-8 |

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
`scope`：`collector` `relay` `ios` `mac` `kit` `docs`

## 4. Pull Request

- 標題同 commit 格式，內文連結 Issue（`Closes #N`）。
- 使用 PR 模板，勾選測試與安全檢查。
- 合併方式：Squash merge，保持 `main` 歷史乾淨。

## 5. 發版

每個里程碑完成後：更新 `CHANGELOG.md` → 打 tag `vX.Y.0` → 建立 GitHub Release。

## 6. 安全檢查（每次 push 前）

- `git diff --staged` 確認沒有 token、密鑰、個人帳號資訊。
- 新的設定檔先寫 `.example` 版本，真實檔案加入 `.gitignore`。
