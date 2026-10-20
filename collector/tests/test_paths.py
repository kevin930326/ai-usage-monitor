import unittest
from pathlib import Path

from usage_collector.paths import resolve_home

DEFAULT = Path.home() / "Library" / "Application Support" / "AIUsageMonitor"


class ResolveHomeTest(unittest.TestCase):
    def test_uses_environment_variable(self):
        self.assertEqual(resolve_home({"AI_USAGE_MONITOR_HOME": "/tmp/aum"}), Path("/tmp/aum"))

    def test_defaults_to_application_support(self):
        self.assertEqual(resolve_home({}), DEFAULT)

    def test_empty_value_falls_back_like_the_mac_app(self):
        # UsageKit 的 UsageFileLocator 把空字串視為未設定，兩邊必須一致
        self.assertEqual(resolve_home({"AI_USAGE_MONITOR_HOME": ""}), DEFAULT)


if __name__ == "__main__":
    unittest.main()
