"""合併寫入 config.json 的一個欄位，保留其他欄位。
用法：python3 update-config.py <config.json> <key> <value>"""
import json
import sys
from pathlib import Path

path, key, value = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
try:
    config = json.loads(path.read_text())
except (FileNotFoundError, json.JSONDecodeError):
    config = {}
config[key] = value
path.write_text(json.dumps(config, indent=2, ensure_ascii=False) + "\n")
