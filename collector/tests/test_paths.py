import unittest
from pathlib import Path

from usage_collector import system
from usage_collector.paths import TestHomeNotSet, is_testing, resolve_home

DEFAULT = system.default_home({})  # macOS：~/Library/Application Support/AIUsageMonitor（見 test_system）


class ResolveHomeTest(unittest.TestCase):
    def test_uses_environment_variable(self):
        self.assertEqual(resolve_home({"AI_USAGE_MONITOR_HOME": "/tmp/aum"}), Path("/tmp/aum"))

    def test_defaults_to_application_support(self):
        self.assertEqual(resolve_home({}, modules=()), DEFAULT)

    def test_empty_value_falls_back_like_the_mac_app(self):
        # UsageKit 的 UsageFileLocator 把空字串視為未設定，兩邊必須一致
        self.assertEqual(resolve_home({"AI_USAGE_MONITOR_HOME": ""}, modules=()), DEFAULT)


class TestEnvironmentTest(unittest.TestCase):
    def test_detects_unittest_pytest_and_the_flag(self):
        self.assertTrue(is_testing({}, modules=("unittest",)))
        self.assertTrue(is_testing({}, modules=("pytest",)))
        self.assertTrue(is_testing({"AUM_TESTING": "1"}, modules=()))
        self.assertFalse(is_testing({"AUM_TESTING": ""}, modules=()))
        self.assertFalse(is_testing({}, modules=("json",)))

    def test_refuses_the_default_folder_while_testing(self):
        for environ in ({}, {"AI_USAGE_MONITOR_HOME": ""}):
            with self.assertRaises(TestHomeNotSet):
                resolve_home(environ)  # 這個行程已載入 unittest
        with self.assertRaises(TestHomeNotSet):
            resolve_home({"AUM_TESTING": "1"}, modules=())

    def test_an_explicit_folder_is_still_allowed_while_testing(self):
        self.assertEqual(resolve_home({"AI_USAGE_MONITOR_HOME": "/tmp/aum", "AUM_TESTING": "1"}), Path("/tmp/aum"))


if __name__ == "__main__":
    unittest.main()
