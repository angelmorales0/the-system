import Foundation

/// The quest day's countdown ring. It starts full at midnight local time and drains to empty
/// at the next midnight, when an unfinished required set becomes a penalty.
/// Under `urgentFraction` of the day left, the ring turns penalty red.
struct DayClock: Codable, Equatable {
    static let segments = 28
    /// The ring turns red when less than this share of the day is left.
    static let urgentFraction = 0.15
    static let storageKey = "com.angelmorales.thesystem.dayclock.v2"

    var dayKey: String
    var startedAt: Date

    /// The next midnight, which ends the ring's quest day in the phone's current time zone.
    var deadline: Date { deadline(in: QuestDay.calendar) }

    func deadline(in calendar: Calendar) -> Date {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let dayStart = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              let next = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return QuestDay.endOfDay(startedAt).addingTimeInterval(1)
        }
        return next
    }

    func progress(at now: Date) -> Double {
        let span = deadline.timeIntervalSince(startedAt)
        guard span > 0 else { return 1 }
        return min(max(now.timeIntervalSince(startedAt) / span, 0), 1)
    }

    func litSegments(at now: Date) -> Int {
        Int((progress(at: now) * Double(Self.segments)).rounded(.down))
    }

    /// Share of the day still left: 1 at midnight, 0 at the next midnight.
    func remaining(at now: Date) -> Double {
        1 - progress(at: now)
    }

    /// Dashes still lit as the ring drains: all at the start, none at the deadline.
    func remainingSegments(at now: Date) -> Int {
        Self.segments - litSegments(at: now)
    }

    func isUrgent(at now: Date) -> Bool {
        remaining(at: now) < Self.urgentFraction
    }

    /// The time the ring draws. In DEBUG, launch with `-ringPreviewRemaining 0.1`
    /// to draw the ring as if that share of the day were left. Release builds always use `now`.
    func displayDate(for now: Date) -> Date {
        #if DEBUG
        // Launch arguments arrive as strings, so parse the text.
        if let text = UserDefaults.standard.string(forKey: "ringPreviewRemaining"), let left = Double(text) {
            let span = deadline.timeIntervalSince(startedAt)
            return startedAt.addingTimeInterval(span * (1 - min(max(left, 0), 1)))
        }
        #endif
        return now
    }

    /// Keeps today's ring, or starts the ring for the quest day that holds `now` at its midnight start.
    static func resolve(current: DayClock?, now: Date) -> DayClock {
        let key = QuestDay.key(for: now)
        // The local date went back after a flight west. Keep the later day's ring.
        if let current, current.dayKey >= key {
            return current
        }
        return DayClock(dayKey: key, startedAt: QuestDay.start(of: key) ?? now)
    }

    static func load(from defaults: UserDefaults = .standard) -> DayClock? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(DayClock.self, from: data)
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

/// Debug self-checks for the day ring. `GameStore.init` stops on the first failure.
enum DayClockRules {
    static func check() -> [String] {
        var errors: [String] = []
        let calendar = QuestDay.calendar
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute)) ?? .distantPast
        }

        // Opened at 9:30: the ring started at midnight and ends at the next midnight.
        let morning = DayClock.resolve(current: nil, now: at(2, 9, 30))
        if morning.dayKey != "2026-10-02" || morning.startedAt != at(2, 0) {
            errors.append("the ring should start at midnight local time, got \(morning.startedAt)")
        }
        if morning.deadline != at(3, 0) {
            errors.append("the ring should end at the next midnight")
        }
        // 24 hours: half the ring is gone at 12:00.
        if morning.remainingSegments(at: at(2, 0)) != DayClock.segments
            || morning.remainingSegments(at: at(2, 12)) != 14
            || morning.remainingSegments(at: at(3, 0)) != 0 {
            errors.append("the ring should drain from 28 dashes at midnight to 0 the next midnight")
        }
        // 15% of 24 hours is 3h36m, so 20:23 is still cyan and 20:25 is red.
        if morning.isUrgent(at: at(2, 20, 23)) || !morning.isUrgent(at: at(2, 20, 25)) {
            errors.append("the ring should turn red under 15% of the day left")
        }

        // 2:00 AM belongs to the new day.
        let lateNight = DayClock.resolve(current: nil, now: at(3, 2))
        if lateNight.dayKey != "2026-10-03" || lateNight.startedAt != at(3, 0) {
            errors.append("2:00 AM should use the new quest day's ring")
        }
        if QuestDay.key(for: at(2, 23, 59)) != "2026-10-02" || QuestDay.key(for: at(3, 0)) != "2026-10-03" {
            errors.append("the quest day should change at midnight")
        }
        if QuestDay.endOfDay(at(2, 23)) != at(3, 0).addingTimeInterval(-1) {
            errors.append("quest deadlines should be 23:59:59")
        }

        // Flying west after midnight: the local date goes back, the ring keeps the later day.
        let nextDay = DayClock.resolve(current: morning, now: at(3, 6))
        let flewWest = DayClock.resolve(current: nextDay, now: at(2, 23))
        if flewWest != nextDay {
            errors.append("an earlier quest day should keep the later day's ring")
        }
        if nextDay.dayKey != "2026-10-03" || nextDay.startedAt != at(3, 0) {
            errors.append("a new quest day should start a new ring at midnight")
        }

        // In New York, the same quest day ends at midnight New York time.
        if let newYork = TimeZone(identifier: "America/New_York") {
            var eastern = Calendar(identifier: .gregorian)
            eastern.timeZone = newYork
            let midnight = eastern.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 0))
            if morning.deadline(in: eastern) != midnight {
                errors.append("the ring should end at midnight in the phone's time zone")
            }
        }

        // A snapshot does not roll back to an earlier quest day, so the day is not judged twice.
        var later = GameSnapshot.fresh(catalog: FallbackCatalog.bundled(), now: at(3, 6))
        let penalty = later.player.penaltyOpen
        later.refreshIfNeeded(catalog: FallbackCatalog.bundled(), now: at(2, 23))
        if later.bundle.dayKey != "2026-10-03" || later.player.penaltyOpen != penalty {
            errors.append("an earlier quest day should not roll the quest day back")
        }
        return errors
    }
}
