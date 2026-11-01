import Foundation

/// Everything the stat levels read besides the day's integration snapshot, all fetched on the phone:
/// 180 days of Hevy workouts (STR, and the AGI tests logged in Hevy), 90 days of WHOOP and Apple Health
/// recovery days (REC), and 180 days of runs, swims, VO₂ max, and zone 2 sessions (END).
struct StatInputs: Equatable {
    var hevyWorkouts: [HevyWorkout] = []
    var agility: [AgilityMeasurement] = []
    var recoveryDays: [RecoveryDay] = []
    var runEfforts: [RunEffort] = []
    var swimEfforts: [SwimEffort] = []
    var vo2: [VO2MaxReading] = []
    var zoneTwo: [ZoneTwoSession] = []
    /// Source → "ok", "not configured", or why the last read failed.
    var sources: [String: String] = [:]
}

/// What the loader keeps between reads, in Application Support (never the App Group, never a token).
/// A source is read again after 15 minutes: only the newest days, with a full read once a day.
struct StatInputCache: Codable, Equatable {
    static let fileName = "stat_inputs.json"

    var hevyWorkouts: [HevyWorkout] = []
    var hevyFetchedAt: Date?
    var hevyFullFetchAt: Date?
    var whoopDays: [RecoveryDay] = []
    var whoopFetchedAt: Date?
    var whoopFullFetchAt: Date?
    var stravaEvents: [WorkoutEvent] = []
    var stravaFetchedAt: Date?
    var stravaFullFetchAt: Date?
    /// Apple Health workout id → its longest zone 2 session (0 minutes when it had none).
    var zoneTwo: [String: ZoneTwoSession] = [:]

    static var fileURL: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(fileName)
    }

    static func load() -> StatInputCache {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return StatInputCache() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(StatInputCache.self, from: data)) ?? StatInputCache()
    }

    func save() {
        guard var url = Self.fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return }
        #if os(iOS)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? data.write(to: url, options: [.atomic])
        #endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

enum StatInputLoader {
    static let refreshSeconds: TimeInterval = 15 * 60
    static let fullRefreshSeconds: TimeInterval = 24 * 60 * 60
    /// An incremental read starts this many days before the newest cached item, so a late edit still lands.
    static let overlapDays = 2
    /// A workout's zone 2 result is cached once its heart rate samples have had a day to sync.
    static let zoneTwoSettleSeconds: TimeInterval = 24 * 60 * 60

    /// `zone` nil uses the phone's current time zone.
    static func load(now: Date = .now, zone: TimeZone? = nil) async -> StatInputs {
        let zone = zone ?? QuestDay.timeZone
        var cache = StatInputCache.load()
        var sources: [String: String] = [:]
        cache = await refreshHevy(cache, now: now, sources: &sources)
        cache = await refreshWhoop(cache, now: now, zone: zone, sources: &sources)
        cache = await refreshStrava(cache, now: now, sources: &sources)
        let health = await HealthKitBridge.statInputs(now: now)
        sources["health"] = health.available ? "ok" : "not available"

        let effortStart = now.addingTimeInterval(-Double(EnduranceLevel.effortWindowDays) * 86_400)
        let events = cache.stravaEvents + health.workouts.filter { $0.start >= effortStart }
        var zoneSessions: [ZoneTwoSession] = []
        if let maxHR = health.maxHeartRate {
            for workout in health.workouts where ZoneTwo.eligible(workout) && workout.start >= effortStart {
                let session: ZoneTwoSession
                if let cached = cache.zoneTwo[workout.id] {
                    session = cached
                } else {
                    let samples = await HealthKitBridge.heartRate(from: workout.start, to: workout.end)
                    session = ZoneTwoSession(minutes: ZoneTwo.longestMinutes(samples, maxHeartRate: maxHR), date: workout.start, source: "Apple Health")
                    if now.timeIntervalSince(workout.end) >= zoneTwoSettleSeconds { cache.zoneTwo[workout.id] = session }
                }
                if session.minutes > 0 { zoneSessions.append(session) }
            }
        }
        cache.zoneTwo = cache.zoneTwo.filter { $0.value.date >= effortStart }
        cache.save()

        return StatInputs(
            hevyWorkouts: cache.hevyWorkouts,
            agility: AgilityHevy.measurements(cache.hevyWorkouts),
            recoveryDays: mergeRecoveryDays(whoop: cache.whoopDays, health: health.nutritionDays),
            runEfforts: EnduranceEfforts.runEfforts(events),
            swimEfforts: EnduranceEfforts.swimEfforts(events),
            vo2: health.vo2,
            zoneTwo: zoneSessions,
            sources: sources
        )
    }

    // MARK: - Sources

    private static func refreshHevy(_ cache: StatInputCache, now: Date, sources: inout [String: String]) async -> StatInputCache {
        var cache = cache
        let windowStart = now.addingTimeInterval(-Double(StrengthLevel.windowDays) * 86_400)
        guard due(cache.hevyFetchedAt, now: now) else {
            sources["hevy"] = "cached"
            return cache
        }
        let full = cache.hevyWorkouts.isEmpty || due(cache.hevyFullFetchAt, now: now, after: fullRefreshSeconds)
        let since = full ? windowStart : incrementalStart(newest: cache.hevyWorkouts.map(\.start).max(), windowStart: windowStart)
        let (workouts, status) = await HevyClient.history(since: since)
        sources["hevy"] = status
        switch status {
        case "ok":
            cache.hevyWorkouts = merge(cache.hevyWorkouts, workouts, full: full, id: \.id, date: \.start, windowStart: windowStart)
            cache.hevyFetchedAt = now
            if full { cache.hevyFullFetchAt = now }
        case "not configured":
            cache.hevyWorkouts = []
            cache.hevyFetchedAt = now
            cache.hevyFullFetchAt = nil
        default:
            break
        }
        return cache
    }

    private static func refreshWhoop(_ cache: StatInputCache, now: Date, zone: TimeZone, sources: inout [String: String]) async -> StatInputCache {
        var cache = cache
        let windowStart = now.addingTimeInterval(-Double(RecoveryLevel.baselineDays) * 86_400)
        let windowKey = OnDeviceTime.dayKey(windowStart, zone: zone)
        guard due(cache.whoopFetchedAt, now: now) else {
            sources["whoop"] = "cached"
            return cache
        }
        let full = cache.whoopDays.isEmpty || due(cache.whoopFullFetchAt, now: now, after: fullRefreshSeconds)
        let newest = cache.whoopDays.map(\.dayKey).max().flatMap { OnDeviceTime.dayBounds($0, zone: zone)?.start }
        let start = full ? windowStart : incrementalStart(newest: newest, windowStart: windowStart)
        let (days, status) = await WhoopRecovery.history(start: start, end: now, zone: zone)
        sources["whoop"] = status
        switch status {
        case "ok":
            var byDay = full ? [:] : Dictionary(cache.whoopDays.map { ($0.dayKey, $0) }, uniquingKeysWith: { _, new in new })
            for day in days { byDay[day.dayKey] = day }
            cache.whoopDays = byDay.keys.filter { $0 >= windowKey }.sorted().compactMap { byDay[$0] }
            cache.whoopFetchedAt = now
            if full { cache.whoopFullFetchAt = now }
        case "not configured":
            cache.whoopDays = []
            cache.whoopFetchedAt = now
            cache.whoopFullFetchAt = nil
        default:
            break
        }
        return cache
    }

    private static func refreshStrava(_ cache: StatInputCache, now: Date, sources: inout [String: String]) async -> StatInputCache {
        var cache = cache
        let windowStart = now.addingTimeInterval(-Double(EnduranceLevel.effortWindowDays) * 86_400)
        guard due(cache.stravaFetchedAt, now: now) else {
            sources["strava"] = "cached"
            return cache
        }
        let full = cache.stravaEvents.isEmpty || due(cache.stravaFullFetchAt, now: now, after: fullRefreshSeconds)
        let start = full ? windowStart : incrementalStart(newest: cache.stravaEvents.map(\.start).max(), windowStart: windowStart)
        let (activities, status) = await StravaClient.history(start: start, end: now)
        sources["strava"] = status
        switch status {
        case "ok":
            let events = activities.compactMap(StravaClient.activity)
            cache.stravaEvents = merge(cache.stravaEvents, events, full: full, id: \.id, date: \.start, windowStart: windowStart)
            cache.stravaFetchedAt = now
            if full { cache.stravaFullFetchAt = now }
        case "not configured":
            cache.stravaEvents = []
            cache.stravaFetchedAt = now
            cache.stravaFullFetchAt = nil
        default:
            break
        }
        return cache
    }

    // MARK: - Pure helpers

    static func due(_ fetchedAt: Date?, now: Date, after seconds: TimeInterval = refreshSeconds) -> Bool {
        guard let fetchedAt else { return true }
        return now.timeIntervalSince(fetchedAt) >= seconds
    }

    /// Two days before the newest cached item, never before the window.
    static func incrementalStart(newest: Date?, windowStart: Date) -> Date {
        guard let newest else { return windowStart }
        return max(windowStart, newest.addingTimeInterval(-Double(overlapDays) * 86_400))
    }

    /// New items replace cached ones with the same id. A full read drops everything not in it. Items before the window go.
    static func merge<T>(_ cached: [T], _ fresh: [T], full: Bool, id: KeyPath<T, String>, date: KeyPath<T, Date>, windowStart: Date) -> [T] {
        var byId: [String: T] = [:]
        if !full {
            for item in cached { byId[item[keyPath: id]] = item }
        }
        for item in fresh { byId[item[keyPath: id]] = item }
        return byId.values.filter { $0[keyPath: date] >= windowStart }.sorted { $0[keyPath: date] > $1[keyPath: date] }
    }

    /// WHOOP fields and Apple Health nutrition on the same day join one row. Oldest first.
    static func mergeRecoveryDays(whoop: [RecoveryDay], health: [RecoveryDay]) -> [RecoveryDay] {
        var byDay = Dictionary(whoop.map { ($0.dayKey, $0) }, uniquingKeysWith: { _, new in new })
        for nutrition in health {
            var day = byDay[nutrition.dayKey] ?? RecoveryDay(dayKey: nutrition.dayKey)
            day.caffeineMg = nutrition.caffeineMg
            day.proteinG = nutrition.proteinG
            day.fatG = nutrition.fatG
            day.carbsG = nutrition.carbsG
            day.caloriesKcal = nutrition.caloriesKcal
            day.maintenanceKcal = nutrition.maintenanceKcal
            day.bodyMassKg = nutrition.bodyMassKg
            byDay[nutrition.dayKey] = day
        }
        return byDay.keys.sorted().compactMap { byDay[$0] }
    }

    // MARK: - Self-check (runs in DEBUG at launch)

    static func check() -> [String] {
        var errors: [String] = []
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        if !due(nil, now: now) || due(now.addingTimeInterval(-600), now: now) || !due(now.addingTimeInterval(-901), now: now) {
            errors.append("a source is due with no read, or 15 minutes after the last one")
        }
        let window = now.addingTimeInterval(-10 * 86_400)
        if incrementalStart(newest: nil, windowStart: window) != window
            || incrementalStart(newest: now, windowStart: window) != now.addingTimeInterval(-2 * 86_400)
            || incrementalStart(newest: window.addingTimeInterval(3_600), windowStart: window) != window {
            errors.append("an incremental read starts two days before the newest item, never before the window")
        }
        func event(_ id: String, daysAgo: Double, meters: Double = 0) -> WorkoutEvent {
            let start = now.addingTimeInterval(-daysAgo * 86_400)
            return WorkoutEvent(source: "strava", externalId: id, sport: "Run", start: start, end: start, movingTimeSec: 0, distanceMeters: meters)
        }
        let cached = [event("a", daysAgo: 1), event("b", daysAgo: 5), event("old", daysAgo: 20)]
        let fresh = [event("a", daysAgo: 1, meters: 5), event("c", daysAgo: 0)]
        let partial = merge(cached, fresh, full: false, id: \.id, date: \.start, windowStart: window)
        if partial.map(\.externalId) != ["c", "a", "b"] || partial[1].distanceMeters != 5 {
            errors.append("an incremental merge should replace by id, keep the rest, and drop items before the window, got \(partial.map(\.externalId))")
        }
        let replaced = merge(cached, fresh, full: true, id: \.id, date: \.start, windowStart: window)
        if replaced.map(\.externalId) != ["c", "a"] {
            errors.append("a full merge should keep only the fresh items, got \(replaced.map(\.externalId))")
        }
        var whoop = RecoveryDay(dayKey: "2026-10-02")
        whoop.hrv = 70
        var food = RecoveryDay(dayKey: "2026-10-02")
        food.proteinG = 150
        food.bodyMassKg = 80
        var foodOnly = RecoveryDay(dayKey: "2026-10-01")
        foodOnly.caloriesKcal = 2_500
        let merged = mergeRecoveryDays(whoop: [whoop], health: [food, foodOnly])
        if merged.map(\.dayKey) != ["2026-10-01", "2026-10-02"] || merged[1].hrv != 70 || merged[1].proteinG != 150
            || merged[1].bodyMassKg != 80 || merged[0].caloriesKcal != 2_500 || merged[0].hrv != nil {
            errors.append("WHOOP and Health days should join by day, got \(merged)")
        }
        if let data = try? JSONEncoder().encode(StatInputCache()), (try? JSONDecoder().decode(StatInputCache.self, from: data)) != StatInputCache() {
            errors.append("an empty cache should survive a save")
        }
        return errors
    }
}
