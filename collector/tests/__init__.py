"""測試不能讀到這台電腦真的對話紀錄、也不能寫到真的資料夾（ADR-0009 的隱私規則）：
在任何測試模組匯入 usage_collector 之前，把資料夾與兩個紀錄資料夾都指到暫存位置。"""
import atexit
import os
import shutil
import tempfile

_HOME = tempfile.mkdtemp(prefix="aum-tests-")
atexit.register(shutil.rmtree, _HOME, ignore_errors=True)
os.environ.setdefault("AI_USAGE_MONITOR_HOME", os.path.join(_HOME, "app"))
os.environ["CLAUDE_CONFIG_DIR"] = os.path.join(_HOME, "claude")
os.environ["CODEX_HOME"] = os.path.join(_HOME, "codex")
