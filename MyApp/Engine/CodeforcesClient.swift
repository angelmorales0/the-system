import Foundation

/// The public Codeforces API (`user.info` and `user.rating`). No key: the handle is typed in Status → Connections.
enum CodeforcesClient {
    static let api = "https://codeforces.com/api"
    static let noHandle = "TODO: Type your Codeforces handle in Status → Connections."

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
        return reading(info: info, history: history ?? nil, handle: handle, now: now)
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
    static func reading(info: JSONValue?, history: JSONValue?, handle: String, now: Date) -> CodeforcesReading {
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
        base.checkedAt = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        return base
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
