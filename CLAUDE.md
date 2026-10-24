# CLAUDE.md

## 資料夾與 worktree

- `~/Documents/ai-usage-monitor`（主資料夾）是 launchd 收集器與 iPhone 自動重裝排程的執行位置，**一律維持在 `main`**：不要切換分支、不要在這裡開發、不要移動或改名。
- 新的 worktree 一律建在 `~/Documents/ai-usage-monitor-work/worktrees/<分支名稱>`，例如：

  ```bash
  git -C ~/Documents/ai-usage-monitor worktree add \
    ~/Documents/ai-usage-monitor-work/worktrees/feat/my-change -b feat/my-change origin/main
  ```

- 搬移 worktree 用 `git worktree move`，不要直接 `mv`；PR 合併後用 `git worktree remove` 移除，再刪掉本機與遠端分支。
- `~/Documents/ai-usage-monitor-work/archive/` 放不再使用的舊資料夾（不是 worktree）。

## 開 PR 前

- `scripts/verify-all.sh` 通過後，**先跑 `scripts/codex-review.sh` 並寫 triage**，再開 PR（或 push 最後一版）。流程、triage 格式與 Codex 額度不足時的替代做法見 `.claude/skills/codex-review/SKILL.md`。
- 只修 triage 中接受的項目，每項一個 commit；PR 內文附 triage 摘要。

## 截圖比對

- `scripts/verify-all.sh` 會跑 `scripts/snapshots.sh`：以固定時間、時區與假資料用 ImageRenderer 產生 Mac 面板、完整統計、設定、選單列圖示，以及 iPhone 小工具、鎖定畫面 Live Activity、動態島（淺色、深色），和 `apple/Snapshots/` 的基準比對，容許小誤差。
- 畫面**有意**改變時執行 `scripts/update-snapshots.sh` 更新基準，逐張檢查 `git diff` 中的圖再提交，PR 內文說明哪些截圖改了、為什麼。沒打算改畫面卻不符時，看 `build/snapshots/diff/` 的差異圖找原因，不要直接更新基準。
- 基準綁定產生它的環境（`apple/Snapshots/<平台>/ENVIRONMENT`：Mac 記 macOS 與 Xcode，iPhone 記 Xcode 與模擬器）；某平台環境不同時，該平台的畫面差異只印警告、不算失敗（CI 的 macOS runner 通常屬於這種），缺圖或讀不到圖仍算失敗。升級 macOS 或 Xcode 後先在 main 上更新基準。

