"""Windows：收集器以 pythonw（沒有主控台）執行，啟動 claude／codex 時不能跳出主控台視窗，連它們再啟動的孫程序也不行；
逾時時整棵程序樹都要結束。以一個會再啟動 python.exe 孫程序的假 CLI 實際啟動，用 EnumWindows 檢查。
只在 Windows 執行（CI 的 collector (Windows)）。"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from pathlib import Path

COLLECTOR = Path(__file__).resolve().parent.parent

# 假的 claude／codex：啟動一個 python.exe 孫程序（預設旗標，和 hook、MCP 伺服器一樣繼承主控台），
# 兩個程序都把自己的 PID 與主控台視窗（HWND）寫進 pids 資料夾，再等一段時間讓測試列舉視窗。
# role 為 orphan-child 時，孫程序繼承輸出管線，子程序隨即結束（父程序先走、孫程序握著管線）
FAKE_CLI = textwrap.dedent("""
    import ctypes, os, subprocess, sys, time
    out, role, hold = sys.argv[1], sys.argv[2], float(sys.argv[3])
    k32, u32 = ctypes.WinDLL("kernel32"), ctypes.WinDLL("user32")
    k32.GetConsoleWindow.restype = ctypes.c_void_p
    hwnd = k32.GetConsoleWindow()
    with open(os.path.join(out, f"{role}-{os.getpid()}"), "w") as f:
        f.write(str(hwnd or 0))
    if role == "child":
        subprocess.Popen([sys.executable, __file__, out, "grandchild", str(hold)])
    elif role == "orphan-child":
        subprocess.Popen([sys.executable, __file__, out, "grandchild", str(hold)], stdout=sys.stdout, stderr=sys.stderr)
        while len(os.listdir(out)) < 2:
            time.sleep(0.05)
        sys.exit(0)
    time.sleep(hold)
""")

# 以 pythonw 執行的驅動程式：模擬收集器，用指定的方式啟動假 CLI，程序樹還在時列舉看得到的頂層視窗
DRIVER = textwrap.dedent("""
    import ctypes, ctypes.wintypes as wt, json, os, subprocess, sys, threading, time
    sys.path.insert(0, sys.argv[1])
    from usage_collector import system
    fake, out, mode, result_path = sys.argv[2:6]
    role = "orphan-child" if mode == "orphan-timeout" else "child"
    argv = [sys.executable.replace("pythonw.exe", "python.exe"), fake, out, role]
    result = {"error": None, "timed_out": False, "elapsed": None}

    def launch():
        started = time.monotonic()
        try:
            if mode == "plain":  # 修正前的 run_claude：subprocess.run 不帶任何旗標
                subprocess.run(argv + ["4"], stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
            elif mode == "no-window":  # 修正前的 codex：CREATE_NO_WINDOW＋新 process group
                subprocess.run(argv + ["4"], stdin=subprocess.DEVNULL, capture_output=True, timeout=30,
                               creationflags=0x08000000 | 0x00000200)
            elif mode == "fixed":
                system.run_isolated(argv + ["4"], stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
            elif mode in ("timeout", "orphan-timeout"):
                system.run_isolated(argv + ["60"], stdin=subprocess.DEVNULL, capture_output=True, timeout=3)
        except subprocess.TimeoutExpired:
            result["timed_out"] = True
        except Exception as e:
            result["error"] = repr(e)
        result["elapsed"] = time.monotonic() - started

    worker = threading.Thread(target=launch)
    worker.start()
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline and len(os.listdir(out)) < 2:
        time.sleep(0.1)
    time.sleep(0.5)
    names = os.listdir(out)
    pids = {int(n.rsplit("-", 1)[1]) for n in names}
    # 主控台視窗的擁有者可能是 conhost.exe：除了比對 PID，也比對各程序回報的 GetConsoleWindow() HWND
    consoles = {int(open(os.path.join(out, n)).read() or 0) for n in names} - {0}
    u32 = ctypes.WinDLL("user32")
    windows = []
    @ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
    def visit(hwnd, _):
        pid = wt.DWORD()
        u32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        if (pid.value in pids or (hwnd or 0) in consoles) and u32.IsWindowVisible(hwnd):
            windows.append(hwnd or 0)
        return True
    u32.EnumWindows(visit, 0)
    worker.join(90)
    result.update(pids=sorted(pids), consoles=sorted(consoles), windows=sorted(set(windows)))
    with open(result_path, "w") as f:
        json.dump(result, f)
""")


def alive(pid: int) -> bool:
    out = subprocess.run(["tasklist", "/FI", f"PID eq {pid}", "/NH"], capture_output=True, text=True).stdout
    return str(pid) in out


@unittest.skipUnless(sys.platform == "win32", "Windows 主控台視窗的行為")
class HiddenConsoleTest(unittest.TestCase):
    def run_driver(self, mode: str) -> dict:
        pythonw = Path(sys.executable).with_name("pythonw.exe")
        with tempfile.TemporaryDirectory(prefix="aum-console-") as d:
            fake, driver, out, result = (Path(d) / "fake_cli.py", Path(d) / "driver.py",
                                         Path(d) / "pids", Path(d) / "result.json")
            fake.write_text(FAKE_CLI, encoding="utf-8")
            driver.write_text(DRIVER, encoding="utf-8")
            out.mkdir()
            subprocess.run([str(pythonw), str(driver), str(COLLECTOR), str(fake), str(out), mode, str(result)],
                           timeout=120, check=True)
            data = json.loads(result.read_text(encoding="utf-8"))
        print(f"\n[{mode}] {data}", file=sys.stderr)  # 留在 CI 紀錄，方便比對各種啟動方式
        self.assertIsNone(data["error"])
        self.assertEqual(len(data["pids"]), 2, "子程序與孫程序都要啟動")
        return data

    def test_plain_launch_from_pythonw_shows_a_window(self):
        # 修正前的 run_claude 能重現問題：沒有主控台的父程序啟動主控台程式，Windows 替它開了看得到的視窗
        self.assertTrue(self.run_driver("plain")["windows"])

    def test_old_no_window_flags_for_comparison(self):
        # 修正前的 codex 旗標：結果只記在 CI 紀錄（孫程序是否跳窗依 Windows 版本而定），不判定
        self.run_driver("no-window")

    def test_hidden_console_shows_no_window_for_the_whole_tree(self):
        data = self.run_driver("fixed")
        self.assertTrue(data["consoles"], "子程序與孫程序共用一個（隱藏的）主控台")
        self.assertEqual(data["windows"], [])

    def assert_tree_gone(self, data: dict) -> None:
        self.assertTrue(data["timed_out"])
        self.assertLess(data["elapsed"], 3 + 15, "逾時後清理要在有限時間內返回")
        self.assertEqual(data["windows"], [])
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and any(alive(p) for p in data["pids"]):
            time.sleep(0.5)
        self.assertEqual([p for p in data["pids"] if alive(p)], [], "逾時後不能留下孤兒程序")

    def test_timeout_ends_the_whole_tree(self):
        self.assert_tree_gone(self.run_driver("timeout"))

    def test_timeout_after_the_cli_exits_ends_the_grandchild(self):
        # C-01：CLI 先結束、孫程序握著輸出管線；taskkill /T 找不到孫程序，要靠 Job Object 結束，且不能無限等管線
        self.assert_tree_gone(self.run_driver("orphan-timeout"))


if __name__ == "__main__":
    unittest.main()
