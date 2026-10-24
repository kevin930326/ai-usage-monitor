"""App 內建收集器（ADR-0013 第 3 節）：`usage_collector.setup` 的偵測與 config.json，以及 `--agent app`。

用假的 claude／codex 執行檔與暫存 HOME，不會執行這台電腦真的 CLI，也不讀任何登入資訊。
"""
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest import mock

from usage_collector import __main__ as cli
from usage_collector import setup

COLLECTOR = Path(__file__).resolve().parents[1]


def write_exec(path: Path, body: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/bin/sh\n" + textwrap.dedent(body).lstrip())
    path.chmod(0o755)
    return path


@unittest.skipIf(sys.platform == "win32", "假的執行檔是 sh 腳本")
class SetupDetectionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__("shutil").rmtree(self.tmp, ignore_errors=True))
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.bin = self.tmp / "bin"
        self.env = {"HOME": str(self.home), "PATH": str(self.bin)}
        self.config = self.tmp / "app" / "config.json"
        self.none = {"claude": (), "codex": ()}

    def fake_claude(self, rc: int, where: Path | None = None) -> Path:
        return write_exec(where or self.bin / "claude", f"""
            [ "$1 $2 $3" = "auth status --json" ] || exit 9
            echo '{{"email": "someone@example.com"}}'
            exit {rc}
        """)

    def fake_codex(self, rc: int, text: str) -> Path:
        return write_exec(self.bin / "codex", f"""
            [ "$1 $2" = "login status" ] || exit 9
            echo "{text}"
            exit {rc}
        """)

    def test_claude_states_follow_the_exit_code(self):
        for rc, state in [(0, "enabled"), (1, "not_logged_in"), (3, "unknown")]:
            with self.subTest(rc=rc):
                path = self.fake_claude(rc)
                self.assertEqual(setup.detect_claude(str(path), self.env), state)

    def test_missing_claude_is_unknown_only_when_it_was_used_before(self):
        self.assertEqual(setup.detect_claude(None, self.env), "not_installed")
        (self.home / ".claude").mkdir()
        self.assertEqual(setup.detect_claude(None, self.env), "unknown")
        self.assertEqual(setup.detect_claude(None, {**self.env, "CLAUDE_CONFIG_DIR": str(self.tmp / "none")}), "not_installed")

    def test_codex_states(self):
        cases = [(0, "Logged in using ChatGPT", "enabled"), (0, "Logged in using an API key - sk-***", "api_key"),
                 (1, "Not logged in", "not_logged_in"), (0, "Something new", "unknown"),
                 (2, "Logged in using ChatGPT", "unknown")]
        for rc, text, state in cases:
            with self.subTest(text=text, rc=rc):
                path = self.fake_codex(rc, text)
                self.assertEqual(setup.detect_codex(str(path), self.env), state)
        self.assertEqual(setup.detect_codex(None, self.env), "not_installed")
        (self.home / ".codex").mkdir()
        self.assertEqual(setup.detect_codex(None, self.env), "unknown")

    def test_node_script_next_to_node_runs_with_a_bare_path(self):
        # npm 版：`#!/usr/bin/env node` 腳本，node 在同一個資料夾，環境的 PATH 不含它
        npm_bin = self.tmp / "npm" / "bin"
        write_exec(npm_bin / "node", """
            [ "$2 $3" = "login status" ] || exit 9
            echo "Logged in using ChatGPT"
        """)
        codex = npm_bin / "codex"
        codex.write_text("#!/usr/bin/env node\n")
        codex.chmod(0o755)
        env = {"HOME": str(self.home), "PATH": "/usr/bin:/bin"}
        self.assertEqual(setup.detect_codex(str(codex), env), "enabled")

    def test_detection_passes_config_dirs_to_the_cli(self):
        seen = self.tmp / "seen"
        path = write_exec(self.bin / "claude", f"""
            echo "$CLAUDE_CONFIG_DIR" > "{seen}"
            exit 0
        """)
        setup.detect_claude(str(path), {**self.env, "CLAUDE_CONFIG_DIR": "/custom/claude"})
        self.assertEqual(seen.read_text().strip(), "/custom/claude")

    def test_timeout_is_unknown_and_kills_the_group(self):
        marker = self.tmp / "child-alive"
        path = write_exec(self.bin / "claude", f"""
            (sleep 3; touch "{marker}") &
            sleep 30
        """)
        with mock.patch.object(setup, "TIMEOUT", 0.5):
            self.assertEqual(setup.detect_claude(str(path), self.env), "unknown")
        __import__("time").sleep(3.5)
        self.assertFalse(marker.exists(), "逾時後子程序仍在執行")

    def test_candidates_expand_home_and_pick_newest_version(self):
        old = self.fake_claude(0, self.home / ".nvm/versions/node/v20.1.0/bin/claude")
        new = self.fake_claude(0, self.home / ".nvm/versions/node/v22.3.0/bin/claude")
        found = setup.find_executable("claude", ["~/.local/bin/claude", "~/.nvm/versions/node/*/bin/claude"], self.env)
        self.assertEqual(found, str(new))
        self.assertNotEqual(found, str(old))
        self.assertIsNone(setup.find_executable("claude", ["~/.local/bin/claude"], {**self.env, "PATH": ""}))

    def test_run_writes_paths_and_enabled_providers_and_keeps_other_fields(self):
        self.config.parent.mkdir(parents=True)
        self.config.write_text(json.dumps({"relay_url": "https://relay.example", "enabled_providers": ["codex"]}))
        claude = self.fake_claude(0)
        codex = self.fake_codex(1, "Not logged in")
        result = setup.run(self.config, self.env, candidates=self.none)
        config = json.loads(self.config.read_text())
        self.assertEqual(config["relay_url"], "https://relay.example")
        self.assertEqual(config["claude_path"], str(claude))
        self.assertEqual(config["codex_path"], str(codex))
        self.assertEqual(config["enabled_providers"], ["claude"])
        self.assertNotIn("claude_config_dir", config)
        self.assertEqual(result, {"claude": {"state": "enabled", "found": True},
                                  "codex": {"state": "not_logged_in", "found": True}, "enabled_providers": ["claude"]})
        # 結果不含路徑或帳號（App 會顯示）
        self.assertNotIn(str(self.tmp), json.dumps(result))
        self.assertNotIn("example.com", json.dumps(result))

    def test_config_dirs_follow_env_and_are_kept_without_it(self):
        self.config.parent.mkdir(parents=True)
        self.config.write_text(json.dumps({"claude_config_dir": "/custom/claude", "codex_home": "/custom/codex"}))
        setup.run(self.config, self.env, candidates=self.none)
        config = json.loads(self.config.read_text())
        self.assertEqual((config["claude_config_dir"], config["codex_home"]), ("/custom/claude", "/custom/codex"))
        setup.run(self.config, {**self.env, "CODEX_HOME": str(self.tmp / "codex")}, candidates=self.none)
        self.assertEqual(json.loads(self.config.read_text())["codex_home"], str(self.tmp / "codex"))

    def test_detection_uses_saved_paths_and_dirs(self):
        # Codex 在候選位置以外、登入資料在自訂資料夾；App 的環境沒有 CODEX_HOME
        seen = self.tmp / "seen"
        custom = write_exec(self.tmp / "elsewhere" / "codex", f"""
            echo "$CODEX_HOME" > "{seen}"
            echo "Logged in using ChatGPT"
        """)
        self.fake_claude(0)
        self.config.parent.mkdir(parents=True)
        self.config.write_text(json.dumps({"codex_path": str(custom), "codex_home": "/custom/codex",
                                           "enabled_providers": ["claude", "codex"]}))
        result = setup.run(self.config, self.env, candidates=self.none)
        self.assertEqual(result["codex"]["state"], "enabled")
        self.assertEqual(seen.read_text().strip(), "/custom/codex")
        config = json.loads(self.config.read_text())
        self.assertEqual(config["enabled_providers"], ["claude", "codex"])
        self.assertEqual(config["codex_path"], str(custom))

    def test_saved_path_that_no_longer_exists_falls_back_to_search(self):
        self.config.parent.mkdir(parents=True)
        self.config.write_text(json.dumps({"claude_path": str(self.tmp / "gone" / "claude")}))
        claude = self.fake_claude(0)
        setup.run(self.config, self.env, candidates=self.none)
        self.assertEqual(json.loads(self.config.read_text())["claude_path"], str(claude))

    def test_unknown_keeps_enabled_providers(self):
        self.config.parent.mkdir(parents=True)
        self.config.write_text(json.dumps({"enabled_providers": ["claude", "codex"]}))
        self.fake_claude(0)
        (self.home / ".codex").mkdir()  # 用過 Codex，但這次找不到 → 不知道
        result = setup.run(self.config, self.env, candidates=self.none)
        self.assertIsNone(result["enabled_providers"])
        self.assertEqual(json.loads(self.config.read_text())["enabled_providers"], ["claude", "codex"])

    def test_nothing_logged_in_does_not_write_enabled_providers(self):
        self.fake_claude(1)
        result = setup.run(self.config, self.env, candidates=self.none)
        self.assertIsNone(result["enabled_providers"])
        self.assertNotIn("enabled_providers", json.loads(self.config.read_text()))

    def test_dry_run_writes_nothing(self):
        self.fake_claude(0)
        setup.run(self.config, self.env, dry_run=True, candidates=self.none)
        self.assertFalse(self.config.exists())

    def test_refuses_to_overwrite_non_object_config(self):
        self.config.parent.mkdir(parents=True)
        self.config.write_text("[1, 2]")
        with self.assertRaises(ValueError):
            setup.run(self.config, self.env, candidates=self.none)
        self.assertEqual(self.config.read_text(), "[1, 2]")


@unittest.skipIf(sys.platform == "win32", "App 內建的收集器只在 macOS（ADR-0013）；日誌權限 0o600 是 POSIX 的")
class AppAgentTests(unittest.TestCase):
    """`--agent app`：日誌寫在自己的檔案；install-launchd.sh 的收集器在時不執行。"""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__("shutil").rmtree(self.tmp, ignore_errors=True))
        self.agents = self.tmp / "LaunchAgents"
        self.agents.mkdir()
        self.home = self.tmp / "app"
        self.home.mkdir()
        (self.home / "config.json").write_text(json.dumps({"enabled_providers": []}))
        self.env = {**os.environ, "AI_USAGE_MONITOR_HOME": str(self.home), "AUM_TESTING": "1",
                    "AUM_LAUNCH_AGENTS_DIR": str(self.agents)}

    def run_agent(self) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, "-m", "usage_collector", "--agent", "app", "--quiet"], cwd=COLLECTOR,
                              env=self.env, capture_output=True, text=True, timeout=60)

    def test_skips_when_legacy_agent_is_installed(self):
        (self.agents / f"{cli.LEGACY_LABEL}.plist").write_text("<plist/>")
        result = self.run_agent()
        self.assertEqual(result.returncode, 0)
        log = (self.home / "logs" / "collector.log").read_text()
        self.assertIn("偵測到 install-launchd.sh 安裝的收集器", log)
        self.assertEqual(result.stderr, "")  # 都寫進日誌檔

    def test_runs_and_logs_to_its_own_file_without_legacy_agent(self):
        result = self.run_agent()
        log = (self.home / "logs" / "collector.log").read_text()
        self.assertNotIn("偵測到 install-launchd.sh", log)
        self.assertIn("沒有啟用任何服務", log)
        self.assertEqual(result.stderr, "")
        self.assertEqual(oct((self.home / "logs" / "collector.log").stat().st_mode & 0o777), "0o600")

    def test_legacy_job_still_in_launchd_counts_as_installed(self):
        # plist 已移走但 launchd 還有舊的工作（遷移時 bootout 失敗）：內建的也不能執行（Fable F-02）
        with tempfile.TemporaryDirectory() as d:
            env = {"AUM_LAUNCH_AGENTS_DIR": d}
            self.assertTrue(cli.legacy_agent_installed(env, job_loaded=lambda: True))
            self.assertFalse(cli.legacy_agent_installed(env, job_loaded=lambda: False))
            # 安裝測試（AUM_LAUNCH_AGENTS_DIR）沒指定 job_loaded 時只看那個資料夾，不問真的 launchd
            with mock.patch.object(cli, "legacy_job_loaded", side_effect=AssertionError("不應該問 launchd")):
                self.assertFalse(cli.legacy_agent_installed(env))
            (Path(d) / f"{cli.LEGACY_LABEL}.plist").write_text("")
            self.assertTrue(cli.legacy_agent_installed(env, job_loaded=lambda: False))

    @unittest.skipUnless(sys.platform == "darwin", "launchctl 只有 macOS 有")
    def test_legacy_job_loaded_reads_launchctl_print(self):
        done = lambda code: subprocess.CompletedProcess([], code)  # noqa: E731
        with mock.patch.object(cli.subprocess, "run", return_value=done(0)) as run:
            self.assertTrue(cli.legacy_job_loaded())
        self.assertEqual(run.call_args.args[0][:2], ["/bin/launchctl", "print"])
        self.assertTrue(run.call_args.args[0][2].endswith(f"/{cli.LEGACY_LABEL}"))
        with mock.patch.object(cli.subprocess, "run", return_value=done(113)):
            self.assertFalse(cli.legacy_job_loaded())  # 找不到這個工作
        # 無法確認時當成還在：寧可這一輪不收集，也不要兩個同時跑
        with mock.patch.object(cli.subprocess, "run", side_effect=subprocess.TimeoutExpired("launchctl", 10)):
            self.assertTrue(cli.legacy_job_loaded())
        with mock.patch.object(cli.subprocess, "run", side_effect=OSError):
            self.assertTrue(cli.legacy_job_loaded())

    def test_real_log_path_without_custom_home(self):
        path = cli.app_agent_log_path({"HOME": "/Users/x"})
        self.assertEqual(path.parts[-4:], ("Library", "Logs", "AIUsageMonitor", "collector.log"))
        self.assertEqual(cli.launch_agents_dir({}).parts[-2:], ("Library", "LaunchAgents"))


if __name__ == "__main__":
    unittest.main()
