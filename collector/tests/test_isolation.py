import unittest

from usage_collector import history, paths


class IsolationTest(unittest.TestCase):
    def test_tests_do_not_use_the_real_folder(self):
        """tests/__init__.py 把資料夾指到暫存位置。沒有它時（例如 `python3 -m unittest discover -s tests`），
        匯入 usage_collector 就會因 `paths.TestHomeNotSet` 失敗，不會寫到真的 history.sqlite3。"""
        real = paths.resolve_home({}, modules=())
        self.assertNotEqual(paths.APP_SUPPORT_DIR, real)
        self.assertNotEqual(history.HISTORY_PATH.parent, real)


if __name__ == "__main__":
    unittest.main()
