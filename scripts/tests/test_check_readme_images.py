"""scripts/check-readme-images.py：README 的截圖齊全，比對應的截圖基準舊時提醒。"""
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "check-readme-images.py"
HEADER = "# 圖片\t來源\t基準\t寬度\n"


class CheckReadmeImagesTests(unittest.TestCase):
    def setUp(self):
        self.repo = Path(tempfile.mkdtemp(prefix="aum-readme-images-"))
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", str(self.repo)]))
        self.git("init", "-q")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "user.name", "test")
        self.write("README.md", '<img src="docs/images/panel.png">\n')
        self.write("docs/images/SOURCES.tsv", HEADER + "panel.png\tmac:panel-light.png\tapple/Snapshots/mac/panel-light.png\t-\n")
        self.write("docs/images/panel.png", "image v1")
        self.write("apple/Snapshots/mac/panel-light.png", "baseline v1")
        self.commit("first", when=1_000_000)

    def git(self, *args, when=None):
        env = dict(os.environ)
        if when is not None:
            env["GIT_AUTHOR_DATE"] = env["GIT_COMMITTER_DATE"] = f"@{when} +0000"
        return subprocess.run(["git", "-C", str(self.repo), *args], capture_output=True, text=True, check=True, env=env)

    def write(self, rel, body):
        path = self.repo / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")

    def commit(self, message, when):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message, when=when)

    def run_check(self, *args, env=None):
        environ = {k: v for k, v in os.environ.items() if k != "GITHUB_ACTIONS"}
        environ.update({"README_IMAGES_ROOT": str(self.repo), **(env or {})})
        return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True, env=environ)

    def test_up_to_date_passes(self):
        r = self.run_check()
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("齊全", r.stdout)

    def test_baseline_committed_later_warns(self):
        self.write("apple/Snapshots/mac/panel-light.png", "baseline v2")
        self.commit("update baseline", when=2_000_000)
        r = self.run_check()
        self.assertEqual(r.returncode, 0)
        self.assertIn("docs/images/panel.png 比截圖基準 apple/Snapshots/mac/panel-light.png 舊", r.stdout)
        self.assertIn("scripts/update-readme-images.sh", r.stdout)
        self.assertEqual(self.run_check("--strict").returncode, 1)

    def test_image_updated_after_baseline_passes(self):
        self.write("apple/Snapshots/mac/panel-light.png", "baseline v2")
        self.commit("update baseline", when=2_000_000)
        self.write("docs/images/panel.png", "image v2")
        self.commit("update image", when=3_000_000)
        self.assertNotIn("提醒：", self.run_check().stdout)

    def test_uncommitted_baseline_change_warns_until_image_changes_too(self):
        self.write("apple/Snapshots/mac/panel-light.png", "baseline v2")
        self.assertIn("提醒：", self.run_check().stdout)
        self.write("docs/images/panel.png", "image v2")
        self.assertNotIn("提醒：", self.run_check().stdout)

    def test_missing_image_fails(self):
        self.write("README.md", '<img src="docs/images/panel.png"> <img src="docs/images/gone.png">\n')
        r = self.run_check()
        self.assertEqual(r.returncode, 1)
        self.assertIn("docs/images/gone.png 不存在", r.stdout)
        self.assertIn("docs/images/gone.png 沒有列在", r.stdout)

    def test_unlisted_image_fails(self):
        self.write("docs/images/extra.png", "x")
        self.write("README.md", '<source srcset="docs/images/extra.png"><img src="docs/images/panel.png">\n')
        r = self.run_check()
        self.assertEqual(r.returncode, 1)
        self.assertIn("docs/images/extra.png 沒有列在", r.stdout)

    def test_missing_baseline_fails(self):
        (self.repo / "apple/Snapshots/mac/panel-light.png").unlink()
        r = self.run_check()
        self.assertEqual(r.returncode, 1)
        self.assertIn("基準 apple/Snapshots/mac/panel-light.png 不存在", r.stdout)

    def test_image_without_baseline_is_not_compared(self):
        self.write("docs/images/SOURCES.tsv", HEADER + "panel.png\tios-screen:light\t-\t520\n")
        self.commit("no baseline", when=2_000_000)
        r = self.run_check("--strict")
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_unreferenced_source_warns(self):
        self.write("docs/images/other.png", "x")
        self.write("docs/images/SOURCES.tsv", HEADER + "panel.png\tmac:panel-light.png\tapple/Snapshots/mac/panel-light.png\t-\n"
                   "other.png\tmac:other.png\t-\t-\n")
        r = self.run_check()
        self.assertEqual(r.returncode, 0)
        self.assertIn("docs/images/other.png 列在", r.stdout)

    def test_github_actions_annotations(self):
        self.write("apple/Snapshots/mac/panel-light.png", "baseline v2")
        r = self.run_check(env={"GITHUB_ACTIONS": "true"})
        self.assertIn("::warning::docs/images/panel.png", r.stdout)

    def test_shallow_clone_says_history_is_missing(self):
        clone = Path(tempfile.mkdtemp(prefix="aum-readme-shallow-"))
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", str(clone)]))
        self.write("apple/Snapshots/mac/panel-light.png", "baseline v2")
        self.commit("update baseline", when=2_000_000)
        subprocess.run(["git", "clone", "-q", "--depth", "1", f"file://{self.repo}", str(clone / "r")], check=True)
        r = subprocess.run([sys.executable, str(SCRIPT)], capture_output=True, text=True,
                           env={**os.environ, "README_IMAGES_ROOT": str(clone / "r")})
        self.assertEqual(r.returncode, 0)
        self.assertIn("fetch-depth: 0", r.stdout)

    def test_git_failure_is_not_reported_as_up_to_date(self):
        # 不是 git 資料夾：所有 git 查詢都失敗
        plain = Path(tempfile.mkdtemp(prefix="aum-readme-nogit-"))
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", str(plain)]))
        for rel in ("README.md", "docs/images/SOURCES.tsv", "docs/images/panel.png", "apple/Snapshots/mac/panel-light.png"):
            (plain / rel).parent.mkdir(parents=True, exist_ok=True)
            (plain / rel).write_bytes((self.repo / rel).read_bytes())
        env = {k: v for k, v in os.environ.items() if k != "GITHUB_ACTIONS"}
        env.update({"README_IMAGES_ROOT": str(plain), "GIT_CEILING_DIRECTORIES": str(plain.parent)})
        r = subprocess.run([sys.executable, str(SCRIPT)], capture_output=True, text=True, env=env)
        self.assertEqual(r.returncode, 0)
        self.assertIn("無法查詢提交歷史", r.stdout)
        self.assertNotIn("齊全", r.stdout)
        self.assertNotIn(str(plain), r.stdout)
        r = subprocess.run([sys.executable, str(SCRIPT), "--strict"], capture_output=True, text=True, env=env)
        self.assertEqual(r.returncode, 1)

    def test_repository_is_consistent(self):
        r = subprocess.run([sys.executable, str(SCRIPT)], capture_output=True, text=True,
                           env={k: v for k, v in os.environ.items() if k not in ("README_IMAGES_ROOT", "GITHUB_ACTIONS")})
        self.assertNotIn("錯誤：", r.stdout)
        self.assertEqual(r.returncode, 0, r.stdout)


if __name__ == "__main__":
    unittest.main()
