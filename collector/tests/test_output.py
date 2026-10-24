import io
import json
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

from usage_collector import __main__ as cli
from usage_collector import local_store, relay
from usage_collector.models import SCHEMA_VERSION, ProviderError, ProviderUsage, parse_iso
from usage_collector.providers import claude

OK_PROVIDERS = {"a": mock.Mock(fetch=mock.Mock(return_value=ProviderUsage(plan="Pro")))}


class SchemaTest(unittest.TestCase):
    def test_snapshot_has_schema_version(self):
        with mock.patch.dict(cli.PROVIDERS, OK_PROVIDERS, clear=True):
            self.assertEqual(cli.collect(["a"])["schema_version"], SCHEMA_VERSION)

    def test_parse_iso_accepts_z_suffix(self):
        self.assertEqual(parse_iso("2026-10-20T10:00:00Z"), parse_iso("2026-10-20T10:00:00+00:00"))


class ClaudeScopedLimitsTest(unittest.TestCase):
    def test_per_model_weekly_limits_are_hidden(self):
        text = ("Current session: 21% used · resets Oct 21 at 3am (UTC)\n"
                "Current week (Fable): 5% used · resets Oct 20 at 11pm (UTC)\n")
        windows = claude.parse(text, "Max").to_dict()["windows"]
        self.assertEqual([(w["id"], w["hidden"]) for w in windows],
                         [("five_hour", False), ("weekly_fable", True)])
        self.assertEqual(windows[1]["label"], "每週 Fable")


class LocalStoreTest(unittest.TestCase):
    def test_atomic_write_overwrites_and_leaves_no_temp_files(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "sub" / "usage.json"
            local_store.write_snapshot({"v": 1}, path)
            local_store.write_snapshot({"v": 2}, path)
            self.assertEqual(json.loads(path.read_text()), {"v": 2})
            self.assertEqual([p.name for p in path.parent.iterdir()], ["usage.json"])


class RelayUploadTest(unittest.TestCase):
    def test_posts_snapshot_with_bearer_token(self):
        resp = mock.MagicMock()
        resp.__enter__.return_value.read.return_value = b'{"ok": true}'
        with mock.patch.object(relay, "load_relay_url", return_value="https://relay.example"), \
             mock.patch.object(relay, "read_write_token", return_value="w-token"), \
             mock.patch("usage_collector.http._opener.open", return_value=resp) as urlopen:
            relay.upload({"schema_version": 1})
        req = urlopen.call_args.args[0]
        self.assertEqual(req.full_url, "https://relay.example/usage")
        self.assertEqual(req.get_method(), "POST")
        self.assertEqual(req.get_header("Authorization"), "Bearer w-token")
        self.assertEqual(json.loads(req.data), {"schema_version": 1})

    def test_missing_config_raises_not_configured(self):
        with self.assertRaises(relay.RelayNotConfigured):
            relay.load_relay_url(Path("/nonexistent/config.json"))


class MainTest(unittest.TestCase):
    def run_main(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.dict(cli.PROVIDERS, OK_PROVIDERS, clear=True), \
             mock.patch.object(cli, "enabled_providers", return_value=["a"]), \
             mock.patch.object(cli.token_stats, "run_safely"), \
             redirect_stdout(out), redirect_stderr(err):
            code = cli.main(list(args))
        return code, out.getvalue(), err.getvalue()

    def test_unconfigured_relay_is_skipped_not_failed(self):
        with mock.patch.object(relay, "upload", side_effect=relay.RelayNotConfigured("未設定")):
            code, out, err = self.run_main("--upload", "--quiet")
        self.assertEqual((code, out), (0, ""))
        self.assertIn("略過上傳", err)

    def test_upload_failure_returns_non_zero(self):
        with mock.patch.object(relay, "upload", side_effect=ProviderError("上傳中繼失敗：HTTP 500")):
            code, _, err = self.run_main("--upload", "--quiet")
        self.assertEqual(code, 1)
        self.assertIn("HTTP 500", err)

    def test_write_local_calls_store(self):
        # 服務狀態會連網：測試一律換掉
        with mock.patch.object(local_store, "write_snapshot") as write, \
             mock.patch.object(cli.service_status, "update_safely"):
            self.run_main("--write-local", "--quiet")
        self.assertEqual(write.call_args.args[0]["schema_version"], SCHEMA_VERSION)


if __name__ == "__main__":
    unittest.main()
