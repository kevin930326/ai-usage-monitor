#!/bin/bash
# 畫面有意改變時重新產生截圖比對的基準（apple/Snapshots/），之後用 git diff 檢查每張的改變再提交。
#   scripts/update-snapshots.sh                  # Mac 與 iPhone
#   SNAPSHOT_PLATFORMS=mac scripts/update-snapshots.sh
exec "$(dirname "$0")/snapshots.sh" --update
