"""scripts/setup-iphone.sh 與 scripts/render-qr.swift（iPhone 配對，ADR-0012）的測試。

HOME 指到暫存資料夾；xcodebuild、xcodegen、xcrun（devicectl）、security、curl、defaults 都是假的
（PATH 最前面），不碰真的 Keychain、Xcode 設定、手機與網路。假密鑰只存在測試裡。
"""
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "setup-iphone.sh"
RENDER = ROOT / "scripts" / "render-qr.swift"
READ = "fake-read-token-0123456789"
WRITE = "fake-write-token-9876543210"
UDID = "00008110-001A2B3C4D5E6F70"
DEVICES = {"result": {"devices": [{
    "hardwareProperties": {"platform": "iOS", "reality": "physical", "deviceType": "iPhone", "udid": UDID},
    "deviceProperties": {"name": "測試手機"}, "connectionProperties": {"transportType": "localNetwork"},
}]}}


def write_exec(path: Path, body: str) -> None:
    path.write_text("#!/bin/bash\n" + textwrap.dedent(body))
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


@unittest.skipUnless(sys.platform == "darwin", "setup-iphone.sh 只在 macOS 上執行")
class SetupIphoneTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.home = self.tmp / "home"
        self.bin = self.tmp / "bin"
        self.log = self.tmp / "calls.log"
        self.config_dir = self.home / "Library" / "Application Support" / "AIUsageMonitor"
        for d in (self.bin, self.config_dir):
            d.mkdir(parents=True)
        (self.tmp / "devices.json").write_text(json.dumps(DEVICES))
        log = self.log
        write_exec(self.bin / "xcodebuild", f'echo "xcodebuild $*" >>"{log}"; [ "$1" = -version ] && echo "Xcode 26.0"; exit 0\n')
        write_exec(self.bin / "xcodegen", f'echo "xcodegen $*" >>"{log}"\n')
        write_exec(self.bin / "defaults", "exit 1\n")
        write_exec(self.bin / "xcrun", f'''
            echo "xcrun $*" >>"{log}"
            if [ "$1 $2 $3" = "devicectl list devices" ]; then
                while [ $# -gt 0 ]; do [ "$1" = --json-output ] && cp "{self.tmp}/devices.json" "$2"; shift; done
            fi
            exit 0
        ''')
        # 假的 Keychain：FAKE_READ／FAKE_WRITE 是「已存的」密鑰；add 時從標準輸入讀（模擬互動輸入）
        write_exec(self.bin / "security", f'''
            svc=""; prev=""; for a in "$@"; do [ "$prev" = -s ] && svc=$a; prev=$a; done
            echo "security $1 $svc" >>"{log}"
            case "$1 $svc" in
                "find-generic-password AIUsageMonitor-relay-read")
                    v=${{FAKE_READ:-$(cat "{self.tmp}/stored-read" 2>/dev/null)}}; [ -n "$v" ] && echo "$v" && exit 0; exit 44 ;;
                "find-generic-password AIUsageMonitor-relay-write") [ -n "${{FAKE_WRITE:-}}" ] && echo "$FAKE_WRITE" && exit 0; exit 44 ;;
                "add-generic-password AIUsageMonitor-relay-read") echo "{READ}" >"{self.tmp}/stored-read"; exit 0 ;;
            esac
            exit 1
        ''')
        # 假的 curl：記下參數（確認密鑰不在參數裡）與標準輸入的標頭，依 FAKE_STATUS 回應
        write_exec(self.bin / "curl", f'''
            echo "curl $*" >>"{log}"
            cat >"{self.tmp}/curl-stdin"
            out=""
            while [ $# -gt 0 ]; do [ "$1" = -o ] && out="$2"; shift; done
            printf '%s' "${{FAKE_BODY:-{{\\"code\\":\\"7K3MQ9TD\\",\\"expires_at\\":\\"2026-10-24T21:10:00Z\\"}}}}" >"$out"
            printf '%s' "${{FAKE_STATUS:-200}}"
        ''')

    def config(self, **values):
        (self.config_dir / "config.json").write_text(json.dumps(values))

    def run_script(self, *args, env=None):
        environ = {"HOME": str(self.home), "PATH": f"{self.bin}:/usr/bin:/bin", "LANG": "zh_TW.UTF-8"}
        environ.update(env or {})
        return subprocess.run(["/bin/bash", str(SCRIPT), *args], capture_output=True, text=True, env=environ,
                              stdin=subprocess.DEVNULL, start_new_session=True, timeout=180)

    def calls(self):
        return self.log.read_text() if self.log.exists() else ""

    def test_dry_run_detects_everything_and_changes_nothing(self):
        r = self.run_script("--team", "ABCDE12345", "--auto-reinstall", "--dry-run")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("✅ Team ID：ABCDE12345", r.stdout)
        self.assertIn("✅ iPhone：測試手機（localNetwork）", r.stdout)
        self.assertIn("會執行：", r.stdout)
        self.assertIn("reinstall-ios.sh", r.stdout)
        self.assertIn("install-reinstall-launchd.sh", r.stdout)
        self.assertFalse((self.config_dir / "config.json").exists())
        self.assertNotIn("xcodebuild -project", self.calls())
        self.assertNotIn("security", self.calls())

    def test_missing_tools_and_team_explain_what_to_do(self):
        (self.bin / "xcodegen").unlink()
        r = self.run_script("--team", "ABCDE12345", "--dry-run")
        self.assertEqual(r.returncode, 2)
        self.assertIn("brew install xcodegen", r.stderr)
        write_exec(self.bin / "xcodegen", "exit 0\n")
        write_exec(self.bin / "security", "exit 1\n")  # 找不到憑證
        r = self.run_script("--dry-run")
        self.assertEqual(r.returncode, 2)
        self.assertIn("Xcode → Settings → Accounts", r.stderr)
        self.assertEqual(self.run_script("--team", "bad").returncode, 2)
        self.assertEqual(self.run_script("--pair", "url").returncode, 2)

    def test_no_or_several_iphones(self):
        (self.tmp / "devices.json").write_text(json.dumps({"result": {"devices": []}}))
        r = self.run_script("--team", "ABCDE12345", "--dry-run")
        self.assertEqual(r.returncode, 3)
        self.assertIn("開發者模式", r.stderr)
        second = json.loads(json.dumps(DEVICES["result"]["devices"][0]))
        second["hardwareProperties"]["udid"] = "00008110-FFFFFFFFFFFFFFFF"
        (self.tmp / "devices.json").write_text(json.dumps({"result": {"devices": DEVICES["result"]["devices"] + [second]}}))
        r = self.run_script("--team", "ABCDE12345", "--dry-run")
        self.assertEqual(r.returncode, 3)
        self.assertIn("--udid", r.stderr)
        r = self.run_script("--team", "ABCDE12345", "--udid", UDID, "--dry-run")
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_pair_needs_an_https_relay(self):
        r = self.run_script("--pair-only", "qr")
        self.assertEqual(r.returncode, 5)
        self.assertIn("relay_url", r.stderr)
        self.config(relay_url="http://relay.example.dev")
        self.assertEqual(self.run_script("--pair-only", "qr").returncode, 5)

    def test_pair_dry_run_reads_no_keychain(self):
        self.config(relay_url="https://relay.example.dev/")
        for mode in ("qr", "code"):
            r = self.run_script("--pair-only", mode, "--dry-run")
            self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("security", self.calls())
        self.assertNotIn("curl", self.calls())

    def test_qr_shows_the_read_token_only_as_a_qr_code(self):
        self.config(relay_url="https://relay.example.dev/")
        r = self.run_script("--pair-only", "qr", env={"FAKE_READ": READ, "FAKE_WRITE": WRITE})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("▀", r.stdout)
        self.assertNotIn(READ, r.stdout + r.stderr)
        self.assertNotIn(WRITE, r.stdout + r.stderr)
        self.assertIn("\033[3J", r.stdout)  # 按 Enter 後清除捲動緩衝
        # 終端機上的 QR 碼解得回正確的配對內容（只有網址與讀取密鑰）
        qr = r.stdout.split("✅ 中繼：relay.example.dev\n", 1)[1].split("在 iPhone", 1)[0].strip("\n")
        decoded = subprocess.run(["swift", str(RENDER), "--decode"], input=qr, capture_output=True, text=True, timeout=180)
        self.assertEqual(decoded.returncode, 0, decoded.stderr)
        self.assertEqual(decoded.stdout.strip(), "aiusage-pair:v1:" + _b64url({"read": READ, "url": "https://relay.example.dev"}))

    def test_qr_is_cleared_when_interrupted(self):
        # Codex C-03：顯示 QR 碼後按 Ctrl-C 或被終止，也要清除畫面與捲動緩衝（以偽終端機等在「按 Enter」）
        import os, pty, select, signal, time
        self.config(relay_url="https://relay.example.dev")
        env = {"HOME": str(self.home), "PATH": f"{self.bin}:/usr/bin:/bin", "LANG": "zh_TW.UTF-8", "FAKE_READ": READ}
        for sig, code in ((signal.SIGINT, 130), (signal.SIGTERM, 143)):
            pid, fd = pty.fork()
            if pid == 0:
                os.execve("/bin/bash", ["/bin/bash", str(SCRIPT), "--pair-only", "qr"], env)
            out, deadline = b"", time.time() + 180
            while "按 Enter".encode() not in out and time.time() < deadline:
                if select.select([fd], [], [], 1)[0]:
                    try:
                        out += os.read(fd, 65536)
                    except OSError:
                        break
            self.assertIn("▀".encode(), out)
            # macOS 的 bash 3.2 印出 read -p 的提示後才開始讀：訊號剛好落在中間時會被擱著，讀取照樣等下去
            # （使用者再按一次 Ctrl-C 就會結束）。測試沒看到結束就每秒重送一次，最多 10 秒
            os.kill(pid, sig)
            resend = time.time() + 10
            while True:
                ready = select.select([fd], [], [], 1)[0]
                if not ready:
                    if time.time() > resend:
                        break
                    os.kill(pid, sig)
                    continue
                try:
                    chunk = os.read(fd, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                out += chunk
            _, status = os.waitpid(pid, 0)
            os.close(fd)
            self.assertEqual(os.waitstatus_to_exitcode(status), code)
            self.assertIn(b"\033[3J", out.split("按 Enter".encode(), 1)[1])

    def test_qr_asks_for_the_read_token_once_and_refuses_the_write_token(self):
        self.config(relay_url="https://relay.example.dev")
        r = self.run_script("--pair-only", "qr")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("add-generic-password AIUsageMonitor-relay-read", self.calls())
        # 讀取與寫入密鑰相同：不顯示 QR 碼
        r = self.run_script("--pair-only", "qr", env={"FAKE_READ": WRITE, "FAKE_WRITE": WRITE})
        self.assertEqual(r.returncode, 5)
        self.assertNotIn("▀", r.stdout)
        r = self.run_script("--pair-only", "qr", env={"FAKE_READ": "short"})
        self.assertEqual(r.returncode, 5)

    def test_short_code_sends_the_write_token_on_stdin(self):
        self.config(relay_url="https://relay.example.dev")
        r = self.run_script("--pair-only", "code", env={"FAKE_WRITE": WRITE})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("短碼：7K3M-Q9TD", r.stdout)
        self.assertIn("https://relay.example.dev/pair", self.calls())
        self.assertNotIn(WRITE, self.calls())  # 不在 curl 的參數裡
        self.assertEqual((self.tmp / "curl-stdin").read_text(), f"Authorization: Bearer {WRITE}\n")
        self.assertNotIn(WRITE, r.stdout + r.stderr)

    def test_short_code_failures(self):
        self.config(relay_url="https://relay.example.dev")
        r = self.run_script("--pair-only", "code")
        self.assertEqual(r.returncode, 5)
        self.assertIn("set-relay.sh", r.stderr)
        r = self.run_script("--pair-only", "code", env={"FAKE_WRITE": WRITE, "FAKE_STATUS": "404"})
        self.assertEqual(r.returncode, 5)
        self.assertIn("還不支援短碼", r.stderr)
        r = self.run_script("--pair-only", "code", env={"FAKE_WRITE": WRITE, "FAKE_BODY": '{"code":"bad"}'})
        self.assertEqual(r.returncode, 5)
        self.assertIn("格式不正確", r.stderr)


def _b64url(obj) -> str:
    import base64
    raw = json.dumps(obj, separators=(",", ":"), sort_keys=True).replace("/", "\\/").encode()
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


if __name__ == "__main__":
    unittest.main()
