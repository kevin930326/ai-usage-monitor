"""平台差異（usage_collector/system.py，ADR-0011 第 2 節）：以參數或 mock 模擬 Windows，在任何平台都能跑。"""
import json
import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock
from zoneinfo import ZoneInfoNotFoundError, available_timezones

from usage_collector import __main__ as main_module
from usage_collector import paths, system
from usage_collector.paths import resolve_home


class DefaultHomeTest(unittest.TestCase):
    def test_mac(self):
        self.assertEqual(system.default_home({}, windows=False),
                         Path.home() / "Library" / "Application Support" / "AIUsageMonitor")

    def test_windows_uses_localappdata(self):
        self.assertEqual(system.default_home({"LOCALAPPDATA": r"C:\Users\王小明\AppData\Local"}, windows=True),
                         Path(r"C:\Users\王小明\AppData\Local") / "AIUsageMonitor")

    def test_windows_without_localappdata(self):
        self.assertEqual(system.default_home({}, windows=True), Path.home() / "AppData" / "Local" / "AIUsageMonitor")

    def test_resolve_home_uses_the_platform_default(self):
        self.assertEqual(resolve_home({}, modules=()), system.default_home({}))


class ExecutableFallbackTest(unittest.TestCase):
    def test_mac_only_has_the_chatgpt_codex(self):
        self.assertEqual(system.executable_fallbacks("claude", {}, windows=False), ())
        self.assertTrue(system.executable_fallbacks("codex", {}, windows=False)[0].startswith("/Applications/ChatGPT.app"))

    def test_windows_native_and_npm_installs(self):
        env = {"USERPROFILE": r"C:\Users\u", "APPDATA": r"C:\Users\u\AppData\Roaming"}
        self.assertEqual(system.executable_fallbacks("claude", env, windows=True),
                         (str(Path(r"C:\Users\u") / ".local" / "bin" / "claude.exe"),
                          str(Path(r"C:\Users\u\AppData\Roaming") / "npm" / "claude.cmd")))

    def test_resolve_executable_tries_the_platform_fallbacks(self):
        with tempfile.TemporaryDirectory() as d:
            # Windows 以副檔名判斷能不能直接執行（system.is_launchable）
            exe = Path(d) / ("claude.exe" if sys.platform == "win32" else "claude")
            exe.write_text("")
            exe.chmod(0o755)
            config = Path(d) / "config.json"
            with mock.patch.dict(os.environ, {"PATH": str(Path(d) / "empty")}), \
                    mock.patch.object(paths.system, "executable_fallbacks", return_value=(str(exe),)):
                self.assertEqual(paths.resolve_executable("claude_path", "claude", config_path=config), str(exe))
                # 呼叫端給了 fallbacks 時不再加平台的
                self.assertIsNone(paths.resolve_executable("claude_path", "claude", (), config_path=config))


    def test_windows_skips_powershell_shims(self):
        """npm 會同時產生 codex.ps1 與 codex.cmd：.ps1 不能直接執行，要選 .cmd（C-03）。"""
        with tempfile.TemporaryDirectory() as d:
            ps1, cmd = Path(d) / "codex.ps1", Path(d) / "codex.cmd"
            ps1.write_text("")
            cmd.write_text("")
            config = Path(d) / "config.json"
            config.write_text(json.dumps({"codex_path": str(ps1)}), encoding="utf-8")
            with mock.patch.object(system, "IS_WINDOWS", True), \
                    mock.patch.dict(os.environ, {"PATH": str(Path(d) / "empty")}):
                self.assertFalse(system.is_launchable(str(ps1)))
                self.assertFalse(system.is_launchable(d))
                self.assertTrue(system.is_launchable(str(cmd)))
                self.assertEqual(paths.resolve_executable("codex_path", "codex", (str(ps1), str(cmd)),
                                                          config_path=config), str(cmd))


class ZoneTest(unittest.TestCase):
    @unittest.skipUnless(available_timezones(), "沒有時區資料庫（Windows 未安裝 tzdata）")
    def test_known_zone(self):
        self.assertEqual(str(system.zone("UTC", None)), "UTC")

    def test_windows_without_tz_database_uses_local_time(self):
        local = object()
        with mock.patch.object(system, "IS_WINDOWS", True), \
                mock.patch.object(system, "ZoneInfo", side_effect=ZoneInfoNotFoundError("x")), \
                mock.patch.object(system, "available_timezones", return_value=set()):
            self.assertIs(system.zone("Asia/Taipei", local), local)

    def test_unknown_name_with_a_database_still_fails(self):
        with mock.patch.object(system, "IS_WINDOWS", True), \
                mock.patch.object(system, "ZoneInfo", side_effect=ZoneInfoNotFoundError("x")), \
                mock.patch.object(system, "available_timezones", return_value={"UTC"}):
            with self.assertRaises(ZoneInfoNotFoundError):
                system.zone("Mars/Base", None)


class PopenTest(unittest.TestCase):
    def test_windows_hides_the_console_and_uses_a_new_group(self):
        with mock.patch.object(system, "IS_WINDOWS", True):
            flags = system.isolated_popen_kwargs()["creationflags"]
        self.assertTrue(flags & system.CREATE_NO_WINDOW and flags & system.CREATE_NEW_PROCESS_GROUP)

    def test_posix_uses_a_new_session(self):
        with mock.patch.object(system, "IS_WINDOWS", False):
            self.assertEqual(system.isolated_popen_kwargs(), {"start_new_session": True})

    def test_read_flags_never_follow_links_where_supported(self):
        if hasattr(os, "O_NOFOLLOW"):
            self.assertTrue(system.OPEN_READ_FLAGS & os.O_NOFOLLOW)


class EntryStatTest(unittest.TestCase):
    def test_entry_stat_matches_fstat_after_opening(self):
        # Token 統計開檔後以 (st_dev, st_ino) 確認是列舉到的那一個檔案：兩邊的值必須一致（Windows 也是）
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "a.jsonl").write_text("x\n", encoding="utf-8")
            entry = next(os.scandir(d))
            st = system.entry_stat(entry)
            fd = os.open(entry.path, system.OPEN_READ_FLAGS)
            try:
                opened = os.fstat(fd)
            finally:
                os.close(fd)
            self.assertEqual((st.st_dev, st.st_ino), (opened.st_dev, opened.st_ino))
            self.assertNotEqual(st.st_ino, 0)


class TokensOnlyTest(unittest.TestCase):
    """--tokens-only（Windows 排程的預設）：不執行 claude／codex、不寫 usage.json，只有 Token 統計。"""

    def test_tokens_only_skips_quota_and_writes_the_log_file(self):
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            claude_dir = home / "claude" / "projects" / "p"
            claude_dir.mkdir(parents=True)
            line = {"type": "assistant", "timestamp": "2026-10-20T01:00:00Z", "requestId": "r1",
                    "message": {"id": "m1", "model": "claude-opus-5-5",
                                "usage": {"input_tokens": 3, "output_tokens": 4}}}
            (claude_dir / "11111111-1111-4111-8111-111111111111.jsonl").write_text(json.dumps(line) + "\n", encoding="utf-8")
            log_file = home / "collector.log"
            db = home / "history.sqlite3"
            dirs = {"claude": home / "claude", "codex": home / "codex"}
            original = main_module.token_stats.run
            saved_stderr = sys.stderr
            try:
                with mock.patch.object(main_module, "collect", side_effect=AssertionError("不該收集額度")), \
                        mock.patch.object(main_module.local_store, "write_snapshot",
                                          side_effect=AssertionError("不該寫 usage.json")), \
                        mock.patch.object(main_module.token_stats, "run", lambda path=None: original(db, dirs)), \
                        mock.patch.object(main_module.token_stats.system, "lower_priority"):
                    code = main_module.main(["--tokens-only", "--quiet", "--log-file", str(log_file)])
            finally:
                if sys.stderr is not saved_stderr:
                    sys.stderr.close()
                sys.stderr = saved_stderr
            self.assertEqual(code, 0)
            self.assertTrue(log_file.exists())
            self.assertFalse((home / "usage.json").exists())
            with sqlite3.connect(db) as conn:
                total = conn.execute("SELECT SUM(input_tokens + output_tokens) FROM daily_tokens").fetchone()[0]
            conn.close()
            self.assertEqual(total, 7)


    def test_second_run_on_windows_keeps_counting(self):
        """Windows 的 stat 一律回報 0666（C-01）：第二次執行不能因為權限檢查而略過統計。"""
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            claude_dir = home / "claude" / "projects" / "p"
            claude_dir.mkdir(parents=True)
            log = claude_dir / "11111111-1111-4111-8111-111111111111.jsonl"
            db = home / "history.sqlite3"
            dirs = {"claude": home / "claude", "codex": home / "codex"}

            def line(n):
                return json.dumps({"type": "assistant", "timestamp": "2026-10-20T01:00:00Z", "requestId": f"r{n}",
                                   "message": {"id": f"m{n}", "model": "claude-opus-5-5",
                                               "usage": {"input_tokens": 3, "output_tokens": 4}}}) + "\n"

            original = main_module.token_stats.run
            with mock.patch.object(main_module.history.system, "IS_WINDOWS", True), \
                    mock.patch.object(main_module.token_stats, "run", lambda path=None: original(db, dirs)), \
                    mock.patch.object(main_module.token_stats.system, "lower_priority"):
                log.write_text(line(1), encoding="utf-8")
                self.assertEqual(main_module.main(["--tokens-only", "--quiet"]), 0)
                os.chmod(db, 0o666)
                with log.open("a", encoding="utf-8") as f:
                    f.write(line(2))
                self.assertEqual(main_module.main(["--tokens-only", "--quiet"]), 0)
            with sqlite3.connect(db) as conn:
                total = conn.execute("SELECT SUM(input_tokens + output_tokens) FROM daily_tokens").fetchone()[0]
            conn.close()
            self.assertEqual(total, 14)

    def test_failure_returns_non_zero(self):
        with mock.patch.object(main_module.token_stats, "run_safely", return_value=False):
            self.assertEqual(main_module.main(["--tokens-only", "--quiet"]), 1)


class LogFileTest(unittest.TestCase):
    def test_log_file_is_utf8(self):
        with tempfile.TemporaryDirectory() as d:
            log_file = Path(d) / "collector.log"
            saved = sys.stderr
            try:
                with mock.patch.object(main_module.token_stats, "run_safely", return_value=True):
                    main_module.main(["--tokens-only", "--log-file", str(log_file)])
                main_module.log("測試：中文日誌")
            finally:
                sys.stderr.close()
                sys.stderr = saved
            self.assertIn("測試：中文日誌", log_file.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
