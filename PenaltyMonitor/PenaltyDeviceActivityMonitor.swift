import Foundation
import DeviceActivity
import FamilyControls
import ManagedSettings
import UserNotifications

/// Re-asserts the penalty lock while a penalty is active. It does not start a Live Activity.
/// At 5:00 it locks the phone if the quest day that just ended left its required set open, even when the app is closed.
/// Interval end does not lift shields; only the main app clears them after the penalty quests are done.
/// And it counts phone screen time: each threshold event of the daily count writes its minutes for the app to read.
/// This target is `nonisolated`. If the SDK marks these overrides isolated, drop the `nonisolated` keyword.
class PenaltyDeviceActivityMonitor: DeviceActivityMonitor {
    nonisolated override func intervalDidStart(for activity: DeviceActivityName) {
        if activity.rawValue == FocusMonitor.activity {
            FocusMonitor.startDay(now: Date())
            return
        }
        if activity.rawValue == PhoneScreenMonitor.activity { return }
        if activity.rawValue == PenaltyMonitorGroup.dawnActivity {
            PenaltyMonitorShields.lockIfDayMissed(now: Date())
            return
        }
        PenaltyMonitorShields.reassert()
    }

    nonisolated override func intervalDidEnd(for activity: DeviceActivityName) {
        if activity.rawValue == FocusMonitor.activity {
            FocusMonitor.endDay(now: Date())
            return
        }
        if activity.rawValue == PhoneScreenMonitor.activity { return }
        if activity.rawValue == PenaltyMonitorGroup.dawnActivity { return }
        PenaltyMonitorShields.reassert()
    }

    nonisolated override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        if activity.rawValue == FocusMonitor.activity {
            FocusMonitor.record(event: event.rawValue, now: Date())
            return
        }
        if activity.rawValue == PhoneScreenMonitor.activity {
            PhoneScreenMonitor.record(event.rawValue, now: Date())
        }
    }
}

/// Mirrors `PenaltyGroup` and `QuestDay.startHour` in the app. Keep the strings in step.
enum PenaltyMonitorGroup {
    static let suiteName = "group.devplaceholder.HDDJMVMX.thesystem"
    static let penaltyActiveKey = "penaltyActive"
    static let startedAtKey = "penaltyStartedAt"
    static let openDayKey = "penaltyOpenDayKey"
    static let allowedSelectionKey = "penaltyAllowedSelection"
    static let hiddenSelectionKey = "penaltyHiddenSelection"
    static let storeName = "penalty"
    static let dawnActivity = "penaltyDawn"
    static let dayStartHour = 5
}

enum PenaltyMonitorShields {
    nonisolated static func reassert() {
        let defaults = UserDefaults(suiteName: PenaltyMonitorGroup.suiteName) ?? .standard
        guard defaults.bool(forKey: PenaltyMonitorGroup.penaltyActiveKey) else {
            ManagedSettingsStore(named: .init(PenaltyMonitorGroup.storeName)).clearAllSettings()
            return
        }
        lockEverything()
    }

    /// The app writes the open quest day. If that day ended before this 5:00, the penalty starts now.
    nonisolated static func lockIfDayMissed(now: Date) {
        let defaults = UserDefaults(suiteName: PenaltyMonitorGroup.suiteName) ?? .standard
        guard let openDay = defaults.string(forKey: PenaltyMonitorGroup.openDayKey), openDay < questDayKey(for: now) else {
            reassert()
            return
        }
        let alreadyActive = defaults.bool(forKey: PenaltyMonitorGroup.penaltyActiveKey)
        defaults.set(true, forKey: PenaltyMonitorGroup.penaltyActiveKey)
        if defaults.object(forKey: PenaltyMonitorGroup.startedAtKey) == nil {
            defaults.set(now.timeIntervalSince1970, forKey: PenaltyMonitorGroup.startedAtKey)
        }
        lockEverything()
        guard !alreadyActive else { return }
        let content = UNMutableNotificationContent()
        content.title = "PENALTY QUEST"
        content.body = "Yesterday's daily quest was not completed. Every app except your allowed apps is locked until the penalty quest is cleared in The System."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "penalty-\(openDay)", content: content, trigger: nil))
    }

    /// Same rule as `PenaltyEnforcement.applyShields` in the app: every app category except the allowed apps,
    /// every website, and the hidden apps off the Home Screen. iOS keeps calls and emergency SOS open.
    nonisolated private static func lockEverything() {
        let defaults = UserDefaults(suiteName: PenaltyMonitorGroup.suiteName) ?? .standard
        let allowed = apps(defaults, PenaltyMonitorGroup.allowedSelectionKey)
        let hidden = apps(defaults, PenaltyMonitorGroup.hiddenSelectionKey).subtracting(allowed)
        let store = ManagedSettingsStore(named: .init(PenaltyMonitorGroup.storeName))
        store.shield.applications = nil
        store.shield.webDomains = nil
        store.shield.applicationCategories = .all(except: allowed)
        store.shield.webDomainCategories = .all()
        store.application.blockedApplications = Set(hidden.map { Application(token: $0) })
        store.application.denyAppRemoval = true
    }

    /// The app tokens of a selection the app saved, or none.
    nonisolated private static func apps(_ defaults: UserDefaults, _ key: String) -> Set<ApplicationToken> {
        guard let data = defaults.data(forKey: key),
              let selection = try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: data) else { return [] }
        return selection.applicationTokens
    }

    /// Same rule as `QuestDay.key` in the app: before 5:00 is still the day before.
    nonisolated static func questDayKey(for date: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        let local = calendar.component(.hour, from: date) < PenaltyMonitorGroup.dayStartHour
            ? calendar.date(byAdding: .day, value: -1, to: date) ?? date
            : date
        let parts = calendar.dateComponents([.year, .month, .day], from: local)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }
}

/// Mirrors `PhoneScreenGroup` in the app. Keep the strings in step.
enum PhoneScreenMonitor {
    static let activity = "screenTimeDay"
    static let eventPrefix = "phone_"
    static let minutesKey = "screenTimePhoneMinutes"
    static let dayKey = "screenTimePhoneDayKey"
    static let timesKey = "screenTimePhoneTimes"

    /// `phone_95` → 95 minutes of phone use today. Keeps the highest value of the quest day,
    /// and when each threshold was reached, so the app can find phone time that overlaps Mac time.
    nonisolated static func record(_ event: String, now: Date) {
        guard event.hasPrefix(eventPrefix), let minutes = Int(event.dropFirst(eventPrefix.count)) else { return }
        let defaults = UserDefaults(suiteName: PenaltyMonitorGroup.suiteName) ?? .standard
        let today = PenaltyMonitorShields.questDayKey(for: now)
        let sameDay = defaults.string(forKey: dayKey) == today
        let previous = sameDay ? defaults.integer(forKey: minutesKey) : 0
        var times = sameDay ? defaults.dictionary(forKey: timesKey) as? [String: Double] ?? [:] : [:]
        times[String(minutes)] = times[String(minutes)] ?? now.timeIntervalSince1970
        defaults.set(today, forKey: dayKey)
        defaults.set(max(previous, minutes), forKey: minutesKey)
        defaults.set(times, forKey: timesKey)
    }
}

/// Mirrors `FocusGroup` in the app. Keep the strings in step.
/// Stores the highest FOC threshold reached per quest day; the app turns these into `FocusDay` rows.
enum FocusMonitor {
    static let activity = "focusDay"
    static let daysKey = "focusDays"
    static let socialTrackedKey = "focusSocialTracked"
    static let screenPrefix = "screen-"
    static let socialPrefix = "social-"
    /// Older days are dropped. FOC scores the newest 30.
    static let keepDays = 60

    /// A monitored day starts at 0 minutes, so a day under every threshold reads 0, not "no data".
    nonisolated static func startDay(now: Date) {
        update(now: now) { row, socialTracked in
            if row["screen"] == nil { row["screen"] = 0 }
            if socialTracked, row["social"] == nil { row["social"] = 0 }
        }
    }

    nonisolated static func record(event: String, now: Date) {
        for (prefix, field) in [(screenPrefix, "screen"), (socialPrefix, "social")] where event.hasPrefix(prefix) {
            guard let minutes = Int(event.dropFirst(prefix.count)) else { return }
            update(now: now) { row, _ in row[field] = max(row[field] ?? 0, minutes) }
        }
    }

    /// Called at 4:59, which still belongs to the day that is ending.
    nonisolated static func endDay(now: Date) {
        update(now: now) { row, _ in row["complete"] = 1 }
    }

    nonisolated private static func update(now: Date, _ change: (inout [String: Int], Bool) -> Void) {
        let defaults = UserDefaults(suiteName: PenaltyMonitorGroup.suiteName) ?? .standard
        var days = defaults.dictionary(forKey: daysKey) as? [String: [String: Int]] ?? [:]
        let key = PenaltyMonitorShields.questDayKey(for: now)
        var row = days[key] ?? [:]
        change(&row, defaults.bool(forKey: socialTrackedKey))
        days[key] = row
        for old in days.keys.sorted().dropLast(keepDays) {
            days.removeValue(forKey: old)
        }
        defaults.set(days, forKey: daysKey)
    }
}
