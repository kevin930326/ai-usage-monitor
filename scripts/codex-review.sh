#!/bin/bash
# 以 Codex 唯讀審查目前分支（開 PR 前執行，見 .claude/skills/codex-review/SKILL.md）。
#
#   scripts/codex-review.sh [--diff | --full]
#
#   --diff  （預設）只審 git diff origin/main...HEAD 的變更
#   --full  審查整個 repo 的目前狀態
#
# 報告：${AUM_REVIEW_DIR}（預設 ~/Documents/ai-usage-monitor-work/reviews）/<分支，斜線換成 ->-codex.md，
# Codex 的完整輸出在同名的 .log。模型固定 gpt-6.1-sol、reasoning effort medium、sandbox read-only；
# 模型無法使用、額度不足或執行失敗時印出原因並以非 0 結束，不改用其他模型，也不覆蓋上一份報告。
#
# 結束碼：0 完成；2 參數錯誤或沒有變更；3 找不到 codex；4 Codex 執行失敗（含額度不足、模型不可用）
set -euo pipefail
MODEL=gpt-6.1-sol
EFFORT=medium
FALLBACK_CODEX=/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex

MODE=diff
for arg in "$@"; do
  case "$arg" in
    --diff) MODE=diff ;;
    --full) MODE=full ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "不認得的參數：${arg}（只支援 --diff、--full）" >&2; exit 2 ;;
  esac
done

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "請在 repo（或它的 worktree）裡執行" >&2; exit 2; }
cd "$ROOT"
BRANCH=$(git rev-parse --abbrev-ref HEAD)
[ "$BRANCH" = HEAD ] && BRANCH=detached-$(git rev-parse --short HEAD)
OUT_DIR=${AUM_REVIEW_DIR:-$HOME/Documents/ai-usage-monitor-work/reviews}
mkdir -p "$OUT_DIR"
REPORT=$OUT_DIR/${BRANCH//\//-}-codex.md
LOG=$OUT_DIR/${BRANCH//\//-}-codex.log

if command -v codex >/dev/null 2>&1; then
  CODEX=$(command -v codex)
elif [ -x "$FALLBACK_CODEX" ]; then
  CODEX=$FALLBACK_CODEX
else
  echo "找不到 codex：PATH 中沒有，${FALLBACK_CODEX} 也不存在" >&2
  exit 3
fi

if [ "$MODE" = diff ]; then
  # 盡量比對最新的 main；離線時用本機已有的 origin/main
  git fetch -q origin main 2>/dev/null || echo "（無法 fetch origin/main，改用本機的 origin/main）" >&2
  # 先確認比較基準存在，再區分「沒有變更」(0)、「有變更」(1)與 git 錯誤（其他），錯誤時不呼叫 Codex
  if ! git rev-parse -q --verify 'origin/main^{commit}' >/dev/null; then
    echo "找不到 origin/main，無法決定審查範圍（先 git fetch origin main，或用 --full）" >&2
    exit 2
  fi
  if ! git merge-base origin/main HEAD >/dev/null 2>&1; then
    echo "HEAD 與 origin/main 沒有共同祖先，無法決定審查範圍（或用 --full）" >&2
    exit 2
  fi
  set +e
  git diff --quiet origin/main...HEAD
  DIFF_CODE=$?
  set -e
  if [ $DIFF_CODE -eq 0 ]; then
    echo "origin/main...HEAD 沒有變更，不需要審查（要審整個 repo 用 --full）" >&2
    exit 2
  elif [ $DIFF_CODE -ne 1 ]; then
    echo "git diff 失敗（exit ${DIFF_CODE}），沒有呼叫 Codex" >&2
    exit 2
  fi
  SCOPE="只審查 \`git diff origin/main...HEAD\` 的變更（先執行這個指令取得 diff；需要時可閱讀相關檔案的完整內容作為上下文，但只回報與這些變更有關的問題）。"
  RANGE="git diff origin/main...HEAD（$(git rev-parse --short origin/main)...$(git rev-parse --short HEAD)）"
else
  SCOPE="審查整個 repo 目前的狀態（HEAD $(git rev-parse --short HEAD)），以收集器、中繼、UsageKit 與各 App 的程式碼與腳本為主。"
  RANGE="整個 repo（HEAD $(git rev-parse --short HEAD)）"
fi

PROMPT="你是程式碼審查者。${SCOPE}
只能閱讀：不要修改、建立或刪除任何檔案，不要執行會寫檔、連網或改變 git 狀態的指令。
依據 repo 的 CLAUDE.md、需求文件（docs/01-requirements.md）、ADR（docs/adr/，ADR-0001～ADR-0011，特別是 ADR-0008～0011）與設計 skill（.claude/skills/ai-usage-monitor-design/SKILL.md）檢查：
1. 正確性（邏輯錯誤、邊界條件、競態、錯誤處理）
2. 隱私與資安（不得保存或輸出對話內容、提示詞、檔案或專案路徑、帳號資訊；檔案權限；密鑰；內容外洩到日誌或錯誤訊息）
3. 效能（NFR-8：面板關閉時不佔 CPU／GPU；NFR-10：量測門檻、收集器每次執行增加 < 1 秒）
4. 與需求文件或 ADR 不一致之處
5. 測試缺口
不要提純風格偏好。
輸出格式：報告最上方第一行註明「模型：<你的模型名稱與 reasoning effort>」。每一項用標題「C-01｜[嚴重度：高/中/低]｜標題」（依序編號），每項包含：檔案:行號、問題、證據、建議修正、驗收方式。沒有問題就寫「沒有發現問題」並說明檢查範圍。全部用繁體中文。"

TMP_REPORT=$(mktemp "$OUT_DIR/.codex-review.XXXXXX")
trap 'rm -f "$TMP_REPORT"' EXIT
echo "Codex 審查中（${MODE}，${MODEL}／${EFFORT}，唯讀）：${RANGE}" >&2
set +e
"$CODEX" exec -m "$MODEL" -c "model_reasoning_effort=\"$EFFORT\"" --sandbox read-only -C "$ROOT" \
  -o "$TMP_REPORT" "$PROMPT" </dev/null >"$LOG" 2>&1
CODE=$?
set -e

# 額度不足、模型不可用等錯誤：Codex 可能仍以 0 結束，所以也檢查輸出
FAIL_RE='usage limit|rate limit|quota|insufficient|exceeded|model .*(not found|not supported|does not exist|unavailable)|unsupported model|invalid model|unauthorized|401|403|stream error|ERROR'
reason() { grep -Ei "$FAIL_RE" "$LOG" | grep -v '^ *[-*>|#]' | tail -3 | cut -c1-300; }
WHY=
if [ $CODE -ne 0 ]; then WHY="exit ${CODE}"
elif [ ! -s "$TMP_REPORT" ]; then WHY="沒有產生報告"
elif ! grep -qE 'C-[0-9]+|沒有發現問題' "$TMP_REPORT"; then WHY="報告不是審查格式"
fi
if [ -n "$WHY" ]; then
  echo "Codex 審查失敗（${WHY}）。原因：" >&2
  r=$(reason || true)
  if [ -n "$r" ]; then echo "$r" >&2; else tail -5 "$LOG" | cut -c1-300 >&2; fi
  echo "完整輸出：${LOG}；沒有改用其他模型，上一份報告（若有）未被覆蓋" >&2
  exit 4
fi

# 標頭與內容先寫成同資料夾的暫存檔，成功後才以 rename 取代正式報告（中途失敗時舊報告不變）
FINAL_TMP=$(mktemp "$OUT_DIR/.codex-review.XXXXXX")
trap 'rm -f "$TMP_REPORT" "$FINAL_TMP"' EXIT
{
  echo "<!-- codex-review.sh：${MODEL}，reasoning effort ${EFFORT}，sandbox read-only；範圍：${RANGE}；$(date '+%Y-%m-%d %H:%M %Z') -->"
  echo
  cat "$TMP_REPORT"
} >"$FINAL_TMP"
mv -f "$FINAL_TMP" "$REPORT"
echo "報告：${REPORT}" >&2
echo "下一步：寫 triage（${REPORT%.md}-triage.md），見 .claude/skills/codex-review/SKILL.md" >&2
