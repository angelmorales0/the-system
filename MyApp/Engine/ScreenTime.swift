import Foundation

#if os(iOS)
import DeviceActivity
import FamilyControls
#endif

/// The daily screen time quest: phone minutes from Screen Time, work minutes (the Mac) from the backend.
/// Only the combined total can fail it. A sub-cap over its limit only turns its line red.
/// Over 510 minutes the quest fails, the day misses its required set, and a penalty opens at the day's end.
enum ScreenTime {
    static let questId = "daily_screen_time"
    static let title = "Screen Time"
    static let totalCapMinutes = 510
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

    var totalMinutes: Int { phoneMinutes + workMinutes }
    /// Red line, no failure.
    var phoneOver: Bool { phoneMinutes > ScreenTime.phoneCapMinutes }
    var workOver: Bool { workMinutes > ScreenTime.workCapMinutes }
    /// The only failure: the combined total over 8.5 hours.
    var overTotal: Bool { totalMinutes > ScreenTime.totalCapMinutes }
}

/// App Group storage shared with the Screen Time monitor. The monitor repeats these strings; change them together.
enum PhoneScreenGroup {
    static let selectionKey = "screenTimeSelection"
    static let minutesKey = "screenTimePhoneMinutes"
    static let dayKey = "screenTimePhoneDayKey"
    static let activity = "screenTimeDay"
    /// Event names are this prefix plus the minutes they mark: `phone_95`.
    static let eventPrefix = "phone_"

    /// Thresholds the monitor reports: every 5 minutes up to 2 hours, then every 10 minutes up to the total cap.
    /// Phone minutes can be the whole 510 on a day with no Mac work.
    static let thresholds: [Int] = Array(stride(from: 5, through: 120, by: 5)) + Array(stride(from: 130, through: ScreenTime.totalCapMinutes + 10, by: 10))

    /// Phone minutes the monitor wrote for `dayKey`, or nil when it has none for that day.
    static func minutes(for dayKey: String, defaults: UserDefaults = PenaltyGroup.defaults) -> Int? {
        guard defaults.string(forKey: Self.dayKey) == dayKey else { return nil }
        return defaults.integer(forKey: minutesKey)
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
    /// Takes the newest readings for today and moves the Screen Time row. Over the total cap, the row fails and stays failed.
    mutating func applyScreenTime(phoneMinutes: Int?, workMinutes: Int?) {
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

        // 8 h of work and 30 min of phone is 510: work is red, the quest still holds.
        snapshot.applyScreenTime(phoneMinutes: 30, workMinutes: 480)
        let day = snapshot.screenTimeToday
        let quest = snapshot.bundle.quests.first { $0.id == ScreenTime.questId }
        if !day.workOver || day.phoneOver || day.overTotal || quest?.status != .pending || quest?.progress.current != 510 {
            errors.append("8 h work + 30 min phone should be red for work but not failed, got \(day) \(String(describing: quest?.status))")
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

        // One more minute of phone: 511 fails the quest and opens a penalty at the day's end.
        snapshot.applyScreenTime(phoneMinutes: 31, workMinutes: nil)
        if snapshot.bundle.quests.first(where: { $0.id == ScreenTime.questId })?.status != .failed || !snapshot.missesRequiredSet {
            errors.append("511 minutes should fail the quest and miss the required set")
        }
        // A lower reading later does not undo it.
        snapshot.applyScreenTime(phoneMinutes: 10, workMinutes: 10)
        if snapshot.screenTimeToday.totalMinutes != 511 || snapshot.bundle.quests.first(where: { $0.id == ScreenTime.questId })?.status != .failed {
            errors.append("a lower reading must not lower the count or clear the failure")
        }
        snapshot.refreshIfNeeded(catalog: catalog, now: now.addingTimeInterval(86_400))
        if snapshot.player.penaltyTier != 1 || snapshot.screenTimeToday.totalMinutes != 0 {
            errors.append("a failed Screen Time day should open penalty tier 1 and start the next day at 0, got tier \(snapshot.player.penaltyTier)")
        }

        // 7 h + 1.5 h is exactly the cap; both lines stay normal.
        var exact = ScreenTimeDay(dayKey: "x")
        exact.workMinutes = 420
        exact.phoneMinutes = 90
        if exact.workOver || exact.phoneOver || exact.overTotal {
            errors.append("7 h work and 1.5 h phone should be inside every cap")
        }
        if PhoneScreenGroup.thresholds.first != 5 || PhoneScreenGroup.thresholds.last ?? 0 <= ScreenTime.totalCapMinutes
            || Set(PhoneScreenGroup.thresholds).count != PhoneScreenGroup.thresholds.count {
            errors.append("phone thresholds should run from 5 minutes past the total cap, without repeats")
        }
        if ScreenTime.clock(280) != "4h 40m" || ScreenTime.clock(32) != "32m" || ScreenTime.clock(420) != "7h" {
            errors.append("screen time clock format wrong")
        }
        return errors
    }
}
