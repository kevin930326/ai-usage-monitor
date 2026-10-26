using System.Text.Json.Nodes;

namespace AIUsageMonitor.Core.Tests;

/// <summary>
/// golden.json 的額度歷史與 Token 統計部分（apple/UsageKit/Tests/UsageKitTests/LogicGoldenHistory.swift 的 C# 版）。
/// 欄位名稱、時間（Unix 秒，四捨五入）、日期（YYYY-MM-DD）與浮點（9 位小數）的輸出都和 Swift 相同。
/// </summary>
internal static class LogicGoldenHistory
{
    /// <summary>熱力圖的週數（同 Swift 的 heatmapWeeks）</summary>
    private const int HeatmapWeeks = 8;

    private static TimeZoneInfo Zone(JsonNode c) => TimeZoneInfo.FindSystemTimeZoneById(c["time_zone"]?.GetValue<string>() ?? "UTC");

    private static JsonNode Time(DateTimeOffset date) => SwiftMath.Round(date.ToUnixTimeMilliseconds() / 1000.0);

    private static JsonNode? Number(double? x) => LogicGoldenTests.Round9(x) is { } v ? JsonValue.Create(v) : null;

    private static JsonArray Array(IEnumerable<JsonNode?> items) => new([.. items]);

    private static JsonNode? Record(TokenRecord? r) => r is null ? null : new JsonObject { ["value"] = r.Value, ["day"] = r.Day };

    // MARK: 額度歷史

    internal static JsonObject History(JsonNode c, UsageSnapshot snapshot, QuotaHistory history, DateTimeOffset now)
    {
        var zone = Zone(c);
        var s = NextProviderSuggestion.From(snapshot, now);
        JsonNode? suggestion = s is null ? null : new JsonObject
        {
            ["provider"] = s.Provider, ["window"] = s.Window.Id, ["remaining_pct"] = Number(s.RemainingPct), ["exhausted_provider"] = s.ExhaustedProvider,
        };
        var upcoming = Array(UpcomingReset.List(snapshot, now).Select(r => (JsonNode)new JsonObject
        {
            ["key"] = $"{r.Provider}/{r.Window.Id}", ["resets_at"] = Time(r.ResetsAt), ["position"] = Number(r.Position), ["just_reset"] = r.JustReset,
        }));
        var awaiting = Array(UpcomingReset.AwaitingStart(snapshot).Select(p => (JsonNode)JsonValue.Create(p.Key)));
        var forecasts = Array(WeeklyForecast.List(snapshot, history, now).Select(f => (JsonNode)new JsonObject
        {
            ["key"] = $"{f.Provider}/{f.Window.Id}",
            ["resets_at"] = Time(f.ResetsAt),
            ["uses_recent_rate"] = f.UsesRecentRate,
            ["outcome"] = f.Result switch
            {
                WeeklyForecast.Outcome.RunsOut => "runs_out",
                WeeklyForecast.Outcome.LastsUntilReset => "lasts_until_reset",
                _ => "not_enough_data",
            },
            ["runs_out_at"] = f.RunsOutAt is { } at ? Time(at) : null,
            ["day_part"] = f.RunsOutAt is { } d ? WeeklyForecast.DayPart(d, zone) : null,
        }));
        var trends = new JsonArray();
        var consumption = new JsonArray();
        if (c["samples"] is JsonArray { Count: > 0 } || c["runs"] is JsonArray { Count: > 0 })
        {
            foreach (var key in snapshot.OrderedProviderKeys)
            {
                var p = snapshot.Providers[key];
                if (p.Error is not null) continue;
                foreach (var w in p.VisibleWindows)
                {
                    var trend = new QuotaTrend(key, w, history, now);
                    trends.Add(new JsonObject
                    {
                        ["key"] = $"{key}/{w.Id}",
                        ["start"] = Time(trend.Span.Start),
                        ["end"] = Time(trend.Span.End),
                        ["points"] = Array(trend.Points.Select(pt => (JsonNode)Array([Time(pt.Ts), Number(pt.RemainingPct)]))),
                        ["gaps"] = Array(trend.Gaps.Select(g => (JsonNode)Array([Time(g.Start), Time(g.End)]))),
                        ["has_enough_data"] = trend.HasEnoughData,
                        ["expected_now"] = Number(trend.ExpectedRemaining(now)),
                    });
                }
            }
            var keys = history.Samples.Select(x => $"{x.Provider}/{x.WindowId}").Distinct().Order(StringComparer.Ordinal);
            foreach (var key in keys)
            {
                var parts = key.Split('/', 2);
                var q = new QuotaConsumption(parts[0], parts[1], history, now, zone);
                consumption.Add(new JsonObject
                {
                    ["key"] = key,
                    ["sample_count"] = q.SampleCount,
                    ["has_enough_data"] = q.HasEnoughData,
                    ["peak"] = Number(q.Peak),
                    ["starts"] = Array(q.Hours.Select(h => Time(h.Start))),
                    ["consumed"] = Array(q.Hours.Select(h => Number(h.Consumed))),
                    ["estimated"] = Array(q.Hours.Select(h => (JsonNode)h.Estimated)),
                    ["levels"] = Array(q.Hours.Select(h => (JsonNode)q.Level(h.Consumed ?? 0))),
                    ["daily"] = Array(q.DailyTotals.Select(d => (JsonNode)new JsonObject
                    {
                        ["start"] = Time(d.Start), ["consumed"] = Number(d.Consumed), ["estimated"] = d.Estimated,
                    })),
                });
            }
        }
        return new JsonObject
        {
            ["suggestion"] = suggestion, ["upcoming_resets"] = upcoming, ["awaiting_start"] = awaiting,
            ["weekly_forecast"] = forecasts, ["trends"] = trends, ["consumption"] = consumption,
        };
    }

    // MARK: Token 統計

    private static TokenCounts Counts(JsonNode? n) => new(
        n?["input"]?.GetValue<long>() ?? 0, n?["cache_write"]?.GetValue<long>() ?? 0, n?["cache_read"]?.GetValue<long>() ?? 0,
        n?["output"]?.GetValue<long>() ?? 0, n?["reasoning"]?.GetValue<long>() ?? 0);

    internal static JsonObject TokenCase(JsonNode c)
    {
        var zone = Zone(c);
        var now = LogicGoldenTests.Parse(c["now"]!.GetValue<string>());
        var input = c["data"]!;
        var upload = input["upload_status"]?.GetValue<string>();
        var devices = new TokenDevices(
            (input["devices"]?.AsArray() ?? []).Select(d => new TokenDevice(
                d!["id"]!.GetValue<string>(), d["name"]!.GetValue<string>(),
                d["last_upload"] is JsonValue lu ? LogicGoldenTests.Parse(lu.GetValue<string>()) : null,
                d["revoked"]?.GetValue<bool>() ?? false, d["is_self"]?.GetValue<bool>() ?? false)).ToList(),
            upload == "revoked", upload == "copied");
        var recordDays = new Dictionary<string, IReadOnlyDictionary<string, long>>();
        if (input["record_days"] is JsonObject rd)
        {
            foreach (var (day, map) in rd) recordDays[day] = map!.AsObject().ToDictionary(p => p.Key, p => p.Value!.GetValue<long>());
        }
        var data = new TokenStatsData
        {
            Days = input["days"]!.AsArray().Select(d => new TokenDayRow(
                d!["day"]!.GetValue<string>(), d["provider"]!.GetValue<string>(), d["model"]!.GetValue<string>(), Counts(d["counts"]),
                d["task_count"]?.GetValue<int>() ?? 0, d["task_seconds"]?.GetValue<int>() ?? 0, d["longest_task_seconds"]?.GetValue<int>() ?? 0,
                d["device"]?.GetValue<string>() ?? TokenDevices.Local)).ToList(),
            Hours = (input["hours"]?.AsArray() ?? []).Select(h => new TokenHourRow(
                h!["day"]!.GetValue<string>(), h["hour"]!.GetValue<int>(), h["provider"]!.GetValue<string>(), h["model"]!.GetValue<string>(),
                Counts(h["counts"]))).ToList(),
            Records = (input["records"]?.AsObject() ?? []).ToDictionary(
                p => p.Key, p => new TokenRecord(p.Value!["value"]!.GetValue<long>(), p.Value["day"]?.GetValue<string>())),
            RecordDays = recordDays,
            FirstScanDone = true,
            RetentionDays = input["retention_days"]?.GetValue<int>() ?? 365,
            DataFrom = input["data_from"]?.GetValue<string>(),
            Devices = devices,
        };

        var scopes = new JsonObject();
        foreach (var scope in devices.Scopes)
        {
            var scoped = data.Scoped(scope);
            // 這台電腦：兩種計算方式 × 三個服務範圍；其他裝置範圍只比對主數字的「全部」（同 Swift）
            var full = scope == TokenDeviceScope.ThisComputer;
            var measures = new JsonObject();
            foreach (var (name, measure) in full
                         ? new[] { ("main", TokenMeasure.Main), ("cached", TokenMeasure.IncludingCacheRead) }
                         : [("main", TokenMeasure.Main)])
            {
                var measured = scoped.Measured(measure);
                var blocks = new JsonObject();
                foreach (var tokenScope in full ? TokenScopes.AllCases : [TokenScope.All])
                {
                    blocks[tokenScope.RawValue()] = TokenBlock(measured, tokenScope, now, zone);
                }
                measures[name] = blocks;
            }
            scopes[scope.RawValue] = new JsonObject
            {
                ["has_data"] = scoped.HasData,
                ["providers"] = Array(scoped.Providers.Select(p => (JsonNode)JsonValue.Create(p))),
                ["first_available_day"] = scoped.FirstAvailableDay(now, zone) is { } f ? LocalCalendar.Key(f) : null,
                ["measures"] = measures,
            };
        }
        return new JsonObject
        {
            ["name"] = c["name"]!.GetValue<string>(),
            ["has_data"] = data.HasData,
            ["providers"] = Array(data.Providers.Select(p => (JsonNode)JsonValue.Create(p))),
            ["devices"] = new JsonObject
            {
                ["enabled"] = devices.Enabled,
                ["count"] = devices.Count,
                ["scopes"] = Array(devices.Scopes.Select(x => (JsonNode)JsonValue.Create(x.RawValue))),
                ["resolve_none"] = devices.Resolve(null).RawValue,
                ["resolve_missing"] = devices.Resolve(TokenDeviceScope.Device("missing-device")).RawValue,
                ["resolve_this"] = devices.Resolve(TokenDeviceScope.ThisComputer).RawValue,
                ["notes"] = Array(devices.Devices.Select(d => (JsonNode)new JsonObject
                {
                    ["id"] = d.Id,
                    ["stale_note"] = TokenDevices.StaleNote(d, now),
                    ["upload_text"] = TokenDevices.UploadText(d, now),
                    ["menu_title"] = d.IsSelf ? null : devices.MenuTitle(TokenDeviceScope.Device(d.Id), now),
                })),
            },
            ["scopes"] = scopes,
        };
    }

    private static JsonObject TokenBlock(TokenStatsData data, TokenScope scope, DateTimeOffset now, TimeZoneInfo zone)
    {
        var s = new TokenSummary(data, scope, now, zone);
        JsonObject Bars(TokenActivityRange range)
        {
            var list = TokenActivity.Bars(data, scope, range, now, zone);
            return new JsonObject
            {
                ["start"] = LocalCalendar.Key(list[0].Start),
                ["values"] = Array(list.Select(b => (JsonNode)b.Value)),
                ["available"] = Array(list.Select(b => (JsonNode)b.Available)),
                ["by_provider"] = new JsonObject
                {
                    ["claude"] = Array(list.Select(b => (JsonNode)b.ByProvider.GetValueOrDefault("claude"))),
                    ["codex"] = Array(list.Select(b => (JsonNode)b.ByProvider.GetValueOrDefault("codex"))),
                },
            };
        }
        var heatmap = new TokenHeatmap(data, scope, now, zone, HeatmapWeeks);
        return new JsonObject
        {
            ["summary"] = new JsonObject
            {
                ["this_week_value"] = s.ThisWeekValue,
                ["this_week_main"] = s.ThisWeek.Main,
                ["last_week_same_period"] = s.LastWeekSamePeriod,
                ["change_pct"] = Number(s.ChangePct),
                ["best_day"] = Record(s.BestDay),
                ["longest_task"] = Record(s.LongestTaskSeconds),
                ["current_streak"] = s.CurrentStreak,
                ["longest_streak"] = Record(s.LongestStreak),
                ["total"] = Record(s.Total),
                ["streak_is_record"] = s.StreakIsRecord,
            },
            ["days30"] = Bars(TokenActivityRange.Days30),
            ["weeks"] = Bars(TokenActivityRange.Weeks),
            ["cumulative"] = Bars(TokenActivityRange.Cumulative),
            ["heatmap"] = new JsonObject
            {
                ["first_monday"] = LocalCalendar.Key(heatmap.FirstMonday),
                ["cells"] = Array(heatmap.Cells.Select(v => v is { } x ? JsonValue.Create(x) : null)),
                ["thresholds"] = Array(heatmap.Thresholds.Select(v => (JsonNode)v)),
                ["truncated"] = heatmap.Truncated,
            },
            ["models"] = Array(TokenBreakdown.Models(data, scope).Select(m => (JsonNode)new JsonObject
            {
                ["id"] = m.Id, ["value"] = m.Counts.Value(data.Measure),
            })),
            ["hours"] = Array(TokenBreakdown.Hours(data, scope).Select(v => (JsonNode)v)),
        };
    }
}
