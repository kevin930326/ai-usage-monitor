# 以截圖模式啟動 iPhone App，等它把 island-sizes.json 寫進 Documents（最後才寫，表示全部畫完）。
# scripts/snapshots.sh 與 scripts/update-readme-images.sh 以 source 載入；測試：scripts/tests/test_ios_render_launch.py。
#
#   SIMCTL_CHILD_AUM_RENDER=1 … launch_ios_render <UDID> <bundle ID> <Documents 資料夾> [App 的參數…]
#
# 剛開機後的第一次啟動，App 程序在、畫面卻常常沒出現；截圖由畫面的 .task 觸發，所以一張都不會輸出，
# `simctl bootstatus -b` 也等不到這一步。第一次啟動 IOS_RENDER_FIRST_WAIT 秒（預設 45）內一張 PNG 都沒有，
# 就結束 App 再啟動一次；已經開始畫（有 PNG）就繼續等，慢的機器不會被誤判。平常 2～15 秒完成。
# 每次啟動最多等 IOS_RENDER_WAIT 秒（預設 300）。完成回 0，兩次都沒完成回 1（呼叫端印「iOS 截圖逾時」）。
launch_ios_render() {
  local udid=$1 bundle=$2 docs=$3
  shift 3
  local first=${IOS_RENDER_FIRST_WAIT:-45} limit=${IOS_RENDER_WAIT:-300} attempt second
  for attempt in 1 2; do
    xcrun simctl launch --terminate-running-process "$udid" "$bundle" "$@" >/dev/null
    for second in $(seq "$limit"); do
      [ -f "$docs/island-sizes.json" ] && return 0
      if [ "$attempt" = 1 ] && [ "$second" -gt "$first" ] && ! compgen -G "$docs/*.png" >/dev/null; then break; fi
      sleep 1
    done
    [ -f "$docs/island-sizes.json" ] && return 0
    [ "$attempt" = 1 ] && echo "iOS 截圖：第一次啟動沒有完成（剛開機時畫面常常沒出現），重新啟動一次"
  done
  return 1
}
