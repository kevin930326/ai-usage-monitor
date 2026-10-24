import unittest

from usage_collector import history, paths


class IsolationTest(unittest.TestCase):
    def test_tests_do_not_use_the_real_folder(self):
        """tests/__init__.py 把資料夾指到暫存位置；`python3 -m unittest discover -s tests` 不會載入它，
        這時沒有 mock 的寫入會進到真的 history.sqlite3。請在 collector 資料夾執行 `python3 -m unittest`。"""
        real = paths.resolve_home({})
        self.assertNotEqual(paths.APP_SUPPORT_DIR, real)
        self.assertNotEqual(history.HISTORY_PATH.parent, real)


if __name__ == "__main__":
    unittest.main()
