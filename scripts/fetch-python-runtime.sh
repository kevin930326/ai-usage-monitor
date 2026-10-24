#!/bin/bash
# 下載 App 內嵌用的 Python 執行環境（ADR-0013 第 2 節），驗證 SHA-256 後解壓並精簡。
#
#   scripts/fetch-python-runtime.sh [輸出資料夾]     # 預設 build/python-runtime
#
# 版本與 SHA-256 固定寫在這裡（python-build-standalone 的 GitHub Release），不在建置時取「最新」。
# 更新版本：改 RELEASE、PYTHON_VERSION、SHA256（與 Release 的 SHA256SUMS 相同），再跑收集器測試：
#   AI_USAGE_MONITOR_HOME=$(mktemp -d) build/python-runtime/python/bin/python3.13 -B -m unittest   （在 collector/ 執行）
# 結果：<輸出資料夾>/python（bin/python3.13 與 lib/python3.13），已下載的壓縮檔留在 <輸出資料夾>/cache 重複使用。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$ROOT/build/python-runtime}
RELEASE=20261013
PYTHON_VERSION=3.13.16
ARCH=aarch64-apple-darwin
SHA256=16a5332fb0dcb77f163fc8f8cbccd95be1644cc53e68e5d2a79f50afd6680a0e
NAME=cpython-${PYTHON_VERSION}+${RELEASE}-${ARCH}-install_only_stripped.tar.gz
URL=https://github.com/astral-sh/python-build-standalone/releases/download/${RELEASE}/${NAME/+/%2B}

mkdir -p "$OUT/cache"
touch "$OUT/.metadata_never_index"
ARCHIVE=$OUT/cache/$NAME
if [ ! -f "$ARCHIVE" ] || [ "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')" != "$SHA256" ]; then
  echo "下載 Python ${PYTHON_VERSION}（${RELEASE}，${ARCH}）…"
  curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$ARCHIVE.part" "$URL"
  mv "$ARCHIVE.part" "$ARCHIVE"
fi
GOT=$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')
if [ "$GOT" != "$SHA256" ]; then
  echo "SHA-256 不符：預期 ${SHA256}，實際 ${GOT}；沒有解壓" >&2
  rm -f "$ARCHIVE"
  exit 1
fi

rm -rf "$OUT/python" "$OUT/python.tmp"
mkdir "$OUT/python.tmp"
tar -xzf "$ARCHIVE" -C "$OUT/python.tmp"
PY=$OUT/python.tmp/python
LIB=$PY/lib/python3.13
# 收集器只用標準函式庫的 json、sqlite3、ssl、urllib、subprocess…：其餘的開發工具、GUI 與 pip 都不需要
rm -rf "$PY/include" "$PY/share" "$PY/lib/pkgconfig" "$PY/lib/libpython3.13.dylib" \
       "$PY"/lib/libtcl* "$PY"/lib/tcl* "$PY"/lib/tk* "$PY"/lib/itcl* "$PY"/lib/thread* \
       "$LIB/idlelib" "$LIB/tkinter" "$LIB/turtledemo" "$LIB/ensurepip" "$LIB/pydoc_data" "$LIB/lib2to3" \
       "$LIB"/config-3.13-* "$LIB"/site-packages/pip* "$LIB"/lib-dynload/_tkinter*
(cd "$PY/bin" && rm -f idle3* pip* pydoc3* python3-config python3.13-config python && ln -sf python3.13 python3)
find "$PY" -name __pycache__ -type d -prune -exec rm -rf {} +
"$PY/bin/python3.13" -I -c 'import json, sqlite3, ssl, urllib.request, subprocess, zlib' \
  || { echo "精簡後的 Python 缺少收集器需要的模組" >&2; exit 1; }
mv "$PY" "$OUT/python"
rmdir "$OUT/python.tmp"
echo "Python ${PYTHON_VERSION}：$OUT/python（$(du -sh "$OUT/python" | awk '{print $1}')）"
