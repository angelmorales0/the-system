import Foundation

#if os(iOS)
import DeviceActivity
import FamilyControls
#endif

/// The daily screen time quest: phone minutes from Screen Time, work minutes (the Mac) from the backend.
/// Only the combined total can fail it. A sub-cap over its limit only turns its line red.
/// Phone minutes that overlap Mac minutes count once. Until the Macs report their minutes, the full
/// possible overlap is taken out, so the total is never inflated (see `ScreenTimeDay.sharedMinutes`).
/// At 500 minutes the row turns yellow. Past the 30-minute grace (over 530) the quest fails,
/// the day misses its required set, and a penalty opens at the day's end.
enum ScreenTime {
    static let questId = "daily_screen_time"
    static let title = "Screen Time"
    static let totalCapMinutes = 500
    /// Minutes over the total cap before the quest fails.
    static let graceMinutes = 30
    static var failAfterMinutes: Int { totalCapMinutes + graceMinutes }
    static let workCapMinutes = 420
    static let phoneCapMinutes = 90

    static func quest(mode: QuestMode, now: Date) -> Quest {
        Quest(
            id: questId,
            title: title,
            kind: .daily,
            stat: .FOC,
            verification: VerificationSpec(method: .screenTimeLimit, params: ["maxMinutes": .number(Double(totalCapMinutes))]),
            deadline: QuestDay.endOfDay(now),
            xp: 20,
            difficulty: .normal,
            mode: mode,
            progress: QuestProgress(current: 0, target: Double(totalCapMinutes), unit: "min"),
            reward: nil,
            status: .pending,
            grantedXP: 0,
            grantedStatPoints: 0,
            grantedRecoveryToken: false,
            assignedAt: now
        )
    }

    /// Adds the row once, after the last required quest, so Stretching still follows it.
    static func ensure(in bundle: QuestBundle, now: Date) -> QuestBundle {
        guard !bundle.quests.isEmpty, !bundle.quests.contains(where: { $0.id == questId }) else { return bundle }
        var copy = bundle
        let insertAt = copy.quests.lastIndex(where: { $0.kind != .optional }).map { $0 + 1 } ?? copy.quests.count
        copy.quests.insert(quest(mode: bundle.mode, now: now), at: insertAt)
        return copy
    }

    /// `4h 40m`, `32m`, `7h`.
    static func clock(_ minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest)m" }
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }
}

/// One quest day of screen time. A source with no reading counts as 0 and says so.
struct ScreenTimeDay: Codable, Equatable {
    var dayKey: String
    var phoneMinutes = 0
    var workMinutes = 0
    var phoneMeasured = false
    var workMeasured = false
    /// Phone minutes that surely happened while a Mac was also counting (see `ScreenOverlap`). Counted once.
    /// Nil until the Macs' minute bitmap arrives. Optional, so days saved before it existed still load.
    var overlapMinutes: Int?

    /// True once the Macs' minute bitmap gave a real overlap count.
    var overlapMeasured: Bool { overlapMinutes != nil }
    /// Minutes counted once. With no measurement, every phone minute may have been a Mac minute too,
    /// so the full possible overlap is taken out: the total is never inflated by double counting.
    var sharedMinutes: Int {
        guard let overlapMinutes else { return min(phoneMinutes, workMinutes) }
        return min(overlapMinutes, phoneMinutes, workMinutes)
    }
    var totalMinutes: Int { phoneMinutes + workMinutes - sharedMinutes }
    /// Red line, no failure.
    var phoneOver: Bool { phoneMinutes > ScreenTime.phoneCapMinutes }
    var workOver: Bool { workMinutes > ScreenTime.workCapMinutes }
    /// Yellow row: the total reached 8 h 20 m but is still inside the grace.
    var atCap: Bool { totalMinutes >= ScreenTime.totalCapMinutes && !overTotal }
    /// The only failure: the combined total more than 30 minutes over 8 h 20 m.
    var overTotal: Bool { totalMinutes > ScreenTime.failAfterMinutes }
}

/// App Group storage shared with the Screen Time monitor. The monitor repeats these strings; change them together.
enum PhoneScreenGroup {
    static let selectionKey = "screenTimeSelection"
    static let minutesKey = "screenTimePhoneMinutes"
    static let dayKey = "screenTimePhoneDayKey"
    static let activity = "screenTimeDay"
    /// Event names are this prefix plus the minutes they mark: `phone_95`.
    static let eventPrefix = "phone_"
    /// Threshold minutes → when the monitor saw it, as seconds since 1970.
    static let timesKey = "screenTimePhoneTimes"

    /// Thresholds the monitor reports: every 5 minutes up to 2 hours, then every 10 minutes past the failure point.
    /// Phone minutes can be the whole day on a day with no Mac work.
    static let thresholds: [Int] = Array(stride(from: 5, through: 120, by: 5)) + Array(stride(from: 130, through: ScreenTime.failAfterMinutes + 10, by: 10))

    /// Phone minutes the monitor wrote for `dayKey`, or nil when it has none for that day.
    static func minutes(for dayKey: String, defaults: UserDefaults = PenaltyGroup.defaults) -> Int? {
        guard defaults.string(forKey: Self.dayKey) == dayKey else { return nil }
        return defaults.integer(forKey: minutesKey)
    }

    /// When each phone threshold was reached on `dayKey`. Empty when the monitor has none for that day.
    static func times(for dayKey: String, defaults: UserDefaults = PenaltyGroup.defaults) -> [Int: Date] {
        guard defaults.string(forKey: Self.dayKey) == dayKey,
              let raw = defaults.dictionary(forKey: timesKey) as? [String: Double] else { return [:] }
        var times: [Int: Date] = [:]
        for (minutes, seconds) in raw {
            if let minutes = Int(minutes) { times[minutes] = Date(timeIntervalSince1970: seconds) }
        }
        return times
    }

    static var hasSelection: Bool {
        PenaltyGroup.defaults.data(forKey: selectionKey) != nil
    }

    #if os(iOS)
    static func load() -> FamilyActivitySelection {
        guard let data = PenaltyGroup.defaults.data(forKey: selectionKey),
              let selection = try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: data) else {
            return FamilyActivitySelection()
        }
        return selection
    }

    static func save(_ selection: FamilyActivitySelection) {
        let empty = selection.applicationTokens.isEmpty && selection.categoryTokens.isEmpty && selection.webDomainTokens.isEmpty
        guard !empty, let data = try? PropertyListEncoder().encode(selection) else {
            PenaltyGroup.defaults.removeObject(forKey: selectionKey)
            return
        }
        PenaltyGroup.defaults.set(data, forKey: selectionKey)
    }
    #endif
}

/// Finds phone minutes that happened while a Mac was counting, so the same minute is not counted twice.
/// iOS only says when phone use passed each threshold, not which minutes it used. Between two thresholds
/// the phone used `p` minutes somewhere in a window of `w` minutes, and the Macs were active `m` of them.
/// At least `p + m - w` of those minutes were shared, so only that much is removed: never more than is sure.
enum ScreenOverlap {
    /// Extra minute on each window for a late threshold report, so the estimate stays on the safe side.
    static let slackMinutes = 1

    static func minutes(phoneTimes: [Int: Date], macActive: Data, dayStart: Date) -> Int {
        let slots = macActive.count * 8
        func active(_ slot: Int) -> Bool { macActive[slot >> 3] & (1 << UInt8(slot & 7)) != 0 }
        var shared = 0
        var lastMinutes = 0
        var windowStart = 0
        for (minutes, time) in phoneTimes.sorted(by: { $0.key < $1.key }) {
            let offset = time.timeIntervalSince(dayStart) / 60
            let windowEnd = min(slots, max(windowStart, Int(offset.rounded(.up))))
            let phone = minutes - lastMinutes
            let mac = (windowStart..<windowEnd).filter(active).count
            let window = windowEnd - windowStart + slackMinutes
            shared += max(0, min(phone, mac, phone + mac - window))
            lastMinutes = minutes
            windowStart = min(windowEnd, max(windowStart, Int(offset.rounded(.down))))
        }
        return shared
    }
}

/// Starts the daily phone count: one schedule from the quest day's start to the next, with a threshold event every few minutes.
/// Screen Time counts only the apps the player chose, so the picker should hold All Apps & Categories.
enum ScreenTimeEnforcement {
    static func syncMonitoring() {
        #if os(iOS)
        let center = DeviceActivityCenter()
        let name = DeviceActivityName(PhoneScreenGroup.activity)
        center.stopMonitoring([name])
        let selection = PhoneScreenGroup.load()
        guard !(selection.applicationTokens.isEmpty && selection.categoryTokens.isEmpty && selection.webDomainTokens.isEmpty) else { return }
        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: QuestDay.startHour, minute: 0),
            intervalEnd: DateComponents(hour: (QuestDay.startHour + 23) % 24, minute: 59),
            repeats: true
        )
        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        for minutes in PhoneScreenGroup.thresholds {
            events[DeviceActivityEvent.Name(PhoneScreenGroup.eventPrefix + String(minutes))] = DeviceActivityEvent(
                applications: selection.applicationTokens,
                categories: selection.categoryTokens,
                webDomains: selection.webDomainTokens,
                threshold: DateComponents(minute: minutes)
            )
        }
        try? center.startMonitoring(name, during: schedule, events: events)
        #endif
    }
}

extension GameSnapshot {
    /// Takes the newest readings for today and moves the Screen Time row. Past the grace, the row fails and stays failed.
    mutating func applyScreenTime(phoneMinutes: Int?, workMinutes: Int?, overlapMinutes: Int? = nil) {
        var day = screenTime?.dayKey == bundle.dayKey ? screenTime ?? ScreenTimeDay(dayKey: bundle.dayKey) : ScreenTimeDay(dayKey: bundle.dayKey)
        // Readings only grow during a day; a stale or missing one never lowers the count.
        if let phoneMinutes {
            day.phoneMinutes = max(day.phoneMinutes, phoneMinutes)
            day.phoneMeasured = true
        }
        if let workMinutes {
            day.workMinutes = max(day.workMinutes, workMinutes)
            day.workMeasured = true
        }
        if let overlapMinutes {
            day.overlapMinutes = overlapMinutes
        }
        screenTime = day
        guard let index = bundle.quests.firstIndex(where: { $0.id == ScreenTime.questId }) else { return }
        var quest = bundle.quests[index]
        quest.progress.current = Double(day.totalMinutes)
        if day.overTotal && quest.status == .pending {
            quest.status = .failed
        }
        bundle.quests[index] = quest
    }

    /// Today's readings, or an empty day when nothing has come in yet.
    var screenTimeToday: ScreenTimeDay {
        screenTime?.dayKey == bundle.dayKey ? screenTime ?? ScreenTimeDay(dayKey: bundle.dayKey) : ScreenTimeDay(dayKey: bundle.dayKey)
    }
}

// MARK: - Self-check (runs in DEBUG at launch)

enum ScreenTimeRules {
    static func check() -> [String] {
        var errors: [String] = []
        let catalog = FallbackCatalog.bundled()
        guard let now = QuestDay.date(from: "2026-10-05") else { return ["quest day failed to parse"] }

        // Every day gets the row before Stretching, and a Training day keeps it.
        var snapshot = GameSnapshot.fresh(catalog: catalog, now: now)
        let ids = snapshot.bundle.quests.map(\.id)
        guard let row = ids.firstIndex(of: ScreenTime.questId), let stretch = ids.firstIndex(of: DailyStretch.questId), row < stretch else {
            return ["every day should have the Screen Time row before Stretching, got \(ids)"]
        }
        if TrainingDay.exerciseOnly(snapshot.bundle)?.quests.contains(where: { $0.id == ScreenTime.questId }) != true {
            errors.append("a Training day should keep the Screen Time row")
        }
        if VerificationMethod.screenTimeLimit.allowsLocalCheckbox {
            errors.append("Screen Time is measured, so it must not be a checkbox")
        }

        // 8 h of work and 30 min of phone is 510, past the 500 cap: work is red, the row is yellow, the quest still holds.
        snapshot.applyScreenTime(phoneMinutes: 30, workMinutes: 480, overlapMinutes: 0)
        let day = snapshot.screenTimeToday
        let quest = snapshot.bundle.quests.first { $0.id == ScreenTime.questId }
        if !day.workOver || day.phoneOver || day.overTotal || !day.atCap || quest?.status != .pending || quest?.progress.current != 510 {
            errors.append("8 h work + 30 min phone should be red for work and yellow, but not failed, got \(day) \(String(describing: quest?.status))")
        }
        // A pending Screen Time row alone does not count as an open required set.
        for index in snapshot.bundle.quests.indices where snapshot.bundle.quests[index].id != ScreenTime.questId {
            snapshot.bundle.quests[index].status = .completed
        }
        if snapshot.missesRequiredSet {
            errors.append("a day with everything done and Screen Time under the cap should not miss its required set")
        }
        // At the day's end it completes, with its XP, and no penalty opens.
        var held = snapshot
        let xp = held.player.xp + held.player.level * 1_000_000
        held.refreshIfNeeded(catalog: catalog, now: now.addingTimeInterval(86_400))
        if held.player.penaltyTier != 0 || held.questHistory.first?.quests.first(where: { $0.title == ScreenTime.title })?.status != .completed
            || held.player.xp + held.player.level * 1_000_000 <= xp {
            errors.append("a held Screen Time day should complete with XP and open no penalty")
        }

        // 530 is the last minute of the grace: still yellow and pending.
        snapshot.applyScreenTime(phoneMinutes: 50, workMinutes: nil)
        if !snapshot.screenTimeToday.atCap || snapshot.bundle.quests.first(where: { $0.id == ScreenTime.questId })?.status != .pending {
            errors.append("530 minutes should be yellow and still pending")
        }
        // One more minute of phone: 531 fails the quest and opens a penalty at the day's end.
        snapshot.applyScreenTime(phoneMinutes: 51, workMinutes: nil)
        if snapshot.screenTimeToday.atCap || snapshot.bundle.quests.first(where: { $0.id == ScreenTime.questId })?.status != .failed || !snapshot.missesRequiredSet {
            errors.append("531 minutes should fail the quest and miss the required set")
        }
        // A lower reading later does not undo it.
        snapshot.applyScreenTime(phoneMinutes: 10, workMinutes: 10)
        if snapshot.screenTimeToday.totalMinutes != 531 || snapshot.bundle.quests.first(where: { $0.id == ScreenTime.questId })?.status != .failed {
            errors.append("a lower reading must not lower the count or clear the failure")
        }
        snapshot.refreshIfNeeded(catalog: catalog, now: now.addingTimeInterval(86_400))
        if snapshot.player.penaltyTier != 1 || snapshot.screenTimeToday.totalMinutes != 0 {
            errors.append("a failed Screen Time day should open penalty tier 1 and start the next day at 0, got tier \(snapshot.player.penaltyTier)")
        }

        // 7 h + 1.5 h is 510, inside the grace: both lines stay normal and the row is yellow.
        var exact = ScreenTimeDay(dayKey: "x")
        exact.workMinutes = 420
        exact.phoneMinutes = 90
        exact.overlapMinutes = 0
        if exact.workOver || exact.phoneOver || exact.overTotal || !exact.atCap {
            errors.append("7 h work and 1.5 h phone should be inside both sub-caps and the grace")
        }
        if PhoneScreenGroup.thresholds.first != 5 || PhoneScreenGroup.thresholds.last ?? 0 <= ScreenTime.failAfterMinutes
            || Set(PhoneScreenGroup.thresholds).count != PhoneScreenGroup.thresholds.count {
            errors.append("phone thresholds should run from 5 minutes past the total cap, without repeats")
        }
        // Phone 10:00–10:10 while a Mac was active 10:00–10:15: the second 5 minutes surely overlap.
        if let start = QuestDay.start(of: "2026-10-05") {
            var bits = [UInt8](repeating: 0, count: 188)
            for slot in 300..<315 { bits[slot >> 3] |= 1 << UInt8(slot & 7) }
            let at = { (minute: Int) in start.addingTimeInterval(Double(minute) * 60) }
            let shared = ScreenOverlap.minutes(phoneTimes: [5: at(305), 10: at(310)], macActive: Data(bits), dayStart: start)
            if shared != 4 {
                errors.append("5 phone minutes inside a 5-minute Mac window should share 4 minutes after the slack, got \(shared)")
            }
            // Phone use while every Mac was idle shares nothing.
            if ScreenOverlap.minutes(phoneTimes: [5: at(605), 10: at(610)], macActive: Data(bits), dayStart: start) != 0 {
                errors.append("phone time away from the Mac should not overlap")
            }
            var both = ScreenTimeDay(dayKey: "x")
            both.phoneMinutes = 60
            both.workMinutes = 60
            both.overlapMinutes = 50
            if both.totalMinutes != 70 || both.sharedMinutes != 50 || !both.overlapMeasured {
                errors.append("an hour on each with 50 shared minutes should total 70, got \(both.totalMinutes)")
            }
        }
        // No overlap measurement yet: the phone minutes may all be Mac minutes too, so the total is the larger side.
        var unknown = ScreenTimeDay(dayKey: "x")
        unknown.phoneMinutes = 90
        unknown.workMinutes = 480
        if unknown.overlapMeasured || unknown.sharedMinutes != 90 || unknown.totalMinutes != 480 || unknown.overTotal {
            errors.append("without an overlap count 90 phone + 480 work should total 480, got \(unknown.totalMinutes)")
        }
        // One side alone past the grace still fails, with or without the measurement.
        unknown.phoneMinutes = 531
        if !unknown.overTotal || unknown.totalMinutes != 531 {
            errors.append("531 phone minutes should fail even before the overlap is measured, got \(unknown.totalMinutes)")
        }
        // The same day through the snapshot: no measurement holds the row, then a measured overlap of 10 makes it 560 and fails it.
        var pending = GameSnapshot.fresh(catalog: catalog, now: now)
        pending.applyScreenTime(phoneMinutes: 90, workMinutes: 480)
        if pending.screenTimeToday.totalMinutes != 480 || pending.bundle.quests.first(where: { $0.id == ScreenTime.questId })?.status != .pending {
            errors.append("90 phone + 480 work with no overlap count must not fail the day, got \(pending.screenTimeToday.totalMinutes)")
        }
        pending.applyScreenTime(phoneMinutes: nil, workMinutes: nil, overlapMinutes: 10)
        if pending.screenTimeToday.totalMinutes != 560 || pending.bundle.quests.first(where: { $0.id == ScreenTime.questId })?.status != .failed {
            errors.append("a measured overlap of 10 should make 90 + 480 total 560 and fail, got \(pending.screenTimeToday.totalMinutes)")
        }
        if ScreenTime.clock(280) != "4h 40m" || ScreenTime.clock(32) != "32m" || ScreenTime.clock(420) != "7h" {
            errors.append("screen time clock format wrong")
        }
        return errors
    }
}
