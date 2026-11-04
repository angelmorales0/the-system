import Foundation

/// The public Codeforces API (`user.info` and `user.rating`). No key: the handle is typed in Status → Connections.
enum CodeforcesClient {
    static let api = "https://codeforces.com/api"
    static let noHandle = "TODO: Type your Codeforces handle in Status → Connections."
    static let languageCacheKey = "com.angelmorales.thesystem.codeforces.languages"

    static func snapshot(handle: String? = CodeforcesSettings.handle, now: Date = .now) async -> CodeforcesReading {
        guard let handle else { return .disconnected(reason: noHandle) }
        guard let infoURL = OnDeviceHTTP.url("\(api)/user.info", [("handles", handle)]),
              let info = await result(infoURL) else {
            var reading = CodeforcesReading.disconnected(reason: "TODO: Codeforces user.info failed. Check the handle.")
            reading.configured = true
            reading.handle = handle
            return reading
        }
        // user.rating lists one entry per rated contest. A failure leaves the count at 0, not the rating.
        let history = await OnDeviceHTTP.url("\(api)/user.rating", [("handle", handle)]).asyncMap(result)
        let languages = await contestLanguages(handle: handle, rows: (history ?? nil)?.arrayValue ?? [])
        return reading(info: info, history: history ?? nil, handle: handle, now: now, languages: languages)
    }

    /// The language of each rated contest. A contest never changes, so `user.status` is read only for a new one.
    private static func contestLanguages(handle: String, rows: [JSONValue]) async -> [String: String] {
        let key = "\(languageCacheKey).\(handle.lowercased())"
        var known = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        let ids = rows.compactMap { $0["contestId"]?.doubleValue }.map { String(Int($0)) }
        guard ids.contains(where: { known[$0] == nil }) else { return known }
        // Codeforces allows one call each 2 seconds.
        try? await Task.sleep(for: .seconds(2.1))
        guard let url = OnDeviceHTTP.url("\(api)/user.status", [("handle", handle), ("from", "1"), ("count", "10000")]),
              let status = await result(url) else { return known }
        let found = languages(status: status)
        for id in ids { known[id] = found[id] ?? "" }
        UserDefaults.standard.set(known, forKey: key)
        return known
    }

    /// Contest id → language name of most of the player's accepted submissions there. Without any, of all their submissions.
    static func languages(status: JSONValue?) -> [String: String] {
        var counts: [String: [String: Int]] = [:]
        for row in status?.arrayValue ?? [] {
            guard row["author"]?["participantType"]?.stringValue == "CONTESTANT",
                  let id = row["contestId"]?.doubleValue ?? row["problem"]?["contestId"]?.doubleValue,
                  let language = row["programmingLanguage"]?.stringValue.flatMap(CodeforcesLanguage.init(submission:)) else { continue }
            let points = row["verdict"]?.stringValue == "OK" ? 1_000 : 1
            counts[String(Int(id)), default: [:]][language.rawValue, default: 0] += points
        }
        return counts.compactMapValues { $0.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key }
    }

    static func test() async -> (ok: Bool, message: String) {
        let reading = await snapshot()
        if reading.available {
            return (true, reading.rating.map { "Connected. Rating \($0)." } ?? "Connected. No rated contests yet.")
        }
        return (false, reading.reason)
    }

    /// The `result` of an OK reply, or nil.
    private static func result(_ url: URL) async -> JSONValue? {
        guard let payload = await OnDeviceHTTP.getJSON(url, headers: ["User-Agent": "the-system-ios/1.0"]),
              payload["status"]?.stringValue == "OK" else { return nil }
        return payload["result"]
    }

    /// Pure parse of `user.info` (a list or one user) and `user.rating`.
    static func reading(info: JSONValue?, history: JSONValue?, handle: String, now: Date, languages: [String: String] = [:]) -> CodeforcesReading {
        guard !handle.isEmpty else { return .disconnected(reason: noHandle) }
        var base = CodeforcesReading.disconnected(reason: "")
        base.configured = true
        base.handle = handle
        let user = info?.arrayValue?.first ?? info
        guard let user, user.objectValue != nil, let name = user["handle"]?.stringValue, !name.isEmpty else {
            base.reason = "TODO: Codeforces has no user \(handle). Check the handle."
            return base
        }
        // Unrated users have no rating, maxRating, or rank fields.
        base.available = true
        base.handle = name
        base.rating = user["rating"]?.doubleValue.map { Int($0) }
        base.maxRating = user["maxRating"]?.doubleValue.map { Int($0) }
        base.rank = user["rank"]?.stringValue
        base.contests = history?.arrayValue?.count ?? 0
        base.history = history?.arrayValue?.compactMap { contest($0, languages: languages) }.sorted { $0.time < $1.time }
        base.checkedAt = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        return base
    }

    /// One `user.rating` row, or nil when a field is missing.
    private static func contest(_ row: JSONValue, languages: [String: String]) -> CodeforcesContest? {
        guard let time = row["ratingUpdateTimeSeconds"]?.doubleValue, let old = row["oldRating"]?.doubleValue,
              let new = row["newRating"]?.doubleValue else { return nil }
        let language = row["contestId"]?.doubleValue.flatMap { languages[String(Int($0))] }.flatMap(CodeforcesLanguage.init(rawValue:))
        return CodeforcesContest(time: Int(time), oldRating: Int(old), newRating: Int(new), language: language)
    }

    // MARK: - Self-check (runs in DEBUG at launch). Fixtures from backend/integrations.py.

    static func check() -> [String] {
        var errors: [String] = []
        let now = Date(timeIntervalSince1970: 1_790_000_000.5)
        let rated = reading(
            info: .array([.object(["handle": .string("tourist"), "rating": .number(2150), "maxRating": .number(2300), "rank": .string("master"), "email": .string("hidden")])]),
            history: .array([.object(["contestId": .number(1)]), .object(["contestId": .number(2)])]),
            handle: "tourist",
            now: now
        )
        if !rated.available || rated.rating != 2150 || rated.maxRating != 2300 || rated.rank != "master" || rated.contests != 2 {
            errors.append("Codeforces should read the current rating and contest count")
        }
        if rated.checkedAt != Date(timeIntervalSince1970: 1_790_000_000) || JSONValue.from(rated)?.sortedString().contains("hidden") != false {
            errors.append("Codeforces checkedAt should be whole seconds and extra fields dropped")
        }
        let dated = reading(
            info: .array([.object(["handle": .string("tourist"), "rating": .number(1520)])]),
            history: .array([.object(["contestId": .number(9), "ratingUpdateTimeSeconds": .number(200), "oldRating": .number(1500), "newRating": .number(1520)]),
                             .object(["contestId": .number(8), "ratingUpdateTimeSeconds": .number(100), "oldRating": .number(1450), "newRating": .number(1500)])]),
            handle: "tourist",
            now: now,
            languages: ["9": "Java", "8": ""]
        )
        if dated.history?.map(\.newRating) != [1500, 1520] || dated.history?.map(\.language) != [nil, .java] {
            errors.append("Codeforces should keep the rated contests, oldest first, with their language")
        }
        func submission(_ contest: Double, _ language: String, _ verdict: String, type: String = "CONTESTANT") -> JSONValue {
            .object(["contestId": .number(contest), "programmingLanguage": .string(language), "verdict": .string(verdict),
                     "author": .object(["participantType": .string(type)])])
        }
        let picked = languages(status: .array([
            submission(1, "Python 3", "WRONG_ANSWER"), submission(1, "Python 3", "WRONG_ANSWER"), submission(1, "Java 21", "OK"),
            submission(2, "PyPy 3-64", "WRONG_ANSWER"),
            submission(3, "GNU G++20", "OK", type: "PRACTICE"),
        ]))
        if picked != ["1": "Java", "2": "Python"] {
            errors.append("a contest should count for its accepted language, and practice should not count, got \(picked)")
        }
        let unrated = reading(info: .array([.object(["handle": .string("newbie")])]), history: .array([]), handle: "newbie", now: now)
        if !unrated.available || unrated.rating != nil || unrated.maxRating != nil || unrated.contests != 0 {
            errors.append("an unrated Codeforces user should have no rating")
        }
        let none = reading(info: .array([]), history: nil, handle: "", now: now)
        if none.configured || none.available || !none.reason.contains("handle") {
            errors.append("Codeforces without a handle should be disconnected with a TODO")
        }
        let unknown = reading(info: .array([]), history: nil, handle: "ghost", now: now)
        if !unknown.configured || unknown.available || !unknown.reason.hasPrefix("TODO") {
            errors.append("an unknown Codeforces handle should be configured but unavailable")
        }
        return errors
    }
}

extension Optional {
    /// Runs an async transform on a present value.
    func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let value = self else { return nil }
        return await transform(value)
    }
}
