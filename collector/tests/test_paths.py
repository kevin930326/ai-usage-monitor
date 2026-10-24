import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from usage_collector import system
from usage_collector.paths import TestHomeNotSet, cli_environ, is_testing, resolve_home
from usage_collector.providers import codex

DEFAULT = system.default_home({})  # macOS：~/Library/Application Support/AIUsageMonitor（見 test_system）


class ResolveHomeTest(unittest.TestCase):
    def test_uses_environment_variable(self):
        self.assertEqual(resolve_home({"AI_USAGE_MONITOR_HOME": "/tmp/aum"}), Path("/tmp/aum"))

    def test_defaults_to_application_support(self):
        self.assertEqual(resolve_home({}, modules=()), DEFAULT)

    def test_empty_value_falls_back_like_the_mac_app(self):
        # UsageKit 的 UsageFileLocator 把空字串視為未設定，兩邊必須一致
        self.assertEqual(resolve_home({"AI_USAGE_MONITOR_HOME": ""}, modules=()), DEFAULT)


class TestEnvironmentTest(unittest.TestCase):
    def test_detects_unittest_pytest_and_the_flag(self):
        self.assertTrue(is_testing({}, modules=("unittest",)))
        self.assertTrue(is_testing({}, modules=("pytest",)))
        self.assertTrue(is_testing({"AUM_TESTING": "1"}, modules=()))
        self.assertFalse(is_testing({"AUM_TESTING": ""}, modules=()))
        self.assertFalse(is_testing({}, modules=("json",)))

    def test_refuses_the_default_folder_while_testing(self):
        for environ in ({}, {"AI_USAGE_MONITOR_HOME": ""}):
            with self.assertRaises(TestHomeNotSet):
                resolve_home(environ)  # 這個行程已載入 unittest
        with self.assertRaises(TestHomeNotSet):
            resolve_home({"AUM_TESTING": "1"}, modules=())

    def test_an_explicit_folder_is_still_allowed_while_testing(self):
        self.assertEqual(resolve_home({"AI_USAGE_MONITOR_HOME": "/tmp/aum", "AUM_TESTING": "1"}), Path("/tmp/aum"))


if __name__ == "__main__":
    unittest.main()


class CliEnvironTest(unittest.TestCase):
    """額度 CLI 用的環境：config.json 的 claude_config_dir／codex_home 優先（Codex C-02）"""

    def test_config_dirs_override_and_unset_ones_are_not_added(self):
        with tempfile.TemporaryDirectory() as d:
            config = Path(d) / "config.json"
            config.write_text(json.dumps({"claude_config_dir": str(Path(d) / "c"), "codex_home": str(Path(d) / "x")}))
            env = cli_environ(config, {"PATH": "p", "CODEX_HOME": "old"})
            self.assertEqual((env["CLAUDE_CONFIG_DIR"], env["CODEX_HOME"], env["PATH"]),
                             (str(Path(d) / "c"), str(Path(d) / "x"), "p"))
            config.write_text(json.dumps({"claude_config_dir": None, "codex_home": ""}))
            self.assertEqual(cli_environ(config, {"CODEX_HOME": "kept"}), {"CODEX_HOME": "kept"})
            config.write_text("[1, 2]")
            self.assertEqual(cli_environ(config, {}), {})
            self.assertEqual(cli_environ(Path(d) / "missing.json", {"A": "1"}), {"A": "1"})

    def test_codex_app_server_gets_codex_home_from_config(self):
        with tempfile.TemporaryDirectory() as d:
            config = Path(d) / "config.json"
            config.write_text(json.dumps({"codex_home": str(Path(d) / "codex-home")}))
            with mock.patch("usage_collector.paths.CONFIG_PATH", config), \
                 mock.patch("usage_collector.providers.codex.subprocess.Popen", side_effect=OSError) as popen:
                with self.assertRaises(codex.ProviderError):
                    codex.AppServer(str(Path(d) / "codex"))
            env = popen.call_args.kwargs["env"]
            self.assertEqual(env["CODEX_HOME"], str(Path(d) / "codex-home"))
            self.assertTrue(env["PATH"].startswith(d))
