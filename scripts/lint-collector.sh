#!/bin/bash
# 收集器的靜態檢查：ruff（風格與常見錯誤）＋ mypy（型別）。設定在 collector/pyproject.toml。
#
#   scripts/lint-collector.sh
#
# 工具版本固定在 collector/requirements-lint.txt；第一次執行時裝到 build/lint-venv（已在 .gitignore），
# 之後重用。收集器本身只用標準函式庫，這兩個工具只在開發與 CI 用。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VENV=${LINT_VENV:-$ROOT/build/lint-venv}
REQ=$ROOT/collector/requirements-lint.txt
mkdir -p "$ROOT/build"
touch "$ROOT/build/.metadata_never_index"
if [ ! -x "$VENV/bin/ruff" ] || [ ! -x "$VENV/bin/mypy" ] || ! cmp -s "$REQ" "$VENV/requirements-lint.txt"; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q --disable-pip-version-check -r "$REQ"
  cp "$REQ" "$VENV/requirements-lint.txt"
fi
cd "$ROOT/collector"
"$VENV/bin/ruff" check .
"$VENV/bin/mypy"
