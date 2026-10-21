import io
import json
import os
import stat
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from contextlib import redirect_stderr, redirect_stdout
from unittest import mock

from usage_collector import __main__ as cli
from usage_collector.models import ProviderError
from usage_collector.providers import claude

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "claude"
# 錄下 usage-max 時的時間（2026-10-21 23:25 台北）
RECORDED_AT = datetime(2026, 10, 21, 15, 25, tzinfo=timezone.utc)


def fixture(name: str) -> str:
    return (FIXTURES / name).read_text(encoding="utf-8")


def window_dicts(usage) -> list[tuple]:
    return [(w["id"], w["label"], w["used_pct"], w["resets_at"], w["hidden"]) for w in usage.to_dict()["windows"]]


class ClaudeParseTest(unittest.TestCase):
    """以錄下的真實輸出（已遮蔽）與依 Claude Code 格式化程式手寫的輸出解析。"""

    MAX_WINDOWS = [
        ("five_hour", "5 小時", 45.0, "2026-10-21T17:00:00Z", False),
        ("weekly", "每週", 12.0, "2026-10-27T23:00:00Z", False),
        ("weekly_fable", "每週 Fable", 0.0, "2026-10-27T23:00:00Z", True),
    ]

    def test_json_output(self):
        usage = claude.parse(claude.usage_text(fixture("usage-max.json")), "Max", RECORDED_AT)
        self.assertEqual(window_dicts(usage), self.MAX_WINDOWS)

    def test_text_output(self):
        usage = claude.parse(claude.usage_text(fixture("usage-max.txt")), None, RECORDED_AT)
        self.assertEqual(window_dicts(usage), self.MAX_WINDOWS)

    def test_partial_limits(self):
        usage = claude.parse(fixture("partial.txt"), None, RECORDED_AT)
        self.assertEqual(window_dicts(usage), [("weekly", "每週", 3.0, "2026-10-27T23:00:00Z", False)])

    def test_overage_year_minutes_and_missing_reset(self):
        now = datetime(2026, 12, 31, 20, 0, tzinfo=timezone.utc)  # 洛杉磯 12/31 中午
        usage = claude.parse(fixture("overage.txt"), None, now)
        self.assertEqual(window_dicts(usage), [
            ("five_hour", "5 小時", 100.0, "2027-01-01T07:30:00Z", False),
            ("weekly", "每週", 87.0, "2027-01-02T08:00:00Z", False),
            ("weekly_sonnet", "每週 Sonnet", 40.0, "2027-01-02T08:00:00Z", True),
            ("weekly_opus", "每週 Opus", 97.0, None, True),
        ])

    def test_reset_hour_must_be_1_to_12(self):
        for text in ("Oct 22 at 0am (Asia/Taipei)", "Oct 22 at 13pm (Asia/Taipei)", "Oct 22 at 99pm (Asia/Taipei)"):
            with self.subTest(text), self.assertRaisesRegex(ProviderError, "格式已改變"):
                claude.parse_reset(text, RECORDED_AT)

    def test_reset_variants(self):
        cases = {
            "Oct 22 at 1am (Asia/Taipei)": "2026-10-21T17:00:00Z",
            "Oct 22, 1 AM (Asia/Taipei)": "2026-10-21T17:00:00Z",   # 舊版 ICU
            "Oct 22 at 12pm (Asia/Taipei)": "2026-10-22T04:00:00Z",
            "Oct 22 at 12:05am (UTC)": "2026-10-22T00:05:00Z",
        }
        for text, expected in cases.items():
            with self.subTest(text):
                resets = claude.parse_reset(text, RECORDED_AT).astimezone(timezone.utc)
                self.assertEqual(resets.strftime("%Y-%m-%dT%H:%M:%SZ"), expected)

    def test_format_changed_is_error_not_zero(self):
        for text in (fixture("format-changed.txt"),
                     "Current session: 45% used · resets tomorrow",
                     "Current week (Opus): 97% used",           # 只有各模型額度，沒有主要額度
                     "Current session: 45% used · resets Oct 22 at 1am (Mars/Base)",
                     "Usage limits\n5-hour: 45%"):
            with self.subTest(text), self.assertRaisesRegex(ProviderError, "格式已改變"):
                claude.parse(text, None, RECORDED_AT)

    def test_missing_or_bad_percent_is_error_not_zero(self):
        # C-04：額度行缺少百分比、負數、非數字或 NaN 時回報格式錯誤，不能變成「0% 已用」
        for line in ("Current session: used · resets Oct 22 at 1am (Asia/Taipei)",
                     "Current session: % used",
                     "Current session: -5% used",
                     "Current session: nan% used",
                     "Current session: twelve% used",
                     "Current week (all models): 12 % used",
                     "Current session: " + "9" * 400 + "% used"):   # float() 會變成 inf
            with self.subTest(line[:60]), self.assertRaisesRegex(ProviderError, "格式已改變"):
                claude.parse(line, None, RECORDED_AT)

    def test_bad_hidden_scoped_line_is_error_not_skipped(self):
        # 各模型的每週額度行認不得時也視為格式改變：文字格式沒有文件保證，
        # 一行認不得就不該相信其他行（API 版本的 C-04 是只略過該項，這裡刻意更嚴格）
        text = ("Current session: 45% used · resets Oct 22 at 1am (Asia/Taipei)\n"
                "Current week (all models): 12% used · resets Oct 28 at 7am (Asia/Taipei)\n"
                "Current week (Opus): % used\n")
        with self.assertRaisesRegex(ProviderError, "格式已改變"):
            claude.parse(text, None, RECORDED_AT)

    def test_zero_and_over_limit_are_kept(self):
        # 0 是真的沒用；超過 100（超額）照實傳出，顯示端會限制在 0～100
        text = "Current session: 0% used\nCurrent week (all models): 104.5% used\n"
        self.assertEqual([w.used_pct for w in claude.parse(text, None, RECORDED_AT).windows], [0.0, 104.5])

    def test_logged_out(self):
        with self.assertRaisesRegex(ProviderError, "尚未用 Claude 訂閱登入"):
            claude.parse(fixture("logged-out.txt"), None, RECORDED_AT)

    def test_limits_unavailable(self):
        with self.assertRaisesRegex(ProviderError, "暫時查不到"):
            claude.parse(fixture("no-limits.txt"), None, RECORDED_AT)

    def test_json_envelope_errors(self):
        with self.assertRaisesRegex(ProviderError, "回報錯誤"):
            claude.usage_text(json.dumps({"is_error": True, "result": ""}))
        with self.assertRaisesRegex(ProviderError, "格式已改變"):
            claude.usage_text(json.dumps({"type": "result"}))


class FakeClaude:
    """在臨時資料夾產生假的 claude 執行檔，並把 config.json 的 claude_path 指向它。"""

    def __init__(self, usage: str = "usage-max.json", auth: str = "auth-status.json", script: str = ""):
        self.dir = tempfile.TemporaryDirectory()
        root = Path(self.dir.name)
        self.cwd_marker = root / "cwd"
        self.path = root / "claude"
        self.path.write_text(
            "#!/bin/bash\n"
            f"pwd > '{self.cwd_marker}'\n"
            # stdin 必須是 /dev/null（字元裝置），不能是管線
            "[ -c /dev/stdin ] || exit 97\n"
            f"{script}\n"
            f"if [ \"$1\" = auth ]; then cat '{FIXTURES / auth}'; exit 0; fi\n"
            f"[ \"$*\" = '{' '.join(claude.USAGE_ARGS)}' ] || exit 98\n"
            f"cat '{FIXTURES / usage}'\n")
        self.path.chmod(self.path.stat().st_mode | stat.S_IEXEC)
        self.config = root / "config.json"
        self.config.write_text(json.dumps({"relay_url": "https://x", "claude_path": str(self.path)}))
        self.patch = mock.patch("usage_collector.paths.CONFIG_PATH", self.config)

    def __enter__(self):
        self.patch.start()
        return self

    def __exit__(self, *exc):
        self.patch.stop()
        self.dir.cleanup()


class ClaudeFetchTest(unittest.TestCase):
    def test_fetch_runs_claude_and_reads_plan(self):
        with FakeClaude() as fake:
            usage = claude.fetch()
            cwd = fake.cwd_marker.read_text().strip()
        self.assertEqual(usage.plan, "Max")
        self.assertEqual([w.id for w in usage.windows], ["five_hour", "weekly", "weekly_fable"])
        # 在暫存資料夾執行，不載入任何專案的 CLAUDE.md
        self.assertNotEqual(Path(cwd).resolve(), Path.cwd().resolve())
        self.assertIn("aum-claude-", cwd)

    def test_personal_data_stays_out_of_snapshot(self):
        with FakeClaude():
            snapshot = cli.collect(["claude"])
        text = json.dumps(snapshot)
        self.assertIsNone(snapshot["providers"]["claude"]["error"])
        for secret in ("person@example.com", "Organization", "00000000", "example-server", "/Users/example"):
            self.assertNotIn(secret, text)

    def test_plan_is_optional(self):
        with FakeClaude(auth="logged-out.txt") as fake:
            usage = claude.fetch()
        self.assertIsNone(usage.plan)
        self.assertEqual(len(usage.windows), 3)

    def test_logged_out(self):
        with FakeClaude(usage="logged-out.txt"), self.assertRaisesRegex(ProviderError, "尚未用 Claude 訂閱登入"):
            claude.fetch()

    def test_format_changed(self):
        with FakeClaude(usage="format-changed.txt"), self.assertRaisesRegex(ProviderError, "格式已改變"):
            claude.fetch()

    def test_claude_not_found(self):
        with tempfile.TemporaryDirectory() as d:
            config = Path(d) / "config.json"
            config.write_text(json.dumps({"claude_path": str(Path(d) / "missing")}))
            with mock.patch("usage_collector.paths.CONFIG_PATH", config), \
                 mock.patch.dict(os.environ, {"PATH": d}), \
                 self.assertRaisesRegex(ProviderError, "找不到 claude"):
                claude.fetch()

    def test_timeout(self):
        with FakeClaude(script="sleep 5"), mock.patch.object(claude, "TIMEOUT", 0.3), \
             self.assertRaisesRegex(ProviderError, "逾時"):
            claude.fetch()

    def test_claude_output_stays_out_of_the_log(self):
        # 日誌（launchd 導到 collector.log）只會有固定的錯誤訊息：claude 的 stderr、
        # auth status 的輸出（含 email）都不能進去
        script = "echo 'person@example.com' >&2; [ \"$1\" = auth ] && exit 0; exit 3"
        out, err = io.StringIO(), io.StringIO()
        with FakeClaude(script=script), mock.patch.object(cli, "enabled_providers", return_value=["claude"]), \
             redirect_stdout(out), redirect_stderr(err):
            code = cli.main(["--compact"])
        self.assertEqual(code, 1)
        self.assertIn("claude: Claude Code 執行 /usage 失敗（結束碼 3）", err.getvalue())
        for secret in ("person@example.com", "@", "Organization", "/Users/example"):
            self.assertNotIn(secret, err.getvalue())
            self.assertNotIn(secret, out.getvalue())

    def test_unparsable_plan_is_dropped_quietly(self):
        # auth status 印出非 JSON 或含個資的錯誤時：plan 為 None、不寫日誌、用量照常
        script = "if [ \"$1\" = auth ]; then echo 'error: person@example.com not logged in' >&2; echo 'not json'; exit 1; fi"
        err = io.StringIO()
        with FakeClaude(script=script), redirect_stderr(err):
            usage = claude.fetch()
        self.assertIsNone(usage.plan)
        self.assertEqual(len(usage.windows), 3)
        self.assertEqual(err.getvalue(), "")

    def test_non_zero_exit_hides_stderr(self):
        with FakeClaude(script="echo 'person@example.com' >&2; exit 3"), \
             self.assertRaises(ProviderError) as ctx:
            claude.fetch()
        self.assertIn("結束碼 3", str(ctx.exception))
        self.assertNotIn("@", str(ctx.exception))


class ResolveClaudePathTest(unittest.TestCase):
    def test_reads_config_and_falls_back_to_path(self):
        with tempfile.TemporaryDirectory() as d:
            exe = Path(d) / "claude"
            exe.write_text("#!/bin/sh\n")
            exe.chmod(0o755)
            config = Path(d) / "config.json"
            config.write_text(json.dumps({"relay_url": "https://x", "claude_path": str(exe)}))
            self.assertEqual(claude.resolve_claude_path(config), str(exe))
            config.write_text(json.dumps({"relay_url": "https://x"}))
            with mock.patch.dict(os.environ, {"PATH": d}):
                self.assertEqual(claude.resolve_claude_path(config), str(exe))
            with mock.patch.dict(os.environ, {"PATH": "/nonexistent"}):
                self.assertIsNone(claude.resolve_claude_path(Path(d) / "missing.json"))


if __name__ == "__main__":
    unittest.main()
