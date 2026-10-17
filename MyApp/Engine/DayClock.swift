import Foundation

/// The quest day's countdown ring. It starts full when the phone powers on in the morning
/// and drains to empty at midnight, when an unfinished required set becomes a penalty.
/// Under `urgentFraction` of the day left, the ring turns penalty red.
struct DayClock: Codable, Equatable {
    enum Source: String, Codable {
        /// The phone powered on during this quest day.
        case boot
        /// The phone stayed on overnight, so the first app open of the day stands in.
        case open
    }

    static let segments = 28
    /// The ring turns red when less than this share of the day is left.
    static let urgentFraction = 0.15
    static let storageKey = "com.angelmorales.thesystem.dayclock.v1"

    var dayKey: String
    var startedAt: Date
    var source: Source

    /// Local midnight that ends the ring's quest day, in the phone's current time zone.
    var deadline: Date { deadline(in: QuestDay.calendar) }

    func deadline(in calendar: Calendar) -> Date {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let dayStart = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              let midnight = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return QuestDay.endOfDay(startedAt)
        }
        return midnight
    }

    func progress(at now: Date) -> Double {
        let span = deadline.timeIntervalSince(startedAt)
        guard span > 0 else { return 1 }
        return min(max(now.timeIntervalSince(startedAt) / span, 0), 1)
    }

    func litSegments(at now: Date) -> Int {
        Int((progress(at: now) * Double(Self.segments)).rounded(.down))
    }

    /// Share of the day still left: 1 at the start, 0 at midnight.
    func remaining(at now: Date) -> Double {
        1 - progress(at: now)
    }

    /// Dashes still lit as the ring drains: all at the start, none at midnight.
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

    /// Keeps today's start, or starts a new day at today's power-on (else at this open).
    /// A power-on after an `.open` start moves the start once: a late-night open, then sleep, then the phone turns on.
    static func resolve(current: DayClock?, now: Date, boot: Date?) -> DayClock {
        let key = QuestDay.key(for: now)
        let bootToday = boot.flatMap { $0 <= now && QuestDay.key(for: $0) == key ? $0 : nil }
        // The local date went back after a flight west. Keep the later day's ring.
        if let current, current.dayKey > key {
            return current
        }
        if let current, current.dayKey == key {
            if current.source == .open, let bootToday, bootToday > current.startedAt {
                return DayClock(dayKey: key, startedAt: bootToday, source: .boot)
            }
            return current
        }
        if let bootToday {
            return DayClock(dayKey: key, startedAt: bootToday, source: .boot)
        }
        return DayClock(dayKey: key, startedAt: now, source: .open)
    }

    /// When the phone last powered on. Restarts reset it; sleep and app launches do not.
    static func bootTime() -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var value = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctl(&mib, u_int(mib.count), &value, &size, nil, 0) == 0, value.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value.tv_sec) + TimeInterval(value.tv_usec) / 1_000_000)
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

        // Phone off overnight, on at 7:00, app opened at 9:30: the ring starts at 7:00.
        let morning = DayClock.resolve(current: nil, now: at(2, 9, 30), boot: at(2, 7))
        if morning.startedAt != at(2, 7) || morning.source != .boot {
            errors.append("the ring should start at today's power-on")
        }
        if morning.deadline != at(3, 0) {
            errors.append("the ring should be full at the next local midnight")
        }
        if morning.litSegments(at: at(2, 7)) != 0 || morning.litSegments(at: at(3, 0)) != DayClock.segments {
            errors.append("the ring should go from empty at power-on to full at midnight")
        }
        if morning.litSegments(at: at(2, 15, 30)) != 14 {
            errors.append("halfway from 7:00 to midnight should light 14 of 28 segments, got \(morning.litSegments(at: at(2, 15, 30)))")
        }
        // The drawn ring drains: all 28 dashes at power-on, 14 halfway, none at midnight.
        if morning.remainingSegments(at: at(2, 7)) != DayClock.segments
            || morning.remainingSegments(at: at(2, 15, 30)) != 14
            || morning.remainingSegments(at: at(3, 0)) != 0 {
            errors.append("the ring should drain from 28 dashes at power-on to 0 at midnight")
        }
        // 17 hours from 7:00 to midnight: 15% left is 2h33m, so 21:26 is still cyan and 21:28 is red.
        if morning.isUrgent(at: at(2, 21, 26)) || !morning.isUrgent(at: at(2, 21, 28)) || !morning.isUrgent(at: at(3, 0)) {
            errors.append("the ring should turn red under 15% of the day left")
        }

        // Phone stayed on since yesterday: the first open stands in.
        let stayedOn = DayClock.resolve(current: nil, now: at(2, 8), boot: at(1, 7))
        if stayedOn.startedAt != at(2, 8) || stayedOn.source != .open {
            errors.append("without a power-on today the first open should start the ring")
        }

        // Opened at 0:30 before sleep, phone on at 7:00: the start moves to 7:00 once.
        let lateNight = DayClock.resolve(current: nil, now: at(2, 0, 30), boot: at(1, 7))
        let woke = DayClock.resolve(current: lateNight, now: at(2, 7, 5), boot: at(2, 7))
        if woke.startedAt != at(2, 7) || woke.source != .boot {
            errors.append("a power-on after a late-night open should restart the ring")
        }

        // A restart in the afternoon keeps the morning start.
        let restarted = DayClock.resolve(current: woke, now: at(2, 15), boot: at(2, 14))
        if restarted != woke {
            errors.append("a later restart should not reset a power-on start")
        }

        // Flying west after midnight: the local date goes back, the ring keeps the later day.
        let flewWest = DayClock.resolve(current: woke, now: at(1, 22), boot: at(2, 7))
        if flewWest != woke {
            errors.append("an earlier local date should keep the later day's ring")
        }

        // In New York, the same quest day ends at New York midnight.
        if let newYork = TimeZone(identifier: "America/New_York") {
            var eastern = Calendar(identifier: .gregorian)
            eastern.timeZone = newYork
            let midnight = eastern.date(from: DateComponents(year: 2026, month: 10, day: 3))
            if woke.deadline(in: eastern) != midnight {
                errors.append("the ring should end at local midnight in the phone's time zone")
            }
        }

        // A snapshot does not roll back to an earlier local date, so the day is not judged twice.
        var later = GameSnapshot.fresh(catalog: FallbackCatalog.bundled(), now: at(3, 1))
        let tier = later.player.penaltyTier
        later.refreshIfNeeded(catalog: FallbackCatalog.bundled(), now: at(2, 22))
        if later.bundle.dayKey != "2026-10-03" || later.player.penaltyTier != tier {
            errors.append("an earlier local date should not roll the quest day back")
        }

        // The next quest day starts fresh.
        let nextDay = DayClock.resolve(current: woke, now: at(3, 8), boot: at(3, 6, 45))
        if nextDay.dayKey != "2026-10-03" || nextDay.startedAt != at(3, 6, 45) {
            errors.append("a new quest day should start a new ring")
        }
        return errors
    }
}
