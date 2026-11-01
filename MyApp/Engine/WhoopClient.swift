import Foundation

/// WHOOP API v2 from the phone, with the owner's own WHOOP app and the tokens in the Keychain.
/// Port of the backend's WHOOP snapshot and 30-day recovery, sleep, and cycle reader.
enum WhoopClient {
    static let api = "https://api.prod.whoop.com/developer"
    static let pageLimit = 25
    static let maxPages = 6

    static var configured: Bool { SecretStore.has(.whoopTokens) }

    /// Today's recovery, sleep, strain, and workouts for one local day.
    static func snapshot(dayKey: String, zone: TimeZone? = nil) async -> WhoopDayReading {
        var base = WhoopDayReading.disconnected(dayKey: dayKey, reason: "")
        guard configured else {
            base.reason = "TODO: Sign in to WHOOP in Status → Connections."
            return base
        }
        guard let token = await OAuthClient.accessToken(.whoop) else {
            base.configured = true
            base.reason = "TODO: WHOOP token refresh failed. Sign in again in Status → Connections."
            return base
        }
        guard let (start, end) = OnDeviceTime.dayBounds(dayKey, zone: zone ?? QuestDay.timeZone) else { return base }
        async let recoveryPage = collection(token, "/v2/recovery", start, end)
        async let cyclePage = collection(token, "/v2/cycle", start, end)
        async let sleepPage = collection(token, "/v2/activity/sleep", start, end)
        async let workoutPage = collection(token, "/v2/activity/workout", start, end)
        let (recovery, cycle, sleep, workouts) = await (recoveryPage, cyclePage, sleepPage, workoutPage)
        if recovery == nil, cycle == nil, workouts == nil {
            base.configured = true
            base.reason = "TODO: WHOOP request failed."
            return base
        }
        return reading(dayKey: dayKey, recovery: recovery, cycle: cycle, sleep: sleep, workouts: workouts)
    }

    /// Pure: the snapshot from the four collection replies.
    static func reading(dayKey: String, recovery: JSONValue?, cycle: JSONValue?, sleep: JSONValue?, workouts: JSONValue?) -> WhoopDayReading {
        let score = firstScore(recovery)
        return WhoopDayReading(
            available: true,
            configured: true,
            reason: "",
            dayKey: dayKey,
            recoveryScore: score["recovery_score"]?.doubleValue.map { Int($0) },
            restingHr: score["resting_heart_rate"]?.doubleValue.map { Int($0) },
            hrv: score["hrv_rmssd_milli"]?.doubleValue,
            sleepPerformance: firstScore(sleep)["sleep_performance_percentage"]?.doubleValue.map { Int($0) },
            dayStrain: firstScore(cycle)["strain"]?.doubleValue,
            scored: firstRecord(recovery)?["score_state"]?.stringValue == "SCORED",
            workouts: events(workouts)
        )
    }

    /// Cycles, recoveries, and sleeps from `start` to `end`, for the training history.
    static func history(start: Date, end: Date) async -> (records: [String: [JSONValue]], status: String) {
        let empty: [String: [JSONValue]] = ["cycles": [], "recoveries": [], "sleeps": []]
        guard configured else { return (empty, "not configured") }
        guard let token = await OAuthClient.accessToken(.whoop) else { return (empty, "token refresh failed") }
        async let cycles = records(token, "/v2/cycle", start, end)
        async let recoveries = records(token, "/v2/recovery", start, end)
        async let sleeps = records(token, "/v2/activity/sleep", start, end)
        let result = await ["cycles": cycles, "recoveries": recoveries, "sleeps": sleeps]
        if result.values.allSatisfy(\.isEmpty) { return (result, "request failed or no data") }
        return (result, "ok")
    }

    static func test() async -> (ok: Bool, message: String) {
        guard let token = await OAuthClient.accessToken(.whoop) else { return (false, "Sign in to WHOOP again: the token could not be refreshed.") }
        guard let url = OnDeviceHTTP.url("\(api)/v2/cycle", [("limit", "1")]),
              let reply = await OnDeviceHTTP.get(url, headers: StravaClient.bearer(token)) else { return (false, "Cannot reach WHOOP.") }
        if (200..<300).contains(reply.status) { return (true, "Connected to WHOOP.") }
        return (false, "WHOOP answered with HTTP \(reply.status).")
    }

    static func query(_ start: Date, _ end: Date, limit: Int, next: String = "") -> [(String, String)] {
        var query = [("start", OnDeviceTime.utcString(start)), ("end", OnDeviceTime.utcString(end)), ("limit", String(limit))]
        if !next.isEmpty { query.append(("nextToken", next)) }
        return query
    }

    private static func collection(_ token: String, _ path: String, _ start: Date, _ end: Date) async -> JSONValue? {
        guard let url = OnDeviceHTTP.url(api + path, query(start, end, limit: 10)),
              let payload = await OnDeviceHTTP.getJSON(url, headers: StravaClient.bearer(token)), payload.objectValue != nil else { return nil }
        return payload
    }

    /// Every record of one collection from `start` to `end`, up to `maxPages` pages. `WhoopRecovery` reads it too.
    static func records(_ token: String, _ path: String, _ start: Date, _ end: Date) async -> [JSONValue] {
        var records: [JSONValue] = []
        var next = ""
        for _ in 0..<maxPages {
            guard let url = OnDeviceHTTP.url(api + path, query(start, end, limit: pageLimit, next: next)),
                  let payload = await OnDeviceHTTP.getJSON(url, headers: StravaClient.bearer(token)), payload.objectValue != nil else { break }
            records += (payload["records"]?.arrayValue ?? []).filter { $0.objectValue != nil }
            next = payload["next_token"]?.stringValue ?? ""
            if next.isEmpty { break }
        }
        return records
    }

    static func firstRecord(_ payload: JSONValue?) -> JSONValue? {
        guard let first = payload?["records"]?.arrayValue?.first, first.objectValue != nil else { return nil }
        return first
    }

    static func firstScore(_ payload: JSONValue?) -> JSONValue {
        guard let score = firstRecord(payload)?["score"], score.objectValue != nil else { return .object([:]) }
        return score
    }

    /// WHOOP workouts as workout events. WHOOP has no distance here.
    static func events(_ payload: JSONValue?) -> [WorkoutEvent] {
        (payload?["records"]?.arrayValue ?? []).compactMap { record in
            guard let startText = record["start"]?.stringValue, let endText = record["end"]?.stringValue,
                  let start = OnDeviceTime.parse(startText), let end = OnDeviceTime.parse(endText) else { return nil }
            let id: String = {
                switch record["id"] {
                case .string(let value) where !value.isEmpty: return value
                case .number(let value): return String(format: "%.0f", value)
                default: return startText
                }
            }()
            return WorkoutEvent(source: "whoop", externalId: id, sport: record["sport_name"]?.stringValue ?? "other",
                                start: start, end: end, movingTimeSec: 0, distanceMeters: nil)
        }
    }

    // MARK: - Self-check (runs in DEBUG at launch)

    static func check() -> [String] {
        var errors: [String] = []
        let recovery: JSONValue = .object(["records": .array([.object([
            "cycle_id": .number(7), "score_state": .string("SCORED"),
            "score": .object(["recovery_score": .number(71), "hrv_rmssd_milli": .number(62.44), "resting_heart_rate": .number(51)]),
        ])])])
        let sleep: JSONValue = .object(["records": .array([.object(["score": .object(["sleep_performance_percentage": .number(88)])])])])
        let cycle: JSONValue = .object(["records": .array([.object(["score": .object(["strain": .number(9.31)])])])])
        let workouts: JSONValue = .object(["records": .array([.object([
            "id": .string("abc"), "sport_name": .string("running"),
            "start": .string("2026-10-22T14:00:00.123Z"), "end": .string("2026-10-22T14:45:00.456Z"),
        ])])])
        let day = reading(dayKey: "2026-10-22", recovery: recovery, cycle: cycle, sleep: sleep, workouts: workouts)
        if day.recoveryScore != 71 || day.restingHr != 51 || day.hrv != 62.44 || day.sleepPerformance != 88 || day.dayStrain != 9.31 || !day.scored {
            errors.append("the WHOOP snapshot should read recovery, HRV, resting HR, sleep, and strain")
        }
        if day.workouts.count != 1 || day.workouts.first?.sport != "running" || day.workouts.first.map({ OnDeviceTime.utcString($0.start) }) != "2026-10-22T14:00:00Z" {
            errors.append("a WHOOP workout should become a workout event without fractional seconds")
        }
        let empty = reading(dayKey: "2026-10-22", recovery: .object(["records": .array([])]), cycle: nil, sleep: nil, workouts: nil)
        if empty.recoveryScore != nil || empty.scored || !empty.workouts.isEmpty {
            errors.append("an empty WHOOP day should have no values")
        }
        return errors
    }
}
