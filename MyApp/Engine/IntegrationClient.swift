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

/// Reads WHOOP, Strava, Mercury, Hevy, and Codeforces on the phone, with the keys in the Keychain. No server is needed.
enum IntegrationClient {
    static func load(dayKey: String) async -> RemoteDayReadings {
        let months = financeMonthKeys(dayKey: dayKey)
        async let hevyReading = HevyClient.snapshot(dayKey: dayKey)
        async let stravaReading = StravaClient.snapshot(dayKey: dayKey)
        async let whoopReading = WhoopClient.snapshot(dayKey: dayKey)
        async let codeforcesReading = CodeforcesClient.snapshot()
        async let mercuryReading = MercuryClient.load(dayKey: dayKey, months: [months.last, months.this])
        let (whoop, strava, mercury, hevy, codeforces) = await (whoopReading, stravaReading, mercuryReading, hevyReading, codeforcesReading)
        record(.whoop, configured: whoop.configured, available: whoop.available, reason: whoop.reason)
        record(.strava, configured: strava.configured, available: strava.available, reason: strava.reason)
        record(.mercury, configured: mercury.day.configured, available: mercury.day.available, reason: mercury.day.reason)
        record(.hevy, configured: hevy.configured, available: hevy.available, reason: hevy.reason)
        record(.codeforces, configured: codeforces.configured, available: codeforces.available, reason: codeforces.reason)
        return RemoteDayReadings(
            whoop: whoop,
            strava: strava,
            mercury: mercury.day,
            hevy: hevy,
            codeforces: codeforces,
            financeMonths: mercury.months
        )
    }

    /// Saves a short state for the Connections row. A service that is not set keeps "Not set".
    static func record(_ connection: Connection, configured: Bool, available: Bool, reason: String) {
        guard configured else { return }
        ConnectionStatusStore.record(connection, ok: available, message: reason)
    }

    /// "2026-10-17" → this month "2026-10" and last month "2026-09". FIN scores the newest complete month.
    static func financeMonthKeys(dayKey: String) -> (this: String, last: String) {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return (String(dayKey.prefix(7)), String(dayKey.prefix(7))) }
        let (year, month) = (parts[0], parts[1])
        let last = month == 1 ? (year - 1, 12) : (year, month - 1)
        return (String(format: "%04d-%02d", year, month), String(format: "%04d-%02d", last.0, last.1))
    }
}
