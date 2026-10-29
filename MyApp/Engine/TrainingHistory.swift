import Foundation

/// Thirty days of training and recovery for the quest planner. Port of backend/history.py.
///
/// The phone reads Hevy, Strava, and WHOOP once per quest day, reduces the feeds to short summaries,
/// and adds them to the morning context as `trainingHistory`. `limitProblems` then rejects a plan that
/// breaks the hard training limits, whatever the model wrote.
/// No tokens, notes, Strava activity names, or GPS traces leave this file.
enum TrainingHistory {
    static let historyDays = 30
    static let cacheSeconds: TimeInterval = 15 * 60
    static let lbPerKg = 2.20462

    // A run counts as a 10K or 5K within GPS rounding, like the app's 50 m tolerance.
    static let tenKMinMeters = 9_950.0
    static let fiveKMinMeters = 4_950.0

    // Hard limits on heavy squat and deadlift work around the running.
    static let heavyShareOfE1rm = 0.80
    static let heavyRepsMax = 6
    static let heavyLowerMaxPer7Days = 2
    static let heavyLowerMinDaysApart = 2
    static let maxTenKsPerDay = 2
    // Running goal: this many km in every 7-day window, today included. Runs come in 5 km steps, at most 20 km a day.
    static let runKmPer7Days = 50
    static let runStepKm = 5
    static let maxRunKmPerDay = 20

    // Fatigue: a lift is declining when its newest session scores under 97% of the better of the two before it.
    static let declineShare = 0.97
    // A deload is due when this many lifts are declining at once, or two are and HRV is 10% under its 30-day average.
    static let deloadDecliningLifts = 3
    static let hrvDropShare = 0.90

    static let heavyLowerPattern = "squat|deadlift"
    static let lowerPattern = "squat|deadlift|lunge|leg press|hip thrust|step up|leg curl|leg extension|calf|romanian|rdl|good morning"
    static let runTypes: Set<String> = ["run", "trailrun", "virtualrun"]

    private static var cache: [String: (at: Date, history: JSONValue)] = [:]

    // MARK: - Building

    /// Training history for the context's quest day. Cached per day and time zone for 15 minutes.
    static func build(context: JSONValue, now: Date = .now) async -> JSONValue {
        let day = context["player"]?["localDate"]?.stringValue ?? ""
        let tz = context["player"]?["timezone"]?.stringValue ?? ""
        let key = "\(day)|\(tz)"
        if let cached = cache[key], now.timeIntervalSince(cached.at) < cacheSeconds { return cached.history }
        let zone = TimeZone(identifier: tz) ?? OnDeviceTime.losAngeles
        guard let today = OnDeviceTime.dayBounds(day, zone: zone)?.start,
              let start = OnDeviceTime.dayBounds(OnDeviceTime.addDays(day, -historyDays), zone: zone)?.start,
              let end = OnDeviceTime.dayBounds(day, zone: zone)?.end else {
            return .object(["sources": .object(["error": .string("bad day")])])
        }
        _ = today
        async let hevy = HevyClient.history(since: start)
        async let strava = StravaClient.history(start: start, end: end)
        async let whoop = WhoopClient.history(start: start, end: end)
        let (workouts, activities, recovery) = await (hevy, strava, whoop)
        var history = summarize(
            today: day,
            zone: zone,
            workouts: workouts.workouts,
            activities: activities.activities,
            whoop: recovery.records,
            goals: context["goals"] ?? .object([:]),
            questDays: context["recentDays"]?.arrayValue ?? []
        ).objectValue ?? [:]
        history["sources"] = .object(["hevy": .string(workouts.status), "strava": .string(activities.status), "whoop": .string(recovery.status)])
        let result = JSONValue.object(history)
        cache[key] = (now, result)
        return result
    }

    // MARK: - Summaries (pure)

    static func summarize(today: String, zone: TimeZone, workouts: [HevyWorkout], activities: [JSONValue], whoop: [String: [JSONValue]],
                          goals: JSONValue, questDays: [JSONValue]) -> JSONValue {
        let lifts = liftSummaries(workouts, today: today, zone: zone)
        let sessions = liftSessions(workouts, lifts: lifts, today: today, zone: zone)
        let runs = runList(activities, today: today, zone: zone)
        let recovery = recoveryDays(whoop, zone: zone)
        let goalKm = goals["runKmPer7Days"]?.doubleValue.map { Int($0) }.flatMap { $0 == 0 ? nil : $0 } ?? runKmPer7Days
        return .object([
            "windowDays": .number(Double(historyDays)),
            "today": .string(today),
            "weekday": .string(weekday(today)),
            "strengthSessions": .array(sessions),
            "lifts": lifts.json,
            "strengthTargets": .array(strengthTargets(goals["strength"]?.arrayValue ?? [], lifts: lifts)),
            "runs": .array(runs),
            "recovery": .array(recovery),
            "week": weekSummary(runs: runs, sessions: sessions, questDays: questDays),
            "runWindow": runWindow(runs, goalKm: goalKm),
            "fatigue": fatigueSummary(lifts.json, recovery: recovery),
            "limits": .object([
                "heavyLowerMaxPer7Days": .number(Double(heavyLowerMaxPer7Days)),
                "heavyLowerMinDaysApart": .number(Double(heavyLowerMinDaysApart)),
                "heavyMeans": .string("squat or deadlift work set at \(Int(heavyShareOfE1rm * 100))%+ of the lift's best 30-day e1RM, or \(heavyRepsMax) reps or fewer"),
                "maxTenKsPerDay": .number(Double(maxTenKsPerDay)),
                "heavyLowerDates": .array(sessions.filter { $0["heavyLower"]?.boolValue == true }.compactMap { $0["date"] }),
            ]),
        ])
    }

    static func weekday(_ day: String) -> String {
        let utc = TimeZone(identifier: "UTC") ?? .current
        guard let date = OnDeviceTime.dayBounds(day, zone: utc)?.start else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = utc
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }

    /// `Squat (Barbell)` → `squat`, the name the app's Hevy check compares.
    static func baseName(_ title: String) -> String {
        var name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasSuffix(")"), let open = name.range(of: "(", options: .backwards) {
            name = String(name[..<open.lowerBound])
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    /// Python's `round`: halves go to the even neighbor.
    static func pyRound(_ value: Double, _ digits: Int = 0) -> Double {
        let scale = pow(10, Double(digits))
        return (value * scale).rounded(.toNearestOrEven) / scale
    }

    /// Epley, like the app: weight × (1 + reps / 30). One rep returns the weight.
    static func e1rm(_ kg: Double, _ reps: Int) -> Double {
        reps <= 1 ? kg : kg * (1 + Double(reps) / 30)
    }

    static func workingSets(_ exercise: HevyExercise) -> [HevySet] {
        exercise.sets.filter { $0.type.lowercased() != "warmup" }
    }

    /// Lift summaries in the order they were first logged, with a JSON view keyed by name.
    struct Lifts {
        var order: [String] = []
        var entries: [String: [String: JSONValue]] = [:]
        var json: JSONValue { .object(entries.mapValues { .object($0) }) }
    }

    /// Per exercise: each session's working sets, top set, and e1RM, newest first, plus the 30-day best.
    static func liftSummaries(_ workouts: [HevyWorkout], today: String, zone: TimeZone) -> Lifts {
        var lifts = Lifts()
        var sessions: [String: [JSONValue]] = [:]
        for workout in workouts.sorted(by: { $0.start < $1.start }) {
            let day = OnDeviceTime.dayKey(workout.start, zone: zone)
            for exercise in workout.exercises {
                let name = baseName(exercise.title)
                let sets = workingSets(exercise)
                guard !name.isEmpty, !sets.isEmpty else { continue }
                if lifts.entries[name] == nil {
                    lifts.order.append(name)
                    lifts.entries[name] = ["exercise": .string(name), "hevyTitle": .string(exercise.title)]
                }
                var top: HevySet?
                for set in sets where (set.weightKg ?? 0) > 0 && (set.reps ?? 0) > 0 {
                    if let best = top, e1rm(set.weightKg ?? 0, set.reps ?? 0) <= e1rm(best.weightKg ?? 0, best.reps ?? 0) { continue }
                    top = set
                }
                let topE1rm = top.map { e1rm($0.weightKg ?? 0, $0.reps ?? 0) }
                let seconds = sets.reduce(0) { $0 + ($1.durationSec ?? 0) }
                let bestSeconds = sets.map { $0.durationSec ?? 0 }.max() ?? 0
                sessions[name, default: []].append(.object([
                    "date": .string(day),
                    "sets": .array(sets.map { .string(setText($0)) }),
                    "topSet": top.map { .string(setText($0)) } ?? .null,
                    "topSetKg": top?.weightKg.map(JSONValue.number) ?? .null,
                    "e1rmKg": topE1rm.map { .number(pyRound($0, 1)) } ?? .null,
                    "e1rmLb": topE1rm.map { .number(pyRound($0 * lbPerKg)) } ?? .null,
                    "bestReps": .number(Double(sets.map { $0.reps ?? 0 }.max() ?? 0)),
                    "totalReps": .number(Double(sets.reduce(0) { $0 + ($1.reps ?? 0) })),
                    "seconds": seconds > 0 ? .number(seconds) : .null,
                    "bestSeconds": bestSeconds > 0 ? .number(bestSeconds) : .null,
                ]))
            }
        }
        for name in lifts.order {
            guard var entry = lifts.entries[name] else { continue }
            let list = Array((sessions[name] ?? []).reversed())
            let values = list.compactMap { $0["e1rmKg"]?.doubleValue }.filter { $0 != 0 }
            entry["sessions"] = .array(list)
            entry["bestE1rmKg"] = values.max().map(JSONValue.number) ?? .null
            entry["bestE1rmLb"] = values.max().map { .number(pyRound($0 * lbPerKg)) } ?? .null
            let last = list.first?["date"]?.stringValue ?? today
            entry["lastDate"] = .string(last)
            entry["daysSinceLast"] = .number(Double(OnDeviceTime.daysBetween(last, today)))
            entry["sessionCount"] = .number(Double(list.count))
            entry["lowerBody"] = .bool(matches(lowerPattern, name))
            if values.count >= 2, let first = values.first, let oldest = values.last {
                entry["e1rmChangeKg"] = .number(pyRound(first - oldest, 1))
            }
            for (key, value) in liftTrend(list) { entry[key] = .string(value) }
            lifts.entries[name] = entry
        }
        return lifts
    }

    /// e1RM for weighted work, else reps in the best set, else seconds held.
    static func sessionScore(_ session: JSONValue) -> Double {
        for key in ["e1rmKg", "bestReps", "seconds"] {
            if let value = session[key]?.doubleValue, value != 0 { return value }
        }
        return 0
    }

    /// `improving`, `steady`, `stalled`, `declining`, or `dropping` from the newest sessions (newest first), with advice.
    static func liftTrend(_ sessions: [JSONValue]) -> [String: String] {
        let scores = sessions.map { sessionScore($0) }.filter { $0 > 0 }
        guard scores.count >= 3 else { return ["trend": "new", "advice": "Not enough sessions to judge. Progress normally."] }
        let newest = scores[0]
        let previousBest = max(scores[1], scores[2])
        if newest < declineShare * previousBest {
            if scores[0] < scores[1], scores[1] < scores[2] {
                return ["trend": "dropping", "advice": "Dropped two sessions in a row. Deload this lift: half the sets at 60-70% of the top set, no added weight."]
            }
            return ["trend": "declining", "advice": "Below the last sessions. Cut its sets by a third and use 5-10% less weight than the last top set."]
        }
        if scores.count >= 4, newest <= scores[1...3].max() ?? 0 {
            return ["trend": "stalled", "advice": "No new best in 3 sessions. Repeat the weight and aim for one more rep, or drop 5% and build back."]
        }
        if newest > previousBest { return ["trend": "improving", "advice": "Progress as planned."] }
        return ["trend": "steady", "advice": "Progress as planned."]
    }

    /// Whole-body fatigue: how many lifts are falling, and whether HRV is down. Says when to deload.
    static func fatigueSummary(_ lifts: JSONValue, recovery: [JSONValue]) -> JSONValue {
        let falling = (lifts.objectValue ?? [:]).filter { _, entry in
            ["declining", "dropping"].contains(entry["trend"]?.stringValue ?? "") && (entry["daysSinceLast"]?.doubleValue ?? 99) <= 10
        }.keys.sorted()
        let hrv = recovery.compactMap { $0["hrv"]?.doubleValue }
        let recent = Array(hrv.prefix(7))
        let average = { (values: [Double]) in values.reduce(0, +) / Double(max(values.count, 1)) }
        let hrvDown = hrv.count >= 14 && average(recent) < hrvDropShare * average(hrv)
        let deload = falling.count >= deloadDecliningLifts || (falling.count >= 2 && hrvDown)
        return .object([
            "decliningLifts": .array(falling.map(JSONValue.string)),
            "hrv7DayVs30Day": recent.isEmpty ? .null : .number(pyRound(average(recent) / average(hrv), 2)),
            "deloadRecommended": .bool(deload),
            "advice": .string(deload ? "Deload today: every lift at half its sets and 60-70% of its last top set." : ""),
        ])
    }

    /// `100kg (220lb) x5 @8`, `x12`, or `60s`. Short enough for 30 days of sets.
    static func setText(_ set: HevySet) -> String {
        var parts: [String] = []
        if let kg = set.weightKg, kg != 0 { parts.append("\(String(format: "%g", kg))kg (\(Int(pyRound(kg * lbPerKg)))lb)") }
        if let reps = set.reps, reps != 0 { parts.append("x\(reps)") }
        if let seconds = set.durationSec, seconds != 0, (set.reps ?? 0) == 0 { parts.append("\(Int(seconds))s") }
        if let rpe = set.rpe, rpe != 0 { parts.append("@\(String(format: "%g", rpe))") }
        return parts.isEmpty ? "logged" : parts.joined(separator: " ")
    }

    static func isHeavySet(_ name: String, _ set: HevySet, bestKg: Double?) -> Bool {
        guard matches(heavyLowerPattern, name) else { return false }
        let kg = set.weightKg ?? 0
        let reps = set.reps ?? 0
        guard kg > 0, reps > 0 else { return false }
        if let bestKg, bestKg != 0, kg >= heavyShareOfE1rm * bestKg { return true }
        return reps <= heavyRepsMax
    }

    /// One row per Hevy workout, newest first, marked when it held heavy squat or deadlift work.
    static func liftSessions(_ workouts: [HevyWorkout], lifts: Lifts, today: String, zone: TimeZone) -> [JSONValue] {
        workouts.sorted(by: { $0.start > $1.start }).map { workout in
            let day = OnDeviceTime.dayKey(workout.start, zone: zone)
            var names: [String] = []
            var heavy = false
            for exercise in workout.exercises {
                let name = baseName(exercise.title)
                guard !name.isEmpty else { continue }
                names.append(name)
                let best = lifts.entries[name]?["bestE1rmKg"]?.doubleValue
                heavy = heavy || workingSets(exercise).contains { isHeavySet(name, $0, bestKg: best) }
            }
            return .object([
                "date": .string(day),
                "daysAgo": .number(Double(OnDeviceTime.daysBetween(day, today))),
                "exercises": .array(names.map(JSONValue.string)),
                "minutes": .number(pyRound(workout.end.timeIntervalSince(workout.start) / 60)),
                "lowerBody": .bool(names.contains { matches(lowerPattern, $0) }),
                "heavyLower": .bool(heavy),
            ])
        }
    }

    /// Every Strava activity in the window, newest first. Runs get pace and a 5K or 10K label. Names are dropped.
    static func runList(_ activities: [JSONValue], today: String, zone: TimeZone) -> [JSONValue] {
        var rows: [JSONValue] = []
        for item in activities {
            guard let start = OnDeviceTime.parse(item["start_date"]?.stringValue ?? "") else { continue }
            let day = OnDeviceTime.dayKey(start, zone: zone)
            let sportType = item["sport_type"]?.stringValue ?? ""
            let type = item["type"]?.stringValue ?? ""
            let sport = !sportType.isEmpty ? sportType : !type.isEmpty ? type : "other"
            let meters = item["distance"]?.doubleValue ?? 0
            let moving = item["moving_time"]?.doubleValue ?? 0
            var row: [String: JSONValue] = [
                "date": .string(day),
                "daysAgo": .number(Double(OnDeviceTime.daysBetween(day, today))),
                "type": .string(sport),
                "km": .number(pyRound(meters / 1000, 2)),
                "movingMin": .number(pyRound(moving / 60, 1)),
            ]
            let isRun = runTypes.contains(sport.lowercased())
            if isRun, meters > 0, moving > 0 {
                let pace = moving / (meters / 1000)
                row["pacePerKm"] = .string(String(format: "%d:%02d", Int(pace / 60), Int(pace.truncatingRemainder(dividingBy: 60))))
            }
            if isRun {
                row["counts"] = .string(meters >= tenKMinMeters ? "10K" : meters >= fiveKMinMeters ? "5K" : "short")
            }
            for (source, target) in [("average_heartrate", "avgHr"), ("max_heartrate", "maxHr"), ("total_elevation_gain", "elevationM"), ("suffer_score", "relativeEffort")] {
                if let value = item[source]?.doubleValue { row[target] = .number(pyRound(value)) }
            }
            rows.append(.object(row))
        }
        // Stable, like Python's sort: same-day rows keep their order.
        return rows.enumerated().sorted { lhs, rhs in
            let (a, b) = (lhs.element["date"]?.stringValue ?? "", rhs.element["date"]?.stringValue ?? "")
            return a != b ? a > b : lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// One row per WHOOP cycle, newest first: recovery, HRV, resting heart rate, sleep, and the day's strain.
    static func recoveryDays(_ whoop: [String: [JSONValue]], zone: TimeZone) -> [JSONValue] {
        var order: [String] = []
        var days: [String: [String: JSONValue]] = [:]
        func id(_ value: JSONValue?) -> String? {
            switch value {
            case .number(let number): "n\(number)"
            case .string(let text): "s\(text)"
            default: nil
            }
        }
        func rounded(_ value: JSONValue?, _ digits: Int = 0) -> JSONValue? {
            value?.doubleValue.map { .number(pyRound($0, digits)) }
        }
        for cycle in whoop["cycles"] ?? [] {
            guard let start = OnDeviceTime.parse(cycle["start"]?.stringValue ?? ""), let key = id(cycle["id"]) else { continue }
            if days[key] == nil { order.append(key) }
            var row: [String: JSONValue] = ["date": .string(OnDeviceTime.dayKey(start, zone: zone))]
            row["strain"] = rounded(cycle["score"]?["strain"], 1)
            days[key] = row
        }
        for recovery in whoop["recoveries"] ?? [] {
            guard let key = id(recovery["cycle_id"]), var row = days[key], let score = recovery["score"], score.objectValue != nil else { continue }
            row["recovery"] = rounded(score["recovery_score"])
            row["hrv"] = rounded(score["hrv_rmssd_milli"], 1)
            row["restingHr"] = rounded(score["resting_heart_rate"])
            days[key] = row
        }
        for sleep in whoop["sleeps"] ?? [] {
            if sleep["nap"].truthy { continue }
            guard let key = id(sleep["cycle_id"]), var row = days[key], let score = sleep["score"], score.objectValue != nil else { continue }
            let stages = score["stage_summary"]
            let asleep = (stages?["total_in_bed_time_milli"]?.doubleValue ?? 0) - (stages?["total_awake_time_milli"]?.doubleValue ?? 0)
            row["sleepPerformance"] = rounded(score["sleep_performance_percentage"])
            row["sleepHours"] = asleep > 0 ? .number(pyRound(asleep / 3_600_000, 1)) : nil
            row["sleepEfficiency"] = rounded(score["sleep_efficiency_percentage"])
            days[key] = row
        }
        let rows = order.compactMap { days[$0] }
        return rows.enumerated().sorted { lhs, rhs in
            let (a, b) = (lhs.element["date"]?.stringValue ?? "", rhs.element["date"]?.stringValue ?? "")
            return a != b ? a > b : lhs.offset < rhs.offset
        }.map { .object($0.element) }
    }

    /// Each STR target the player kept, with the best matching lift in the window and the gap left.
    /// Weight goals compare e1RM (gapLb), rep goals the best set (gapReps), and holds the longest set (gapSeconds).
    /// The player's own goals ("custom": true) are scored the same way and keep their flag and split day.
    static func strengthTargets(_ targets: [JSONValue], lifts: Lifts) -> [JSONValue] {
        targets.map { target in
            let aliases = Set((target["aliases"]?.arrayValue ?? []).compactMap(\.stringValue).map { $0.lowercased() })
            let matched = lifts.order.filter { aliases.contains($0.replacingOccurrences(of: "-", with: " ")) }.compactMap { lifts.entries[$0] }
            var row: [String: JSONValue] = [:]
            for key in ["category", "goal", "targetLb", "targetReps", "targetSeconds", "unit", "custom", "splitDay"] {
                if let value = target[key], !value.isNull { row[key] = value }
            }
            let allSessions = matched.flatMap { $0["sessions"]?.arrayValue ?? [] }
            let best = matched.map { $0["bestE1rmLb"]?.doubleValue ?? 0 }.max() ?? 0
            let reps = allSessions.map { $0["bestReps"]?.doubleValue ?? 0 }.max() ?? 0
            let seconds = allSessions.map { $0["bestSeconds"]?.doubleValue ?? 0 }.max() ?? 0
            let targetLb = target["targetLb"]?.doubleValue
            let targetReps = target["targetReps"]?.doubleValue
            let weightGoal = targetLb != nil && targetReps != nil
            if !matched.isEmpty {
                row["matchedExercises"] = .array(matched.compactMap { $0["exercise"] })
                row["lastTrained"] = matched.compactMap { $0["lastDate"]?.stringValue }.max().map(JSONValue.string)
            }
            if best != 0 {
                row["bestE1rmLb"] = .number(best)
                if let targetLb, let targetReps {
                    let goal = e1rm(targetLb, Int(targetReps))
                    row["goalE1rmLb"] = .number(pyRound(goal))
                    row["gapLb"] = .number(max(0, pyRound(goal - best)))
                }
            } else if reps != 0 {
                row["bestRepsInASet"] = .number(reps)
            }
            if !weightGoal, let targetReps, reps != 0 {
                row["bestRepsInASet"] = .number(reps)
                row["gapReps"] = .number(max(0, Double(Int(targetReps)) - reps))
            }
            if let targetSeconds = target["targetSeconds"]?.doubleValue, seconds != 0 {
                row["bestSecondsInASet"] = .number(pyRound(seconds))
                row["gapSeconds"] = .number(max(0, pyRound(targetSeconds - seconds)))
            }
            if matched.isEmpty { row["status"] = .string("not trained in 30 days") }
            return .object(row)
        }
    }

    static func runKm(_ runs: [JSONValue], _ days: ClosedRange<Int>) -> Double {
        pyRound(runs.filter { $0["counts"].truthy && days.contains(Int($0["daysAgo"]?.doubleValue ?? -1)) }
            .reduce(0) { $0 + ($1["km"]?.doubleValue ?? 0) }, 2)
    }

    /// Quests that cover `km` in 5 km steps: 20 → two 10Ks, 15 → a 10K and a 5K.
    static func runsFor(_ km: Int) -> [String] {
        Array(repeating: "10K", count: km / 10) + Array(repeating: "5K", count: (km % 10) / runStepKm)
    }

    /// What today must run so the 7 days ending today hold `goalKm`. The last 6 days count; today's runs fill the rest.
    static func runWindow(_ runs: [JSONValue], goalKm: Int) -> JSONValue {
        let prior = runKm(runs, 1...6)
        let needed = max(0, Double(goalKm) - prior)
        let hundredths = Int(needed * 100)
        let steps = (hundredths + runStepKm * 100 - 1) / (runStepKm * 100)
        let planned = min(maxRunKmPerDay, steps * runStepKm)
        return .object([
            "goalKm": .number(Double(goalKm)),
            "kmLast6Days": .number(prior),
            "kmRunToday": .number(runKm(runs, 0...0)),
            "kmNeededToday": .number(pyRound(needed, 2)),
            "plannedKmToday": .number(Double(planned)),
            "runsToday": .array(runsFor(planned).map(JSONValue.string)),
            "shortfallKm": .number(pyRound(max(0, needed - Double(planned)), 2)),
            // Tomorrow these km leave the window, so tomorrow needs about this much again.
            "kmLeavingTomorrow": .number(runKm(runs, 6...6)),
        ])
    }

    /// The last 7 days at a glance, and days where a required quest was missed.
    static func weekSummary(runs: [JSONValue], sessions: [JSONValue], questDays: [JSONValue]) -> JSONValue {
        let last7 = runs.filter { ($0["daysAgo"]?.doubleValue ?? 99) <= 6 }
        let recentSessions = sessions.filter { ($0["daysAgo"]?.doubleValue ?? 99) <= 6 }
        return .object([
            "last7Days": .object([
                "tenKs": .number(Double(last7.filter { $0["counts"]?.stringValue == "10K" }.count)),
                "runKm": .number(runKm(runs, 0...6)),
                "strengthSessions": .number(Double(recentSessions.count)),
                "heavyLowerSessions": .number(Double(recentSessions.filter { $0["heavyLower"]?.boolValue == true }.count)),
            ]),
            "missedQuestDays": .array(questDays.filter { $0["missedRequired"].truthy }.map { $0["dayKey"] ?? .null }),
        ])
    }

    // MARK: - Hard limits

    static func params(_ quest: JSONValue) -> JSONValue? {
        guard let params = quest["verification"]?["params"], params.objectValue != nil else { return nil }
        return params
    }

    static func method(_ quest: JSONValue) -> String? { quest["verification"]?["method"]?.stringValue }

    static func questIsHeavyLower(_ quest: JSONValue, lifts: JSONValue?) -> Bool {
        guard method(quest) == "hevy_sets", let params = params(quest) else { return false }
        let exercise = params["exercise"]?.stringValue ?? ""
        let name = baseName(!exercise.isEmpty ? exercise : quest["title"]?.stringValue ?? "")
        guard matches(heavyLowerPattern, name) else { return false }
        let best = lifts?[name]?["bestE1rmKg"]?.doubleValue
        if let weight = params["minWeightKg"]?.doubleValue, let best, best != 0 {
            return weight >= heavyShareOfE1rm * best
        }
        if let reps = params["minReps"]?.doubleValue { return reps <= Double(heavyRepsMax) }
        return quest["difficulty"]?.stringValue == "hard"
    }

    static func isTenK(_ quest: JSONValue) -> Bool { params(quest)?["minDistanceMeters"]?.doubleValue == 10_000 }

    static func plannedRunKm(_ quests: [JSONValue]) -> Int {
        quests.reduce(0) { total, quest in
            guard quest["kind"]?.stringValue != "penalty", let meters = params(quest)?["minDistanceMeters"]?.doubleValue,
                  meters == 5_000 || meters == 10_000 else { return total }
            return total + Int(meters) / 1000
        }
    }

    /// Hard limits the model cannot talk its way past. Runs on every generated Training bundle.
    static func limitProblems(_ bundle: JSONValue, _ history: JSONValue?) -> [String] {
        guard bundle["mode"]?.stringValue == "performance_training" else { return [] }
        let quests = (bundle["quests"]?.arrayValue ?? []).filter { $0.objectValue != nil }
        var problems: [String] = []
        let lifts = history?["lifts"]
        for quest in quests where method(quest) == "hevy_sets" {
            guard let params = params(quest), let entry = lifts?[baseName(params["exercise"]?.stringValue ?? "")], entry.truthy else { continue }
            let trend = entry["trend"]?.stringValue ?? ""
            let last = entry["sessions"]?.arrayValue?.first?["topSetKg"]?.doubleValue
            if ["declining", "dropping"].contains(trend), let weight = params["minWeightKg"]?.doubleValue, let last, last != 0, weight > last {
                problems.append("\(entry["exercise"]?.stringValue ?? "") is \(trend); do not add weight above the last top set")
            }
        }
        let tenKs = quests.filter { isTenK($0) }.count
        if tenKs > maxTenKsPerDay { problems.append("more than \(maxTenKsPerDay) 10Ks in one day") }
        let km = plannedRunKm(quests)
        if km > maxRunKmPerDay { problems.append("more than \(maxRunKmPerDay) km of runs in one day") }
        if let planned = history?["runWindow"]?["plannedKmToday"]?.intValue, km < planned {
            let goal = history?["runWindow"]?["goalKm"]?.intValue.map(String.init) ?? "None"
            problems.append("today needs \(planned) km of runs to keep \(goal) km in 7 days, the plan has \(km)")
        }
        guard quests.contains(where: { questIsHeavyLower($0, lifts: lifts) }) else { return problems }
        if tenKs >= 2 { problems.append("heavy squats or deadlifts on a two-10K day") }
        let recent = (history?["strengthSessions"]?.arrayValue ?? []).filter { $0["heavyLower"].truthy }.compactMap { $0["daysAgo"]?.doubleValue }.map { Int($0) }
        if recent.contains(where: { $0 < heavyLowerMinDaysApart }) {
            problems.append("heavy squats or deadlifts less than \(heavyLowerMinDaysApart) days after the last heavy lower-body day")
        }
        if Set(recent.filter { (1...6).contains($0) }).count + 1 > heavyLowerMaxPer7Days {
            problems.append("more than \(heavyLowerMaxPer7Days) heavy lower-body days in 7")
        }
        return problems
    }

    // MARK: - Self-check (runs in DEBUG at launch). Fixtures from backend/history.py.

    static func check() -> [String] {
        var errors: [String] = []
        let zone = OnDeviceTime.losAngeles
        let today = "2026-10-22"  // Thursday
        func date(_ text: String) -> Date { OnDeviceTime.parse(text) ?? .distantPast }
        func lift(_ day: Int, _ title: String, _ sets: [(Double, Int)], rpe: Double? = nil) -> HevyWorkout {
            let stamp = String(format: "2026-10-%02d", day)
            return HevyWorkout(id: "\(title)-\(day)", title: "Workout", start: date("\(stamp)T17:00:00Z"), end: date("\(stamp)T18:05:00Z"), exercises: [
                HevyExercise(title: title, templateId: nil, sets: [HevySet(type: "warmup", reps: 5, weightKg: 40, rpe: nil, durationSec: nil)]
                    + sets.map { HevySet(type: "normal", reps: $0.1, weightKg: $0.0, rpe: rpe, durationSec: nil) }),
            ])
        }
        func run(_ day: Int, _ meters: Double, _ moving: Double = 3000) -> JSONValue {
            .object(["start_date": .string(String(format: "2026-10-%02dT15:00:00Z", day)), "sport_type": .string("Run"), "distance": .number(meters),
                     "moving_time": .number(moving), "average_heartrate": .number(150.4), "name": .string("private")])
        }
        let workouts = [
            lift(20, "Squat (Barbell)", [(120, 5), (120, 5), (120, 5)], rpe: 8),
            lift(15, "Squat (Barbell)", [(80, 10), (80, 10)]),
            lift(21, "Bench Press (Barbell)", [(90, 5), (90, 5)], rpe: 8),
        ]
        let activities = [run(19, 10_020), run(20, 10_000, 3100), run(21, 5_010, 1500), run(10, 9_000)]
        let whoop: [String: [JSONValue]] = [
            "cycles": [.object(["id": .number(7), "start": .string("2026-10-22T06:00:00Z"), "score": .object(["strain": .number(9.31)])])],
            "recoveries": [.object(["cycle_id": .number(7), "score": .object(["recovery_score": .number(71), "hrv_rmssd_milli": .number(62.44), "resting_heart_rate": .number(51)])])],
            "sleeps": [.object(["cycle_id": .number(7), "nap": .bool(false), "score": .object(["sleep_performance_percentage": .number(88),
                "stage_summary": .object(["total_in_bed_time_milli": .number(28_800_000), "total_awake_time_milli": .number(1_800_000)])])])],
        ]
        let goals: JSONValue = .object(["runKmPer7Days": .number(50), "strength": .array([.object([
            "category": .string("Squat"), "goal": .string("315 lb × 1"), "aliases": .array([.string("squat")]), "targetLb": .number(315), "targetReps": .number(1),
        ])])])
        let history = summarize(today: today, zone: zone, workouts: workouts, activities: activities, whoop: whoop, goals: goals,
                                questDays: [.object(["dayKey": .string("2026-10-20"), "missedRequired": .bool(true)])])

        let squat = history["lifts"]?["squat"]
        if squat?["sessionCount"]?.intValue != 2 || squat?["sessions"]?.arrayValue?.first?["date"]?.stringValue != "2026-10-20"
            || squat?["sessions"]?.arrayValue?.first?["sets"]?.arrayValue?.first?.stringValue != "120kg (265lb) x5 @8" {
            errors.append("squat sessions should be newest first without warm-ups")
        }
        if squat?["bestE1rmKg"]?.doubleValue != 140 || squat?["daysSinceLast"]?.intValue != 2 {
            errors.append("squat best e1RM should be 140 kg, 2 days ago")
        }
        let heavy = (history["strengthSessions"]?.arrayValue ?? []).filter { $0["heavyLower"]?.boolValue == true }.compactMap { $0["date"]?.stringValue }
        if heavy != ["2026-10-20"] { errors.append("only the 5-rep squat day should be heavy, got \(heavy)") }
        let window = history["runWindow"] ?? .null
        // 25.03 km in the last 6 days: today needs 24.97 km, more than one day allows, so two 10Ks and 4.97 km short.
        if window["kmLast6Days"]?.doubleValue != 25.03 || window["plannedKmToday"]?.intValue != 20
            || window["runsToday"] != .array([.string("10K"), .string("10K")]) || window["shortfallKm"]?.doubleValue != 4.97 {
            errors.append("run window wrong: \(window.sortedString())")
        }
        func tenK(_ days: Int, _ km: Double) -> JSONValue { .object(["km": .number(km), "daysAgo": .number(Double(days)), "counts": .string("10K")]) }
        let forty = runWindow([tenK(1, 10), tenK(2, 10), tenK(3, 10), tenK(5, 10)], goalKm: 50)
        if forty["plannedKmToday"]?.intValue != 10 || forty["runsToday"] != .array([.string("10K")]) {
            errors.append("40 km in the last 6 days should need one 10K today")
        }
        if runWindow(Array(repeating: tenK(2, 12.2), count: 3), goalKm: 50)["runsToday"] != .array([.string("10K"), .string("5K")]) {
            errors.append("13.4 km to go should round up to a 10K and a 5K")
        }
        if runWindow([], goalKm: 50)["runsToday"] != .array([.string("10K"), .string("10K")]) {
            errors.append("starting from zero should give the most one day allows")
        }
        let week = history["week"] ?? .null
        if week["last7Days"]?["runKm"]?.doubleValue != 25.03 || week["missedQuestDays"] != .array([.string("2026-10-20")]) {
            errors.append("last 7 days wrong")
        }
        let runs = history["runs"]?.arrayValue ?? []
        if runs.compactMap({ $0["counts"]?.stringValue }) != ["5K", "10K", "10K", "5K"] || runs.dropFirst().first?["pacePerKm"]?.stringValue != "5:10" {
            errors.append("runs should be labeled and paced")
        }
        if history.sortedString().contains("private") { errors.append("Strava activity names must not reach the model") }
        let expectedRecovery: JSONValue = .array([.object(["date": .string("2026-10-21"), "strain": .number(9.3), "recovery": .number(71), "hrv": .number(62.4),
                                                           "restingHr": .number(51), "sleepPerformance": .number(88), "sleepHours": .number(7.5)])])
        if history["recovery"] != expectedRecovery { errors.append("recovery row wrong: \(history["recovery"]?.sortedString() ?? "")") }
        let squatTarget = history["strengthTargets"]?.arrayValue?.first
        if squatTarget?["bestE1rmLb"]?.doubleValue != 309 || squatTarget?["gapLb"]?.doubleValue != 6 || squatTarget?["lastTrained"]?.stringValue != "2026-10-20" {
            errors.append("the squat target should show a 6 lb gap")
        }
        if history["weekday"]?.stringValue != "Thursday" { errors.append("2026-10-22 is a Thursday") }

        // The player's own goals: a weight goal shows its e1RM gap, a rep goal its rep gap, a hold its seconds gap.
        func timed(_ day: Int, _ title: String, _ sets: [HevySet]) -> HevyWorkout {
            let stamp = String(format: "2026-10-%02d", day)
            return HevyWorkout(id: "\(title)-\(day)", title: "Workout", start: date("\(stamp)T17:00:00Z"), end: date("\(stamp)T18:00:00Z"),
                               exercises: [HevyExercise(title: title, templateId: nil, sets: sets)])
        }
        func target(_ category: String, _ goal: String, _ alias: String, lb: Double? = nil, reps: Double? = nil, seconds: Double? = nil, unit: String, day: String) -> JSONValue {
            jsonObject(["category": .string(category), "goal": .string(goal), "aliases": .array([.string(alias)]), "targetLb": lb.map(JSONValue.number),
                        "targetReps": reps.map(JSONValue.number), "targetSeconds": seconds.map(JSONValue.number), "unit": .string(unit),
                        "custom": .bool(true), "splitDay": .string(day)])
        }
        let own = [
            target("Hip Thrust", "225 lb × 5", "hip thrust", lb: 225, reps: 5, unit: "lb", day: "Deadlift Day"),
            target("Muscle Up", "10 reps in one set", "muscle up", reps: 10, unit: "reps", day: "Arms Day"),
            target("L-Sit", "30 sec in one hold", "l sit", seconds: 30, unit: "seconds", day: "Arms Day"),
            target("Sled Push", "300 lb × 10", "sled push", lb: 300, reps: 10, unit: "lb", day: "Squat Day"),
        ]
        let ownLifts = liftSummaries([
            lift(18, "Hip Thrust (Barbell)", [(80, 5), (85, 5)]),
            timed(19, "Muscle-Up", [HevySet(type: "normal", reps: 6, weightKg: nil, rpe: nil, durationSec: nil), HevySet(type: "normal", reps: 4, weightKg: nil, rpe: nil, durationSec: nil)]),
            timed(20, "L-Sit", [HevySet(type: "normal", reps: nil, weightKg: nil, rpe: nil, durationSec: 12), HevySet(type: "normal", reps: nil, weightKg: nil, rpe: nil, durationSec: 20)]),
        ], today: today, zone: zone)
        let scored = strengthTargets(own, lifts: ownLifts)
        // 85 kg × 5 is 187 lb, e1RM 219 lb; the goal 225 lb × 5 is e1RM 262 lb: a 44 lb gap.
        if scored[0]["custom"]?.boolValue != true || scored[0]["splitDay"]?.stringValue != "Deadlift Day" || scored[0]["bestE1rmLb"]?.doubleValue != 219 || scored[0]["gapLb"]?.doubleValue != 44 {
            errors.append("a custom weight goal should show its e1RM gap: \(scored[0].sortedString())")
        }
        if scored[1]["bestRepsInASet"]?.doubleValue != 6 || scored[1]["gapReps"]?.doubleValue != 4 { errors.append("a custom rep goal should show a 4-rep gap") }
        if scored[2]["bestSecondsInASet"]?.doubleValue != 20 || scored[2]["gapSeconds"]?.doubleValue != 10 { errors.append("a custom hold should show a 10 sec gap") }
        if scored[3]["status"]?.stringValue != "not trained in 30 days" || scored[3]["goal"]?.stringValue != "300 lb × 10" {
            errors.append("an untrained custom goal should still be listed")
        }

        // The lift limits below are checked without the run window; the window has its own check at the end.
        var limits = history.objectValue ?? [:]
        limits["runWindow"] = nil

        func scores(_ values: Double...) -> [JSONValue] { values.map { .object(["e1rmKg": .number($0)]) } }
        let trends = [scores(110, 105, 100), scores(95, 100, 98), scores(90, 95, 100), scores(100, 102, 101, 99), scores(100), scores(101, 100, 100)].map { liftTrend($0)["trend"] ?? "" }
        if trends != ["improving", "declining", "dropping", "stalled", "new", "improving"] { errors.append("lift trends wrong: \(trends)") }
        if liftTrend([.object(["bestReps": .number(8)]), .object(["bestReps": .number(10)]), .object(["bestReps": .number(10)])])["trend"] != "declining" {
            errors.append("fewer reps on a bodyweight lift should count as declining")
        }
        let falling: [String: JSONValue] = Dictionary(uniqueKeysWithValues: ["squat", "bench press", "lateral raise"].map {
            ($0, JSONValue.object(["trend": .string("declining"), "daysSinceLast": .number(2)]))
        })
        if fatigueSummary(.object(falling), recovery: [])["deloadRecommended"]?.boolValue != true { errors.append("three declining lifts should call for a deload") }
        let two = JSONValue.object(falling.filter { $0.key != "lateral raise" })
        let lowHrv = Array(repeating: JSONValue.object(["hrv": .number(50)]), count: 7) + Array(repeating: JSONValue.object(["hrv": .number(70)]), count: 7)
        if fatigueSummary(two, recovery: [])["deloadRecommended"]?.boolValue != false || fatigueSummary(two, recovery: lowHrv)["deloadRecommended"]?.boolValue != true {
            errors.append("two declining lifts should call for a deload only with HRV down")
        }
        func bundle(_ quests: JSONValue...) -> JSONValue { .object(["mode": .string("performance_training"), "quests": .array(quests)]) }
        func hevy(_ exercise: String, _ extra: [String: JSONValue]) -> JSONValue {
            var params: [String: JSONValue] = ["exercise": .string(exercise), "sets": .number(3)]
            params.merge(extra) { $1 }
            return .object(["verification": .object(["method": .string("hevy_sets"), "params": .object(params)]), "difficulty": .string("normal")])
        }
        let declining: JSONValue = .object(["lifts": .object(["lateral raise": .object(["exercise": .string("lateral raise"), "trend": .string("declining"),
                                                                                           "sessions": .array([.object(["topSetKg": .number(12.5)])])])]),
                                            "strengthSessions": .array([])])
        if limitProblems(bundle(hevy("Lateral Raise", ["minWeightKg": .number(15)])), declining).isEmpty || !limitProblems(bundle(hevy("Lateral Raise", ["minWeightKg": .number(10)])), declining).isEmpty {
            errors.append("a declining lift should not get more weight, but less is fine")
        }
        let tenKQuest: JSONValue = .object(["verification": .object(["method": .string("strava_activity"), "params": .object(["types": .array([.string("Run")]), "minDistanceMeters": .number(10_000)])])])
        let base = JSONValue.object(limits)
        if !limitProblems(bundle(hevy("Squat", ["minReps": .number(5), "minWeightKg": .number(125)])), base).isEmpty {
            errors.append("heavy squats 2 days after the last heavy day should pass")
        }
        var yesterday = limits
        if var first = history["strengthSessions"]?.arrayValue?.dropFirst().first?.objectValue {
            first["daysAgo"] = .number(1)
            yesterday["strengthSessions"] = .array([.object(first)])
        }
        if limitProblems(bundle(hevy("Squat", ["minReps": .number(5), "minWeightKg": .number(125)])), .object(yesterday)).isEmpty {
            errors.append("heavy squats the day after a heavy squat day should be rejected")
        }
        // Light squats are fine the next day: 90 kg is under 80% of a 140 kg e1RM.
        if !limitProblems(bundle(hevy("Squat", ["minReps": .number(10), "minWeightKg": .number(90)])), .object(yesterday)).isEmpty {
            errors.append("light squats should not count as heavy")
        }
        var crowded = limits
        crowded["strengthSessions"] = .array([.object(["daysAgo": .number(2), "heavyLower": .bool(true)]), .object(["daysAgo": .number(5), "heavyLower": .bool(true)])])
        if limitProblems(bundle(hevy("Deadlift", ["minReps": .number(3)])), .object(crowded)).isEmpty {
            errors.append("a third heavy lower-body day in 7 should be rejected")
        }
        if limitProblems(bundle(tenKQuest, tenKQuest, hevy("Squat", ["minReps": .number(5)])), base).isEmpty { errors.append("heavy squats on a two-10K day should be rejected") }
        if limitProblems(bundle(tenKQuest, tenKQuest, tenKQuest), base).isEmpty { errors.append("three 10Ks in a day should be rejected") }
        if !limitProblems(bundle(tenKQuest, tenKQuest, hevy("Bench Press", ["minReps": .number(5)])), base).isEmpty { errors.append("two 10Ks and bench press should pass") }
        var windowed = limits
        windowed["runWindow"] = window
        if !limitProblems(bundle(tenKQuest, hevy("Bench Press", ["minReps": .number(5)])), .object(windowed)).contains(where: { $0.contains("km of runs") }) {
            errors.append("one 10K should be rejected when the window needs 20 km today")
        }
        if !limitProblems(.object(["mode": .string("full_recovery"), "quests": .array([tenKQuest, tenKQuest, tenKQuest])]), base).isEmpty {
            errors.append("limits apply only to Training days")
        }
        return errors
    }
}
