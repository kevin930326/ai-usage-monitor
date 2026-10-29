import io
import json
import os
import stat
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

from usage_collector import service_status
from usage_collector.models import ProviderError

NOW = datetime(2026, 10, 24, 3, 0, tzinfo=timezone.utc)
STATUS_FIXTURES = Path(__file__).resolve().parent / "fixtures" / "status"


def summary(indicator="none", components=(), incidents=()):
    """假的 Statuspage summary.json（只有用到的欄位，加上一些不該保留的欄位）"""
    return {
        "page": {"id": "x", "name": "Fake", "url": "https://example.invalid"},
        "status": {"indicator": indicator, "description": "All Systems Operational" if indicator == "none" else "Partial outage"},
        "components": [{"id": str(i), "name": n, "status": s, "description": "secret-ish text", "group": False}
                       for i, (n, s) in enumerate(components)],
        "incidents": [{"id": str(i), "name": n, "status": st, "impact": imp, "shortlink": "https://stspg.io/x",
                       "incident_updates": [{"body": "long body text that must not be stored"}]}
                      for i, (n, st, imp) in enumerate(incidents)],
    }


class ParseTest(unittest.TestCase):
    def test_keeps_only_needed_fields(self):
        data = service_status.parse("claude", summary(
            "major",
            components=[("claude.ai", "operational"), ("Claude Code", "partial_outage"),
                        ("Claude API (api.anthropic.com)", "degraded_performance")],
            incidents=[("Elevated errors on Claude Code", "investigating", "major"), ("Old one", "resolved", "minor")]))
        self.assertEqual(data["indicator"], "major")
        self.assertEqual(data["components"], [
            {"name": "Claude Code", "status": "partial_outage", "related": True},
            {"name": "Claude API (api.anthropic.com)", "status": "degraded_performance", "related": True},
        ])
        self.assertEqual(data["incidents"], [{"name": "Elevated errors on Claude Code", "impact": "major"}])
        self.assertEqual(data["page"], "https://status.claude.com")
        dumped = json.dumps(data)
        for leaked in ("secret-ish", "long body", "stspg.io", "example.invalid"):
            self.assertNotIn(leaked, dumped)

    def test_unrelated_codex_components(self):
        data = service_status.parse("codex", summary("minor", components=[("Image Generation", "degraded_performance"),
                                                                           ("Codex in ChatGPT Desktop", "major_outage")]))
        self.assertEqual([c["related"] for c in data["components"]], [False, True])

    def test_bad_format_raises_and_items_are_capped(self):
        with self.assertRaises(ProviderError):
            service_status.parse("claude", {"status": {"indicator": "on fire"}})
        with self.assertRaises(ProviderError):
            service_status.parse("claude", [])
        many = summary("minor", components=[(f"C{i} " + "x" * 300, "partial_outage") for i in range(20)])
        data = service_status.parse("claude", many)
        self.assertEqual(len(data["components"]), service_status.MAX_ITEMS)
        self.assertTrue(all(len(c["name"]) <= service_status.MAX_TEXT for c in data["components"]))
        weird = summary("none", components=[("ok", "melting"), (None, "partial_outage")])
        self.assertEqual(service_status.parse("claude", weird)["components"], [])
        # 陣列欄位不是陣列：當成沒有項目
        odd = {"status": {"indicator": "minor"}, "components": 42, "incidents": "x"}
        self.assertEqual(service_status.parse("claude", odd)["components"], [])
        self.assertEqual(service_status.parse("claude", odd)["incidents"], [])


class UpdateTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = Path(self.dir.name) / "service-status.json"
        self.calls = []

        def fake(url, headers, timeout=15, max_bytes=None):
            self.calls.append((url, headers))
            if "openai" in url:
                raise ProviderError("網路錯誤")
            return {"incidents": []} if "incidents" in url else summary()
        self.patch = mock.patch.object(service_status.http, "request_json", side_effect=fake)
        self.patch.start()

    def tearDown(self):
        self.patch.stop()
        self.dir.cleanup()

    def test_writes_private_file_without_credentials(self):
        self.assertTrue(service_status.update(["claude", "codex"], self.path, now=NOW))
        data = json.loads(self.path.read_text())
        self.assertEqual(data["schema_version"], 1)
        self.assertEqual(data["providers"]["claude"]["indicator"], "none")
        self.assertEqual(data["providers"]["codex"]["error"], "網路錯誤")
        self.assertIsNone(data["providers"]["codex"]["indicator"])
        if sys.platform != "win32":  # Windows 沒有 POSIX 權限位元（%LOCALAPPDATA% 的 ACL 只有使用者本人）
            self.assertEqual(stat.S_IMODE(os.stat(self.path).st_mode), 0o600)
        self.assertEqual([c[1] for c in self.calls], [{}, {}, {}])  # 不帶任何標頭（密鑰、cookie）
        # summary.json 失敗的服務不再查事故清單
        self.assertEqual([c[0] for c in self.calls], ["https://status.claude.com/api/v2/summary.json",
                                                      "https://status.claude.com/api/v2/incidents/unresolved.json",
                                                      "https://status.openai.com/api/v2/summary.json"])
        self.assertTrue(data["providers"]["claude"]["incidents_checked"])
        self.assertFalse(data["providers"]["codex"]["incidents_checked"])

    def test_rate_limited_unless_providers_change(self):
        service_status.update(["claude"], self.path, now=NOW)
        self.assertFalse(service_status.update(["claude"], self.path, now=NOW + timedelta(seconds=60)))
        self.assertEqual(len(self.calls), 2)
        self.assertTrue(service_status.update(["claude", "codex"], self.path, now=NOW + timedelta(seconds=61)))
        self.assertTrue(service_status.update(["claude", "codex"], self.path, now=NOW + timedelta(seconds=61 + 240)))
        # 時鐘倒退：照常抓取
        self.assertTrue(service_status.update(["claude", "codex"], self.path, now=NOW - timedelta(hours=1)))

    def test_one_failing_page_does_not_stop_the_other(self):
        for failing, error in (("claude", TimeoutError("timed out /secret")), ("codex", TypeError("bad /secret"))):
            self.calls.clear()

            def fake(url, headers, timeout=15, max_bytes=None, failing=failing, error=error):
                self.calls.append((url, headers))
                if ("claude" if "claude" in url else "codex") == failing:
                    raise error
                return summary("minor", components=[("Codex", "partial_outage")])
            with self.subTest(failing=failing), mock.patch.object(service_status.http, "request_json", side_effect=fake):
                self.path.unlink(missing_ok=True)
                self.assertTrue(service_status.update(["claude", "codex"], self.path, now=NOW))
                data = json.loads(self.path.read_text())["providers"]
                other = "codex" if failing == "claude" else "claude"
                self.assertIsNone(data[failing]["indicator"])
                self.assertEqual(data[failing]["error"], f"狀態頁讀取失敗（{type(error).__name__}）")
                self.assertEqual(data[other]["indicator"], "minor")
                self.assertNotIn("/secret", self.path.read_text())

    def test_unknown_providers_are_ignored(self):
        service_status.update(["claude", "gemini"], self.path, now=NOW)
        self.assertEqual(list(json.loads(self.path.read_text())["providers"]), ["claude"])

    def test_update_safely_logs_class_only(self):
        err = io.StringIO()
        with mock.patch.object(service_status, "_write", side_effect=PermissionError("/secret/path")), redirect_stderr(err):
            service_status.update_safely(["claude"], self.path)
        self.assertIn("PermissionError", err.getvalue())
        self.assertNotIn("/secret/path", err.getvalue())


def incident(i, name, status="investigating", impact="minor", components=None, **extra):
    """假的事故（Statuspage 有 components；incident.io 沒有），加上不該保留的更新內文"""
    data = {"id": i, "name": name, "status": status, "impact": impact, "created_at": "2026-10-24T02:10:00.000Z",
            "started_at": "2026-10-24T02:05:00.000Z", "shortlink": "https://stspg.io/x",
            "incident_updates": [{"body": "long body text that must not be stored"}], **extra}
    if components is not None:
        data["components"] = [{"name": n} for n in components]
    return data


class IncidentsTest(unittest.TestCase):
    def test_claude_keeps_related_or_unlisted(self):
        data = {"incidents": [
            incident("abc123", "Elevated errors on Claude Code", impact="major", components=["Claude Code"]),
            incident("def456", "Console is slow", components=["Claude Console (platform.claude.com)"]),
            incident("ghi789", "Something odd", components=[]),
            incident("../evil", "Bad id", components=["claude.ai"]),
        ]}
        result = service_status.parse_incidents("claude", data)
        self.assertEqual([i["name"] for i in result], ["Elevated errors on Claude Code", "Something odd", "Bad id"])
        self.assertEqual(result[0], {"name": "Elevated errors on Claude Code", "impact": "major",
                                     "url": "https://status.claude.com/incidents/abc123",
                                     "started_at": "2026-10-24T02:05:00Z"})
        self.assertIsNone(result[2]["url"])
        dumped = json.dumps(result)
        for leaked in ("long body", "stspg.io", "evil"):
            self.assertNotIn(leaked, dumped)

    def test_openai_filters_resolved(self):
        data = {"incidents": [
            incident("01J", "Codex errors", started_at=None),
            incident("01K", "Fixed", status="resolved"),
            incident("01L", "Postmortem", status="postmortem"),
            incident("01M", "Resolved but status stale", resolved_at="2026-10-24T02:30:00Z"),
            incident("01N", "Weird API", impact="apocalyptic", started_at="soon", created_at="yesterday"),
        ]}
        result = service_status.parse_incidents("codex", data)
        self.assertEqual(result, [
            {"name": "Codex errors", "impact": "minor", "url": "https://status.openai.com/incidents/01J",
             "started_at": "2026-10-24T02:10:00Z"},
            {"name": "Weird API", "impact": "none", "url": "https://status.openai.com/incidents/01N", "started_at": None},
        ])

    def test_openai_keeps_only_codex_related_names(self):
        names = ["Degraded performance in ChatGPT, Codex, and APIs", "Elevated Responses API errors",
                 "Elevated error rates for Ads POST requests", "Help Center Chat Support Degraded",
                 "Rapid codexy apiary"]
        data = {"incidents": [incident(f"01{n}", name) for n, name in enumerate(names)]}
        result = service_status.parse_incidents("codex", data)
        self.assertEqual([i["name"] for i in result], names[:2])

    def test_chatgpt_only_incidents_do_not_count_for_codex(self):
        """ADR-0018 第 4 節（2026-10-29 決定）：名稱只寫 ChatGPT 的事故不讓 Codex 生病；同時提到 Codex 或 API 的仍然算"""
        data = json.loads((STATUS_FIXTURES / "openai-incidents.json").read_text(encoding="utf-8"))
        result = service_status.parse_incidents("codex", data)
        self.assertEqual([i["name"] for i in result],
                         ["Degraded performance in ChatGPT and Codex", "Increased latency in ChatGPT and the API"])
        self.assertTrue(all("ChatGPT" in i["name"] for i in data["incidents"][:3]))

    def test_names_drop_control_and_format_characters(self):
        data = {"incidents": [incident("01J", "Codex\u202e errors\u200b\x00\n now")]}
        self.assertEqual(service_status.parse_incidents("codex", data)[0]["name"], "Codex errors now")

    def test_bad_format_raises(self):
        for bad in ([], {}, {"incidents": "x"}):
            with self.assertRaises(ProviderError):
                service_status.parse_incidents("codex", bad)

    def test_incident_failure_keeps_summary(self):
        def fake(url, headers, timeout=15, max_bytes=None):
            if "incidents" in url:
                raise TimeoutError("/secret")
            return summary("minor", incidents=[("From summary", "investigating", "minor")])
        with mock.patch.object(service_status.http, "request_json", side_effect=fake):
            result = service_status.fetch("claude")
        self.assertEqual(result["indicator"], "minor")
        self.assertFalse(result["incidents_checked"])
        self.assertEqual(result["incidents"], [{"name": "From summary", "impact": "minor"}])


class AnnotateTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = Path(self.dir.name) / "service-status.json"

    def tearDown(self):
        self.dir.cleanup()

    def write(self, providers, updated=NOW):
        self.path.write_text(json.dumps({"schema_version": 1, "updated_at": service_status.iso_utc(updated),
                                         "providers": providers}))

    def snapshot(self):
        return {"providers": {"claude": {"error": None, "windows": []}, "codex": {"error": "x", "windows": []}}}

    def test_adds_checked_incidents_capped(self):
        items = [{"name": f"Incident {i}", "impact": "major", "url": f"https://status.claude.com/incidents/i{i}",
                  "started_at": "2026-10-24T02:05:00Z"} for i in range(5)]
        items[1]["url"] = "https://evil.example/incidents/x"
        items[2]["started_at"] = "2026-10-24T02:05:00"  # 沒有時區
        self.write({"claude": {"error": None, "incidents_checked": True, "incidents": items},
                    "codex": {"error": None, "incidents_checked": True, "incidents": []}})
        snap = self.snapshot()
        service_status.annotate(snap, self.path, now=NOW + timedelta(minutes=5))
        self.assertEqual(snap["providers"]["claude"]["incidents"], [
            {"name": "Incident 0", "impact": "major", "url": "https://status.claude.com/incidents/i0",
             "started_at": "2026-10-24T02:05:00Z"},
            {"name": "Incident 1", "impact": "major", "started_at": "2026-10-24T02:05:00Z"},
            {"name": "Incident 2", "impact": "major", "url": "https://status.claude.com/incidents/i2"},
        ])
        # 額度收集失敗的服務也放（狀態頁與額度無關），沒有事故時是空陣列
        self.assertEqual(snap["providers"]["codex"]["incidents"], [])

    def test_omits_when_unchecked_failed_stale_or_missing(self):
        cases = [
            ({"claude": {"error": None, "incidents_checked": False, "incidents": [{"name": "x", "impact": "minor"}]}}, NOW),
            ({"claude": {"error": "網路錯誤", "incidents_checked": False, "incidents": []}}, NOW),
            ({"claude": {"error": None, "incidents_checked": True, "incidents": []}}, NOW - timedelta(minutes=20)),
            ({"claude": {"error": None, "incidents_checked": True, "incidents": []}}, NOW + timedelta(minutes=5)),
        ]
        for providers, updated in cases:
            with self.subTest(providers=providers, updated=updated):
                self.write(providers, updated)
                snap = self.snapshot()
                service_status.annotate(snap, self.path, now=NOW)
                self.assertNotIn("incidents", snap["providers"]["claude"])
                self.assertNotIn("incidents", snap["providers"]["codex"])
        self.path.unlink()
        snap = self.snapshot()
        service_status.annotate(snap, self.path, now=NOW)
        self.assertNotIn("incidents", snap["providers"]["claude"])
        self.path.write_text("not json")
        service_status.annotate(snap, self.path, now=NOW)
        self.assertNotIn("incidents", snap["providers"]["claude"])
