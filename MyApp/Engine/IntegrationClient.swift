import Foundation

struct RemoteDayReadings: Equatable {
    var whoop: WhoopDayReading
    var strava: StravaDayReading
    var mercury: MercuryDayReading
}

/// Reads WHOOP, Strava, and Mercury summaries from the local backend. Tokens never come back to the phone.
enum IntegrationClient {
    static func load(dayKey: String) async -> RemoteDayReadings {
        let base = QuestGenerateClient.resolvedBase(
            environment: ProcessInfo.processInfo.environment,
            defaults: UserDefaults.standard.string(forKey: QuestGenerateClient.defaultsKey)
        )
        guard let base else {
            return RemoteDayReadings(
                whoop: .disconnected(dayKey: dayKey, reason: "TODO: WHOOP is not connected. Set QUEST_GENERATE_BASE_URL to the backend."),
                strava: .disconnected(dayKey: dayKey, reason: "TODO: Strava is not connected. Set QUEST_GENERATE_BASE_URL to the backend."),
                mercury: .disconnected(dayKey: dayKey, reason: "TODO: Mercury is not connected. Set QUEST_GENERATE_BASE_URL to the backend.")
            )
        }
        async let whoop = fetch(WhoopDayReading.self, base: base, path: "v1/integrations/whoop/snapshot", dayKey: dayKey)
            ?? .disconnected(dayKey: dayKey, reason: "TODO: WHOOP snapshot failed. Check the backend tokens.")
        async let strava = fetch(StravaDayReading.self, base: base, path: "v1/integrations/strava/snapshot", dayKey: dayKey)
            ?? .disconnected(dayKey: dayKey, reason: "TODO: Strava snapshot failed. Check the backend tokens.")
        async let mercury = fetch(MercuryDayReading.self, base: base, path: "v1/integrations/mercury/snapshot", dayKey: dayKey)
            ?? .disconnected(dayKey: dayKey, reason: "TODO: Mercury snapshot failed. Check MERCURY_API_TOKEN on the backend.")
        let readings = await (whoop, strava, mercury)
        return RemoteDayReadings(whoop: readings.0, strava: readings.1, mercury: readings.2)
    }

    private static func fetch<T: Decodable>(_ type: T.Type, base: URL, path: String, dayKey: String) async -> T? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        let extra = path.split(separator: "/").map(String.init)
        components.path = "/" + (components.path.split(separator: "/").map(String.init) + extra).joined(separator: "/")
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "day", value: dayKey))
        components.queryItems = items
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = QuestGenerateClient.timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = QuestGenerateClient.timeout
        configuration.timeoutIntervalForResource = QuestGenerateClient.timeout
        do {
            let (data, response) = try await URLSession(configuration: configuration).data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        } catch {
            return nil
        }
    }
}
