import Foundation
import UserNotifications

#if os(iOS)
import DeviceActivity
import FamilyControls
import ManagedSettings
#endif

/// App Group keys shared with the Screen Time monitor and the shield extensions.
/// The extensions repeat these strings; change them in every target together.
enum EmergencyGroup {
    static let settingsKey = "emergencySettings"
    static let questKey = "emergencyQuest"
    static let lowStepsDayKey = "emergencyLowStepsDayKey"
    static let stretchDayKey = "emergencyStretchDayKey"
    /// Read by the shield configuration for its copy.
    static let lockdownKindKey = "emergencyLockdownKind"
    static let lockdownEndsAtKey = "emergencyLockdownEndsAt"

    static let storeName = "emergency"
    /// The removed bedtime lockdown. Old installs may still have these schedules and keys; `removeBedtime` clears them.
    static let retiredBedtimeActivity = "emergencyBedtime"
    static let retiredReleaseActivity = "emergencyRelease"
    static let retiredBedtimeKind = "bedtime_lockdown"
    static let retiredKeys = ["emergencyBedtimeTriggeredAt", "emergencyBedtimeHandledAt", "emergencyLockdownMinutes"]

    static var defaults: UserDefaults { PenaltyGroup.defaults }
}

enum EmergencyStore {
    static func loadSettings() -> EmergencySettings {
        guard let data = EmergencyGroup.defaults.data(forKey: EmergencyGroup.settingsKey),
              let settings = try? JSONDecoder().decode(EmergencySettings.self, from: data) else { return .standard }
        return settings
    }

    static func save(_ settings: EmergencySettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        EmergencyGroup.defaults.set(data, forKey: EmergencyGroup.settingsKey)
    }

    static func loadQuest() -> EmergencyQuest? {
        guard let data = EmergencyGroup.defaults.data(forKey: EmergencyGroup.questKey) else { return nil }
        return try? JSONDecoder().decode(EmergencyQuest.self, from: data)
    }

    static func save(_ quest: EmergencyQuest?) {
        if let quest, let data = try? JSONEncoder().encode(quest) {
            EmergencyGroup.defaults.set(data, forKey: EmergencyGroup.questKey)
        } else {
            EmergencyGroup.defaults.removeObject(forKey: EmergencyGroup.questKey)
        }
    }

    static var lowStepsDayKey: String? {
        get { EmergencyGroup.defaults.string(forKey: EmergencyGroup.lowStepsDayKey) }
        set { EmergencyGroup.defaults.set(newValue, forKey: EmergencyGroup.lowStepsDayKey) }
    }

    static var stretchDayKey: String? {
        get { EmergencyGroup.defaults.string(forKey: EmergencyGroup.stretchDayKey) }
        set { EmergencyGroup.defaults.set(newValue, forKey: EmergencyGroup.stretchDayKey) }
    }

}

/// Screen Time and notification side effects. The rules live in `EmergencyRules`.
enum EmergencyEnforcement {
    /// Stops the bedtime watch of older builds and lifts a bedtime lockdown it may have left on.
    /// Safe to run at every launch.
    static func removeBedtime() {
        let defaults = EmergencyGroup.defaults
        EmergencyGroup.retiredKeys.forEach { defaults.removeObject(forKey: $0) }
        if defaults.string(forKey: EmergencyGroup.lockdownKindKey) == EmergencyGroup.retiredBedtimeKind {
            clearLockdown()
        }
        #if os(iOS)
        DeviceActivityCenter().stopMonitoring([
            DeviceActivityName(EmergencyGroup.retiredBedtimeActivity),
            DeviceActivityName(EmergencyGroup.retiredReleaseActivity),
        ])
        #endif
    }

    /// A walk or a stretch locks only the distractor selection,
    /// so the phone stays usable for music, maps, or a stretching video. iOS keeps calls and emergency SOS open.
    static func applyLockdown(for quest: EmergencyQuest) {
        let defaults = EmergencyGroup.defaults
        defaults.set(quest.kind.rawValue, forKey: EmergencyGroup.lockdownKindKey)
        defaults.set(quest.deadline.timeIntervalSince1970, forKey: EmergencyGroup.lockdownEndsAtKey)
        #if os(iOS)
        let store = ManagedSettingsStore(named: .init(EmergencyGroup.storeName))
        let selection = PenaltySelectionStore.load()
        store.shield.applications = selection.applicationTokens.isEmpty ? nil : selection.applicationTokens
        store.shield.webDomains = selection.webDomainTokens.isEmpty ? nil : selection.webDomainTokens
        store.shield.applicationCategories = selection.categoryTokens.isEmpty ? nil : .specific(selection.categoryTokens)
        store.shield.webDomainCategories = selection.categoryTokens.isEmpty ? nil : .specific(selection.categoryTokens)
        #endif
    }

    static func clearLockdown() {
        EmergencyGroup.defaults.removeObject(forKey: EmergencyGroup.lockdownKindKey)
        EmergencyGroup.defaults.removeObject(forKey: EmergencyGroup.lockdownEndsAtKey)
        #if os(iOS)
        ManagedSettingsStore(named: .init(EmergencyGroup.storeName)).clearAllSettings()
        #endif
    }

    static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func notify(_ quest: EmergencyQuest) {
        let content = UNMutableNotificationContent()
        content.title = "EMERGENCY QUEST: \(quest.title.uppercased())"
        switch quest.kind {
        case .lowSteps:
            let minutes = Int(quest.deadline.timeIntervalSince(quest.startedAt) / 60)
            content.body = "Walk \(quest.targetSteps.formatted()) steps in \(minutes) minutes. Failure will result in a penalty."
        case .skippedStretch:
            let minutes = Int(quest.deadline.timeIntervalSince(quest.startedAt) / 60)
            content.body = "You skipped stretching. Log \(Int(DailyStretch.minutes)) minutes of stretches in Hevy within \(minutes) minutes. Failure will result in a penalty."
        }
        content.sound = .default
        content.interruptionLevel = .active
        let request = UNNotificationRequest(identifier: quest.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
