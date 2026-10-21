"""合併寫入 config.json 的一個欄位，保留其他欄位（relay_url、claude_path 等）。
用法：python3 update-config.py <config.json> <key> <value>

檔案不存在時建立新檔；檔案內容不是 JSON 物件時中止（結束碼 1），不覆寫，
避免洗掉其他設定。先寫暫存檔再改名，寫到一半中斷也不會留下壞掉的檔案。"""
import json
import os
import sys
import tempfile
from pathlib import Path


def update(path: Path, key: str, value: str) -> None:
    try:
        config = json.loads(path.read_text())
    except FileNotFoundError:
        config = {}
    except json.JSONDecodeError as e:
        raise SystemExit(f"{path} 不是有效的 JSON（{e}），沒有寫入，請先修正或刪除該檔案")
    if not isinstance(config, dict):
        raise SystemExit(f"{path} 不是 JSON 物件，沒有寫入")
    config[key] = value
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".config-", suffix=".json")
    with os.fdopen(fd, "w") as f:
        f.write(json.dumps(config, indent=2, ensure_ascii=False) + "\n")
    os.replace(tmp, path)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("用法：update-config.py <config.json> <key> <value>")
    update(Path(sys.argv[1]), sys.argv[2], sys.argv[3])
