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
    /// Written by the monitor when bedtime use reaches the threshold.
    static let bedtimeTriggeredAtKey = "emergencyBedtimeTriggeredAt"
    /// Written by the app once it has turned that trigger into a quest.
    static let bedtimeHandledAtKey = "emergencyBedtimeHandledAt"
    static let lockdownMinutesKey = "emergencyLockdownMinutes"
    /// Read by the shield configuration for its copy.
    static let lockdownKindKey = "emergencyLockdownKind"
    static let lockdownEndsAtKey = "emergencyLockdownEndsAt"

    static let storeName = "emergency"
    static let bedtimeActivity = "emergencyBedtime"
    static let releaseActivity = "emergencyRelease"
    static let bedtimeEvent = "bedtimeUse"

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
        EmergencyGroup.defaults.set(settings.lockdownMinutes, forKey: EmergencyGroup.lockdownMinutesKey)
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

    /// A bedtime trigger the app has not handled yet. Reading it marks it handled.
    static func takeBedtimeTrigger() -> Date? {
        let defaults = EmergencyGroup.defaults
        let triggered = defaults.double(forKey: EmergencyGroup.bedtimeTriggeredAtKey)
        let handled = defaults.double(forKey: EmergencyGroup.bedtimeHandledAtKey)
        guard triggered > 0, triggered > handled else { return nil }
        defaults.set(triggered, forKey: EmergencyGroup.bedtimeHandledAtKey)
        return Date(timeIntervalSince1970: triggered)
    }
}

/// Screen Time and notification side effects. The rules live in `EmergencyRules`.
enum EmergencyEnforcement {
    /// Starts or stops the nightly bedtime watch. It needs a distractor selection: Screen Time counts use only for chosen apps.
    static func syncMonitoring(_ settings: EmergencySettings) {
        #if os(iOS)
        let center = DeviceActivityCenter()
        let name = DeviceActivityName(EmergencyGroup.bedtimeActivity)
        center.stopMonitoring([name])
        let selection = PenaltySelectionStore.load()
        let hasTokens = !(selection.applicationTokens.isEmpty && selection.categoryTokens.isEmpty && selection.webDomainTokens.isEmpty)
        guard settings.bedtimeEnabled, hasTokens else { return }
        let start = EmergencyRules.effectiveBedtimeStart(settings)
        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: start / 60, minute: start % 60),
            intervalEnd: DateComponents(hour: settings.wakeTime / 60, minute: settings.wakeTime % 60),
            repeats: true
        )
        let event = DeviceActivityEvent(
            applications: selection.applicationTokens,
            categories: selection.categoryTokens,
            webDomains: selection.webDomainTokens,
            threshold: DateComponents(minute: max(1, settings.bedtimeGraceMinutes))
        )
        try? center.startMonitoring(name, during: schedule, events: [DeviceActivityEvent.Name(EmergencyGroup.bedtimeEvent): event])
        #else
        _ = settings
        #endif
    }

    /// Bedtime locks every app category and website. A walk locks only the distractor selection,
    /// so the phone stays usable for music or maps on the walk. iOS keeps calls and emergency SOS open.
    static func applyLockdown(for quest: EmergencyQuest) {
        let defaults = EmergencyGroup.defaults
        defaults.set(quest.kind.rawValue, forKey: EmergencyGroup.lockdownKindKey)
        defaults.set(quest.deadline.timeIntervalSince1970, forKey: EmergencyGroup.lockdownEndsAtKey)
        #if os(iOS)
        let store = ManagedSettingsStore(named: .init(EmergencyGroup.storeName))
        switch quest.kind {
        case .bedtimeLockdown:
            store.shield.applicationCategories = .all()
            store.shield.webDomainCategories = .all()
            scheduleRelease(startedAt: quest.startedAt, minutes: Int(quest.deadline.timeIntervalSince(quest.startedAt) / 60))
        case .lowSteps:
            let selection = PenaltySelectionStore.load()
            store.shield.applications = selection.applicationTokens.isEmpty ? nil : selection.applicationTokens
            store.shield.webDomains = selection.webDomainTokens.isEmpty ? nil : selection.webDomainTokens
            store.shield.applicationCategories = selection.categoryTokens.isEmpty ? nil : .specific(selection.categoryTokens)
            store.shield.webDomainCategories = selection.categoryTokens.isEmpty ? nil : .specific(selection.categoryTokens)
        }
        #endif
    }

    static func clearLockdown() {
        EmergencyGroup.defaults.removeObject(forKey: EmergencyGroup.lockdownKindKey)
        EmergencyGroup.defaults.removeObject(forKey: EmergencyGroup.lockdownEndsAtKey)
        #if os(iOS)
        ManagedSettingsStore(named: .init(EmergencyGroup.storeName)).clearAllSettings()
        DeviceActivityCenter().stopMonitoring([DeviceActivityName(EmergencyGroup.releaseActivity)])
        #endif
    }

    #if os(iOS)
    /// A one-time schedule whose end lifts the bedtime lockdown, even if the app never opens.
    private static func scheduleRelease(startedAt: Date, minutes: Int) {
        let window = EmergencyRules.releaseWindow(triggeredAt: startedAt, lockdownMinutes: minutes)
        let parts: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        let schedule = DeviceActivitySchedule(
            intervalStart: QuestDay.calendar.dateComponents(parts, from: window.start),
            intervalEnd: QuestDay.calendar.dateComponents(parts, from: window.end),
            repeats: false
        )
        let center = DeviceActivityCenter()
        let name = DeviceActivityName(EmergencyGroup.releaseActivity)
        center.stopMonitoring([name])
        try? center.startMonitoring(name, during: schedule)
    }
    #endif

    static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func notify(_ quest: EmergencyQuest) {
        let content = UNMutableNotificationContent()
        content.title = "EMERGENCY QUEST: \(quest.title.uppercased())"
        switch quest.kind {
        case .bedtimeLockdown:
            let minutes = Int(quest.deadline.timeIntervalSince(quest.startedAt) / 60)
            content.body = "It is past bedtime. Put your phone down. All apps are locked for \(minutes) minutes."
        case .lowSteps:
            let minutes = Int(quest.deadline.timeIntervalSince(quest.startedAt) / 60)
            content.body = "Walk \(quest.targetSteps.formatted()) steps in \(minutes) minutes. Failure will result in a penalty."
        }
        content.sound = .default
        content.interruptionLevel = .active
        let request = UNNotificationRequest(identifier: quest.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
