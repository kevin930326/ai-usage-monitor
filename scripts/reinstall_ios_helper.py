"""scripts/reinstall-ios.sh 的輔助程式：偵測 Team ID、挑出實體 iPhone、記錄重試狀態。
只讀寫本機檔案，不碰網路與帳號密碼。

用法：
  reinstall_ios_helper.py team
      從 Xcode 已登入的帳號（com.apple.dt.Xcode 偏好設定）偵測 Team ID；
      偵測不到時改看鑰匙圈中 Apple Development 憑證的 OU。只有一個 Team 時印出，否則結束碼 1。
  reinstall_ios_helper.py iphones <devicectl-devices.json>
      印出實體 iPhone，每行「UDID<TAB>名稱<TAB>連線方式」。
  reinstall_ios_helper.py due <state.json> <天數>
      距上次成功已達指定天數（或從未成功）時結束碼 0，否則 1。
  reinstall_ios_helper.py success <state.json>
      記錄成功並清除失敗狀態。
  reinstall_ios_helper.py failure <state.json> <小時>
      記錄失敗；這一輪連續失敗超過指定小時且還沒通知過時印出 notify 與失敗時數。
  reinstall_ios_helper.py scheduled
      launchd 用：以子程序執行 reinstall-ios.sh --if-due 並回傳它的結束碼。

環境變數 AUM_NOW（Unix 秒）可覆寫現在時間，測試重試與通知用。
"""
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def now() -> float:
    return float(os.environ.get("AUM_NOW") or time.time())


# MARK: Team ID

def teams_from_xcode() -> set[str]:
    out = subprocess.run(["defaults", "export", "com.apple.dt.Xcode", "-"], capture_output=True)
    if out.returncode != 0:
        return set()
    prefs = plistlib.loads(out.stdout)
    by_account = prefs.get("IDEProvisioningTeamByIdentifier") or prefs.get("IDEProvisioningTeams") or {}
    return {team["teamID"] for teams in by_account.values() for team in teams if team.get("teamID")}


def teams_from_certificates() -> set[str]:
    out = subprocess.run(["security", "find-certificate", "-a", "-c", "Apple Development", "-p"],
                         capture_output=True, text=True)
    teams = set()
    for pem in re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", out.stdout, re.S):
        subject = subprocess.run(["openssl", "x509", "-noout", "-subject"], input=pem,
                                 capture_output=True, text=True).stdout
        if match := re.search(r"OU\s*=\s*([A-Z0-9]{10})", subject):
            teams.add(match.group(1))
    return teams


def cmd_team() -> int:
    teams = teams_from_xcode() or teams_from_certificates()
    if len(teams) == 1:
        print(teams.pop())
        return 0
    if not teams:
        print("找不到 Team：請先在 Xcode → Settings → Accounts 登入 Apple ID，並用 Xcode 裝一次 App", file=sys.stderr)
    else:
        print(f"有多個 Team（{', '.join(sorted(teams))}），請把要用的寫進 config.json 的 development_team",
              file=sys.stderr)
    return 1


# MARK: 裝置

def cmd_iphones(path: str) -> int:
    devices = json.loads(Path(path).read_text())["result"]["devices"]
    for device in devices:
        hardware = device.get("hardwareProperties", {})
        if hardware.get("platform") != "iOS" or hardware.get("reality") != "physical" \
                or hardware.get("deviceType") != "iPhone":
            continue
        name = device.get("deviceProperties", {}).get("name", "iPhone")
        transport = device.get("connectionProperties", {}).get("transportType") or "-"
        print(f"{hardware.get('udid')}\t{name}\t{transport}")
    return 0


# MARK: 重試狀態

def load(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save(path: Path, state: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".reinstall-", suffix=".json")
    with os.fdopen(fd, "w") as f:
        json.dump(state, f, indent=2)
    os.replace(tmp, path)


def cmd_due(path: str, days: str) -> int:
    last = load(Path(path)).get("last_success")
    return 0 if last is None or now() - last >= float(days) * 86400 else 1


def cmd_success(path: str) -> int:
    save(Path(path), {"last_success": now()})
    return 0


def cmd_failure(path: str, hours: str) -> int:
    state = load(Path(path))
    state.setdefault("failing_since", now())
    failing_hours = (now() - state["failing_since"]) / 3600
    if failing_hours > float(hours) and not state.get("failure_notified"):
        state["failure_notified"] = True
        print(f"notify\t{failing_hours:.0f}")
    save(Path(path), state)
    return 0


# MARK: launchd

def cmd_scheduled() -> int:
    # repo 在 ~/Documents（macOS 隱私保護的資料夾）。launchd 直接執行 /bin/bash 會被拒絕讀取，
    # 由 python3 啟動 bash 時，存取權限算在 python3 上，與收集器的 launchd 工作相同
    script = Path(__file__).resolve().parent / "reinstall-ios.sh"
    return subprocess.call(["/bin/bash", str(script), "--if-due"])


COMMANDS = {"team": cmd_team, "iphones": cmd_iphones, "due": cmd_due,
            "success": cmd_success, "failure": cmd_failure, "scheduled": cmd_scheduled}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        raise SystemExit(__doc__)
    sys.exit(COMMANDS[sys.argv[1]](*sys.argv[2:]))
