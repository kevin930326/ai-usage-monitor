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


if __name__ == "__main__":
    unittest.main()
