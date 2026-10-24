"""scripts/setup-relay.sh（一次部署中繼）的測試。

npx（wrangler）、node、security、curl 都是假的（PATH 最前面）；relay 資料夾是暫存複本、
設定資料夾是暫存資料夾（AI_USAGE_MONITOR_HOME），不登入、不建立任何 Cloudflare 資源、不碰真的 Keychain。
"""
import json
import shutil
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "setup-relay.sh"
KV_ID = "0123456789abcdef0123456789abcdef"


def write_exec(path: Path, body: str) -> None:
    path.write_text("#!/bin/bash\n" + textwrap.dedent(body))
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


@unittest.skipUnless(sys.platform == "darwin", "setup-relay.sh 用到 macOS 的 security")
class SetupRelayTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.bin = self.tmp / "bin"
        self.relay = self.tmp / "relay"
        self.home = self.tmp / "app"
        self.log = self.tmp / "calls.log"
        for d in (self.bin, self.relay / "node_modules", self.home):
            d.mkdir(parents=True)
        shutil.copy(ROOT / "relay" / "wrangler.toml", self.relay)
        shutil.copy(ROOT / "relay" / "package-lock.json", self.relay)
        t, log = self.tmp, self.log
        write_exec(self.bin / "node", '''
            v=${FAKE_NODE:-24.1.0}
            [ "$1" = -p ] && { echo "$v"; exit 0; }
            IFS=. read -r a b _ <<<"$v"; [ "$a" -gt 23 ] || { [ "$a" -eq 23 ] && [ "$b" -ge 6 ]; }
        ''')
        # 假的 wrangler：記下參數與標準輸入（secret put），依 FAKE_* 決定回應
        write_exec(self.bin / "npx", f'''
            [ "$1 $2" = "--no-install wrangler" ] || exit 99
            shift 2
            echo "wrangler $* (cwd=$(basename "$PWD"))" >>"{log}"
            echo "env WRANGLER_WRITE_LOGS=${{WRANGLER_WRITE_LOGS:-}} WRANGLER_LOG_SANITIZE=${{WRANGLER_LOG_SANITIZE:-}}" >>"{t}/wrangler-env"
            case "$1 $2" in
                "whoami --json") [ -e "{t}/logged-in" ] || [ -n "${{FAKE_LOGGED_IN:-}}" ] ;;
                "login ") touch "{t}/logged-in" ;;
                "deployments list")
                    [ -n "${{FAKE_EXISTS:-}}" ] && {{ echo "Created: 2026-10-01"; exit 0; }}
                    echo "${{FAKE_LIST_ERROR:-✘ [ERROR] This Worker does not exist on your account. [code: 10007]}}"; exit 1 ;;
                "kv namespace") echo "✨ Success!"; echo '  "id": "{KV_ID}"' ;;
                "deploy --config") echo "Uploaded ai-usage-relay"; echo "  https://ai-usage-relay.tester.workers.dev" ;;
                "secret put") cat >>"{t}/secrets"; echo >>"{t}/secrets" ;;
                *) exit 1 ;;
            esac
        ''')
        # 假的 Keychain：-i 的 add 指令存成 kc/<service>（FAKE_KC_FAIL 指定的 service 存不進去，但仍回傳 0，同真的 security -i）
        (t / "kc").mkdir()
        write_exec(self.bin / "security", f'''
            echo "security $1" >>"{log}"
            svc=""; prev=""; for a in "$@"; do [ "$prev" = -s ] && svc=$a; prev=$a; done
            case "$1" in
                find-generic-password)
                    [ -n "${{FAKE_KEYCHAIN:-}}" ] && exit 0
                    [ -f "{t}/kc/$svc" ] || exit 44
                    [ "${{@: -1}}" = -w ] && cat "{t}/kc/$svc"; exit 0 ;;
                -i)
                    while read -r cmd _ _ s _ _ _ v; do
                        echo "$cmd -s $s -a default -w $v" >>"{t}/keychain-commands"
                        [ "$s" = "${{FAKE_KC_FAIL:-}}" ] || printf '%s' "$v" >"{t}/kc/$s"
                    done
                    exit 0 ;;
                *) exit 1 ;;
            esac
        ''')
        write_exec(self.bin / "curl", f'''
            echo "curl $*" >>"{log}"
            cat >"{t}/curl-stdin"
            printf '%s' "${{FAKE_STATUS:-404}}"
        ''')

    def run_script(self, *args, env=None):
        environ = {"HOME": str(self.tmp / "home"), "PATH": f"{self.bin}:/usr/bin:/bin", "LANG": "zh_TW.UTF-8",
                   "AUM_RELAY_DIR": str(self.relay), "AI_USAGE_MONITOR_HOME": str(self.home), "AUM_RETRY_SECONDS": "0"}
        environ.update(env or {})
        return subprocess.run(["/bin/bash", str(SCRIPT), *args], capture_output=True, text=True, env=environ,
                              stdin=subprocess.DEVNULL, start_new_session=True, timeout=60)

    def calls(self):
        return self.log.read_text() if self.log.exists() else ""

    def test_dry_run_creates_nothing(self):
        r = self.run_script("--dry-run")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("✅ 這台 Mac 還沒有設定中繼", r.stdout)
        self.assertIn("（dry-run）接下來會", r.stdout)
        self.assertNotIn("wrangler", self.calls())  # 連 whoami 都不跑
        self.assertNotIn("-i", self.calls())
        self.assertFalse((self.relay / "wrangler.local.toml").exists())
        self.assertFalse((self.home / "config.json").exists())

    def test_full_run_with_a_fake_wrangler(self):
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stderr)
        calls = self.calls()
        self.assertIn("wrangler login", calls)
        self.assertIn("wrangler kv namespace create USAGE_KV", calls)
        self.assertIn("wrangler deploy --config wrangler.local.toml (cwd=relay)", calls)
        toml = (self.relay / "wrangler.local.toml").read_text()
        self.assertIn(f'id = "{KV_ID}"', toml)
        self.assertIn('name = "ai-usage-relay"', toml)
        # repo 的 wrangler.toml 沒有被改
        self.assertEqual((self.relay / "wrangler.toml").read_text(), (ROOT / "relay" / "wrangler.toml").read_text())
        # 兩把不同的密鑰，只經由標準輸入；程序參數與輸出都看不到
        write, read = (self.tmp / "secrets").read_text().split()
        self.assertNotEqual(write, read)
        self.assertGreaterEqual(len(read), 40)
        for token in (write, read):
            self.assertNotIn(token, calls)
            self.assertNotIn(token, r.stdout + r.stderr)
        self.assertEqual((self.tmp / "curl-stdin").read_text(), f"Authorization: Bearer {read}\n")
        keychain = (self.tmp / "keychain-commands").read_text()
        self.assertIn(f"-s AIUsageMonitor-relay-write -a default -w {write}", keychain)
        self.assertIn(f"-s AIUsageMonitor-relay-read -a default -w {read}", keychain)
        self.assertEqual(json.loads((self.home / "config.json").read_text())["relay_url"],
                         "https://ai-usage-relay.tester.workers.dev")
        self.assertIn("setup-iphone.sh --pair-only qr", r.stdout)

    def test_wrangler_never_writes_its_own_logs(self):
        # Codex C-01：繼承 WRANGLER_LOG_SANITIZE=false 也要覆寫；wrangler 的錯誤原文不轉印
        r = self.run_script(env={"WRANGLER_LOG_SANITIZE": "false", "WRANGLER_WRITE_LOGS": "true",
                                 "FAKE_LOGGED_IN": "1", "FAKE_LIST_ERROR": "✘ secret-ish /Users/someone/path"})
        self.assertEqual(r.returncode, 4)
        self.assertNotIn("/Users/someone", r.stdout + r.stderr)
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stderr)
        lines = set((self.tmp / "wrangler-env").read_text().splitlines())
        self.assertEqual(lines, {"env WRANGLER_WRITE_LOGS=false WRANGLER_LOG_SANITIZE=true"})

    def test_keychain_failures_are_detected_and_config_is_written_last(self):
        # Codex C-02：security -i 失敗仍回傳 0；任何一把沒存進去都不寫 relay_url、不說完成
        for failing in ("AIUsageMonitor-relay-write", "AIUsageMonitor-relay-read"):
            for p in (self.relay / "wrangler.local.toml", *(self.tmp / "kc").iterdir()):
                p.unlink(missing_ok=True)
            r = self.run_script(env={"FAKE_LOGGED_IN": "1", "FAKE_KC_FAIL": failing})
            self.assertEqual(r.returncode, 5, failing)
            self.assertNotIn("完成", r.stdout)
            self.assertIn("set-relay.sh", r.stderr)
            self.assertFalse((self.home / "config.json").exists())

    def test_stops_on_existing_settings_without_changes(self):
        (self.home / "config.json").write_text(json.dumps({"relay_url": "https://old.example.workers.dev"}))
        r = self.run_script()
        self.assertEqual(r.returncode, 3)
        self.assertIn("relay_url", r.stderr)
        (self.home / "config.json").unlink()
        r = self.run_script(env={"FAKE_KEYCHAIN": "1"})
        self.assertEqual(r.returncode, 3)
        self.assertIn("AIUsageMonitor-relay-write", r.stderr)
        (self.relay / "wrangler.local.toml").write_text("old")
        r = self.run_script("--dry-run")
        self.assertEqual(r.returncode, 3)
        self.assertEqual((self.relay / "wrangler.local.toml").read_text(), "old")
        self.assertNotIn("wrangler", self.calls())

    def test_stops_when_the_worker_already_exists_or_the_lookup_fails(self):
        r = self.run_script(env={"FAKE_LOGGED_IN": "1", "FAKE_EXISTS": "1"})
        self.assertEqual(r.returncode, 3)
        self.assertIn("已經有名為 ai-usage-relay", r.stderr)
        r = self.run_script(env={"FAKE_LOGGED_IN": "1", "FAKE_LIST_ERROR": "✘ [ERROR] fetch failed"})
        self.assertEqual(r.returncode, 4)
        self.assertNotIn("kv namespace", self.calls())
        self.assertNotIn("deploy", self.calls().replace("deployments", ""))
        self.assertFalse((self.relay / "wrangler.local.toml").exists())

    def test_environment_and_argument_checks(self):
        self.assertEqual(self.run_script("--dry-run", env={"FAKE_NODE": "22.11.0"}).returncode, 2)
        self.assertEqual(self.run_script("--name", "Bad_Name", "--dry-run").returncode, 2)
        r = self.run_script("--name", "my-relay", "--dry-run")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("my-relay", r.stdout)

    def test_unexpected_relay_status_fails(self):
        r = self.run_script(env={"FAKE_LOGGED_IN": "1", "FAKE_STATUS": "500"})
        self.assertEqual(r.returncode, 4)
        self.assertFalse((self.home / "config.json").exists())


if __name__ == "__main__":
    unittest.main()
