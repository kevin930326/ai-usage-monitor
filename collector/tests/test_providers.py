import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from usage_collector import __main__ as cli
from usage_collector.models import ProviderError, ProviderUsage
from usage_collector.providers import claude, codex

# 假資料，結構與實際 API 回應相同
CLAUDE_BODY = {
    "five_hour": {"utilization": 12.0, "resets_at": "2026-10-20T10:00:00.123456+00:00"},
    "seven_day": {"utilization": 63.0, "resets_at": "2026-10-26T15:00:00+00:00"},
    "seven_day_opus": None,
}

CODEX_BODY = {
    "plan_type": "pro",
    "rate_limit": {
        "primary_window": {"used_percent": 0, "limit_window_seconds": 18000, "reset_at": 1792529816},
        "secondary_window": {"used_percent": 41, "limit_window_seconds": 604800, "reset_at": 1793094310},
    },
}


class ClaudeParseTest(unittest.TestCase):
    def test_parses_windows_and_skips_null(self):
        usage = claude.parse(CLAUDE_BODY, "Team").to_dict()
        self.assertEqual(usage["plan"], "Team")
        self.assertEqual([w["id"] for w in usage["windows"]], ["five_hour", "weekly"])
        self.assertEqual(usage["windows"][0]["resets_at"], "2026-10-20T10:00:00Z")
        self.assertEqual(usage["windows"][1]["used_pct"], 63.0)

    def test_empty_body_is_error(self):
        with self.assertRaises(ProviderError):
            claude.parse({}, None)


class CodexParseTest(unittest.TestCase):
    def test_parses_primary_and_weekly(self):
        usage = codex.parse(CODEX_BODY).to_dict()
        self.assertEqual(usage["plan"], "Pro")
        self.assertEqual([(w["id"], w["label"]) for w in usage["windows"]],
                         [("five_hour", "5 小時"), ("weekly", "每週")])
        self.assertEqual(usage["windows"][1]["used_pct"], 41.0)

    def test_missing_auth_file(self):
        with self.assertRaisesRegex(ProviderError, "尚未登入"):
            codex.read_tokens(Path("/nonexistent/auth.json"))

    def test_reads_only_needed_tokens(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json") as f:
            json.dump({"tokens": {"access_token": "a", "account_id": "b", "refresh_token": "r"}}, f)
            f.flush()
            self.assertEqual(codex.read_tokens(Path(f.name)), {"access_token": "a", "account_id": "b"})


class CollectTest(unittest.TestCase):
    def test_one_provider_failure_does_not_break_other(self):
        ok = mock.Mock(fetch=mock.Mock(return_value=ProviderUsage(plan="Pro")))
        bad = mock.Mock(fetch=mock.Mock(side_effect=ProviderError("尚未登入")))
        boom = mock.Mock(fetch=mock.Mock(side_effect=KeyError("secret-token-value")))
        with mock.patch.dict(cli.PROVIDERS, {"a": ok, "b": bad, "c": boom}, clear=True):
            snap = cli.collect(["a", "b", "c"])
        self.assertIsNone(snap["providers"]["a"]["error"])
        self.assertEqual(snap["providers"]["b"]["error"], "尚未登入")
        # 未預期例外只顯示類別名稱，不會把例外內容（可能含 token）帶出去
        self.assertNotIn("secret-token-value", snap["providers"]["c"]["error"])


if __name__ == "__main__":
    unittest.main()
