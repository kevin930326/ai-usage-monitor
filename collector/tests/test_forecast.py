"""額度預測（ADR-0018）：fixtures/forecast 的 golden 與 Swift、C# 相同；收集器把預測寫進快照，失敗不影響收集。"""
from __future__ import annotations

import json
import math
import sqlite3
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

from usage_collector import forecast, history
from usage_collector.forecast import Sample
from usage_collector.models import parse_iso

FIXTURES = Path(__file__).resolve().parents[2] / "fixtures" / "forecast"


def run_case(case: dict, now: float) -> dict:
    window = case["window"]
    window_resets = window.get("resets_min")
    samples = []
    for s in case["series"]:
        resets = s.get("resets_min", window_resets)
        for t in range(s["from_min"], s["to_min"] + 1, s["every_min"]):
            used = s["start"] + (s["end"] - s["start"]) * (t - s["from_min"]) / (s["to_min"] - s["from_min"])
            samples.append(Sample(now + t * 60, used, None if resets is None else now + resets * 60))
    samples.sort(key=lambda x: x.ts)
    result = forecast.forecast(window["id"], window["used_pct"], None if window_resets is None else now + window_resets * 60,
                               window.get("hidden", False), case.get("stale", False), samples, now)
    named: dict = {"name": case["name"]}
    if result is not None:
        r: dict = {"exhausts_in_min": math.floor((result["exhausts_at"] - now) / 60), "urgent": result["urgent"]}
        if result["faster"] is not None:
            r["faster"] = result["faster"]
        named["result"] = r
    return named


class ForecastGoldenTests(unittest.TestCase):
    def test_matches_golden(self):
        cases = json.loads((FIXTURES / "cases.json").read_text(encoding="utf-8"))
        golden = json.loads((FIXTURES / "golden.json").read_text(encoding="utf-8"))
        now = parse_iso(cases["now"]).timestamp()
        self.assertEqual(len(golden), len(cases["cases"]))
        for case, expected in zip(cases["cases"], golden):
            with self.subTest(case["name"]):
                self.assertEqual(run_case(case, now), expected)


class AnnotateTests(unittest.TestCase):
    NOW = datetime(2026, 10, 28, 12, 0, tzinfo=timezone.utc)

    def snapshot(self, used: float) -> dict:
        return {"updated_at": "2026-10-28T12:00:00Z", "providers": {
            "claude": {"plan": None, "error": None, "windows": [
                {"id": "five_hour", "label": "5 小時", "used_pct": used, "resets_at": "2026-10-28T15:00:00Z", "hidden": False},
                {"id": "weekly", "label": "每週", "used_pct": 10, "resets_at": "2026-11-01T00:00:00Z", "hidden": False}]},
            "codex": {"plan": None, "error": "讀取失敗", "windows": []}}}

    def test_adds_forecast_from_history_and_current_value(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "history.sqlite3"
            # 過去 50 分鐘每 10 分鐘一筆（40→60），這次收集是 80：近期每小時約 40 點
            for minutes, used in [(-50, 40), (-40, 45), (-30, 50), (-20, 55), (-10, 60)]:
                ts = self.NOW.timestamp() + minutes * 60
                snap = self.snapshot(used)
                snap["updated_at"] = datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                history.record(snap, path, now=datetime.fromtimestamp(ts, timezone.utc))
            snapshot = self.snapshot(80)
            self.assertEqual(forecast.annotate(snapshot, path), 1)
            w = snapshot["providers"]["claude"]["windows"]
            self.assertTrue(w[0]["forecast"]["urgent"])
            self.assertLess(parse_iso(w[0]["forecast"]["exhausts_at"]), parse_iso(w[0]["resets_at"]))
            self.assertNotIn("faster", w[0]["forecast"])  # 沒有過去 7 天的資料
            self.assertNotIn("forecast", w[1])  # 每週額度資料不足：不猜

    def test_missing_or_broken_history_adds_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            snapshot = self.snapshot(80)
            self.assertEqual(forecast.annotate(snapshot, Path(tmp) / "none.sqlite3"), 0)
            self.assertNotIn("forecast", snapshot["providers"]["claude"]["windows"][0])
            broken = Path(tmp) / "broken.sqlite3"
            broken.write_bytes(b"not a database")
            with self.assertRaises(sqlite3.DatabaseError):
                forecast.annotate(snapshot, broken)
            forecast.annotate_safely(snapshot, broken)  # 不丟例外
            self.assertFalse(broken.with_name("broken.sqlite3-wal").exists())  # 唯讀：不建 WAL


if __name__ == "__main__":
    unittest.main()
