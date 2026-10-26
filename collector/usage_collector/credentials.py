"""第二層的密鑰（ADR-0011 第 2 節、NFR-1）：macOS 存在 Keychain，Windows 存在認證管理員（Credential Manager）。
不寫進任何檔案、不寫進日誌。

- `device-key`：這台電腦的寫入密鑰，只能寫 /tokens/daily（每台電腦一把，可單獨撤銷）
- `relay-read`：中繼的讀取密鑰，用來下載其他裝置的每日加總（Mac 預設存；Windows 加 `set-tier2.ps1 -ReadKey` 才存，
  ADR-0015 第 3 節）

貼上的密鑰先以 `normalize` 檢查格式（去掉前後空白與換行；裝置密鑰要 `aumd_` 開頭、48 字元），不對就當場提示，
不必等上傳被拒兩次才知道貼錯（BACKLOG 第 10 節）。
Mac 的密鑰由 `collector/scripts/set-tier2.sh` 讀入、`python -m usage_collector.credentials check` 檢查後，
經 `security -i` 的標準輸入存入（不經過指令列）；Windows 由 `collector/windows/set-tier2.ps1` 呼叫
`python -m usage_collector.credentials store device-key|relay-read`。
"""
from __future__ import annotations

import getpass
import re
import subprocess
import sys

DEVICE_KEY = "device-key"
READ_KEY = "relay-read"
NAMES = (DEVICE_KEY, READ_KEY)
KEYCHAIN_SERVICES = {DEVICE_KEY: "AIUsageMonitor-device-key", READ_KEY: "AIUsageMonitor-relay-read"}
KEYCHAIN_ACCOUNT = "default"


# 裝置密鑰：`aumd_`＋32 bytes 的 base64url（無 padding，43 字元），見 relay/src/tokens.ts 的 newKey
DEVICE_KEY_PREFIX = "aumd_"
DEVICE_KEY_LENGTH = len(DEVICE_KEY_PREFIX) + 43
_DEVICE_KEY = re.compile(r"aumd_[A-Za-z0-9_-]{43}")
# 讀取密鑰（READ_TOKEN）：setup-relay.sh 產生 43 字元的 base64url，手動部署（relay/README.md）用 openssl rand -base64 32
# 的 44 字元。格式不固定，只擋明顯貼錯的：太短、中間有空白、含 base64 以外的字元（也讓 security -i 不必處理引號）
_READ_KEY = re.compile(r"[A-Za-z0-9+/=_.~-]{20,256}")
TRIES = 3


class KeyFormatError(ValueError):
    """貼上的密鑰格式不對；訊息是給使用者看的提示（不含密鑰內容）。"""


def normalize(name: str, raw: str) -> str:
    """去掉前後空白與換行，檢查格式；不對時丟出 `KeyFormatError`（訊息不含密鑰內容）。"""
    value = raw.strip()  # 也去掉 Windows 的 \r 與全形空白
    if not value:
        raise KeyFormatError("沒有輸入密鑰")
    if name == DEVICE_KEY:
        if not value.startswith(DEVICE_KEY_PREFIX):
            hint = "（貼上的看起來像中繼的讀取密鑰）" if _READ_KEY.fullmatch(value) else ""
            raise KeyFormatError(f"寫入密鑰應以 {DEVICE_KEY_PREFIX} 開頭（scripts/relay-device.sh add 印出的那一行）{hint}")
        if len(value) != DEVICE_KEY_LENGTH:
            raise KeyFormatError(f"寫入密鑰應為 {DEVICE_KEY_LENGTH} 個字元，貼上的是 {len(value)} 個（可能少複製或多複製了一段）")
        if not _DEVICE_KEY.fullmatch(value):
            raise KeyFormatError("寫入密鑰含有不該出現的字元（只會有英文字母、數字、- 與 _）")
        return value
    if value.startswith(DEVICE_KEY_PREFIX):
        raise KeyFormatError("這是裝置的寫入密鑰（aumd_ 開頭），這裡要貼中繼的讀取密鑰（READ_TOKEN，和 iPhone App 用的相同）")
    if not _READ_KEY.fullmatch(value):
        if any(c.isspace() for c in value):
            raise KeyFormatError("讀取密鑰中間有空白或換行，可能複製到多餘的文字")
        if len(value) < 20:
            raise KeyFormatError(f"讀取密鑰太短（{len(value)} 個字元），可能少複製了一段")
        raise KeyFormatError("讀取密鑰含有不該出現的字元（只會有英文字母、數字與 + / = _ . ~ -）")
    return value


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


def _prompt(text: str) -> str:
    """主控台用不顯示的提示；標準輸入不是主控台（CI 以管線送入）時讀一行（Windows 的 getpass 直接讀主控台，不讀管線）"""
    if sys.stdin is not None and sys.stdin.isatty():
        return getpass.getpass(text)
    line = sys.stdin.readline() if sys.stdin is not None else ""
    return line


def main(argv: list[str]) -> int:
    """- `store <名稱>`：提示輸入（不顯示），格式不對時重新提示（最多 3 次），存入認證管理員（Windows）
    - `check <名稱>`：從標準輸入讀一行，格式對時把整理過的密鑰印到標準輸出（給 set-tier2.sh 用，不經過指令列）；
      不對時把提示印到標準錯誤、結束碼 1
    - `delete <名稱>`：刪除
    - `has <名稱>`：存過時結束碼 0，沒有時 1（不印出密鑰）"""
    if len(argv) != 2 or argv[0] not in ("store", "check", "delete", "has") or argv[1] not in NAMES:
        print(f"用法：python -m usage_collector.credentials store|check|delete|has {'|'.join(NAMES)}", file=sys.stderr)
        return 2
    if argv[0] == "delete":
        delete(argv[1])
        return 0
    if argv[0] == "has":
        return 0 if read(argv[1]) else 1
    if argv[0] == "check":
        try:
            print(normalize(argv[1], sys.stdin.readline()))
        except KeyFormatError as e:
            print(str(e), file=sys.stderr)
            return 1
        return 0
    for attempt in range(TRIES):
        try:
            value = normalize(argv[1], _prompt("貼上密鑰（不會顯示）："))
            break
        except KeyFormatError as e:
            left = TRIES - attempt - 1
            print(f"{e}{'，請重新貼上' if left else ''}", file=sys.stderr)
    else:
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
