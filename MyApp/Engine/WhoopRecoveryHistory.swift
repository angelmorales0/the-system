import Foundation

/// WHOOP cycles, recoveries, sleeps, and workouts as `RecoveryDay` rows for the REC stat.
/// One row per cycle, keyed by the local day its main sleep ended (the day you woke up). Naps are skipped.
/// Bedtime and wake time are minutes from that day's local midnight, so a 23:00 bedtime is -60.
enum WhoopRecovery {
    /// A cycle that starts at or after this local hour started with a bedtime, not with a wake-up.
    static let eveningStartHour = 15

    /// Up to `days` days back from `now`, oldest first. The status says what happened.
    /// `zone` nil uses the phone's current time zone.
    static func history(start: Date, end: Date, zone: TimeZone? = nil) async -> (days: [RecoveryDay], status: String) {
        let zone = zone ?? QuestDay.timeZone
        guard WhoopClient.configured else { return ([], "not configured") }
        guard let token = await OAuthClient.accessToken(.whoop) else { return ([], "token refresh failed") }
        async let cycles = WhoopClient.recordsChecked(token, "/v2/cycle", start, end)
        async let recoveries = WhoopClient.recordsChecked(token, "/v2/recovery", start, end)
        async let sleeps = WhoopClient.recordsChecked(token, "/v2/activity/sleep", start, end)
        async let workouts = WhoopClient.recordsChecked(token, "/v2/activity/workout", start, end)
        let (cycleRead, recoveryRead, sleepRead, workoutRead) = await (cycles, recoveries, sleeps, workouts)
        if cycleRead.records.isEmpty { return ([], "request failed or no data") }
        // One collection did not answer in full: rows without their sleep or recovery must not replace the saved ones.
        guard cycleRead.complete, recoveryRead.complete, sleepRead.complete, workoutRead.complete else { return ([], "partial") }
        return (days(cycles: cycleRead.records, recoveries: recoveryRead.records, sleeps: sleepRead.records, workouts: workoutRead.records, zone: zone), "ok")
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
        var starts: [String: Date] = [:]
        var keyedBySleep = Set<String>()
        for cycle in cycles {
            guard let start = time(cycle["start"]), let key = id(cycle["id"]) else { continue }
            var day = RecoveryDay(dayKey: OnDeviceTime.dayKey(start, zone: zone))
            // A cycle with no end is still in progress: its strain so far is not the day's strain,
            // and a morning's low value would read as a rest day.
            day.dayStrain = time(cycle["end"]) == nil ? nil : cycle["score"]?["strain"]?.doubleValue
            if byCycle[key] == nil { order.append(key) }
            starts[key] = start
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
            guard let key = id(sleep["cycle_id"]), var day = byCycle[key] else { continue }
            // The row is the day the player woke up on. A WHOOP cycle starts with its sleep, so a 23:00 bedtime
            // would put the cycle on the day before, and two nights could land on one day and drop one.
            // A sleep that has no score yet still has its times, so it still names the day.
            if let end = time(sleep["end"]) {
                day.dayKey = OnDeviceTime.dayKey(end, zone: zone)
                keyedBySleep.insert(key)
            }
            if let score = sleep["score"], score.objectValue != nil {
                day.sleepNeedPct = score["sleep_performance_percentage"]?.doubleValue
                day.sleepConsistencyPct = score["sleep_consistency_percentage"]?.doubleValue
                day.sleepEfficiencyPct = score["sleep_efficiency_percentage"]?.doubleValue
                day.sleepDebtMinutes = score["sleep_needed"]?["need_from_sleep_debt_milli"]?.doubleValue.map { $0 / 60_000 }
                if let midnight = OnDeviceTime.dayBounds(day.dayKey, zone: zone)?.start {
                    if let start = time(sleep["start"]) { day.bedtimeMinutes = start.timeIntervalSince(midnight) / 60 }
                    if let end = time(sleep["end"]) { day.wakeMinutes = end.timeIntervalSince(midnight) / 60 }
                }
            }
            byCycle[key] = day
        }
        // A cycle with no sleep record has only its start. One that started in the afternoon or evening started
        // with a bedtime, so its day is the next one: on its start day it would take the place of the cycle before.
        for (key, start) in starts where !keyedBySleep.contains(key) {
            guard OnDeviceTime.calendar(zone).component(.hour, from: start) >= eveningStartHour,
                  let next = OnDeviceTime.calendar(zone).date(byAdding: .day, value: 1, to: start) else { continue }
            byCycle[key]?.dayKey = OnDeviceTime.dayKey(next, zone: zone)
        }
        // Workouts carry no cycle id. Count them on the local day they started.
        var workoutsByDay: [String: Int] = [:]
        for workout in workouts {
            if let start = time(workout["start"]) { workoutsByDay[OnDeviceTime.dayKey(start, zone: zone), default: 0] += 1 }
        }
        // WHOOP lists newest first. The first cycle seen on a day wins, but a row with its sleep beats one without.
        var byDay: [String: RecoveryDay] = [:]
        for key in order {
            guard var day = byCycle[key] else { continue }
            if let kept = byDay[day.dayKey], kept.sleepNeedPct != nil || day.sleepNeedPct == nil { continue }
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
            // Both cycles are over: WHOOP gives a finished cycle its end.
            .object(["id": .number(2), "start": .string("2026-10-23T14:05:00Z"), "end": .string("2026-10-24T14:00:00Z"), "score": .object(["strain": .number(12.4)])]),
            .object(["id": .number(1), "start": .string("2026-10-22T13:50:00Z"), "end": .string("2026-10-23T14:05:00Z"), "score": .object(["strain": .number(7.1)])]),
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

        // A cycle starts with its sleep. Bed at 23:00 on Oct 21 and at 23:30 on Oct 22: two nights, two rows, each on
        // the day the player woke up, with the bedtime before midnight. The cycle in progress has no final strain.
        let nightCycles: [JSONValue] = [
            .object(["id": .number(12), "start": .string("2026-10-23T06:30:00Z"), "score": .object(["strain": .number(1.3)])]),
            .object(["id": .number(11), "start": .string("2026-10-22T06:00:00Z"), "end": .string("2026-10-23T06:30:00Z"), "score": .object(["strain": .number(11.2)])]),
        ]
        let nightSleeps: [JSONValue] = [
            .object(["cycle_id": .number(12), "nap": .bool(false), "start": .string("2026-10-23T06:30:00Z"), "end": .string("2026-10-23T14:00:00Z"),
                     "score": .object(["sleep_performance_percentage": .number(90)])]),
            .object(["cycle_id": .number(11), "nap": .bool(false), "start": .string("2026-10-22T06:00:00Z"), "end": .string("2026-10-22T14:00:00Z"),
                     "score": .object(["sleep_performance_percentage": .number(85)])]),
        ]
        let nights = days(cycles: nightCycles, recoveries: [], sleeps: nightSleeps, workouts: [], zone: zone)
        if nights.map(\.dayKey) != ["2026-10-22", "2026-10-23"] || nights.first?.bedtimeMinutes != -60 || nights.last?.bedtimeMinutes != -30
            || nights.first?.dayStrain != 11.2 || nights.last?.dayStrain != nil {
            errors.append("a cycle that starts at bedtime should give a row on the wake day, and an open cycle no strain, got \(nights)")
        }
        // The same nights, but the first night's sleep has no score: its row stays on its wake day and no night is lost.
        var unscored = nightSleeps
        unscored[1] = .object(["cycle_id": .number(11), "nap": .bool(false), "start": .string("2026-10-22T06:00:00Z"), "end": .string("2026-10-22T14:00:00Z")])
        let kept = days(cycles: nightCycles, recoveries: [], sleeps: unscored, workouts: [], zone: zone)
        let noRecord = days(cycles: nightCycles, recoveries: [], sleeps: [nightSleeps[0]], workouts: [], zone: zone)
        if kept.map(\.dayKey) != ["2026-10-22", "2026-10-23"] || kept.first?.dayStrain != 11.2 || kept.last?.sleepNeedPct != 90
            || noRecord.map(\.dayKey) != ["2026-10-22", "2026-10-23"] || noRecord.last?.sleepNeedPct != 90 {
            errors.append("a night with no sleep score or no sleep record should keep its own day, got \(kept.map(\.dayKey)) \(noRecord.map(\.dayKey))")
        }
        return errors
    }
}
