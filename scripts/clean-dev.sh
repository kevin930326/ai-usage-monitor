#!/bin/bash
# 列出（並在確認後清理）開發時累積的檔案。預設只列出，不刪任何東西。
#
#   scripts/clean-dev.sh                # 只列出每一類與大小
#   scripts/clean-dev.sh --clean        # 逐類詢問後清理（要在終端機執行）
#   scripts/clean-dev.sh --clean --yes  # 不詢問，全部清理（自動化用）
#
# 清理的範圍（都能重新產生，或已經是要丟的東西）：
#   1. 建置產物：主資料夾與每個 worktree 的 build/、apple/*/build/、apple/UsageKit/.build/
#      （有 build/install.lock 時略過那個資料夾：install-mac-app.sh 正在執行）
#   2. 這個專案超過 30 天沒更新的 Xcode DerivedData（AIUsageMenuBar-*、AIUsageMonitor-*、AIUsageWatch-*、UsageKit-*）。
#      iPhone 自動重裝用的 ~/Library/Caches/AIUsageMonitor/DerivedData 不在範圍內
#   3. 不用的模擬器：runtime 已移除、無法使用的模擬器（xcrun simctl delete unavailable）
#   4. 本機的 backup/* 分支（只刪本機，不碰遠端）
#   5. ~/Documents/ai-usage-monitor-work/design/_trash/ 中超過 30 天的項目：移到垃圾桶（不是直接刪除）
# 有 xcodebuild 正在執行時不清建置產物與 DerivedData（verify-all 或安裝進行中）。
# 不碰收集器的資料（~/Library/Application Support/AIUsageMonitor）、launchd 設定、reviews/ 與 design/ 的其他檔案。
#
# 測試用的覆寫：CLEAN_DEV_WORK（工作資料夾）、CLEAN_DEV_DERIVED（DerivedData）、CLEAN_DEV_TRASH（垃圾桶）、
# CLEAN_DEV_SIMCTL（取代 `xcrun simctl`）、CLEAN_DEV_DAYS（天數，預設 30）、CLEAN_DEV_BUSY_CHECK（取代 `pgrep -x xcodebuild`）。
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${CLEAN_DEV_WORK:-$HOME/Documents/ai-usage-monitor-work}
DERIVED=${CLEAN_DEV_DERIVED:-$HOME/Library/Developer/Xcode/DerivedData}
TRASH=${CLEAN_DEV_TRASH:-$HOME/.Trash}
DAYS=${CLEAN_DEV_DAYS:-30}
read -r -a SIMCTL <<<"${CLEAN_DEV_SIMCTL:-xcrun simctl}"
read -r -a BUSY_CHECK <<<"${CLEAN_DEV_BUSY_CHECK:-pgrep -x xcodebuild}"

CLEAN=0
YES=0
for arg in "$@"; do
  case "$arg" in
    --clean) CLEAN=1 ;;
    --yes) YES=1 ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) echo "不認得的參數：${arg}（只支援 --clean、--yes）" >&2; exit 2 ;;
  esac
done
if [ $CLEAN = 1 ] && [ $YES = 0 ] && [ ! -t 0 ]; then
  echo "--clean 要在終端機執行（會逐類詢問）；自動化時加 --yes" >&2
  exit 2
fi

size() {  # size <路徑...>：合計大小（人看的單位）
  [ $# -gt 0 ] || { echo "0B"; return; }
  du -shc "$@" 2>/dev/null | tail -1 | awk '{print $1}'
}

confirm() {  # confirm <說明>：--clean 時詢問，回答 y 才回傳 0
  [ $CLEAN = 1 ] || return 1
  [ $YES = 1 ] && return 0
  local answer
  read -r -p "  清理「$1」？[y/N] " answer
  [ "$answer" = y ] || [ "$answer" = Y ]
}

is_busy() { "${BUSY_CHECK[@]}" >/dev/null 2>&1; }
busy=0
if is_busy; then busy=1; fi
total_found=0

section() { echo; echo "== $1"; }

# 1. 建置產物
section "建置產物（build/、apple/*/build/、apple/UsageKit/.build/）"
builds=()
while IFS= read -r tree; do
  [ -d "$tree" ] || continue
  for dir in "$tree/build" "$tree"/apple/*/build "$tree/apple/UsageKit/.build"; do
    [ -d "$dir" ] || continue
    if [ -e "$tree/build/install.lock" ] && [ "$dir" = "$tree/build" ]; then
      echo "  略過 ${dir}（install-mac-app.sh 執行中）"
      continue
    fi
    builds+=("$dir")
    printf '  %-8s %s\n' "$(size "$dir")" "$dir"
  done
done < <(git -C "$ROOT" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
if [ ${#builds[@]} -eq 0 ]; then
  echo "  （沒有）"
else
  total_found=1
  echo "  合計 $(size "${builds[@]}")"
  if [ $busy = 1 ]; then
    [ $CLEAN = 1 ] && echo "  xcodebuild 正在執行，這次不清理建置產物"
  elif confirm "建置產物"; then
    # 等待回答的期間可能開始建置或安裝：刪除前再確認一次
    if is_busy; then
      echo "  xcodebuild 剛開始執行，這次不清理建置產物"
    else
      removed=0
      for dir in "${builds[@]}"; do
        if [ -e "$dir/install.lock" ]; then
          echo "  略過 ${dir}（install-mac-app.sh 剛開始執行）"
          continue
        fi
        rm -rf "$dir"
        removed=$((removed + 1))
      done
      echo "  已刪除 ${removed} 個資料夾"
    fi
  fi
fi

# 2. 舊的 DerivedData
section "超過 ${DAYS} 天沒更新的 DerivedData（${DERIVED}）"
derived=()
if [ -d "$DERIVED" ]; then
  while IFS= read -r dir; do
    derived+=("$dir")
    printf '  %-8s %s\n' "$(size "$dir")" "$(basename "$dir")"
  done < <(find "$DERIVED" -mindepth 1 -maxdepth 1 -type d \
    \( -name 'AIUsageMenuBar-*' -o -name 'AIUsageMonitor-*' -o -name 'AIUsageWatch-*' -o -name 'UsageKit-*' \) \
    -mtime +"$DAYS" | sort)
fi
if [ ${#derived[@]} -eq 0 ]; then
  echo "  （沒有）"
else
  total_found=1
  echo "  合計 $(size "${derived[@]}")"
  if [ $busy = 1 ]; then
    [ $CLEAN = 1 ] && echo "  xcodebuild 正在執行，這次不清理 DerivedData"
  elif confirm "舊的 DerivedData"; then
    if is_busy; then
      echo "  xcodebuild 剛開始執行，這次不清理 DerivedData"
    else
      rm -rf "${derived[@]}"
      echo "  已刪除 ${#derived[@]} 個資料夾"
    fi
  fi
fi

# 3. 不用的模擬器
section "無法使用的模擬器（runtime 已移除）"
unavailable=$("${SIMCTL[@]}" list devices unavailable 2>/dev/null | grep -E '\(unavailable' || true)
if [ -z "$unavailable" ]; then
  echo "  （沒有）"
else
  total_found=1
  echo "$unavailable" | sed 's/^ */  /'
  if confirm "無法使用的模擬器"; then
    "${SIMCTL[@]}" delete unavailable
    echo "  已刪除"
  fi
fi

# 4. 本機的 backup/* 分支
section "本機的 backup/* 分支"
branches=()
while IFS= read -r branch; do
  [ -n "$branch" ] && branches+=("$branch")
done < <(git -C "$ROOT" for-each-ref --format='%(refname:short)' 'refs/heads/backup/' 2>/dev/null)
if [ ${#branches[@]} -eq 0 ]; then
  echo "  （沒有）"
else
  total_found=1
  for branch in "${branches[@]}"; do
    printf '  %s  %s\n' "$branch" "$(git -C "$ROOT" log -1 --format='%h %cs %s' "$branch" | cut -c1-80)"
  done
  if confirm "backup/* 分支（只刪本機）"; then
    git -C "$ROOT" branch -D "${branches[@]}" >/dev/null
    echo "  已刪除 ${#branches[@]} 個分支"
  fi
fi

# 5. design/_trash 中的舊東西
TRASH_DIR=$WORK/design/_trash
section "超過 ${DAYS} 天的 ${TRASH_DIR}/ 項目（移到垃圾桶）"
old=()
if [ -d "$TRASH_DIR" ]; then
  while IFS= read -r item; do
    old+=("$item")
    printf '  %-8s %s\n' "$(size "$item")" "$(basename "$item")"
  done < <(find "$TRASH_DIR" -mindepth 1 -maxdepth 1 -mtime +"$DAYS" | sort)
fi
if [ ${#old[@]} -eq 0 ]; then
  echo "  （沒有）"
else
  total_found=1
  echo "  合計 $(size "${old[@]}")"
  if confirm "design/_trash 的舊項目"; then
    mkdir -p "$TRASH"
    stamp=$(date +%Y%m%d-%H%M%S)
    for item in "${old[@]}"; do
      mv "$item" "$TRASH/$(basename "$item")-clean-dev-${stamp}"
    done
    echo "  已移到垃圾桶（${TRASH}）"
  fi
fi

echo
if [ $total_found = 0 ]; then
  echo "沒有需要清理的東西。"
elif [ $CLEAN = 0 ]; then
  echo "只列出、沒有刪除。要清理：scripts/clean-dev.sh --clean"
fi
