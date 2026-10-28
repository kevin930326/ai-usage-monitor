"""scripts/ 的 shell 腳本測試（python3 -m unittest discover -s scripts/tests）。

不連網、不碰真實的 /Applications、垃圾桶、Codex 或 reviews 資料夾：每個測試在暫存資料夾裡
建立假的 repo 與假的 xcodebuild／xcodegen／codex。
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
# 實際踩到的問題在 UTF-8 locale 下才會出現（macOS 的 bash 3.2 把多位元組字元當成變數名稱的一部分）
UTF8_ENV = {"LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"}


def write_exec(path: Path, body: str) -> None:
    path.write_text(textwrap.dedent(body).lstrip())
    path.chmod(0o755)


class NonAsciiAfterVariableTests(unittest.TestCase):
    """`$VAR（` 在 set -u 下會變成「VAR（: unbound variable」；緊接非 ASCII 字元的變數一律寫成 ${VAR}。"""

    PATTERN = re.compile(rb"\$[A-Za-z_][A-Za-z0-9_]*(?=[\x80-\xff])")

    def test_no_shell_variable_directly_followed_by_non_ascii(self):
        files = subprocess.run(["git", "ls-files", "*.sh"], cwd=ROOT, capture_output=True, check=True).stdout.split()
        self.assertTrue(files, "找不到任何 .sh 檔")
        hits = []
        for name in files:
            for n, line in enumerate((ROOT / name.decode()).read_bytes().splitlines(), 1):
                for m in self.PATTERN.finditer(line):
                    hits.append(f"{name.decode()}:{n}: {m.group().decode()}")
        self.assertEqual(hits, [], "改成 ${VAR}：\n" + "\n".join(hits))

    def test_bash_really_breaks_on_unbraced_variable(self):
        # 確認上面的規則不是多餘的：這台機器的 bash 遇到 $X（ 會中斷，${X}（ 正常
        bad = subprocess.run(["/bin/bash", "-c", 'set -u; X=1; echo "$X（"'], env={**os.environ, **UTF8_ENV}, capture_output=True)
        good = subprocess.run(["/bin/bash", "-c", 'set -u; X=1; echo "${X}（"'], env={**os.environ, **UTF8_ENV}, capture_output=True)
        self.assertEqual(good.returncode, 0)
        self.assertEqual(good.stdout.decode().strip(), "1（")
        if sys.platform == "darwin":
            self.assertNotEqual(bad.returncode, 0)


@unittest.skipUnless(sys.platform == "darwin", "install-mac-app.sh 用到 ditto、defaults（macOS）")
class InstallMacAppTests(unittest.TestCase):
    """以 AUM_INSTALL_DIR 跑完整的安裝流程（假 xcodebuild），不結束、不打開任何 App。"""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        repo = self.tmp / "repo"
        (repo / "scripts").mkdir(parents=True)
        (repo / "apple" / "MacMenuBar").mkdir(parents=True)
        shutil.copy(ROOT / "scripts" / "install-mac-app.sh", repo / "scripts")
        self.script = repo / "scripts" / "install-mac-app.sh"
        self.repo = repo
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        write_exec(bin_dir / "xcodegen", """
            #!/bin/bash
            mkdir -p AIUsageMenuBar.xcodeproj
        """)
        # 依 -derivedDataPath 產生一個最小的 .app（只有 Info.plist）
        write_exec(bin_dir / "xcodebuild", """
            #!/bin/bash
            while [ $# -gt 0 ]; do [ "$1" = -derivedDataPath ] && DD=$2; shift; done
            APP="$DD/Build/Products/Release/AIUsageMenuBar.app/Contents"
            mkdir -p "$APP/MacOS"
            cat > "$APP/Info.plist" <<'PLIST'
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>9.8.7</string></dict></plist>
            PLIST
            echo built
        """)
        self.home = self.tmp / "home"
        (self.home / ".Trash").mkdir(parents=True)
        self.apps = self.tmp / "Applications"
        self.apps.mkdir()
        self.env = {**os.environ, **UTF8_ENV, "HOME": str(self.home), "AUM_INSTALL_DIR": str(self.apps),
                    "PATH": f"{bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin"}

    def run_install(self, *args):
        return subprocess.run(["/bin/bash", str(self.script), *args], env=self.env, capture_output=True, text=True, errors="replace", timeout=60)

    def test_full_install_then_upgrade(self):
        first = self.run_install()
        self.assertEqual(first.returncode, 0, first.stderr + first.stdout)
        installed = self.apps / "AIUsageMenuBar.app"
        self.assertTrue((installed / "Contents" / "Info.plist").is_file())
        self.assertIn(f"已安裝：{installed}（版本 9.8.7）", first.stdout)
        self.assertNotIn("已打開", first.stdout)  # AUM_INSTALL_DIR 時不打開
        # 暫存資料夾與鎖都已清掉
        self.assertEqual([p.name for p in self.apps.iterdir()], ["AIUsageMenuBar.app"])
        self.assertFalse((self.repo / "build" / "install.lock").exists())

        second = self.run_install()
        self.assertEqual(second.returncode, 0, second.stderr + second.stdout)
        self.assertIn("舊版本已移到垃圾桶", second.stdout)
        trashed = list((self.home / ".Trash").iterdir())
        self.assertEqual(len(trashed), 1)
        self.assertTrue(trashed[0].name.startswith("AIUsageMenuBar-"))
        self.assertTrue(installed.is_dir())

    def test_lock_held_refuses_and_keeps_lock(self):
        lock = self.repo / "build" / "install.lock"
        lock.mkdir(parents=True)
        result = self.run_install()
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"另一個安裝正在進行（{lock}）", result.stderr)
        self.assertTrue(lock.is_dir())
        self.assertFalse((self.apps / "AIUsageMenuBar.app").exists())

    def test_unknown_argument(self):
        result = self.run_install("--bogus")
        self.assertEqual(result.returncode, 2)
        self.assertIn("不認得的參數：--bogus（只支援 --no-open）", result.stderr)


class ReinstallLockTests(unittest.TestCase):
    """reinstall-ios.sh 的鎖（整合審查 D-h 3-2）：只取出鎖的函式來跑，不執行真的重新安裝。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        script = (ROOT / "scripts" / "reinstall-ios.sh").read_text()
        start = script.index('LOCK="$CONFIG_DIR/.reinstall.lock"')
        end = script.index("if ! acquire_lock; then")
        self.functions = script[start:end]

    def tearDown(self):
        self.tmp.cleanup()

    def run_acquire(self, prelude: str) -> subprocess.CompletedProcess:
        body = f"""
            set -u
            CONFIG_DIR={self.dir}
            LOG={self.dir}/reinstall.log
            log() {{ echo "$*" >>"$LOG"; }}
            {self.functions}
            {prelude}
            acquire_lock; echo "result=$?"
        """
        return subprocess.run(["bash", "-c", textwrap.dedent(body)], capture_output=True, text=True, env={**os.environ, **UTF8_ENV})

    def test_stale_lock_is_taken_over(self):
        lock = self.dir / ".reinstall.lock"
        lock.mkdir()
        (lock / "pid").write_text("999999\n")  # 不存在的程序
        result = self.run_acquire("")
        self.assertIn("result=0", result.stdout)
        self.assertTrue((lock / "pid").read_text().strip().isdigit())
        self.assertEqual(list(self.dir.glob(".reinstall.lock.stale.*")), [])

    def take_over_prelude(self, third_pid: int | None) -> str:
        """第一次 mv（把殘留的鎖改名）之後，模擬改到的其實是別人剛建立的新鎖（PID 424242）；
        third_pid 不是 None 時，這段時間又有第三個程序建立了鎖。之後的 mv 都是真的 mv。"""
        lock = self.dir / ".reinstall.lock"
        third = f'mkdir "{lock}"; echo {third_pid} >"{lock}/pid"' if third_pid else ":"
        return f"""
            MV_CALLS=0
            mv() {{
                MV_CALLS=$((MV_CALLS + 1))
                command mv "$@" || return
                if [ "$MV_CALLS" = 1 ]; then echo 424242 >"$2/pid"; {third}; fi
            }}
        """

    def test_someone_elses_lock_is_put_back(self):
        lock = self.dir / ".reinstall.lock"
        lock.mkdir()
        (lock / "pid").write_text("999999\n")
        result = self.run_acquire(self.take_over_prelude(None))
        self.assertIn("result=1", result.stdout)
        self.assertEqual((lock / "pid").read_text().strip(), "424242")
        self.assertEqual(list(self.dir.glob(".reinstall.lock.stale.*")), [])

    def test_lock_that_cannot_be_put_back_is_kept_outside_the_new_lock(self):
        # 放回時第三個程序已建立新鎖：不能刪掉改名後的資料夾，也不能把它搬進新鎖裡
        #（新鎖的持有者結束時 rm -rf 會連它一起刪掉）
        lock = self.dir / ".reinstall.lock"
        lock.mkdir()
        (lock / "pid").write_text("999999\n")
        result = self.run_acquire(self.take_over_prelude(555))
        self.assertIn("result=1", result.stdout)
        self.assertEqual(sorted(p.name for p in lock.iterdir()), ["pid"])
        self.assertEqual((lock / "pid").read_text().strip(), "555")
        kept = list(self.dir.glob(".reinstall.lock.stale.*"))
        self.assertEqual(len(kept), 1)
        self.assertEqual((kept[0] / "pid").read_text().strip(), "424242")
        log = (self.dir / "reinstall.log").read_text()
        self.assertIn("無法放回鎖", log)
        self.assertNotIn(str(self.dir), log + result.stdout)  # 只記檔名，不記完整路徑


class CodexReviewTests(unittest.TestCase):
    """scripts/codex-review.sh：參數、報告位置、固定的模型參數、失敗時非 0 且不覆蓋舊報告。"""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        git = lambda *a, cwd: subprocess.run(["git", *a], cwd=cwd, check=True, capture_output=True)
        remote = self.tmp / "remote.git"
        git("init", "-q", "--bare", "-b", "main", str(remote), cwd=self.tmp)
        repo = self.tmp / "repo"
        git("init", "-q", "-b", "main", str(repo), cwd=self.tmp)
        for k, v in (("user.name", "t"), ("user.email", "t@example.invalid"), ("commit.gpgsign", "false")):
            git("config", k, v, cwd=repo)
        (repo / "scripts").mkdir()
        shutil.copy(ROOT / "scripts" / "codex-review.sh", repo / "scripts")
        (repo / "a.txt").write_text("1\n")
        git("add", ".", cwd=repo)
        git("commit", "-qm", "init", cwd=repo)
        git("remote", "add", "origin", str(remote), cwd=repo)
        git("push", "-q", "origin", "main", cwd=repo)
        git("fetch", "-q", "origin", cwd=repo)
        git("checkout", "-qb", "feat/some-change", cwd=repo)
        self.repo, self.git = repo, git
        self.reviews = self.tmp / "reviews"
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.args_file = self.tmp / "codex-args"
        self.env = {**os.environ, **UTF8_ENV, "AUM_REVIEW_DIR": str(self.reviews), "HOME": str(self.tmp),
                    "PATH": f"{self.bin}:/usr/bin:/bin", "FAKE_ARGS": str(self.args_file)}

    def fake_codex(self, body: str):
        write_exec(self.bin / "codex", "#!/bin/bash\nprintf '%s\\n' \"$@\" > \"$FAKE_ARGS\"\n"
                   'while [ $# -gt 0 ]; do [ "$1" = -o ] && OUT=$2; shift; done\n' + textwrap.dedent(body))

    def commit_change(self):
        (self.repo / "a.txt").write_text("2\n")
        self.git("commit", "-qam", "change", cwd=self.repo)

    def review(self, *args):
        return subprocess.run(["/bin/bash", "scripts/codex-review.sh", *args], cwd=self.repo, env=self.env,
                              capture_output=True, text=True, errors="replace", timeout=60)

    def test_diff_review_writes_report_with_fixed_model(self):
        self.commit_change()
        self.fake_codex("""
            echo '模型：fake' > "$OUT"; echo '### C-01｜[嚴重度：低]｜x' >> "$OUT"
        """)
        result = self.review()
        self.assertEqual(result.returncode, 0, result.stderr)
        report = self.reviews / "feat-some-change-codex.md"
        text = report.read_text()
        self.assertIn("gpt-6.1-sol，reasoning effort medium，sandbox read-only", text.splitlines()[0])
        self.assertIn("C-01｜[嚴重度：低]｜x", text)
        args = self.args_file.read_text().splitlines()
        self.assertEqual(args[:7], ["exec", "-m", "gpt-6.1-sol", "-c", 'model_reasoning_effort="medium"', "--sandbox", "read-only"])
        self.assertIn("git diff origin/main...HEAD", "\n".join(args))
        self.assertIn("C-01｜[嚴重度：高/中/低]｜標題", "\n".join(args))
        self.assertIn("只能閱讀", "\n".join(args))
        self.assertTrue((self.reviews / "feat-some-change-codex.log").exists())
        self.assertEqual([p.name for p in self.reviews.iterdir() if p.name.startswith(".")], [])

    def test_full_review_without_changes(self):
        self.fake_codex("""
            echo '模型：fake' > "$OUT"; echo '沒有發現問題' >> "$OUT"
        """)
        result = self.review("--full")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("整個 repo", "\n".join(self.args_file.read_text().splitlines()))
        self.assertIn("沒有發現問題", (self.reviews / "feat-some-change-codex.md").read_text())

    def test_no_changes_in_diff_mode(self):
        self.fake_codex("echo should-not-run > \"$OUT\"\n")
        result = self.review()
        self.assertEqual(result.returncode, 2)
        self.assertIn("沒有變更", result.stderr)
        self.assertFalse(self.args_file.exists())

    def test_quota_error_fails_and_keeps_previous_report(self):
        self.commit_change()
        self.reviews.mkdir()
        old = self.reviews / "feat-some-change-codex.md"
        old.write_text("舊報告\n")
        self.fake_codex("""
            echo "ERROR: You've hit your usage limit. Try again later." >&2
            exit 1
        """)
        result = self.review()
        self.assertEqual(result.returncode, 4)
        self.assertIn("usage limit", result.stderr)
        self.assertIn("沒有改用其他模型", result.stderr)
        self.assertEqual(old.read_text(), "舊報告\n")
        # 只呼叫一次，沒有換模型重試
        self.assertEqual(self.args_file.read_text().splitlines()[2], "gpt-6.1-sol")

    def test_exit_zero_without_review_counts_as_failure(self):
        self.commit_change()
        self.fake_codex("""
            echo "stream error: model gpt-6.1-sol is not supported" >&2
            : > "$OUT"
        """)
        result = self.review()
        self.assertEqual(result.returncode, 4)
        self.assertIn("not supported", result.stderr)
        self.assertFalse((self.reviews / "feat-some-change-codex.md").exists())

    def test_missing_base_does_not_call_codex(self):
        self.commit_change()
        self.git("remote", "remove", "origin", cwd=self.repo)  # 連同 origin/main 一起移除，fetch 也會失敗
        self.fake_codex("echo should-not-run > \"$OUT\"\n")
        result = self.review()
        self.assertEqual(result.returncode, 2)
        self.assertIn("找不到 origin/main", result.stderr)
        self.assertFalse(self.args_file.exists())

    def test_no_common_ancestor_does_not_call_codex(self):
        self.git("checkout", "-q", "--orphan", "unrelated", cwd=self.repo)
        (self.repo / "b.txt").write_text("x\n")
        self.git("add", "b.txt", cwd=self.repo)
        self.git("commit", "-qm", "orphan", cwd=self.repo)
        self.fake_codex("echo should-not-run > \"$OUT\"\n")
        result = self.review()
        self.assertEqual(result.returncode, 2)
        self.assertIn("沒有共同祖先", result.stderr)
        self.assertFalse(self.args_file.exists())

    def test_publish_failure_keeps_previous_report(self):
        self.commit_change()
        self.reviews.mkdir()
        old = self.reviews / "feat-some-change-codex.md"
        old.write_text("舊報告\n")
        # Codex 成功，但之後報告資料夾變成唯讀：組報告的暫存檔建不出來
        self.fake_codex("""
            echo '模型：fake' > "$OUT"; echo '沒有發現問題' >> "$OUT"
            chmod 555 "$AUM_REVIEW_DIR"
        """)
        self.addCleanup(os.chmod, self.reviews, 0o755)
        result = self.review()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(old.read_bytes(), "舊報告\n".encode())

    def test_unknown_argument(self):
        result = self.review("--fast")
        self.assertEqual(result.returncode, 2)
        self.assertIn("不認得的參數：--fast", result.stderr)




class LintCollectorTests(unittest.TestCase):
    """lint-collector.sh：已有對應版本的 venv 時不安裝、直接在 collector/ 執行 ruff 與 mypy（假工具，不連網）。"""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="lint test "))  # 含空白的路徑
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.repo = self.tmp / "repo"
        (self.repo / "scripts").mkdir(parents=True)
        (self.repo / "collector").mkdir()
        shutil.copy(ROOT / "scripts" / "lint-collector.sh", self.repo / "scripts")
        shutil.copy(ROOT / "collector" / "requirements-lint.txt", self.repo / "collector")
        self.log = self.tmp / "calls.log"

    def fake_venv(self, venv: Path) -> None:
        (venv / "bin").mkdir(parents=True)
        shutil.copy(self.repo / "collector" / "requirements-lint.txt", venv / "requirements-lint.txt")
        for tool in ("ruff", "mypy"):
            write_exec(venv / "bin" / tool, f"""
                #!/bin/bash
                echo "{tool} $PWD $*" >> "{self.log}"
            """)

    def run_lint(self, venv_arg: str | None, cwd: Path) -> subprocess.CompletedProcess:
        env = {**os.environ}
        env.pop("LINT_VENV", None)
        if venv_arg is not None:
            env["LINT_VENV"] = venv_arg
        return subprocess.run(["/bin/bash", str(self.repo / "scripts" / "lint-collector.sh")], cwd=cwd, env=env,
                              capture_output=True, text=True)

    def test_default_venv_under_build(self):
        self.fake_venv(self.repo / "build" / "lint-venv")
        result = self.run_lint(None, self.tmp)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.log.read_text().splitlines()
        self.assertEqual(calls, [f"ruff {self.repo / 'collector'} check .", f"mypy {self.repo / 'collector'} "])
        self.assertTrue((self.repo / "build" / ".metadata_never_index").exists())

    def test_relative_venv_is_relative_to_caller(self):
        self.fake_venv(self.repo / "tools" / "venv")
        result = self.run_lint("tools/venv", self.repo)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.log.read_text().splitlines()), 2)

    def test_absolute_venv(self):
        self.fake_venv(self.tmp / "abs venv")
        result = self.run_lint(str(self.tmp / "abs venv"), self.repo / "collector")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.log.read_text().splitlines()), 2)


class RelayDeviceTests(unittest.TestCase):
    """relay-device.sh：以假的 curl 檢查送出的請求；管理密鑰只經過標準輸入，不出現在參數裡。"""

    DEVICE = "0f8e2a3c-1b2d-4e5f-8a9b-0c1d2e3f4a5b"

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="relay device "))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.log = self.tmp / "curl.log"
        write_exec(self.bin / "curl", f"""
            #!{sys.executable}
            import json, os, sys
            args = sys.argv[1:]
            with open({str(self.log)!r}, "a") as f:
                f.write(json.dumps({{"args": args, "stdin": sys.stdin.read()}}) + "\\n")
            open(args[args.index("-o") + 1], "w").write(os.environ["FAKE_BODY"])
            print(os.environ.get("FAKE_STATUS", "200"), end="")
        """)
        self.home = self.tmp / "home"
        self.home.mkdir()

    def run_script(self, *args, body="{}", status="200", token="admin-secret", url="https://relay.example.dev"):
        env = {**os.environ, **UTF8_ENV, "PATH": f"{self.bin}:{os.environ['PATH']}", "FAKE_BODY": body,
               "FAKE_STATUS": status, "AI_USAGE_MONITOR_HOME": str(self.home), "AUM_ADMIN_TOKEN": token}
        env.pop("AUM_RELAY_URL", None)
        if url:
            env["AUM_RELAY_URL"] = url
        return subprocess.run(["/bin/bash", str(ROOT / "scripts" / "relay-device.sh"), *args], env=env,
                              capture_output=True, text=True, stdin=subprocess.DEVNULL)

    def calls(self):
        if not self.log.exists():
            return []
        import json
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_add_sends_the_name_and_keeps_the_admin_key_off_the_command_line(self):
        body = '{"device_id": "%s", "name": "工作 PC", "key": "aumd_example"}' % self.DEVICE
        result = self.run_script("add", "工作 PC", body=body, status="201")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("aumd_example", result.stdout)
        (call,) = self.calls()
        self.assertIn("https://relay.example.dev/devices", call["args"])
        self.assertIn('{"name": "工作 PC"}', call["args"])
        self.assertNotIn("admin-secret", " ".join(call["args"]))
        self.assertEqual(call["stdin"], "Authorization: Bearer admin-secret\n")

    def test_list_and_revoke_with_data(self):
        body = '{"devices": [{"device_id": "%s", "name": "Mac", "revoked": false, "last_upload_at": null}]}' % self.DEVICE
        result = self.run_script("list", body=body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Mac  使用中  最後上傳：尚未上傳", result.stdout)
        result = self.run_script("revoke", self.DEVICE, "--delete-data",
                                 body='{"device_id": "%s", "revoked": true, "deleted_data": true}' % self.DEVICE)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("資料已刪除", result.stdout)
        call = self.calls()[-1]
        self.assertIn(f"https://relay.example.dev/devices/{self.DEVICE}/revoke", call["args"])
        self.assertIn('{"delete_data": true}', call["args"])

    def test_rejected_input_does_not_call_the_relay(self):
        for args, kwargs in ((("revoke", "not-a-device"), {}), (("rotate", self.DEVICE, "extra"), {}),
                             (("list",), {"url": "http://relay.example.dev"}), (("list",), {"url": ""}),
                             (("delete", self.DEVICE), {})):
            result = self.run_script(*args, **kwargs)
            self.assertEqual(result.returncode, 2, (args, result.stderr))
        self.assertEqual(self.calls(), [])

    def test_only_exact_local_hosts_may_use_http(self):
        """C-02：http://localhost@… 的主機其實是 @ 後面那個，不能把管理密鑰以明文送出"""
        for url in ("http://localhost@relay.example.test", "http://127.0.0.1.example.test", "http://localhost.example.test",
                    "https://user@relay.example.dev", "http://[::1]@relay.example.test"):
            result = self.run_script("list", url=url)
            self.assertEqual(result.returncode, 2, (url, result.stderr))
        self.assertEqual(self.calls(), [])
        for url in ("http://localhost:8787", "http://127.0.0.1:8787/", "http://[::1]:8787", "https://relay.example.dev/"):
            result = self.run_script("list", body='{"devices": []}', url=url)
            self.assertEqual(result.returncode, 0, (url, result.stderr))
        self.assertEqual(len(self.calls()), 4)

    def test_url_from_config_json(self):
        (self.home / "config.json").write_text('{"relay_url": "https://from-config.example.dev/"}')
        result = self.run_script("list", body='{"devices": []}', url="")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("https://from-config.example.dev/devices", self.calls()[0]["args"])

    def test_http_error_fails_without_printing_a_key(self):
        result = self.run_script("rotate", self.DEVICE, body='{"error": "unauthorized"}', status="401")
        self.assertEqual(result.returncode, 1)
        self.assertIn("HTTP 401", result.stderr)
        self.assertNotIn("寫入密鑰", result.stdout)


class SetTier2Tests(unittest.TestCase):
    """collector/scripts/set-tier2.sh：密鑰只經過假的 security 的提示（不在參數裡），config 與上傳狀態在暫存資料夾。"""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="set tier2 "))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.log = self.tmp / "security.log"
        self.argv_log = self.tmp / "security-argv.log"
        self.store = self.tmp / "keychain"
        self.store.mkdir()
        # 假的 security：記錄參數（-i 時另記標準輸入的指令），密鑰存在 keychain/<service>；
        # FAKE_SECURITY_FAIL_ADD=1 時 add 不生效（security -i 仍回傳 0，同真的 security）
        write_exec(self.bin / "security", f"""
            #!/bin/bash
            echo "$*" >> "{self.argv_log}"
            if [ "$1" = -i ]; then
                while read -r cmd _u _s service _a _acct _w value; do
                    echo "$cmd $_u $_s $service $_a $_acct $_w $value" >> "{self.log}"
                    [ "$cmd" = add-generic-password ] && [ "${{FAKE_SECURITY_FAIL_ADD:-0}}" != 1 ] && printf '%s' "$value" > "{self.store}/$service"
                done
                exit 0
            fi
            echo "$*" >> "{self.log}"
            case "$1" in
                find-generic-password) [ -f "{self.store}/$3" ] || exit 44; [ "${{@: -1}}" = -w ] && cat "{self.store}/$3" && echo ;;
                delete-generic-password) rm -f "{self.store}/$3" ;;
            esac
            exit 0
        """)
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.config = self.home / "config.json"

    DEVICE_KEY = "aumd_" + "A1b2-C3d4_" * 4 + "xyz"
    READ_KEY = "RL4aesydLJXpCzwcEsNc7WDCww9cZEf6RVTmmGY5G2I="

    def run_script(self, *args, keys: str | None = None, env_extra: dict | None = None):
        env = {**os.environ, **UTF8_ENV, "PATH": f"{self.bin}:{os.environ['PATH']}", "AI_USAGE_MONITOR_HOME": str(self.home),
               **(env_extra or {})}
        if keys is None:
            keys = f"{self.DEVICE_KEY}\n{self.READ_KEY}\n"
        return subprocess.run(["/bin/bash", str(ROOT / "collector" / "scripts" / "set-tier2.sh"), *args], env=env,
                              capture_output=True, text=True, input=keys)

    def test_stores_both_keys_and_enables_upload(self):
        import json
        self.config.write_text('{"relay_url": "https://relay.example.dev", "claude_path": "/bin/claude"}')
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.log.read_text().splitlines()
        self.assertEqual(calls, [f"add-generic-password -U -s AIUsageMonitor-device-key -a default -w {self.DEVICE_KEY}",
                                 "find-generic-password -s AIUsageMonitor-device-key -a default -w",
                                 f"add-generic-password -U -s AIUsageMonitor-relay-read -a default -w {self.READ_KEY}",
                                 "find-generic-password -s AIUsageMonitor-relay-read -a default -w"])
        # 密鑰只經過 security -i 的標準輸入，不在任何參數裡
        argv = self.argv_log.read_text()
        self.assertNotIn(self.DEVICE_KEY, argv)
        self.assertNotIn(self.READ_KEY, argv)
        self.assertNotIn(self.DEVICE_KEY, result.stdout + result.stderr)
        config = json.loads(self.config.read_text())
        self.assertIs(config["token_sync"], True)
        self.assertEqual(config["claude_path"], "/bin/claude")
        self.assertTrue((self.home / "history.sqlite3").exists())  # reset 在暫存資料夾

    def test_no_read_key_and_disable(self):
        import json
        self.config.write_text('{"relay_url": "https://relay.example.dev"}')
        self.assertEqual(self.run_script().returncode, 0)
        self.log.unlink()
        # C-05：從完整同步切換成只上傳時，移除之前存的讀取密鑰（收集器才不會繼續下載）
        self.assertEqual(self.run_script("--no-read-key").returncode, 0)
        self.assertEqual(self.log.read_text().splitlines(),
                         [f"add-generic-password -U -s AIUsageMonitor-device-key -a default -w {self.DEVICE_KEY}",
                          "find-generic-password -s AIUsageMonitor-device-key -a default -w",
                          "delete-generic-password -s AIUsageMonitor-relay-read -a default"])
        self.assertEqual(self.run_script("--disable").returncode, 0)
        self.assertIs(json.loads(self.config.read_text())["token_sync"], False)

    def test_failed_update_with_an_old_key_present_stops(self):
        # C-01：security -i 回傳 0 但沒有更新、舊密鑰還在時，不能當成成功
        self.config.write_text('{"relay_url": "https://relay.example.dev"}')
        (self.store / "AIUsageMonitor-device-key").write_text("aumd_" + "O" * 43)
        result = self.run_script("--no-read-key", env_extra={"FAKE_SECURITY_FAIL_ADD": "1"})
        self.assertEqual(result.returncode, 1)
        self.assertIn("無法存入 Keychain", result.stderr)
        self.assertNotIn(self.DEVICE_KEY, result.stdout + result.stderr)
        self.assertNotIn("aumd_OOO", result.stdout + result.stderr)
        self.assertNotIn("token_sync", self.config.read_text())  # 沒有開啟上傳

    def test_trims_whitespace_and_crlf(self):
        self.config.write_text('{"relay_url": "https://relay.example.dev"}')
        result = self.run_script(keys=f"  {self.DEVICE_KEY} \r\n\t{self.READ_KEY}\r\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"-w {self.DEVICE_KEY}\n", self.log.read_text())
        self.assertIn(f"-w {self.READ_KEY}\n", self.log.read_text())

    def test_wrong_format_prompts_again(self):
        # BACKLOG 第 10 節：少複製一個字、把讀取密鑰貼到寫入密鑰的位置，都當場提示並重新詢問
        self.config.write_text('{"relay_url": "https://relay.example.dev"}')
        result = self.run_script(keys=f"{self.DEVICE_KEY[:-1]}\n{self.READ_KEY}\n{self.DEVICE_KEY}\n{self.DEVICE_KEY}\n"
                                      f"{self.READ_KEY}\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("應為 48 個字元，貼上的是 47 個", result.stderr)
        self.assertIn("應以 aumd_ 開頭", result.stderr)
        self.assertIn("這是裝置的寫入密鑰", result.stderr)  # 第三次的 aumd_ 貼在讀取密鑰的位置
        self.assertEqual(result.stderr.count("請重新貼上"), 3)
        self.assertNotIn(self.READ_KEY, result.stderr)
        calls = self.log.read_text().splitlines()
        self.assertEqual(calls[0], f"add-generic-password -U -s AIUsageMonitor-device-key -a default -w {self.DEVICE_KEY}")
        self.assertEqual(calls[2], f"add-generic-password -U -s AIUsageMonitor-relay-read -a default -w {self.READ_KEY}")

    def test_gives_up_after_three_wrong_keys(self):
        self.config.write_text('{"relay_url": "https://relay.example.dev"}')
        result = self.run_script(keys="abc\n\naumd_short\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("沒有存入密鑰", result.stderr)
        self.assertFalse(self.log.exists())
        self.assertNotIn("token_sync", self.config.read_text())  # 沒有開啟上傳

    def test_requires_an_https_relay_url(self):
        self.config.write_text('{"relay_url": "http://relay.example.dev"}')
        result = self.run_script()
        self.assertEqual(result.returncode, 1)
        self.assertFalse(self.log.exists())


def write_png(path: Path, width: int, height: int, changed: int = 0, block: tuple[int, int, int] | None = None) -> None:
    """純色 RGBA PNG；`changed` 個像素（從左上角起）改成紅色；`block`＝(x, y, 邊長) 的正方形改成紅色。"""
    import struct
    import zlib
    rows = []
    for y in range(height):
        row = bytearray([0])
        for x in range(width):
            red = y * width + x < changed or (block is not None and block[0] <= x < block[0] + block[2]
                                                 and block[1] <= y < block[1] + block[2])
            row += bytes([255, 0, 0, 255]) if red else bytes([40, 120, 200, 255])
        rows.append(bytes(row))

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(b"".join(rows)))
                     + chunk(b"IEND", b""))


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc"), "compare-snapshots.swift 用 CoreGraphics（macOS）")
class CompareSnapshotsTests(unittest.TestCase):
    """compare-snapshots.swift：容許少量像素不同；尺寸不同、沒有產生、不同的像素太多時失敗並輸出差異圖。"""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="snapshots test "))
        cls.tool = cls.tmp / "compare"
        subprocess.run(["swiftc", "-O", str(ROOT / "scripts" / "compare-snapshots.swift"), "-o", str(cls.tool)],
                       check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def setUp(self):
        self.case = Path(tempfile.mkdtemp(dir=self.tmp))
        self.base, self.new, self.diff = self.case / "base", self.case / "new", self.case / "diff"
        self.base.mkdir()
        self.new.mkdir()
        write_png(self.base / "a.png", 100, 100)

    def compare(self) -> subprocess.CompletedProcess:
        return subprocess.run([str(self.tool), str(self.base), str(self.new), str(self.diff)], capture_output=True, text=True)

    def test_small_difference_is_tolerated(self):
        write_png(self.new / "a.png", 100, 100, changed=10)  # 0.1%
        result = self.compare()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertFalse((self.diff / "a-diff.png").exists())

    def test_large_difference_fails_with_diff_image(self):
        write_png(self.new / "a.png", 100, 100, changed=500)  # 5%
        result = self.compare()
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL a.png", result.stdout)
        self.assertTrue((self.diff / "a-diff.png").exists())

    def test_small_local_change_in_a_large_image_fails(self):
        # 面板大小的圖上一個數字大小的改變（遠低於整張的 0.2%）也要抓到
        write_png(self.base / "a.png", 720, 1200)
        write_png(self.new / "a.png", 720, 1200, block=(200, 600, 40))  # 0.19%
        result = self.compare()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("區域", result.stdout)
        self.assertTrue((self.diff / "a-diff.png").exists())

    def test_size_change_and_missing_image_fail(self):
        write_png(self.base / "b.png", 10, 10)
        write_png(self.new / "a.png", 100, 101)
        result = self.compare()
        self.assertEqual(result.returncode, 3)  # 缺圖：和畫面不符（1）分開
        self.assertIn("尺寸", result.stdout)
        self.assertIn("沒有產生", result.stdout)


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc") and shutil.which("xcodebuild"),
                     "snapshots.sh 用到 sw_vers、xcodebuild 與 CoreGraphics（macOS）")
class SnapshotsScriptTests(unittest.TestCase):
    """snapshots.sh（SNAPSHOT_FROM 以現成的圖代替產生）：環境不同只放寬畫面差異；缺圖、壞圖一律失敗；
    各平台各自判斷環境；更新時少一張圖就失敗且不動原本的基準。"""
    MAC = ["panel-light", "panel-dark", "stats-window-light", "stats-window-dark",
           "stats-window-cache-read-light", "stats-window-cache-read-dark", "settings-light", "settings-dark",
           "menubar-icons-light", "menubar-icons-dark", "wizard-light", "wizard-dark",
           "tier2-card-revoked-device-light", "tier2-card-revoked-device-dark",
           "tier2-card-deleted-device-light", "tier2-card-deleted-device-dark",
           "tier2-card-all-cache-read-light", "tier2-card-all-cache-read-dark",
           "notch-collapsed", "notch-intro", "notch-expressions", "notch-menubar-light", "notch-menubar-dark",
           "notch-menu-light", "notch-menu-dark"]
    IOS = ["widget-small-light", "widget-small-dark", "widget-medium-light", "widget-medium-dark", "widget-large-light",
           "widget-large-dark", "live-activity-light", "live-activity-dark", "island-normal"]

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="snapshots script "))
        cls.tool = cls.tmp / "compare"
        subprocess.run(["swiftc", "-O", str(ROOT / "scripts" / "compare-snapshots.swift"), "-o", str(cls.tool)],
                       check=True, capture_output=True)
        macos = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()
        xcode = subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True).stdout.split()[1]
        cls.mac_env = f"macos={'.'.join(macos.split('.')[:2])}\nxcode={xcode}\n"
        cls.ios_env = f"xcode={xcode}\nsimulator=test\n"

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def setUp(self):
        self.repo = Path(tempfile.mkdtemp(dir=self.tmp))
        (self.repo / "scripts").mkdir()
        shutil.copy(ROOT / "scripts" / "snapshots.sh", self.repo / "scripts")
        shutil.copy(ROOT / "scripts" / "ios-render-launch.sh", self.repo / "scripts")  # snapshots.sh 以 source 載入
        shutil.copy(ROOT / "scripts" / "compare-snapshots.swift", self.repo / "scripts")
        (self.repo / "build" / "snapshots").mkdir(parents=True)
        shutil.copy(self.tool, self.repo / "build" / "snapshots" / "compare-snapshots")  # 比原始碼新：不重新編譯
        self.base = self.repo / "apple" / "Snapshots"
        self.new = self.repo / "rendered"
        for platform, names, env in (("mac", self.MAC, self.mac_env), ("ios", self.IOS, self.ios_env)):
            for folder in (self.base / platform, self.new / platform):
                folder.mkdir(parents=True)
                for name in names:
                    write_png(folder / f"{name}.png", 20, 20)
            (self.base / platform / "ENVIRONMENT").write_text(env)

    def run_snapshots(self, *args) -> subprocess.CompletedProcess:
        env = {**os.environ, **UTF8_ENV, "SNAPSHOT_FROM": str(self.new), "SNAPSHOT_SIM_DESC": "test"}
        env.pop("GITHUB_ACTIONS", None)
        return subprocess.run(["/bin/bash", str(self.repo / "scripts" / "snapshots.sh"), *args], cwd=self.repo,
                              env=env, capture_output=True, text=True)

    def test_identical_images_pass(self):
        result = self.run_snapshots()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_visual_difference_fails_in_the_same_environment(self):
        write_png(self.new / "mac" / "panel-light.png", 20, 20, changed=40)
        self.assertEqual(self.run_snapshots().returncode, 1)

    def test_visual_difference_only_warns_when_environment_differs(self):
        write_png(self.new / "mac" / "panel-light.png", 20, 20, changed=40)
        (self.base / "mac" / "ENVIRONMENT").write_text("macos=1.0\nxcode=1.0\n")
        result = self.run_snapshots()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("環境和基準不同", result.stdout)

    def test_missing_or_broken_images_fail_even_when_environment_differs(self):
        for platform in ("mac", "ios"):
            (self.base / platform / "ENVIRONMENT").write_text("macos=1.0\nxcode=1.0\nsimulator=old\n")
        (self.new / "mac" / "panel-light.png").unlink()
        self.assertNotEqual(self.run_snapshots().returncode, 0)
        write_png(self.new / "mac" / "panel-light.png", 20, 20)
        (self.new / "ios" / "widget-small-light.png").write_bytes(b"not a png")
        self.assertNotEqual(self.run_snapshots().returncode, 0)

    def test_environment_is_judged_per_platform(self):
        # 只有 iPhone 的模擬器不同：Mac 的畫面差異仍算失敗
        (self.base / "ios" / "ENVIRONMENT").write_text(self.ios_env.replace("simulator=test", "simulator=old"))
        write_png(self.new / "mac" / "panel-light.png", 20, 20, changed=40)
        self.assertEqual(self.run_snapshots().returncode, 1)

    def test_update_with_a_missing_image_keeps_the_old_baseline(self):
        (self.base / "mac" / "ENVIRONMENT").write_text("macos=1.0\nxcode=1.0\n")
        write_png(self.new / "mac" / "panel-dark.png", 20, 20, changed=40)
        (self.new / "mac" / "panel-light.png").unlink()
        before = (self.base / "mac" / "panel-dark.png").read_bytes()
        self.assertNotEqual(self.run_snapshots("--update").returncode, 0)
        self.assertEqual((self.base / "mac" / "panel-dark.png").read_bytes(), before)
        self.assertEqual((self.base / "mac" / "ENVIRONMENT").read_text(), "macos=1.0\nxcode=1.0\n")

    def test_update_replaces_only_the_rendered_platform(self):
        (self.base / "ios" / "ENVIRONMENT").write_text("xcode=1.0\nsimulator=old\n")
        write_png(self.new / "mac" / "panel-dark.png", 20, 20, changed=40)
        env = {**os.environ, **UTF8_ENV, "SNAPSHOT_FROM": str(self.new), "SNAPSHOT_PLATFORMS": "mac"}
        result = subprocess.run(["/bin/bash", str(self.repo / "scripts" / "snapshots.sh"), "--update"], cwd=self.repo,
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.base / "mac" / "panel-dark.png").read_bytes(), (self.new / "mac" / "panel-dark.png").read_bytes())
        self.assertEqual((self.base / "mac" / "ENVIRONMENT").read_text(), self.mac_env)
        self.assertEqual((self.base / "ios" / "ENVIRONMENT").read_text(), "xcode=1.0\nsimulator=old\n")


if __name__ == "__main__":
    unittest.main()


class NotchPerfSummaryTests(unittest.TestCase):
    """notch-perf-summary.py：門檻與缺少取樣都要讓報表失敗（ADR-0016 第 6 節、Codex C-07）。"""
    SCRIPT = ROOT / "scripts" / "notch-perf-summary.py"
    MARKS = {"notch-open": 10, "notch-sleep": 22, "notch-wave": 32, "notch-nod": 35, "notch-tilt": 38, "notch-giggle": 41,
             "notch-look": 44, "notch-pinch": 47, "notch-face": 50, "notch-close": 55, "gaze-move-asleep": 60,
             "gaze-move": 73, "gaze-still": 88, "notch-close-2": 155, "agent-cheer": 158, "waiting-pulse": 161}

    def run_summary(self, samples, marks=None, ticks=()):
        with tempfile.TemporaryDirectory() as tmp:
            s = Path(tmp) / "samples.tsv"
            log = Path(tmp) / "app.log"
            s.write_text("".join(f"{t} {cpu} {rss}\n" for t, cpu, rss in samples))
            log.write_text("".join(f"perf-mark {v} {k}\n" for k, v in (marks or self.MARKS).items())
                           + "".join(f"perf-mark {t} minute-tick\n" for t in ticks))
            return subprocess.run([sys.executable, str(self.SCRIPT), str(s), str(log)], capture_output=True, text=True)

    @staticmethod
    def full(skip=()):
        return [(t, 1.0 if 15 <= t < 30 else 0.0, 100_000) for t in range(0, 187) if not any(a <= t < b for a, b in skip)]

    def test_complete_samples_pass(self):
        result = self.run_summary(self.full())
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_missing_intro_or_wave_samples_fail(self):
        for gap in [(10, 15), (32, 34), (15, 20), (24, 32), (35, 37), (44, 46), (50, 52), (62, 70), (75, 88)]:
            result = self.run_summary(self.full(skip=[gap]))
            self.assertEqual(result.returncode, 1, (gap, result.stdout))
            self.assertIn("缺", result.stdout)

    def test_missing_mark_fails(self):
        marks = dict(self.MARKS)
        del marks["notch-wave"]
        self.assertEqual(self.run_summary(self.full(), marks).returncode, 1)

    def test_busy_idle_fails(self):
        samples = [(t, 6.0 if 24 <= t < 32 else 0.0, 100_000) for t in range(0, 185)]
        self.assertEqual(self.run_summary(samples).returncode, 1)

    def test_redraw_while_collapsed_asleep_fails(self):
        # 收合、睡著時游標移動不能重畫（第二輪：睡著時降到每秒讀 1 次游標）
        samples = [(t, 1.0 if 62 <= t < 70 else 0.0, 100_000) for t in range(0, 185)]
        self.assertEqual(self.run_summary(samples).returncode, 1)

    def test_busy_waiting_pulse_fails(self):
        # 等你下指令的脈動和收合靜止同一個門檻（每 7 秒亮 1.6 秒，平均不能超過 0.3%）
        samples = [(t, 1.0 if 163 <= t < 184 else 0.0, 100_000) for t in range(0, 187)]
        self.assertEqual(self.run_summary(samples).returncode, 1)

    def test_minute_tick_is_excluded_only_from_gaze_rows(self):
        # 每分鐘的時鐘更新落在「睡著、游標移動」裡：扣掉那一秒後照樣通過
        spike = [(t, 5.0 if t == 65 else 0.0, 100_000) for t in range(0, 185)]
        self.assertEqual(self.run_summary(spike).returncode, 1)
        self.assertEqual(self.run_summary(spike, ticks=[64.5]).returncode, 0)
        # 沒落在看滑鼠的階段時不扣：收合後 60～90 秒照樣算進去
        busy = [(t, 9.5 if t == 130 else 0.0, 100_000) for t in range(0, 185)]
        self.assertEqual(self.run_summary(busy, ticks=[129.5]).returncode, 1)
