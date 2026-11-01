import Foundation

/// WHOOP cycles, recoveries, sleeps, and workouts as `RecoveryDay` rows for the REC stat.
/// One row per cycle, keyed by the local day the cycle started (the day you woke up). Naps are skipped.
/// Bedtime and wake time are minutes from that day's local midnight, so a 23:00 bedtime is -60.
enum WhoopRecovery {
    /// Up to `days` days back from `now`, oldest first. The status says what happened.
    /// `zone` nil uses the phone's current time zone.
    static func history(start: Date, end: Date, zone: TimeZone? = nil) async -> (days: [RecoveryDay], status: String) {
        let zone = zone ?? QuestDay.timeZone
        guard WhoopClient.configured else { return ([], "not configured") }
        guard let token = await OAuthClient.accessToken(.whoop) else { return ([], "token refresh failed") }
        async let cycles = WhoopClient.records(token, "/v2/cycle", start, end)
        async let recoveries = WhoopClient.records(token, "/v2/recovery", start, end)
        async let sleeps = WhoopClient.records(token, "/v2/activity/sleep", start, end)
        async let workouts = WhoopClient.records(token, "/v2/activity/workout", start, end)
        let (cycleRecords, recoveryRecords, sleepRecords, workoutRecords) = await (cycles, recoveries, sleeps, workouts)
        if cycleRecords.isEmpty { return ([], "request failed or no data") }
        return (days(cycles: cycleRecords, recoveries: recoveryRecords, sleeps: sleepRecords, workouts: workoutRecords, zone: zone), "ok")
    }

    /// Pure: the four WHOOP collections → one row per local day, oldest first. Nutrition fields stay nil.
    static func days(cycles: [JSONValue], recoveries: [JSONValue], sleeps: [JSONValue], workouts: [JSONValue], zone: TimeZone) -> [RecoveryDay] {
        func id(_ value: JSONValue?) -> String? {
            switch value {
            case .number(let number): "n\(number)"
            case .string(let text): "s\(text)"
            default: nil
            }
        }
        func time(_ value: JSONValue?) -> Date? {
            value?.stringValue.flatMap { OnDeviceTime.parse($0) }
        }

        var byCycle: [String: RecoveryDay] = [:]
        var order: [String] = []
        for cycle in cycles {
            guard let start = time(cycle["start"]), let key = id(cycle["id"]) else { continue }
            var day = RecoveryDay(dayKey: OnDeviceTime.dayKey(start, zone: zone))
            day.dayStrain = cycle["score"]?["strain"]?.doubleValue
            if byCycle[key] == nil { order.append(key) }
            byCycle[key] = day
        }
        for recovery in recoveries {
            guard let key = id(recovery["cycle_id"]), var day = byCycle[key], let score = recovery["score"], score.objectValue != nil else { continue }
            day.hrv = score["hrv_rmssd_milli"]?.doubleValue
            day.restingHr = score["resting_heart_rate"]?.doubleValue
            byCycle[key] = day
        }
        for sleep in sleeps {
            if sleep["nap"].truthy { continue }
            guard let key = id(sleep["cycle_id"]), var day = byCycle[key], let score = sleep["score"], score.objectValue != nil else { continue }
            day.sleepNeedPct = score["sleep_performance_percentage"]?.doubleValue
            day.sleepConsistencyPct = score["sleep_consistency_percentage"]?.doubleValue
            day.sleepEfficiencyPct = score["sleep_efficiency_percentage"]?.doubleValue
            day.sleepDebtMinutes = score["sleep_needed"]?["need_from_sleep_debt_milli"]?.doubleValue.map { $0 / 60_000 }
            if let midnight = OnDeviceTime.dayBounds(day.dayKey, zone: zone)?.start {
                if let start = time(sleep["start"]) { day.bedtimeMinutes = start.timeIntervalSince(midnight) / 60 }
                if let end = time(sleep["end"]) { day.wakeMinutes = end.timeIntervalSince(midnight) / 60 }
            }
            byCycle[key] = day
        }
        // Workouts carry no cycle id. Count them on the local day they started.
        var workoutsByDay: [String: Int] = [:]
        for workout in workouts {
            if let start = time(workout["start"]) { workoutsByDay[OnDeviceTime.dayKey(start, zone: zone), default: 0] += 1 }
        }
        // WHOOP lists newest first. The first cycle seen on a day wins.
        var byDay: [String: RecoveryDay] = [:]
        for key in order {
            guard var day = byCycle[key], byDay[day.dayKey] == nil else { continue }
            day.workoutCount = workoutsByDay[day.dayKey] ?? 0
            byDay[day.dayKey] = day
        }
        return byDay.keys.sorted().compactMap { byDay[$0] }
    }

    // MARK: - Self-check (runs in DEBUG at launch)

    static func check() -> [String] {
        var errors: [String] = []
        let zone = OnDeviceTime.losAngeles
        let cycles: [JSONValue] = [
            .object(["id": .number(2), "start": .string("2026-10-23T14:05:00Z"), "score": .object(["strain": .number(12.4)])]),
            .object(["id": .number(1), "start": .string("2026-10-22T13:50:00Z"), "score": .object(["strain": .number(7.1)])]),
        ]
        let recoveries: [JSONValue] = [
            .object(["cycle_id": .number(2), "score": .object(["recovery_score": .number(71), "hrv_rmssd_milli": .number(62.4), "resting_heart_rate": .number(51)])]),
        ]
        let sleeps: [JSONValue] = [
            .object(["cycle_id": .number(2), "nap": .bool(false), "start": .string("2026-10-23T06:00:00Z"), "end": .string("2026-10-23T14:00:00Z"),
                     "score": .object(["sleep_performance_percentage": .number(88), "sleep_consistency_percentage": .number(81),
                                       "sleep_efficiency_percentage": .number(93), "sleep_needed": .object(["need_from_sleep_debt_milli": .number(1_800_000)])])]),
            .object(["cycle_id": .number(2), "nap": .bool(true), "start": .string("2026-10-23T20:00:00Z"), "end": .string("2026-10-23T20:30:00Z"),
                     "score": .object(["sleep_performance_percentage": .number(10)])]),
        ]
        let workouts: [JSONValue] = [
            .object(["start": .string("2026-10-23T16:00:00Z")]),
            .object(["start": .string("2026-10-23T23:00:00Z")]),
            .object(["start": .string("2026-10-22T16:00:00Z")]),
        ]
        let rows = days(cycles: cycles, recoveries: recoveries, sleeps: sleeps, workouts: workouts, zone: zone)
        guard rows.count == 2, rows[0].dayKey == "2026-10-22", rows[1].dayKey == "2026-10-23" else {
            return ["WHOOP history should give one row per local day, oldest first, got \(rows.map(\.dayKey))"]
        }
        let day = rows[1]
        // 23:00 PDT bedtime the night before is -60; a 07:00 wake is 420. Sleep debt is 30 minutes.
        if day.dayStrain != 12.4 || day.hrv != 62.4 || day.restingHr != 51 || day.sleepNeedPct != 88 || day.sleepConsistencyPct != 81
            || day.sleepEfficiencyPct != 93 || day.sleepDebtMinutes != 30 || day.bedtimeMinutes != -60 || day.wakeMinutes != 420 || day.workoutCount != 2 {
            errors.append("the WHOOP row should carry strain, HRV, RHR, sleep scores, bed and wake times, and the workout count, got \(day)")
        }
        if rows[0].dayStrain != 7.1 || rows[0].hrv != nil || rows[0].sleepNeedPct != nil || rows[0].workoutCount != 1 {
            errors.append("a cycle without recovery or sleep should keep those fields nil, got \(rows[0])")
        }
        if day.proteinG != nil || day.bodyMassKg != nil {
            errors.append("WHOOP rows must not fill nutrition")
        }
        return errors
    }
}
