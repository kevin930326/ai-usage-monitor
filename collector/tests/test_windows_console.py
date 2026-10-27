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
# 兩個程序都把自己的 PID 與主控台視窗是否看得到寫進 pids 資料夾，再等一段時間讓測試列舉視窗
FAKE_CLI = textwrap.dedent("""
    import ctypes, os, subprocess, sys, time
    out, role, hold = sys.argv[1], sys.argv[2], float(sys.argv[3])
    k32, u32 = ctypes.WinDLL("kernel32"), ctypes.WinDLL("user32")
    k32.GetConsoleWindow.restype = ctypes.c_void_p
    hwnd = k32.GetConsoleWindow()
    visible = bool(hwnd) and bool(u32.IsWindowVisible(ctypes.c_void_p(hwnd)))
    with open(os.path.join(out, f"{role}-{os.getpid()}"), "w") as f:
        f.write("1" if visible else "0")
    if role == "child":
        subprocess.Popen([sys.executable, __file__, out, "grandchild", str(hold)])
    time.sleep(hold)
""")

# 以 pythonw 執行的驅動程式：模擬收集器，用指定的方式啟動假 CLI，程序樹還在時列舉看得到的頂層視窗
DRIVER = textwrap.dedent("""
    import ctypes, ctypes.wintypes as wt, json, os, subprocess, sys, threading, time
    sys.path.insert(0, sys.argv[1])
    from usage_collector import system
    fake, out, mode, result_path = sys.argv[2:6]
    argv = [sys.executable.replace("pythonw.exe", "python.exe"), fake, out, "child"]
    result = {"error": None, "timed_out": False}

    def launch():
        try:
            if mode == "plain":  # 修正前的 run_claude：subprocess.run 不帶任何旗標
                subprocess.run(argv + ["4"], stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
            elif mode == "no-window":  # 修正前的 codex：CREATE_NO_WINDOW＋新 process group
                subprocess.run(argv + ["4"], stdin=subprocess.DEVNULL, capture_output=True, timeout=30,
                               creationflags=0x08000000 | 0x00000200)
            elif mode == "fixed":
                system.run_isolated(argv + ["4"], stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
            elif mode == "timeout":
                system.run_isolated(argv + ["60"], stdin=subprocess.DEVNULL, capture_output=True, timeout=3)
        except subprocess.TimeoutExpired:
            result["timed_out"] = True
        except Exception as e:
            result["error"] = repr(e)

    worker = threading.Thread(target=launch)
    worker.start()
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline and len(os.listdir(out)) < 2:
        time.sleep(0.1)
    time.sleep(0.5)
    pids = {int(n.split("-")[1]) for n in os.listdir(out)}
    u32 = ctypes.WinDLL("user32")
    windows = []
    @ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
    def visit(hwnd, _):
        pid = wt.DWORD()
        u32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        if pid.value in pids and u32.IsWindowVisible(hwnd):
            windows.append(pid.value)
        return True
    u32.EnumWindows(visit, 0)
    worker.join(90)
    result.update(pids=sorted(pids), windows=windows,
                  self_reported={n: open(os.path.join(out, n)).read() for n in os.listdir(out)})
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
        self.assertEqual(data["windows"], [])
        self.assertEqual(set(data["self_reported"].values()), {"0"})

    def test_timeout_ends_the_whole_tree(self):
        data = self.run_driver("timeout")
        self.assertTrue(data["timed_out"])
        self.assertEqual(data["windows"], [])
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and any(alive(p) for p in data["pids"]):
            time.sleep(0.5)
        self.assertEqual([p for p in data["pids"] if alive(p)], [], "逾時後不能留下孤兒程序")


if __name__ == "__main__":
    unittest.main()
