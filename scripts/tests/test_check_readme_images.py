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
        self.write("README.md", '<img src="docs/images/panel.png">\n')
        self.write("docs/images/SOURCES.tsv", HEADER + "panel.png\tmac:panel-light.png\tapple/Snapshots/mac/panel-light.png\t-\n")
        self.write("docs/images/panel.png", "image v1")
        self.write("apple/Snapshots/mac/panel-light.png", "baseline v1")
        self.assertEqual(self.run_check("--record", "panel.png").returncode, 0)

    def write(self, rel, body):
        path = self.repo / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")

    def run_check(self, *args, env=None):
        environ = {k: v for k, v in os.environ.items() if k != "GITHUB_ACTIONS"}
        environ.update({"README_IMAGES_ROOT": str(self.repo), **(env or {})})
        return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True, env=environ)

    def test_up_to_date_passes(self):
        r = self.run_check()
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("齊全", r.stdout)

    def test_changed_baseline_warns(self):
        self.write("apple/Snapshots/mac/panel-light.png", "baseline v2")
        r = self.run_check()
        self.assertEqual(r.returncode, 0)
        self.assertIn("docs/images/panel.png 不是依目前的截圖基準 apple/Snapshots/mac/panel-light.png 產生的", r.stdout)
        self.assertIn("scripts/update-readme-images.sh", r.stdout)
        self.assertEqual(self.run_check("--strict").returncode, 1)

    def test_regenerated_image_that_did_not_change_stops_warning(self):
        # 基準改了別的區域，重新產生的 README 圖一模一樣：只有記錄更新，提醒就消失（以前比提交時間時消不掉）
        self.write("apple/Snapshots/mac/panel-light.png", "baseline v2")
        self.assertEqual(self.run_check("--record", "panel.png").returncode, 0)
        self.assertEqual((self.repo / "docs/images/panel.png").read_text(), "image v1")
        r = self.run_check("--strict")
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_baseline_changed_back_passes_again(self):
        self.write("apple/Snapshots/mac/panel-light.png", "baseline v2")
        self.assertIn("提醒：", self.run_check().stdout)
        self.write("apple/Snapshots/mac/panel-light.png", "baseline v1")
        self.assertNotIn("提醒：", self.run_check().stdout)

    def test_missing_record_warns(self):
        (self.repo / "docs/images/BASELINES.tsv").unlink()
        self.assertIn("docs/images/panel.png 不是依目前的截圖基準", self.run_check().stdout)

    def test_record_for_a_different_baseline_warns(self):
        self.write("apple/Snapshots/mac/panel-dark.png", "baseline v1")
        self.write("docs/images/SOURCES.tsv", HEADER + "panel.png\tmac:panel-dark.png\tapple/Snapshots/mac/panel-dark.png\t-\n")
        self.assertIn("提醒：", self.run_check().stdout)

    def test_record_keeps_other_images_and_rejects_unknown_ones(self):
        self.write("docs/images/other.png", "x")
        self.write("apple/Snapshots/mac/other.png", "other baseline")
        self.write("docs/images/SOURCES.tsv", HEADER + "panel.png\tmac:panel-light.png\tapple/Snapshots/mac/panel-light.png\t-\n"
                   "other.png\tmac:other.png\tapple/Snapshots/mac/other.png\t-\n")
        self.assertEqual(self.run_check("--record", "other.png").returncode, 0)
        records = (self.repo / "docs/images/BASELINES.tsv").read_text(encoding="utf-8")
        self.assertIn("panel.png\tapple/Snapshots/mac/panel-light.png\t", records)
        self.assertIn("other.png\tapple/Snapshots/mac/other.png\t", records)
        r = self.run_check("--record", "nope.png")
        self.assertEqual(r.returncode, 1)
        self.assertIn("nope.png 沒有列在", r.stdout)

    def test_missing_image_fails(self):
        self.write("README.md", '<img src="docs/images/panel.png"> <img src="docs/images/gone.png">\n')
        r = self.run_check()
        self.assertEqual(r.returncode, 1)
        self.assertIn("docs/images/gone.png 不存在", r.stdout)
        self.assertIn("docs/images/gone.png 沒有列在", r.stdout)

    def test_translated_readme_is_checked_too(self):
        self.write("README.zh-TW.md", '<img src="docs/images/panel.png"> <img src="docs/images/gone.png">\n')
        r = self.run_check()
        self.assertEqual(r.returncode, 1)
        self.assertIn("README.zh-TW.md 引用的 docs/images/gone.png 不存在", r.stdout)
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
        r = self.run_check("--strict")
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_post_processing_column_is_accepted(self):
        self.write("docs/images/SOURCES.tsv", HEADER + "panel.png\tmac:panel-light.png\tapple/Snapshots/mac/panel-light.png\t-\tcrop=0:1186 frame=24\n")
        r = self.run_check("--strict")
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_wrong_column_count_fails(self):
        self.write("docs/images/SOURCES.tsv", HEADER + "panel.png\tmac:panel-light.png\n")
        r = self.run_check()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("要 4 或 5 欄", r.stderr)

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

    def test_repository_is_consistent(self):
        r = subprocess.run([sys.executable, str(SCRIPT)], capture_output=True, text=True,
                           env={k: v for k, v in os.environ.items() if k not in ("README_IMAGES_ROOT", "GITHUB_ACTIONS")})
        self.assertNotIn("錯誤：", r.stdout)
        self.assertEqual(r.returncode, 0, r.stdout)


if __name__ == "__main__":
    unittest.main()
