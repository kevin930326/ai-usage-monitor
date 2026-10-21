import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "update-config.py"


def run(path: Path, key: str, value: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(SCRIPT), str(path), key, value],
                          capture_output=True, text=True)


class UpdateConfigTest(unittest.TestCase):
    """config.json 由收集器與 iPhone 重新安裝腳本共用，寫入一個欄位不能洗掉其他欄位。"""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = Path(self.dir.name) / "config.json"

    def tearDown(self):
        self.dir.cleanup()

    def test_keeps_other_keys(self):
        self.path.write_text(json.dumps({"relay_url": "https://relay.example.dev", "claude_path": "/bin/claude"}))
        self.assertEqual(run(self.path, "development_team", "ABCDE12345").returncode, 0)
        self.assertEqual(json.loads(self.path.read_text()), {
            "relay_url": "https://relay.example.dev",
            "claude_path": "/bin/claude",
            "development_team": "ABCDE12345",
        })

    def test_creates_missing_file(self):
        self.assertEqual(run(self.path, "iphone_udid", "0000-1111").returncode, 0)
        self.assertEqual(json.loads(self.path.read_text()), {"iphone_udid": "0000-1111"})

    def test_refuses_to_overwrite_broken_file(self):
        self.path.write_text('{"relay_url": "https://relay.example.dev",')
        result = run(self.path, "iphone_udid", "0000-1111")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.path.read_text(), '{"relay_url": "https://relay.example.dev",')

    def test_leaves_no_temp_files(self):
        run(self.path, "a", "1")
        run(self.path, "b", "2")
        self.assertEqual([p.name for p in self.path.parent.iterdir()], ["config.json"])


if __name__ == "__main__":
    unittest.main()
