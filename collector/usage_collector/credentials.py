"""第二層的密鑰（ADR-0011 第 2 節、NFR-1）：macOS 存在 Keychain，Windows 存在認證管理員（Credential Manager）。
不寫進任何檔案、不寫進日誌。

- `device-key`：這台電腦的寫入密鑰，只能寫 /tokens/daily（每台電腦一把，可單獨撤銷）
- `relay-read`：中繼的讀取密鑰，Mac 用來下載其他裝置的每日加總（Windows 不下載，不需要）

Mac 的密鑰由 `collector/scripts/set-tier2.sh` 以 `security` 的提示輸入存入（不經過指令列）；
Windows 由 `collector/windows/set-tier2.ps1` 呼叫 `python -m usage_collector.credentials store device-key`。
"""
from __future__ import annotations

import getpass
import subprocess
import sys

DEVICE_KEY = "device-key"
READ_KEY = "relay-read"
NAMES = (DEVICE_KEY, READ_KEY)
KEYCHAIN_SERVICES = {DEVICE_KEY: "AIUsageMonitor-device-key", READ_KEY: "AIUsageMonitor-relay-read"}
KEYCHAIN_ACCOUNT = "default"


def target(name: str) -> str:
    """Windows 認證管理員裡的名稱（「一般認證」）"""
    return f"AIUsageMonitor/{name}"


if sys.platform == "win32":
    import ctypes
    from ctypes import wintypes

    CRED_TYPE_GENERIC = 1
    CRED_PERSIST_LOCAL_MACHINE = 2  # 只存在這台電腦、這個使用者（不隨漫遊設定檔同步）

    class _FILETIME(ctypes.Structure):
        _fields_ = [("dwLowDateTime", wintypes.DWORD), ("dwHighDateTime", wintypes.DWORD)]

    class _CREDENTIALW(ctypes.Structure):
        _fields_ = [
            ("Flags", wintypes.DWORD),
            ("Type", wintypes.DWORD),
            ("TargetName", wintypes.LPWSTR),
            ("Comment", wintypes.LPWSTR),
            ("LastWritten", _FILETIME),
            ("CredentialBlobSize", wintypes.DWORD),
            ("CredentialBlob", ctypes.POINTER(ctypes.c_ubyte)),
            ("Persist", wintypes.DWORD),
            ("AttributeCount", wintypes.DWORD),
            ("Attributes", ctypes.c_void_p),
            ("TargetAlias", wintypes.LPWSTR),
            ("UserName", wintypes.LPWSTR),
        ]

    _advapi32 = ctypes.WinDLL("advapi32", use_last_error=True)
    _advapi32.CredReadW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                    ctypes.POINTER(ctypes.POINTER(_CREDENTIALW))]
    _advapi32.CredReadW.restype = wintypes.BOOL
    _advapi32.CredWriteW.argtypes = [ctypes.POINTER(_CREDENTIALW), wintypes.DWORD]
    _advapi32.CredWriteW.restype = wintypes.BOOL
    _advapi32.CredDeleteW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD]
    _advapi32.CredDeleteW.restype = wintypes.BOOL
    _advapi32.CredFree.argtypes = [ctypes.c_void_p]

    def _read_windows(name: str) -> str | None:
        pointer = ctypes.POINTER(_CREDENTIALW)()
        if not _advapi32.CredReadW(target(name), CRED_TYPE_GENERIC, 0, ctypes.byref(pointer)):
            return None
        try:
            cred = pointer.contents
            blob = ctypes.string_at(cred.CredentialBlob, cred.CredentialBlobSize)
        finally:
            _advapi32.CredFree(pointer)
        try:
            return blob.decode("utf-16-le") or None
        except UnicodeDecodeError:
            return None

    def _store_windows(name: str, value: str) -> None:
        blob = value.encode("utf-16-le")  # 和 cmdkey／PowerShell 存的一般認證相同
        buffer = (ctypes.c_ubyte * len(blob)).from_buffer_copy(blob)
        cred = _CREDENTIALW()
        cred.Type = CRED_TYPE_GENERIC
        cred.TargetName = target(name)
        cred.CredentialBlobSize = len(blob)
        cred.CredentialBlob = ctypes.cast(buffer, ctypes.POINTER(ctypes.c_ubyte))
        cred.Persist = CRED_PERSIST_LOCAL_MACHINE
        cred.UserName = "AIUsageMonitor"
        if not _advapi32.CredWriteW(ctypes.byref(cred), 0):
            raise OSError(f"無法寫入認證管理員（錯誤 {ctypes.get_last_error()}）")

    def _delete_windows(name: str) -> None:
        _advapi32.CredDeleteW(target(name), CRED_TYPE_GENERIC, 0)


def read(name: str) -> str | None:
    """讀取密鑰；沒有存過或讀不到時回傳 None（不丟例外、不記錄內容）。"""
    if sys.platform == "win32":
        return _read_windows(name)
    try:
        result = subprocess.run(["security", "find-generic-password", "-s", KEYCHAIN_SERVICES[name],
                                 "-a", KEYCHAIN_ACCOUNT, "-w"], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):  # 沒有 security（Linux）或 Keychain 沒有回應
        return None
    value = result.stdout.strip()
    return value if result.returncode == 0 and value else None


def store(name: str, value: str) -> None:
    """只給 Windows 用（Mac 由 set-tier2.sh 以 security 的提示輸入存入，密鑰不經過指令列）。"""
    if sys.platform == "win32":
        _store_windows(name, value)
        return
    raise OSError("macOS 請用 collector/scripts/set-tier2.sh 存入 Keychain")


def delete(name: str) -> None:
    if sys.platform == "win32":
        _delete_windows(name)
        return
    subprocess.run(["security", "delete-generic-password", "-s", KEYCHAIN_SERVICES[name], "-a", KEYCHAIN_ACCOUNT],
                   capture_output=True, check=False)


def main(argv: list[str]) -> int:
    """`python -m usage_collector.credentials store <名稱>`：提示輸入（不顯示）後存入；`delete <名稱>` 刪除。"""
    if len(argv) != 2 or argv[0] not in ("store", "delete") or argv[1] not in NAMES:
        print(f"用法：python -m usage_collector.credentials store|delete {'|'.join(NAMES)}", file=sys.stderr)
        return 2
    if argv[0] == "delete":
        delete(argv[1])
        return 0
    value = getpass.getpass("貼上密鑰（不會顯示）：").strip()
    if not value:
        print("沒有輸入密鑰", file=sys.stderr)
        return 1
    try:
        store(argv[1], value)
    except OSError as e:
        print(str(e), file=sys.stderr)
        return 1
    print(f"已存入：{target(argv[1])}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
