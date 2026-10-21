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


# 假的 codex login status 的輸出與結束碼（與 Codex CLI 0.163 相同；訊息印在 stderr）
CODEX_STATUS = {
    "chatgpt": ("Logged in using ChatGPT", 0),
    "apikey": ("Logged in using an API key - sk-proj-***ABCD", 0),
    "logged-out": ("Not logged in", 1),
    "weird": ("Error: person@example.com something went wrong", 2),
}


def write_fake_codex(bin_dir: Path, state: str) -> Path:
    """假的 codex：只認得 login status，被要求其他事（例如讀 auth.json 的指令）就失敗。"""
    message, code = CODEX_STATUS[state]
    fake = bin_dir / "codex"
    fake.write_text("#!/bin/bash\n"
                    '[ "$1 $2" = "login status" ] || exit 98\n'
                    f"echo '{message}' >&2\n"
                    f"exit {code}\n")
    fake.chmod(0o755)
    return fake


class DetectProvidersTest(unittest.TestCase):
    """install-launchd.sh 用的偵測：問 `claude auth status` 與 `codex login status`，不讀登入檔。"""

    def detect(self, claude: bool | None, codex: str | None, codex_dir: bool = False) -> list[str]:
        """claude：True 已登入、False 未登入、None 找不到 claude。
        codex：CODEX_STATUS 的狀態，None 找不到 codex；codex_dir：~/.codex 是否存在。"""
        with tempfile.TemporaryDirectory() as d:
            home, bin_dir = Path(d) / "home", Path(d) / "bin"
            home.mkdir()
            bin_dir.mkdir()
            # 假的 security：被呼叫就失敗，確認偵測不碰 Claude Code 的 Keychain 項目
            security = bin_dir / "security"
            security.write_text("#!/bin/bash\nexit 99\n")
            security.chmod(security.stat().st_mode | stat.S_IEXEC)
            # 假的 claude：只認得 auth status，登入時結束碼 0（與真的 Claude Code 相同）
            fake = bin_dir / "claude"
            fake.write_text("#!/bin/bash\n"
                            '[ "$1 $2" = "auth status" ] || exit 98\n'
                            'echo \'{"loggedIn": true, "email": "person@example.com"}\'\n'
                            f"exit {0 if claude else 1}\n")
            fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
            fake_codex = write_fake_codex(bin_dir, codex) if codex else None
            if codex_dir:
                (home / ".codex").mkdir()
                # 登入檔不能被讀：權限設成 000，cat 也讀不到
                auth = home / ".codex" / "auth.json"
                auth.write_text('{"tokens": {"access_token": "secret"}}')
                auth.chmod(0)
            env = {**os.environ, "HOME": str(home), "PATH": f"{bin_dir}:/usr/bin:/bin"}
            env.pop("CODEX_HOME", None)
            args = [str(SCRIPTS / "detect-providers.sh"), "" if claude is None else str(fake),
                    str(fake_codex) if fake_codex else ""]
            result = subprocess.run(args, env=env, capture_output=True, text=True, check=True)
        self.assertNotIn("@", result.stdout)
        self.assertNotIn("secret", result.stdout)
        return result.stdout.split()

    def test_claude_detection(self):
        self.assertEqual(self.detect(True, "chatgpt"), ["claude", "codex"])
        self.assertEqual(self.detect(False, "chatgpt"), ["codex"])
        self.assertEqual(self.detect(None, "chatgpt"), ["?claude", "codex"])

    def test_codex_asks_codex_itself(self):
        self.assertEqual(self.detect(True, "chatgpt"), ["claude", "codex"])
        self.assertEqual(self.detect(True, "apikey", codex_dir=True), ["claude"])  # 沒有訂閱額度
        self.assertEqual(self.detect(True, "logged-out", codex_dir=True), ["claude"])  # 有登入檔也不算
        self.assertEqual(self.detect(True, "weird"), ["claude", "?codex"])  # 認不得：不知道

    def test_missing_codex(self):
        self.assertEqual(self.detect(True, None), ["claude"])  # 沒用過 Codex
        self.assertEqual(self.detect(True, None, codex_dir=True), ["claude", "?codex"])  # 用過但找不到


class InstallLaunchdTest(unittest.TestCase):
    """install-launchd.sh 寫 enabled_providers 的規則：任一服務的登入狀態是「不知道」（找不到指令、
    結果認不得）時不能把原本啟用的服務關掉。launchctl／plutil 用假的取代，不會真的安裝。
    注意：腳本也會找 /opt/homebrew/bin/claude 與 /usr/local/bin/claude，這台機器若裝在那裡，
    「找不到 claude」的案例會變成找得到；codex 的候選位置以 AUM_CODEX_FALLBACKS 清空。"""

    def install(self, *, claude_found: bool, claude_logged_in: bool = True, codex: str | None,
                codex_dir: bool = False, existing: dict | None = None) -> tuple[dict, str]:
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            home, bin_dir, config_dir = root / "home", root / "bin", root / "config"
            for p in (home, bin_dir, config_dir):
                p.mkdir()
            for name in ("launchctl", "plutil"):  # 不真的安裝 launchd 工作
                fake = bin_dir / name
                fake.write_text("#!/bin/bash\nexit 0\n")
                fake.chmod(0o755)
            (bin_dir / "python3").symlink_to(sys.executable)
            if claude_found:
                fake = bin_dir / "claude"
                fake.write_text("#!/bin/bash\n"
                                '[ "$1 $2" = "auth status" ] || exit 98\n'
                                'echo \'{"loggedIn": true, "email": "person@example.com"}\'\n'
                                f"exit {0 if claude_logged_in else 1}\n")
                fake.chmod(0o755)
            if codex:
                write_fake_codex(bin_dir, codex)
            if codex_dir:
                (home / ".codex").mkdir()
            if existing is not None:
                (config_dir / "config.json").write_text(json.dumps(existing))
            env = {"HOME": str(home), "PATH": f"{bin_dir}:/usr/bin:/bin", "AI_USAGE_MONITOR_HOME": str(config_dir),
                   "LANG": "en_US.UTF-8", "AUM_CODEX_FALLBACKS": ""}
            result = subprocess.run([str(SCRIPTS / "install-launchd.sh")], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            config_path = config_dir / "config.json"
            config = json.loads(config_path.read_text()) if config_path.exists() else {}
        self.assertNotIn("@", result.stdout)
        return config, result.stdout

    def test_detected_services_are_written(self):
        config, out = self.install(claude_found=True, codex="chatgpt")
        self.assertEqual(config["enabled_providers"], ["claude", "codex"])
        self.assertTrue(config["claude_path"].endswith("/bin/claude"))
        self.assertTrue(config["codex_path"].endswith("/bin/codex"))
        self.assertIn("Claude 用量：啟用", out)
        self.assertIn("Codex 用量：啟用（Codex CLI 已用 ChatGPT 登入）", out)

    def test_paths_are_merged_into_existing_config(self):
        existing = {"relay_url": "https://relay.example", "iphone_udid": "x"}
        config, _ = self.install(claude_found=True, codex="chatgpt", existing=existing)
        self.assertEqual(config["relay_url"], "https://relay.example")
        self.assertEqual(config["iphone_udid"], "x")
        self.assertIn("codex_path", config)

    def test_logged_out_claude_is_disabled(self):
        config, out = self.install(claude_found=True, claude_logged_in=False, codex="chatgpt")
        self.assertEqual(config["enabled_providers"], ["codex"])
        self.assertIn("Claude 用量：未啟用（Claude Code 沒有登入）", out)

    def test_logged_out_codex_is_disabled(self):
        for state in ("logged-out", "apikey"):
            with self.subTest(state=state):
                config, out = self.install(claude_found=True, codex=state, codex_dir=True)
                self.assertEqual(config["enabled_providers"], ["claude"])
                self.assertIn("Codex 用量：未啟用", out)

    def test_never_used_codex_is_disabled(self):
        config, out = self.install(claude_found=True, codex=None)
        self.assertEqual(config["enabled_providers"], ["claude"])
        self.assertNotIn("codex_path", config)

    def test_missing_claude_binary_keeps_existing_providers(self):
        # 重新執行安裝時 shell 找不到 claude：既有的 Claude 啟用不能被悄悄關掉
        existing = {"relay_url": "https://relay.example", "enabled_providers": ["claude", "codex"]}
        config, out = self.install(claude_found=False, codex="chatgpt", existing=existing)
        self.assertEqual({k: v for k, v in config.items() if k != "codex_path"}, existing)
        self.assertIn("找不到 claude 指令", out)
        self.assertIn("Claude 用量：不確定", out)
        self.assertIn("Codex 用量：啟用", out)

    def test_unknown_codex_keeps_existing_providers(self):
        existing = {"relay_url": "https://relay.example", "enabled_providers": ["claude", "codex"]}
        for kwargs, message in (({"codex": None, "codex_dir": True}, "找不到 codex 指令"),
                                ({"codex": "weird"}, "無法判斷 Codex CLI 的登入狀態")):
            with self.subTest(**kwargs):
                config, out = self.install(claude_found=True, existing=existing, **kwargs)
                self.assertEqual(config["enabled_providers"], ["claude", "codex"])
                self.assertEqual(config["relay_url"], "https://relay.example")
                self.assertIn(message, out)
                self.assertIn("Codex 用量：不確定", out)

    def test_missing_claude_binary_leaves_defaults_alone(self):
        config, out = self.install(claude_found=False, codex="chatgpt")
        self.assertNotIn("enabled_providers", config)
        self.assertNotIn("claude_path", config)
        self.assertIn("找不到 claude 指令", out)


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
