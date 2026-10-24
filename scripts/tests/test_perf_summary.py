"""scripts/perf-summary.py：效能量測的報表與門檻（ADR-0010 第 3 節）。只用假的取樣，不啟動 App。"""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "perf-summary.py"

# DebugTools.runPerfSchedule 的時間表（close = 64）
MARKS = {
    "panel-open": 10, "refresh": 22, "glow": 27, "collapse": 32, "expand": 35, "trend-next": 38, "departing": 41,
    "appearance-dark": 44, "appearance-light": 47, "stats-scope": 51, "stats-range": 54, "status-pulse": 57,
    "highlight": 60, "panel-close": 64, "panel-close-2": 166, "stats-open": 184, "stats-close": 194,
    "stats-open-2": 214, "stats-close-2": 224,
}
BASE = 140 * 1024  # KB


class PerfSummaryTests(unittest.TestCase):
    def run_summary(self, rss=lambda t: BASE, marks=MARKS, until=245):
        tmp = Path(tempfile.mkdtemp(prefix="aum-perf-summary-"))
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", str(tmp)]))
        samples = "".join(f"{t} 0.0 {rss(t)}\n" for t in range(until))
        (tmp / "samples.tsv").write_text(samples)
        (tmp / "app.log").write_text("".join(f"perf-mark {v}.0 {k}\n" for k, v in marks.items()))
        return subprocess.run([sys.executable, str(SCRIPT), str(tmp / "samples.tsv"), str(tmp / "app.log"), "normal"],
                              capture_output=True, text=True)

    def test_everything_within_limits_passes(self):
        # 第一次打開統計視窗多 4 MB、第二次開關再多 1 MB：都在 +5 MB 內
        r = self.run_summary(lambda t: BASE + (4 * 1024 if t >= 184 else 0) + (1024 if t >= 214 else 0))
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("完整統計視窗第二次開關後 RSS 不超過第一次關閉後 +5 MB（149.0 MB）：通過", r.stdout)

    def test_growth_after_reopening_the_stats_window_fails(self):
        # Codex C-01：第二次開關後多 100 MB 必須失敗
        r = self.run_summary(lambda t: BASE + (100 * 1024 if t >= 214 else 0))
        self.assertEqual(r.returncode, 1)
        self.assertIn("完整統計視窗第二次開關後 RSS 不超過第一次關閉後 +5 MB（145.0 MB）：未通過", r.stdout)

    def test_missing_second_close_mark_fails(self):
        marks = {k: v for k, v in MARKS.items() if k != "stats-close-2"}
        r = self.run_summary(marks=marks)
        self.assertEqual(r.returncode, 1)
        self.assertIn("第二次開關後 RSS 不超過第一次關閉後 +5 MB（145.0 MB）：未通過", r.stdout.split("統計視窗靜止")[1])

    def test_missing_samples_after_the_second_close_fails(self):
        r = self.run_summary(until=226)  # App 在第二次關閉後就沒有取樣
        self.assertEqual(r.returncode, 1)
        self.assertIn("完整統計視窗第二次開關後 RSS 不超過第一次關閉後 +5 MB（145.0 MB）：未通過", r.stdout)


if __name__ == "__main__":
    unittest.main()
