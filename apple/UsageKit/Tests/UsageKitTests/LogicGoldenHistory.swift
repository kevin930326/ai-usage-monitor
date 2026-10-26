import Foundation
@testable import UsageKit

// golden.json 的額度歷史與 Token 統計部分（ADR-0015 第 4 節，Windows App 階段 2、3）。
// 欄位名稱即 golden.json 的鍵；C# 的 windows/tests/UsageCore.Tests/LogicGoldenHistory.cs 照同樣的名稱與四捨五入輸出。
// 時間一律輸出 Unix 秒（四捨五入到整數）、日期輸出 YYYY-MM-DD、浮點四捨五入到 9 位小數。

/// 任意 JSON 值（輸出用）。物件的鍵由 encoder 的 `.sortedKeys` 排序。
enum JSONValue: Encodable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var c = encoder.singleValueContainer()
            try c.encodeNil()
        case let .bool(v):
            var c = encoder.singleValueContainer()
            try c.encode(v)
        case let .int(v):
            var c = encoder.singleValueContainer()
            try c.encode(v)
        case let .double(v):
            var c = encoder.singleValueContainer()
            try c.encode(v)
        case let .string(v):
            var c = encoder.singleValueContainer()
            try c.encode(v)
        case let .array(v):
            var c = encoder.unkeyedContainer()
            for item in v { try c.encode(item) }
        case let .object(v):
            var c = encoder.container(keyedBy: Key.self)
            for (k, item) in v { try c.encode(item, forKey: Key(stringValue: k)) }
        }
    }
}

extension LogicGoldenTests {
    // MARK: - 輸入（Token 統計）

    struct TokenCase: Decodable {
        var name: String
        var now: Date
        var timeZone: String?
        var data: TokenInput

        enum CodingKeys: String, CodingKey {
            case name, now, data
            case timeZone = "time_zone"
        }
    }

    struct TokenInput: Decodable {
        var days: [DayInput]
        var hours: [HourInput]?
        var records: [String: RecordInput]?
        var recordDays: [String: [String: Int64]]?
        var retentionDays: Int?
        var dataFrom: String?
        var devices: [DeviceInput]?
        var uploadStatus: String?

        enum CodingKeys: String, CodingKey {
            case days, hours, records, devices
            case recordDays = "record_days"
            case retentionDays = "retention_days"
            case dataFrom = "data_from"
            case uploadStatus = "upload_status"
        }
    }

    struct CountsInput: Decodable {
        var input: Int64?
        var cacheWrite: Int64?
        var cacheRead: Int64?
        var output: Int64?
        var reasoning: Int64?

        enum CodingKeys: String, CodingKey {
            case input, output, reasoning
            case cacheWrite = "cache_write"
            case cacheRead = "cache_read"
        }

        var counts: TokenCounts {
            TokenCounts(input: input ?? 0, cacheWrite: cacheWrite ?? 0, cacheRead: cacheRead ?? 0, output: output ?? 0, reasoning: reasoning ?? 0)
        }
    }

    struct DayInput: Decodable {
        var day: String
        var provider: String
        var model: String
        var counts: CountsInput
        var taskCount: Int?
        var taskSeconds: Int?
        var longestTaskSeconds: Int?
        var device: String?

        enum CodingKeys: String, CodingKey {
            case day, provider, model, counts, device
            case taskCount = "task_count"
            case taskSeconds = "task_seconds"
            case longestTaskSeconds = "longest_task_seconds"
        }
    }

    struct HourInput: Decodable {
        var day: String
        var hour: Int
        var provider: String
        var model: String
        var counts: CountsInput
    }

    struct RecordInput: Decodable {
        var value: Int64
        var day: String?
    }

    struct DeviceInput: Decodable {
        var id: String
        var name: String
        var lastUpload: Date?
        var revoked: Bool?
        var isSelf: Bool?

        enum CodingKeys: String, CodingKey {
            case id, name, revoked
            case lastUpload = "last_upload"
            case isSelf = "is_self"
        }
    }

    // MARK: - 共用

    static func calendar(_ identifier: String?) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: identifier ?? "UTC")!
        return c
    }

    static func time(_ date: Date) -> JSONValue { .int(Int64(date.timeIntervalSince1970.rounded())) }
    static func number(_ x: Double) -> JSONValue { .double(round9(x)) }
    static func optional<T>(_ value: T?, _ make: (T) -> JSONValue) -> JSONValue { value.map(make) ?? .null }
    static func record(_ r: TokenRecord?) -> JSONValue {
        optional(r) { .object(["value": .int($0.value), "day": optional($0.day) { .string($0) }]) }
    }

    // MARK: - 額度歷史

    static func historyOutput(_ c: Case, snapshot: UsageSnapshot, history: QuotaHistory) -> JSONValue {
        let now = c.now
        let calendar = calendar(c.timeZone)
        let suggestion = optional(NextProviderSuggestion(snapshot: snapshot, now: now)) { s in
            .object(["provider": .string(s.provider), "window": .string(s.window.id), "remaining_pct": number(s.remainingPct),
                     "exhausted_provider": .string(s.exhaustedProvider)])
        }
        let upcoming = UpcomingReset.list(snapshot: snapshot, now: now).map { r -> JSONValue in
            .object(["key": .string("\(r.provider)/\(r.window.id)"), "resets_at": time(r.resetsAt), "position": number(r.position),
                     "just_reset": .bool(r.justReset)])
        }
        let awaiting = UpcomingReset.awaitingStart(snapshot: snapshot).map { JSONValue.string($0.key) }
        let forecasts = WeeklyForecast.list(snapshot: snapshot, history: history, now: now).map { f -> JSONValue in
            var o: [String: JSONValue] = [
                "key": .string("\(f.provider)/\(f.window.id)"), "resets_at": time(f.resetsAt), "uses_recent_rate": .bool(f.usesRecentRate),
                "runs_out_at": .null, "day_part": .null,
            ]
            switch f.outcome {
            case let .runsOut(at):
                o["outcome"] = .string("runs_out")
                o["runs_out_at"] = time(at)
                o["day_part"] = .string(WeeklyForecast.dayPart(at, calendar: calendar))
            case .lastsUntilReset:
                o["outcome"] = .string("lasts_until_reset")
            case .notEnoughData:
                o["outcome"] = .string("not_enough_data")
            }
            return .object(o)
        }
        var trends: [JSONValue] = []
        var consumption: [JSONValue] = []
        // 走勢與額度消耗只在有歷史輸入的情境輸出（其他情境整段都是「沒有紀錄」，沒有比對的價值）
        if !(c.samples ?? []).isEmpty || !(c.runs ?? []).isEmpty {
            for key in snapshot.orderedProviderKeys {
                guard let p = snapshot.providers[key], p.error == nil else { continue }
                for w in p.visibleWindows {
                    let trend = QuotaTrend(provider: key, window: w, history: history, now: now)
                    trends.append(.object([
                        "key": .string("\(key)/\(w.id)"),
                        "start": time(trend.span.start), "end": time(trend.span.end),
                        "points": .array(trend.points.map { .array([time($0.ts), number($0.remainingPct)]) }),
                        "gaps": .array(trend.gaps.map { .array([time($0.start), time($0.end)]) }),
                        "has_enough_data": .bool(trend.hasEnoughData),
                        "expected_now": number(trend.expectedRemaining(at: now)),
                    ]))
                }
            }
            let keys = Set(history.samples.map { "\($0.provider)/\($0.windowID)" }).sorted()
            for key in keys {
                let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
                let q = QuotaConsumption(provider: parts[0], windowID: parts[1], history: history, now: now, calendar: calendar)
                consumption.append(.object([
                    "key": .string(key),
                    "sample_count": .int(Int64(q.sampleCount)),
                    "has_enough_data": .bool(q.hasEnoughData),
                    "peak": number(q.peak),
                    "starts": .array(q.hours.map { time($0.start) }),
                    "consumed": .array(q.hours.map { optional($0.consumed, number) }),
                    "estimated": .array(q.hours.map { .bool($0.estimated) }),
                    "levels": .array(q.hours.map { .int(Int64(q.level($0.consumed ?? 0))) }),
                    "daily": .array(q.dailyTotals.map { d in
                        .object(["start": time(d.start), "consumed": optional(d.consumed, number), "estimated": .bool(d.estimated)])
                    }),
                ]))
            }
        }
        return .object([
            "suggestion": suggestion, "upcoming_resets": .array(upcoming), "awaiting_start": .array(awaiting),
            "weekly_forecast": .array(forecasts), "trends": .array(trends), "consumption": .array(consumption),
        ])
    }

    // MARK: - Token 統計

    /// 熱力圖的週數（面板是 22 週；golden 用 8 週，檔案小一些，規則相同）
    static let heatmapWeeks = 8

    static func tokenCaseOutput(_ c: TokenCase) -> JSONValue {
        let calendar = calendar(c.timeZone)
        let now = c.now
        let input = c.data
        let upload = input.uploadStatus
        let devices = TokenDevices(
            devices: (input.devices ?? []).map {
                TokenDevice(id: $0.id, name: $0.name, lastUpload: $0.lastUpload, revoked: $0.revoked ?? false, isSelf: $0.isSelf ?? false)
            },
            uploadRevoked: upload == "revoked", uploadCopied: upload == "copied")
        let data = TokenStatsData(
            days: input.days.map {
                TokenDayRow(day: $0.day, provider: $0.provider, model: $0.model, counts: $0.counts.counts, taskCount: $0.taskCount ?? 0,
                            taskSeconds: $0.taskSeconds ?? 0, longestTaskSeconds: $0.longestTaskSeconds ?? 0, device: $0.device ?? TokenDevices.local)
            },
            hours: (input.hours ?? []).map { TokenHourRow(day: $0.day, hour: $0.hour, provider: $0.provider, model: $0.model, counts: $0.counts.counts) },
            records: (input.records ?? [:]).mapValues { TokenRecord(value: $0.value, day: $0.day) },
            recordDays: input.recordDays ?? [:],
            firstScanDone: true, retentionDays: input.retentionDays ?? 365, dataFrom: input.dataFrom, devices: devices)

        var scopes: [String: JSONValue] = [:]
        for scope in devices.scopes {
            let scoped = data.scoped(scope)
            // 這台電腦：兩種計算方式 × 三個服務範圍；其他裝置範圍只比對主數字的「全部」（規則相同，檔案小一些）
            let full = scope == .thisMac
            var measures: [String: JSONValue] = [:]
            for (name, measure) in full ? [("main", TokenMeasure.main), ("cached", .includingCacheRead)] : [("main", .main)] {
                let measured = scoped.measured(measure)
                var blocks: [String: JSONValue] = [:]
                for tokenScope in full ? TokenScope.allCases : [.all] {
                    blocks[tokenScope.rawValue] = tokenBlock(measured, scope: tokenScope, now: now, calendar: calendar)
                }
                measures[name] = .object(blocks)
            }
            scopes[scope.rawValue] = .object([
                "has_data": .bool(scoped.hasData),
                "providers": .array(scoped.providers.map { .string($0) }),
                "first_available_day": optional(scoped.firstAvailableDay(now: now, calendar: calendar)) { .string(TokenCalendar.key($0, calendar: calendar)) },
                "measures": .object(measures),
            ])
        }
        let deviceNotes = devices.devices.map { d -> JSONValue in
            .object([
                "id": .string(d.id),
                "stale_note": optional(TokenDevices.staleNote(d, now: now)) { .string($0) },
                "upload_text": .string(TokenDevices.uploadText(d, now: now)),
                "menu_title": d.isSelf ? .null : .string(devices.menuTitle(.device(d.id), now: now)),
            ])
        }
        return .object([
            "name": .string(c.name),
            "has_data": .bool(data.hasData),
            "providers": .array(data.providers.map { .string($0) }),
            "devices": .object([
                "enabled": .bool(devices.enabled),
                "count": .int(Int64(devices.count)),
                "scopes": .array(devices.scopes.map { .string($0.rawValue) }),
                "resolve_none": .string(devices.resolve(nil).rawValue),
                "resolve_missing": .string(devices.resolve(.device("missing-device")).rawValue),
                "resolve_this": .string(devices.resolve(.thisMac).rawValue),
                "notes": .array(deviceNotes),
            ]),
            "scopes": .object(scopes),
        ])
    }

    static func tokenBlock(_ data: TokenStatsData, scope: TokenScope, now: Date, calendar: Calendar) -> JSONValue {
        let s = TokenSummary(data: data, scope: scope, now: now, calendar: calendar)
        func bars(_ range: TokenActivityRange) -> JSONValue {
            let list = TokenActivity.bars(data: data, scope: scope, range: range, now: now, calendar: calendar)
            return .object([
                "start": .string(TokenCalendar.key(list[0].start, calendar: calendar)),
                "values": .array(list.map { .int($0.value) }),
                "available": .array(list.map { .bool($0.available) }),
                "by_provider": .object(["claude", "codex"].reduce(into: [:]) { result, p in
                    result[p] = .array(list.map { .int($0.byProvider[p] ?? 0) })
                }),
            ])
        }
        let heatmap = TokenHeatmap(data: data, scope: scope, now: now, weeks: heatmapWeeks, calendar: calendar)
        return .object([
            "summary": .object([
                "this_week_value": .int(s.thisWeekValue),
                "this_week_main": .int(s.thisWeek.main),
                "last_week_same_period": .int(s.lastWeekSamePeriod),
                "change_pct": optional(s.changePct, number),
                "best_day": record(s.bestDay),
                "longest_task": record(s.longestTaskSeconds),
                "current_streak": .int(Int64(s.currentStreak)),
                "longest_streak": record(s.longestStreak),
                "total": record(s.total),
                "streak_is_record": .bool(s.streakIsRecord),
            ]),
            "days30": bars(.days30),
            "weeks": bars(.weeks),
            "cumulative": bars(.cumulative),
            "heatmap": .object([
                "first_monday": .string(TokenCalendar.key(heatmap.firstMonday, calendar: calendar)),
                "cells": .array(heatmap.cells.map { optional($0) { .int($0) } }),
                "thresholds": .array(heatmap.thresholds.map { .int($0) }),
                "truncated": .bool(heatmap.truncated),
            ]),
            "models": .array(TokenBreakdown.models(data: data, scope: scope).map {
                .object(["id": .string($0.id), "value": .int($0.counts.value(data.measure))])
            }),
            "hours": .array(TokenBreakdown.hours(data: data, scope: scope).map { .int($0) }),
        ])
    }
}
