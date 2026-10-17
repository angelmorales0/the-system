import Foundation

/// The quest day's countdown ring. It starts empty when the phone powers on in the morning
/// and is full at midnight, when an unfinished required set becomes a penalty.
struct DayClock: Codable, Equatable {
    enum Source: String, Codable {
        /// The phone powered on during this quest day.
        case boot
        /// The phone stayed on overnight, so the first app open of the day stands in.
        case open
    }

    static let segments = 28
    static let storageKey = "com.angelmorales.thesystem.dayclock.v1"

    var dayKey: String
    var startedAt: Date
    var source: Source

    /// Midnight that ends the quest day the ring started on.
    var deadline: Date {
        let calendar = QuestDay.calendar
        let dayStart = calendar.startOfDay(for: startedAt)
        return calendar.date(byAdding: .day, value: 1, to: dayStart) ?? QuestDay.endOfDay(startedAt)
    }

    func progress(at now: Date) -> Double {
        let span = deadline.timeIntervalSince(startedAt)
        guard span > 0 else { return 1 }
        return min(max(now.timeIntervalSince(startedAt) / span, 0), 1)
    }

    func litSegments(at now: Date) -> Int {
        Int((progress(at: now) * Double(Self.segments)).rounded(.down))
    }

    /// Keeps today's start, or starts a new day at today's power-on (else at this open).
    /// A power-on after an `.open` start moves the start once: a late-night open, then sleep, then the phone turns on.
    static func resolve(current: DayClock?, now: Date, boot: Date?) -> DayClock {
        let key = QuestDay.key(for: now)
        let bootToday = boot.flatMap { $0 <= now && QuestDay.key(for: $0) == key ? $0 : nil }
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

        // The next quest day starts fresh.
        let nextDay = DayClock.resolve(current: woke, now: at(3, 8), boot: at(3, 6, 45))
        if nextDay.dayKey != "2026-10-03" || nextDay.startedAt != at(3, 6, 45) {
            errors.append("a new quest day should start a new ring")
        }
        return errors
    }
}
