import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from usage_collector import __main__ as cli
from usage_collector.models import ProviderError, ProviderUsage
from usage_collector.providers import codex

# 假資料，結構與實際 API 回應相同
CODEX_BODY = {
    "plan_type": "pro",
    "rate_limit": {
        "primary_window": {"used_percent": 0, "limit_window_seconds": 18000, "reset_at": 1792529816},
        "secondary_window": {"used_percent": 41, "limit_window_seconds": 604800, "reset_at": 1793094310},
    },
}


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


# C-04：百分比缺少或格式不對時要報錯，不能變成「0% 已用」（Claude 的 /usage 文字解析見 test_claude.py）
BAD_PERCENTS = [None, "12", float("nan"), float("inf"), -5, True]


class PercentValidationTest(unittest.TestCase):
    def test_codex_rejects_missing_percent(self):
        body = {"rate_limit": {"primary_window": {"limit_window_seconds": 18000, "reset_at": 1792529816}}}
        with self.assertRaises(ProviderError):
            codex.parse(body)

    def test_codex_rejects_bad_percent(self):
        for value in BAD_PERCENTS:
            body = {"rate_limit": {"primary_window": {"used_percent": value, "limit_window_seconds": 18000}}}
            with self.subTest(value=value), self.assertRaises(ProviderError):
                codex.parse(body)

    def test_zero_and_over_limit_are_kept(self):
        # 0 是真的沒用；超過 100（超額）照實傳出，顯示端會限制在 0～100
        body = {"rate_limit": {
            "primary_window": {"used_percent": 0, "limit_window_seconds": 18000},
            "secondary_window": {"used_percent": 104.5, "limit_window_seconds": 604800},
        }}
        self.assertEqual([w.used_pct for w in codex.parse(body).windows], [0.0, 104.5])


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
