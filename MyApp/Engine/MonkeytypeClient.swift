import Foundation

/// The best 60 second test on a public Monkeytype profile. Nil when the profile has none.
nonisolated struct MonkeytypeReading: Codable, Equatable {
    var available: Bool
    var configured: Bool
    var reason: String
    var username: String?
    var bestWpm: Double?

    static func disconnected(reason: String) -> MonkeytypeReading {
        MonkeytypeReading(available: false, configured: false, reason: reason, username: nil, bestWpm: nil)
    }
}

/// The public Monkeytype username. It is not a secret, so it stays in UserDefaults.
nonisolated enum MonkeytypeSettings {
    static let usernameKey = "com.angelmorales.thesystem.monkeytype.username"

    static var username: String? {
        get {
            let value = UserDefaults.standard.string(forKey: usernameKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
        set {
            let value = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if value.isEmpty {
                UserDefaults.standard.removeObject(forKey: usernameKey)
            } else {
                UserDefaults.standard.set(value, forKey: usernameKey)
            }
        }
    }
}

/// The public Monkeytype API. `GET /users/{name}/profile` needs no key.
enum MonkeytypeClient {
    static let api = "https://api.monkeytype.com"
    static let noUsername = "TODO: Type your Monkeytype username in Status → Connections."
    /// Seconds of the test that counts. Short tests give much higher numbers.
    static let testSeconds = "60"

    static func snapshot(username: String? = MonkeytypeSettings.username) async -> MonkeytypeReading {
        guard let username else { return .disconnected(reason: noUsername) }
        let name = username.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? username
        guard let url = OnDeviceHTTP.url("\(api)/users/\(name)/profile", []) else { return reading(profile: nil, username: username) }
        return reading(profile: await OnDeviceHTTP.getJSON(url, headers: ["User-Agent": "the-system-ios/1.0"]), username: username)
    }

    static func test() async -> (ok: Bool, message: String) {
        let reading = await snapshot()
        if reading.available {
            return (true, reading.bestWpm.map { "Connected. Best \(Int($0)) WPM in \(testSeconds) seconds." } ?? "Connected. No \(testSeconds) second test yet.")
        }
        return (false, reading.reason)
    }

    /// Pure parse of the profile reply.
    static func reading(profile: JSONValue?, username: String) -> MonkeytypeReading {
        var base = MonkeytypeReading.disconnected(reason: "")
        base.configured = true
        base.username = username
        guard let data = profile?["data"], data.objectValue != nil, data["name"]?.stringValue != nil else {
            base.reason = "TODO: Monkeytype has no public profile for \(username). Check the username."
            return base
        }
        base.available = true
        base.bestWpm = data["personalBests"]?["time"]?[testSeconds]?.arrayValue?.compactMap { $0["wpm"]?.doubleValue }.max()
        return base
    }

    // MARK: - Self-check (runs in DEBUG at launch)

    static func check() -> [String] {
        var errors: [String] = []
        func test(_ wpm: Double) -> JSONValue { .object(["wpm": .number(wpm), "language": .string("english")]) }
        let profile: JSONValue = .object(["data": .object([
            "name": .string("typer"),
            "personalBests": .object(["time": .object(["15": .array([test(180)]), "60": .array([test(90), test(121.5)])])]),
        ])])
        let read = reading(profile: profile, username: "typer")
        if !read.available || read.bestWpm != 121.5 {
            errors.append("Monkeytype should read the best 60 second test, got \(read)")
        }
        let none = reading(profile: .object(["data": .object(["name": .string("new")])]), username: "new")
        if !none.available || none.bestWpm != nil {
            errors.append("a profile with no 60 second test should be connected with no best")
        }
        let missing = reading(profile: nil, username: "ghost")
        if missing.available || !missing.configured || !missing.reason.hasPrefix("TODO") {
            errors.append("a missing Monkeytype profile should be configured but unavailable")
        }
        return errors
    }
}
