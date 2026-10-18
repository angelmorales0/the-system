import Foundation
import DeviceActivity
import FamilyControls
import ManagedSettings
import UserNotifications

/// Re-asserts distractor shields while a penalty is active. It does not start a Live Activity.
/// Interval end does not lift shields; only the main app clears them after the penalty quests are done.
/// It also runs the bedtime emergency: distractor use after bedtime locks every app, and the release schedule lifts it.
/// This target is `nonisolated`. If the SDK marks these overrides isolated, drop the `nonisolated` keyword.
class PenaltyDeviceActivityMonitor: DeviceActivityMonitor {
    nonisolated override func intervalDidStart(for activity: DeviceActivityName) {
        if EmergencyMonitor.isEmergency(activity) { return }
        PenaltyMonitorShields.reassert()
    }

    nonisolated override func intervalDidEnd(for activity: DeviceActivityName) {
        if activity.rawValue == EmergencyMonitor.releaseActivity {
            EmergencyMonitor.endLockdown()
            return
        }
        if EmergencyMonitor.isEmergency(activity) { return }
        PenaltyMonitorShields.reassert()
    }

    nonisolated override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        guard activity.rawValue == EmergencyMonitor.bedtimeActivity, event.rawValue == EmergencyMonitor.bedtimeEvent else { return }
        EmergencyMonitor.startLockdown(now: Date())
    }
}

enum PenaltyMonitorGroup {
    static let suiteName = "group.devplaceholder.HDDJMVMX.thesystem"
    static let penaltyActiveKey = "penaltyActive"
    static let selectionKey = "familyActivitySelection"
    static let storeName = "penalty"
}

enum PenaltyMonitorShields {
    nonisolated static func reassert() {
        let defaults = UserDefaults(suiteName: PenaltyMonitorGroup.suiteName) ?? .standard
        let store = ManagedSettingsStore(named: .init(PenaltyMonitorGroup.storeName))
        guard defaults.bool(forKey: PenaltyMonitorGroup.penaltyActiveKey) else {
            store.clearAllSettings()
            return
        }
        guard let data = defaults.data(forKey: PenaltyMonitorGroup.selectionKey),
              let selection = try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: data) else {
            return
        }
        store.shield.applications = selection.applicationTokens.isEmpty ? nil : selection.applicationTokens
        store.shield.webDomains = selection.webDomainTokens.isEmpty ? nil : selection.webDomainTokens
        if selection.categoryTokens.isEmpty {
            store.shield.applicationCategories = nil
            store.shield.webDomainCategories = nil
        } else {
            store.shield.applicationCategories = .specific(selection.categoryTokens)
            store.shield.webDomainCategories = .specific(selection.categoryTokens)
        }
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
