import Foundation

/// The quest day's countdown ring. It starts full at 5:00 local time and drains to empty
/// at 5:00 the next morning, when an unfinished required set becomes a penalty.
/// Under `urgentFraction` of the day left, the ring turns penalty red.
struct DayClock: Codable, Equatable {
    static let segments = 28
    /// The ring turns red when less than this share of the day is left.
    static let urgentFraction = 0.15
    static let storageKey = "com.angelmorales.thesystem.dayclock.v2"

    var dayKey: String
    var startedAt: Date

    /// 5:00 the next morning, which ends the ring's quest day in the phone's current time zone.
    var deadline: Date { deadline(in: QuestDay.calendar) }

    func deadline(in calendar: Calendar) -> Date {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let dayStart = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: QuestDay.startHour)),
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

    /// Share of the day still left: 1 at 5:00, 0 at 5:00 the next morning.
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

    /// Keeps today's ring, or starts the ring for the quest day that holds `now` at its 5:00 start.
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

        // Opened at 9:30: the ring started at 5:00 and ends at 5:00 the next morning.
        let morning = DayClock.resolve(current: nil, now: at(2, 9, 30))
        if morning.dayKey != "2026-10-02" || morning.startedAt != at(2, 5) {
            errors.append("the ring should start at 5:00 local time, got \(morning.startedAt)")
        }
        if morning.deadline != at(3, 5) {
            errors.append("the ring should end at 5:00 the next morning")
        }
        // 24 hours: half the ring is gone at 17:00.
        if morning.remainingSegments(at: at(2, 5)) != DayClock.segments
            || morning.remainingSegments(at: at(2, 17)) != 14
            || morning.remainingSegments(at: at(3, 5)) != 0 {
            errors.append("the ring should drain from 28 dashes at 5:00 to 0 the next 5:00")
        }
        // 15% of 24 hours is 3h36m, so 1:23 is still cyan and 1:25 is red.
        if morning.isUrgent(at: at(3, 1, 23)) || !morning.isUrgent(at: at(3, 1, 25)) {
            errors.append("the ring should turn red under 15% of the day left")
        }

        // 2:00 AM still belongs to the day before.
        let lateNight = DayClock.resolve(current: nil, now: at(3, 2))
        if lateNight.dayKey != "2026-10-02" || lateNight.startedAt != at(2, 5) {
            errors.append("2:00 AM should still use the previous quest day's ring")
        }
        if QuestDay.key(for: at(3, 4, 59)) != "2026-10-02" || QuestDay.key(for: at(3, 5)) != "2026-10-03" {
            errors.append("the quest day should change at 5:00, not at midnight")
        }
        if QuestDay.endOfDay(at(2, 23)) != at(3, 5).addingTimeInterval(-1) {
            errors.append("quest deadlines should be 4:59:59 the next morning")
        }

        // Flying west after 5:00: the local date goes back, the ring keeps the later day.
        let nextDay = DayClock.resolve(current: morning, now: at(3, 6))
        let flewWest = DayClock.resolve(current: nextDay, now: at(3, 4))
        if flewWest != nextDay {
            errors.append("an earlier quest day should keep the later day's ring")
        }
        if nextDay.dayKey != "2026-10-03" || nextDay.startedAt != at(3, 5) {
            errors.append("a new quest day should start a new ring at 5:00")
        }

        // In New York, the same quest day ends at 5:00 New York time.
        if let newYork = TimeZone(identifier: "America/New_York") {
            var eastern = Calendar(identifier: .gregorian)
            eastern.timeZone = newYork
            let fiveAM = eastern.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 5))
            if morning.deadline(in: eastern) != fiveAM {
                errors.append("the ring should end at 5:00 in the phone's time zone")
            }
        }

        // A snapshot does not roll back to an earlier quest day, so the day is not judged twice.
        var later = GameSnapshot.fresh(catalog: FallbackCatalog.bundled(), now: at(3, 6))
        let tier = later.player.penaltyTier
        later.refreshIfNeeded(catalog: FallbackCatalog.bundled(), now: at(3, 4))
        if later.bundle.dayKey != "2026-10-03" || later.player.penaltyTier != tier {
            errors.append("an earlier quest day should not roll the quest day back")
        }
        return errors
    }
}
