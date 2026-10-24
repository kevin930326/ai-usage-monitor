"""scripts/check-debug-env.py：示範用環境變數只能出現在 #if DEBUG 裡（night4 需要我決定第 24 項）。"""
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "check-debug-env.py"


class CheckDebugEnvTests(unittest.TestCase):
    def run_on(self, files: dict[str, str]) -> subprocess.CompletedProcess:
        tmp = Path(tempfile.mkdtemp(prefix="aum-debug-env-"))
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", str(tmp)]))
        for rel, body in files.items():
            path = tmp / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(textwrap.dedent(body), encoding="utf-8")
        return subprocess.run([sys.executable, str(SCRIPT), str(tmp)], capture_output=True, text=True)

    def test_literal_outside_debug_fails(self):
        # #75 之前的 LoginItemSection：短字串（small string）讓 strings 檢查看不到
        r = self.run_on({"apple/Mac/A.swift": '''
            func status() -> Int {
                let env = ProcessInfo.processInfo.environment
                if env["AUM_DEMO_PANEL"] == "1" { return 0 }
                return 1
            }
            '''})
        self.assertEqual(r.returncode, 1)
        self.assertIn("apple/Mac/A.swift:4 AUM_DEMO_PANEL", r.stdout)

    def test_debug_branches_pass(self):
        r = self.run_on({"apple/Mac/A.swift": '''
            #if DEBUG
            let a = env["AUM_DEMO_PANEL"]
            #if os(macOS)
            let b = env["AUM_RENDER_DIR"]
            #endif
            #endif
            #if DEBUG && os(iOS)
            let c = env["AUM_DEMO"]
            #endif
            #if !DEBUG
            let d = 0
            #else
            let e = env["AUM_RENDER"]
            #endif
            let key = "AUM_TESTING"  // 例外：測試環境的防護旗標
            /// 說明裡的 "AUM_DEMO_PANEL" 不算
            '''})
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_else_of_debug_and_other_conditions_fail(self):
        r = self.run_on({"apple/Mac/A.swift": '''
            #if DEBUG
            let a = 1
            #else
            let b = env["AUM_DEMO"]
            #endif
            #if os(macOS) || DEBUG
            let c = env["AUM_RENDER"]
            #endif
            '''})
        self.assertEqual(r.returncode, 1)
        self.assertIn("A.swift:5 AUM_DEMO", r.stdout)
        self.assertIn("A.swift:8 AUM_RENDER", r.stdout)

    def test_mixed_conditions_that_release_can_satisfy_fail(self):
        # Codex C-01：&& 比 || 優先，`DEBUG && os(macOS) || os(iOS)` 在 iOS Release 也成立
        r = self.run_on({"apple/Mac/A.swift": '''
            #if DEBUG && os(macOS) || os(iOS)
            let a = env["AUM_DEMO"]
            #endif
            #if (DEBUG && os(macOS)) || os(iOS)
            let b = env["AUM_DEMO"]
            #endif
            #if DEBUG && (os(macOS) || os(iOS))
            let c = env["AUM_DEMO"]
            #endif
            #if (DEBUG && os(macOS)) || (DEBUG && os(iOS))
            let d = env["AUM_DEMO"]
            #endif
            '''})
        self.assertEqual(r.returncode, 1)
        self.assertIn("A.swift:3 AUM_DEMO", r.stdout)
        self.assertIn("A.swift:6 AUM_DEMO", r.stdout)
        self.assertNotIn("A.swift:9 ", r.stdout)
        self.assertNotIn("A.swift:12 ", r.stdout)

    def test_tests_folders_are_skipped(self):
        r = self.run_on({"apple/UsageKit/Tests/T/A.swift": 'let a = ["AUM_DEMO": "1"]\n'})
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_the_repository_passes(self):
        r = subprocess.run([sys.executable, str(SCRIPT)], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout)


if __name__ == "__main__":
    unittest.main()
