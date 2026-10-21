import io
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

from usage_collector import __main__ as cli
from usage_collector.models import ProviderError, ProviderUsage
from usage_collector.providers import enabled_providers

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"


class EnabledProvidersTest(unittest.TestCase):
    """config.json 的 enabled_providers：沒有使用某個服務不是錯誤（只有 Claude 或只有 Codex 的使用者）。"""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = Path(self.dir.name) / "config.json"

    def tearDown(self):
        self.dir.cleanup()

    def load(self, config) -> tuple[list[str], str]:
        if config is not None:
            self.path.write_text(config if isinstance(config, str) else json.dumps(config))
        err = io.StringIO()
        with redirect_stderr(err):
            names = enabled_providers(self.path)
        return names, err.getvalue()

    def test_missing_config_enables_all(self):
        # 舊版安裝沒有 config.json 或沒有這個欄位：維持全部啟用
        self.assertEqual(self.load(None), (["claude", "codex"], ""))
        self.assertEqual(self.load({"relay_url": "https://relay.example.dev"}), (["claude", "codex"], ""))

    def test_broken_config_enables_all(self):
        self.assertEqual(self.load('{"relay_url": ')[0], ["claude", "codex"])

    def test_single_provider(self):
        self.assertEqual(self.load({"enabled_providers": ["codex"]}), (["codex"], ""))
        self.assertEqual(self.load({"enabled_providers": ["claude"]}), (["claude"], ""))

    def test_keeps_registry_order_and_dedupes(self):
        self.assertEqual(self.load({"enabled_providers": ["codex", "claude", "codex"]})[0], ["claude", "codex"])

    def test_empty_list_enables_none(self):
        self.assertEqual(self.load({"enabled_providers": []}), ([], ""))

    def test_wrong_type_enables_all_and_logs(self):
        names, err = self.load({"enabled_providers": "claude"})
        self.assertEqual(names, ["claude", "codex"])
        self.assertIn("字串陣列", err)

    def test_unknown_names_are_skipped_and_logged(self):
        names, err = self.load({"enabled_providers": ["claude", "gemini"]})
        self.assertEqual(names, ["claude"])
        self.assertIn("gemini", err)


class CollectEnabledTest(unittest.TestCase):
    def setUp(self):
        self.claude = mock.Mock(fetch=mock.Mock(side_effect=ProviderError("找不到 Claude Code 登入資訊")))
        self.codex = mock.Mock(fetch=mock.Mock(return_value=ProviderUsage(plan="Plus")))
        patcher = mock.patch.dict(cli.PROVIDERS, {"claude": self.claude, "codex": self.codex}, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)

    def run_main(self, enabled):
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(cli, "enabled_providers", return_value=enabled), \
             redirect_stdout(out), redirect_stderr(err):
            code = cli.main(["--compact"])
        return code, json.loads(out.getvalue()), err.getvalue()

    def test_disabled_provider_is_absent_not_error(self):
        code, snapshot, err = self.run_main(["codex"])
        self.assertEqual(code, 0)
        self.assertEqual(list(snapshot["providers"]), ["codex"])
        self.claude.fetch.assert_not_called()
        self.assertEqual(err, "")  # 未啟用的服務不寫日誌

    def test_enabled_provider_without_login_is_still_an_error(self):
        code, snapshot, err = self.run_main(["claude", "codex"])
        self.assertEqual(code, 0)
        self.assertEqual(snapshot["providers"]["claude"]["error"], "找不到 Claude Code 登入資訊")
        self.assertIn("claude: 找不到 Claude Code 登入資訊", err)

    def test_nothing_enabled_returns_non_zero_with_hint(self):
        code, snapshot, err = self.run_main([])
        self.assertEqual((code, snapshot["providers"]), (1, {}))
        self.assertIn("install-launchd.sh", err)

    def test_default_reads_config(self):
        with tempfile.TemporaryDirectory() as d:
            config = Path(d) / "config.json"
            config.write_text(json.dumps({"enabled_providers": ["codex"]}))
            with mock.patch("usage_collector.paths.CONFIG_PATH", config):
                self.assertEqual(list(cli.collect()["providers"]), ["codex"])


class DetectProvidersTest(unittest.TestCase):
    """install-launchd.sh 用的偵測：Keychain 有 Claude Code-credentials、有 ~/.codex/auth.json。"""

    def detect(self, claude: bool, codex: bool) -> list[str]:
        with tempfile.TemporaryDirectory() as d:
            home, bin_dir = Path(d) / "home", Path(d) / "bin"
            home.mkdir()
            bin_dir.mkdir()
            # 假的 security：有 Claude 登入時回傳 0，並確認沒有要求讀出密碼（-w）
            fake = bin_dir / "security"
            fake.write_text("#!/bin/bash\n"
                            'for a in "$@"; do [ "$a" = -w ] && exit 99; done\n'
                            f"exit {0 if claude else 44}\n")
            fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
            if codex:
                (home / ".codex").mkdir()
                (home / ".codex" / "auth.json").write_text("{}")
            env = {**os.environ, "HOME": str(home), "PATH": f"{bin_dir}:/usr/bin:/bin"}
            result = subprocess.run([str(SCRIPTS / "detect-providers.sh")], env=env,
                                    capture_output=True, text=True, check=True)
        return result.stdout.split()

    def test_detection(self):
        self.assertEqual(self.detect(True, True), ["claude", "codex"])
        self.assertEqual(self.detect(True, False), ["claude"])
        self.assertEqual(self.detect(False, True), ["codex"])
        self.assertEqual(self.detect(False, False), [])


class UpdateConfigJsonTest(unittest.TestCase):
    def test_json_value_merges_without_dropping_other_keys(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "config.json"
            path.write_text(json.dumps({"relay_url": "https://relay.example.dev", "claude_path": "/bin/claude"}))
            subprocess.run([sys.executable, str(SCRIPTS / "update-config.py"), "--json", str(path),
                            "enabled_providers", '["codex"]'], check=True)
            self.assertEqual(json.loads(path.read_text()), {
                "relay_url": "https://relay.example.dev",
                "claude_path": "/bin/claude",
                "enabled_providers": ["codex"],
            })

    def test_invalid_json_value_is_not_written(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "config.json"
            path.write_text('{"relay_url": "x"}')
            result = subprocess.run([sys.executable, str(SCRIPTS / "update-config.py"), "--json", str(path),
                                     "enabled_providers", "[codex"], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(path.read_text(), '{"relay_url": "x"}')


if __name__ == "__main__":
    unittest.main()
