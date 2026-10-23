import json
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

from usage_collector import __main__ as cli
from usage_collector.models import ProviderError
from usage_collector.providers import claude, codex

FIXTURES = Path(__file__).resolve().parents[2] / "fixtures"
FIXTURE = FIXTURES / "usage-sample.json"


class SharedFixtureTest(unittest.TestCase):
    """收集器的輸出與 fixtures/usage-sample.json 同格式（中繼與 App 的測試讀同一份）。"""

    def setUp(self):
        self.fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))

    def test_collect_produces_the_fixture(self):
        # Claude 端經過真正的 /usage 文字解析（window_for 改 id／label 推導時這裡會跟著紅），
        # 時間用 UTC 寫、以 UTC 解析，與 fixture 的 Z 時間相同
        text = ("Current session: 62.5% used · resets Oct 21 at 3:30am (UTC)\n"
                "Current week (all models): 35% used · resets Oct 24 at 3am (UTC)\n"
                "Current week (Opus): 97% used · resets Oct 24 at 3am (UTC)\n"
                "Current week (Fable): 0% used\n")
        now = datetime(2026, 10, 21, 3, 0, tzinfo=timezone.utc)
        claude_usage = claude.parse(text, "Max", now)
        providers = {
            "claude": mock.Mock(fetch=mock.Mock(return_value=claude_usage)),
            "codex": mock.Mock(fetch=mock.Mock(side_effect=ProviderError("token 過期，請在 Mac 重新登入 Codex"))),
        }
        with mock.patch.dict(cli.PROVIDERS, providers, clear=True):
            snapshot = cli.collect(list(providers))
        # updated_at 是執行當下的時間，其餘欄位要完全相同
        self.assertEqual(snapshot["schema_version"], self.fixture["schema_version"])
        self.assertEqual(snapshot["providers"], self.fixture["providers"])
        self.assertEqual(set(snapshot), set(self.fixture))

    def test_fixture_round_trips_through_json(self):
        for path in sorted(FIXTURES.glob("usage-*.json")):
            with self.subTest(path.name):
                fixture = json.loads(path.read_text(encoding="utf-8"))
                self.assertEqual(json.loads(json.dumps(fixture, ensure_ascii=False)), fixture)

    def test_collect_produces_codex_only_fixture(self):
        # 只啟用 Codex；app-server 的 planType 不明（plan 為 null）、5 小時額度超過 100%（整合審查 D-i）
        fixture = json.loads((FIXTURES / "usage-codex-only.json").read_text(encoding="utf-8"))
        result = {"rateLimits": {
            "primary": {"usedPercent": 112.5, "windowDurationMins": 300, "resetsAt": 1792555200},    # 04:00Z
            "secondary": {"usedPercent": 40, "windowDurationMins": 10080, "resetsAt": 1792897200},  # 10/25 03:00Z
            "planType": "unknown",
        }}
        providers = {"codex": mock.Mock(fetch=mock.Mock(return_value=codex.parse(result)))}
        with mock.patch.dict(cli.PROVIDERS, providers, clear=True):
            snapshot = cli.collect(["codex"])
        self.assertEqual(snapshot["providers"], fixture["providers"])
        self.assertEqual(set(snapshot), set(fixture))

    def test_collect_with_no_providers_produces_empty_fixture(self):
        fixture = json.loads((FIXTURES / "usage-no-providers.json").read_text(encoding="utf-8"))
        snapshot = cli.collect([])
        self.assertEqual(snapshot["providers"], fixture["providers"])
        self.assertEqual(snapshot["schema_version"], fixture["schema_version"])


if __name__ == "__main__":
    unittest.main()
