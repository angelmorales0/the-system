import Foundation

/// `GET /v1/integrations/screentime/snapshot?day=` on the screen time Worker →
/// `{"available": true, "dayKey": "2026-10-26", "workMinutes": 280}`.
/// Every Mac running FocusTracker adds to `workMinutes`: all Mac time counts as work. A minute used on two Macs counts once.
/// `active` is the merged bitmap of the Macs' active minutes: bit i is minute i after 5:00.
nonisolated struct WorkScreenReading: Decodable, Equatable {
    var available: Bool
    var dayKey: String
    var workMinutes: Int?
    var active: String?

    /// The Macs' active minutes for `dayKey`, or nil when the Worker has none.
    func activeMinutes(for dayKey: String) -> Data? {
        guard available, self.dayKey == dayKey, let active else { return nil }
        return Data(base64Encoded: active)
    }

    /// A reading for another day is ignored.
    func minutes(for dayKey: String) -> Int? {
        available && self.dayKey == dayKey ? workMinutes.map { max(0, $0) } : nil
    }

    /// The newest minute any Mac was active on `dayKey`, or nil when the bitmap has none. `start` is the day's first minute.
    func lastActive(for dayKey: String, start: Date) -> Date? {
        guard let bits = activeMinutes(for: dayKey).map(Array.init), let byte = bits.lastIndex(where: { $0 != 0 }) else { return nil }
        let slot = byte * 8 + 7 - bits[byte].leadingZeroBitCount
        return start.addingTimeInterval(Double(slot) * 60)
    }
}

/// The Mac tracker row on the Connections screen. Receiving: a Mac was active in the last `liveWindow`.
nonisolated enum MacTrackerStatus: Equatable {
    case notSet
    case unreachable
    case noData
    case idle(since: Date)
    case receiving(minutes: Int)

    /// FocusTracker sends every 15 minutes, so a minute up to 30 minutes old is still live.
    static let liveWindow: TimeInterval = 30 * 60

    static func make(settings: MacScreenSettings, reading: WorkScreenReading?, dayKey: String, dayStart: Date?, now: Date) -> MacTrackerStatus {
        guard settings.baseURL != nil else { return .notSet }
        guard let reading else { return .unreachable }
        guard let minutes = reading.minutes(for: dayKey) else { return .noData }
        guard let last = dayStart.flatMap({ reading.lastActive(for: dayKey, start: $0) }) else { return minutes > 0 ? .receiving(minutes: minutes) : .noData }
        return now.timeIntervalSince(last) <= liveWindow ? .receiving(minutes: minutes) : .idle(since: last)
    }
}

/// The Worker address and token, typed in Screen Time → Mac tracker. The same pair goes into FocusTracker on each Mac.
nonisolated struct MacScreenSettings: Equatable {
    static let endpointKey = "com.angelmorales.thesystem.macScreen.endpoint"
    static let tokenKey = "com.angelmorales.thesystem.macScreen.token"

    var endpoint: String
    var token: String

    /// HTTPS only, trailing slash removed. Nil when the address or token is missing.
    var baseURL: URL? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !token.trimmingCharacters(in: .whitespaces).isEmpty,
              let url = URL(string: trimmed), url.scheme == "https", url.host() != nil else { return nil }
        return url
    }

    static func load(from defaults: UserDefaults = .standard) -> MacScreenSettings {
        MacScreenSettings(endpoint: defaults.string(forKey: endpointKey) ?? "", token: defaults.string(forKey: tokenKey) ?? "")
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(endpoint.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.endpointKey)
        defaults.set(token.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.tokenKey)
    }
}

enum MacScreenClient {
    /// Today's Mac minutes, or nil when the tracker is not set up or the Worker cannot be reached.
    static func load(dayKey: String, settings: MacScreenSettings = .load()) async -> WorkScreenReading? {
        guard let request = request(dayKey: dayKey, settings: settings) else { return nil }
        guard let (data, response) = try? await URLSession(configuration: .ephemeral).data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return try? JSONDecoder().decode(WorkScreenReading.self, from: data)
    }

    /// For the settings screen: says whether the Worker answered and the token worked.
    static func test(dayKey: String, settings: MacScreenSettings) async -> String {
        guard let request = request(dayKey: dayKey, settings: settings) else { return "Enter an https address and the token." }
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 { return "The Worker refused the token." }
            guard (200..<300).contains(status), let reading = try? JSONDecoder().decode(WorkScreenReading.self, from: data) else {
                return "The Worker answered with HTTP \(status)."
            }
            guard let minutes = reading.minutes(for: dayKey) else { return "Connected. No Mac has sent minutes today yet." }
            return "Connected. Macs today: \(ScreenTime.clock(minutes))."
        } catch {
            return "Cannot reach the Worker: \(error.localizedDescription)"
        }
    }

    static func request(dayKey: String, settings: MacScreenSettings) -> URLRequest? {
        guard let base = settings.baseURL,
              var components = URLComponents(url: base.appending(path: "v1/integrations/screentime/snapshot"), resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [URLQueryItem(name: "day", value: dayKey)]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = QuestGenerateClient.timeout
        request.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: - Self-check (runs in DEBUG at launch)

    static func check() -> [String] {
        var errors: [String] = []
        let good = MacScreenSettings(endpoint: " https://screentime.me.workers.dev/ ", token: "abc")
        let request = request(dayKey: "2026-10-26", settings: good)
        if request?.url?.absoluteString != "https://screentime.me.workers.dev/v1/integrations/screentime/snapshot?day=2026-10-26"
            || request?.value(forHTTPHeaderField: "Authorization") != "Bearer abc" {
            errors.append("Mac screen request should hit the snapshot path with the token, got \(String(describing: request?.url))")
        }
        if MacScreenSettings(endpoint: "http://x.workers.dev", token: "abc").baseURL != nil
            || MacScreenSettings(endpoint: "https://x.workers.dev", token: "").baseURL != nil {
            errors.append("only an https address with a token should be used")
        }
        let reading = WorkScreenReading(available: true, dayKey: "2026-10-26", workMinutes: 412)
        if reading.minutes(for: "2026-10-26") != 412 || reading.minutes(for: "2026-10-25") != nil
            || WorkScreenReading(available: false, dayKey: "2026-10-26", workMinutes: nil).minutes(for: "2026-10-26") != nil {
            errors.append("a Mac reading should count only for its own day")
        }

        // Bit i is minute i after the day's start: slot 600 is 10 hours in.
        if let start = QuestDay.start(of: "2026-10-26") {
            var bits = [UInt8](repeating: 0, count: 120)
            bits[300 >> 3] |= 1 << UInt8(300 & 7)
            bits[600 >> 3] |= 1 << UInt8(600 & 7)
            let marked = WorkScreenReading(available: true, dayKey: "2026-10-26", workMinutes: 2, active: Data(bits).base64EncodedString())
            let last = start.addingTimeInterval(600 * 60)
            if marked.lastActive(for: "2026-10-26", start: start) != last {
                errors.append("the last active minute should be slot 600, got \(String(describing: marked.lastActive(for: "2026-10-26", start: start)))")
            }
            let day = "2026-10-26"
            let cases: [(MacScreenSettings, WorkScreenReading?, Date, MacTrackerStatus)] = [
                (MacScreenSettings(endpoint: "", token: ""), marked, last, .notSet),
                (good, nil, last, .unreachable),
                (good, WorkScreenReading(available: true, dayKey: "2026-10-25", workMinutes: 9), last, .noData),
                (good, marked, last.addingTimeInterval(20 * 60), .receiving(minutes: 2)),
                (good, marked, last.addingTimeInterval(45 * 60), .idle(since: last)),
            ]
            for (settings, reading, now, expected) in cases where MacTrackerStatus.make(settings: settings, reading: reading, dayKey: day, dayStart: start, now: now) != expected {
                errors.append("Mac tracker status should be \(expected), got \(MacTrackerStatus.make(settings: settings, reading: reading, dayKey: day, dayStart: start, now: now))")
            }
        }
        return errors
    }
}
