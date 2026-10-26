import Foundation

struct RemoteDayReadings: Equatable {
    var whoop: WhoopDayReading
    var strava: StravaDayReading
    var mercury: MercuryDayReading
    var hevy: HevyDayReading
    var codeforces: CodeforcesReading
    /// Mercury months with real data only, newest last. A disconnected month is left out so it cannot pass the budget rule.
    var financeMonths: [FinanceMonth]
}

/// `/v1/integrations/mercury/month` adds connection fields around a `FinanceMonth`.
private nonisolated struct MercuryMonthResponse: Decodable {
    var available: Bool
    var month: String
    var postTaxIncomeUsd: Double
    var spendingUsd: Double
    var budgetUsd: Double?
    var complete: Bool

    var financeMonth: FinanceMonth? {
        guard available else { return nil }
        return FinanceMonth(month: month, postTaxIncomeUsd: postTaxIncomeUsd, spendingUsd: spendingUsd, budgetUsd: budgetUsd, complete: complete)
    }
}

/// Reads WHOOP, Strava, Mercury, Hevy, and Codeforces summaries from the local backend. Tokens never come back to the phone.
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
                mercury: .disconnected(dayKey: dayKey, reason: "TODO: Mercury is not connected. Set QUEST_GENERATE_BASE_URL to the backend."),
                hevy: .disconnected(dayKey: dayKey, reason: "TODO: Hevy is not connected. Set QUEST_GENERATE_BASE_URL to the backend."),
                codeforces: .disconnected(reason: "TODO: Codeforces is not connected. Set QUEST_GENERATE_BASE_URL to the backend."),
                financeMonths: []
            )
        }
        async let whoop = fetch(WhoopDayReading.self, base: base, path: "v1/integrations/whoop/snapshot", dayKey: dayKey)
            ?? .disconnected(dayKey: dayKey, reason: "TODO: WHOOP snapshot failed. Check the backend tokens.")
        async let strava = fetch(StravaDayReading.self, base: base, path: "v1/integrations/strava/snapshot", dayKey: dayKey)
            ?? .disconnected(dayKey: dayKey, reason: "TODO: Strava snapshot failed. Check the backend tokens.")
        async let mercury = fetch(MercuryDayReading.self, base: base, path: "v1/integrations/mercury/snapshot", dayKey: dayKey)
            ?? .disconnected(dayKey: dayKey, reason: "TODO: Mercury snapshot failed. Check MERCURY_API_TOKEN on the backend.")
        async let hevy = fetch(HevyDayReading.self, base: base, path: "v1/integrations/hevy/snapshot", dayKey: dayKey)
            ?? .disconnected(dayKey: dayKey, reason: "TODO: Hevy snapshot failed. Check HEVY_API_KEY on the backend.")
        async let codeforces = fetch(CodeforcesReading.self, base: base, path: "v1/integrations/codeforces/snapshot", dayKey: dayKey)
            ?? .disconnected(reason: "TODO: Codeforces snapshot failed. Check CODEFORCES_HANDLE on the backend.")
        let months = financeMonthKeys(dayKey: dayKey)
        async let lastMonth = fetch(MercuryMonthResponse.self, base: base, path: "v1/integrations/mercury/month", dayKey: dayKey, query: [URLQueryItem(name: "month", value: months.last)])
        async let thisMonth = fetch(MercuryMonthResponse.self, base: base, path: "v1/integrations/mercury/month", dayKey: dayKey, query: [URLQueryItem(name: "month", value: months.this)])
        let readings = await (whoop, strava, mercury, hevy, codeforces)
        let financeMonths = await [lastMonth, thisMonth].compactMap { $0?.financeMonth }
        return RemoteDayReadings(
            whoop: readings.0,
            strava: readings.1,
            mercury: readings.2,
            hevy: readings.3,
            codeforces: readings.4,
            financeMonths: financeMonths
        )
    }

    /// "2026-10-17" → this month "2026-10" and last month "2026-09". FIN scores the newest complete month.
    static func financeMonthKeys(dayKey: String) -> (this: String, last: String) {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return (String(dayKey.prefix(7)), String(dayKey.prefix(7))) }
        let (year, month) = (parts[0], parts[1])
        let last = month == 1 ? (year - 1, 12) : (year, month - 1)
        return (String(format: "%04d-%02d", year, month), String(format: "%04d-%02d", last.0, last.1))
    }

    private static func fetch<T: Decodable>(_ type: T.Type, base: URL, path: String, dayKey: String, query: [URLQueryItem] = []) async -> T? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        let extra = path.split(separator: "/").map(String.init)
        components.path = "/" + (components.path.split(separator: "/").map(String.init) + extra).joined(separator: "/")
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "day", value: dayKey))
        items.append(URLQueryItem(name: "tz", value: QuestDay.timeZone.identifier))
        items.append(contentsOf: query)
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
