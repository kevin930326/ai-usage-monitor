import json
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

from usage_collector import __main__ as cli
from usage_collector.models import ProviderError
from usage_collector.providers import claude

FIXTURE = Path(__file__).resolve().parents[2] / "fixtures" / "usage-sample.json"


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
        text = json.dumps(self.fixture, ensure_ascii=False)
        self.assertEqual(json.loads(text), self.fixture)


if __name__ == "__main__":
    unittest.main()
