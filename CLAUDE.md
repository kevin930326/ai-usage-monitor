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
