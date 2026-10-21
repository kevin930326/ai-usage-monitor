import json
import unittest
from pathlib import Path
from unittest import mock

from usage_collector import __main__ as cli
from usage_collector.models import ProviderError, ProviderUsage, Window, parse_iso

FIXTURE = Path(__file__).resolve().parents[2] / "fixtures" / "usage-sample.json"


class SharedFixtureTest(unittest.TestCase):
    """收集器的輸出與 fixtures/usage-sample.json 同格式（中繼與 App 的測試讀同一份）。"""

    def setUp(self):
        self.fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))

    def test_collect_produces_the_fixture(self):
        claude = ProviderUsage(plan="Max", windows=[
            Window("five_hour", "5 小時", 62.5, parse_iso("2026-10-21T03:30:00Z")),
            Window("weekly", "每週", 35.0, parse_iso("2026-10-24T03:00:00Z")),
            Window("weekly_opus", "每週 Opus", 97.0, parse_iso("2026-10-24T03:00:00Z"), hidden=True),
            Window("weekly_fable", "每週 Fable", 0.0, None, hidden=True),
        ])
        codex = mock.Mock(fetch=mock.Mock(side_effect=ProviderError("token 過期，請在 Mac 重新登入 Codex")))
        providers = {"claude": mock.Mock(fetch=mock.Mock(return_value=claude)), "codex": codex}
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
