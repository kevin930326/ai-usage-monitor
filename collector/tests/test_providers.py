import unittest
from unittest import mock

from usage_collector import __main__ as cli
from usage_collector.models import ProviderError, ProviderUsage


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
