"""這台電腦的硬體指紋（ADR-0014 D-2）：分辨 history.sqlite3 是不是從別台電腦搬來的。

- Mac：`ioreg` 的 IOPlatformUUID（主機板上的識別碼，重灌 macOS 不變）；Windows：登錄檔的 MachineGuid
  （重灌 Windows 會變）；其他系統：`/etc/machine-id`。
- 只存雜湊（`history.sqlite3` 的 `meta.machine_fingerprint`），不存識別碼本身；讀不到時回傳 None（不檢查）。
"""
from __future__ import annotations

import hashlib
import re
import subprocess
import sys
from pathlib import Path

_UUID_RE = re.compile(r'"IOPlatformUUID"\s*=\s*"([0-9A-Fa-f-]{16,})"')


def fingerprint() -> str | None:
    raw = _raw_id()
    if not raw:
        return None
    return hashlib.sha256(f"ai-usage-monitor/machine:{raw.strip().lower()}".encode()).hexdigest()[:32]


def _raw_id() -> str | None:
    try:
        if sys.platform == "win32":
            return _windows_guid()
        if sys.platform == "darwin":
            out = subprocess.run(["/usr/sbin/ioreg", "-rd1", "-c", "IOPlatformExpertDevice"],
                                 capture_output=True, text=True, timeout=5, check=True).stdout
            match = _UUID_RE.search(out)
            return match.group(1) if match else None
        for path in (Path("/etc/machine-id"), Path("/var/lib/dbus/machine-id")):
            if path.is_file():
                return path.read_text(encoding="ascii").strip() or None
    except (OSError, subprocess.SubprocessError, UnicodeDecodeError):
        return None
    return None


def _windows_guid() -> str | None:
    if sys.platform != "win32":  # mypy 在其他平台不檢查 winreg
        return None
    import winreg
    access = winreg.KEY_READ | winreg.KEY_WOW64_64KEY
    with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Microsoft\Cryptography", 0, access) as key:
        value, _ = winreg.QueryValueEx(key, "MachineGuid")
    return value if isinstance(value, str) else None
