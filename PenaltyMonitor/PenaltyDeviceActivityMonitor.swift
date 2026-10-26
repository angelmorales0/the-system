import Foundation
import DeviceActivity
import FamilyControls
import ManagedSettings
import UserNotifications

/// Re-asserts the all-app penalty lock while a penalty is active. It does not start a Live Activity.
/// At 5:00 it locks the phone if the quest day that just ended left its required set open, even when the app is closed.
/// Interval end does not lift shields; only the main app clears them after the penalty quests are done.
/// It also runs the bedtime emergency: distractor use after bedtime locks every app, and the release schedule lifts it.
/// This target is `nonisolated`. If the SDK marks these overrides isolated, drop the `nonisolated` keyword.
class PenaltyDeviceActivityMonitor: DeviceActivityMonitor {
    nonisolated override func intervalDidStart(for activity: DeviceActivityName) {
        if activity.rawValue == FocusMonitor.activity {
            FocusMonitor.startDay(now: Date())
            return
        }
        if EmergencyMonitor.isEmergency(activity) { return }
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
        if activity.rawValue == EmergencyMonitor.releaseActivity {
            EmergencyMonitor.endLockdown()
            return
        }
        if EmergencyMonitor.isEmergency(activity) || activity.rawValue == PenaltyMonitorGroup.dawnActivity { return }
        PenaltyMonitorShields.reassert()
    }

    nonisolated override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        if activity.rawValue == FocusMonitor.activity {
            FocusMonitor.record(event: event.rawValue, now: Date())
            return
        }
        guard activity.rawValue == EmergencyMonitor.bedtimeActivity, event.rawValue == EmergencyMonitor.bedtimeEvent else { return }
        EmergencyMonitor.startLockdown(now: Date())
    }
}

/// Mirrors `PenaltyGroup` and `QuestDay.startHour` in the app. Keep the strings in step.
enum PenaltyMonitorGroup {
    static let suiteName = "group.devplaceholder.HDDJMVMX.thesystem"
    static let penaltyActiveKey = "penaltyActive"
    static let startedAtKey = "penaltyStartedAt"
    static let openDayKey = "penaltyOpenDayKey"
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
        content.body = "Yesterday's daily quest was not completed. Every app is locked until the penalty quest is cleared in The System."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "penalty-\(openDay)", content: content, trigger: nil))
    }

    /// Every app category and website. iOS keeps calls and emergency SOS open.
    nonisolated private static func lockEverything() {
        let store = ManagedSettingsStore(named: .init(PenaltyMonitorGroup.storeName))
        store.shield.applications = nil
        store.shield.webDomains = nil
        store.shield.applicationCategories = .all()
        store.shield.webDomainCategories = .all()
        store.application.denyAppRemoval = true
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

/// Mirrors `EmergencyGroup` in the app. Keep the strings in step.
enum EmergencyMonitor {
    static let storeName = "emergency"
    static let bedtimeActivity = "emergencyBedtime"
    static let releaseActivity = "emergencyRelease"
    static let bedtimeEvent = "bedtimeUse"
    static let triggeredAtKey = "emergencyBedtimeTriggeredAt"
    static let lockdownMinutesKey = "emergencyLockdownMinutes"
    static let lockdownKindKey = "emergencyLockdownKind"
    static let lockdownEndsAtKey = "emergencyLockdownEndsAt"
    /// DeviceActivity refuses a schedule shorter than 15 minutes.
    static let minimumScheduleMinutes = 15

    nonisolated static func isEmergency(_ activity: DeviceActivityName) -> Bool {
        activity.rawValue == bedtimeActivity || activity.rawValue == releaseActivity
    }

    nonisolated static func startLockdown(now: Date) {
        let defaults = UserDefaults(suiteName: PenaltyMonitorGroup.suiteName) ?? .standard
        let saved = defaults.integer(forKey: lockdownMinutesKey)
        let minutes = saved > 0 ? saved : 10
        let end = now.addingTimeInterval(Double(minutes) * 60)
        defaults.set(now.timeIntervalSince1970, forKey: triggeredAtKey)
        defaults.set("bedtime_lockdown", forKey: lockdownKindKey)
        defaults.set(end.timeIntervalSince1970, forKey: lockdownEndsAtKey)

        let store = ManagedSettingsStore(named: .init(storeName))
        store.shield.applicationCategories = .all()
        store.shield.webDomainCategories = .all()

        // Start the schedule early when needed, so it is 15 minutes long and still ends on time.
        let start = now.addingTimeInterval(-Double(max(0, minimumScheduleMinutes - minutes)) * 60)
        let parts: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        let calendar = Calendar.autoupdatingCurrent
        let schedule = DeviceActivitySchedule(
            intervalStart: calendar.dateComponents(parts, from: start),
            intervalEnd: calendar.dateComponents(parts, from: end),
            repeats: false
        )
        let center = DeviceActivityCenter()
        let release = DeviceActivityName(releaseActivity)
        center.stopMonitoring([release])
        try? center.startMonitoring(release, during: schedule)

        let content = UNMutableNotificationContent()
        content.title = "EMERGENCY QUEST: LIGHTS OUT"
        content.body = "It is past bedtime. Put your phone down. All apps are locked for \(minutes) minutes."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "bedtime-\(Int(now.timeIntervalSince1970))", content: content, trigger: nil))
    }

    nonisolated static func endLockdown() {
        let defaults = UserDefaults(suiteName: PenaltyMonitorGroup.suiteName) ?? .standard
        // A walk lockdown is the app's to clear. Lift only a bedtime lockdown here.
        guard defaults.string(forKey: lockdownKindKey) == "bedtime_lockdown" else { return }
        defaults.removeObject(forKey: lockdownKindKey)
        defaults.removeObject(forKey: lockdownEndsAtKey)
        ManagedSettingsStore(named: .init(storeName)).clearAllSettings()
        DeviceActivityCenter().stopMonitoring([DeviceActivityName(releaseActivity)])
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
