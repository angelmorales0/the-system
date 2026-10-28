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
        return errors
    }
}
