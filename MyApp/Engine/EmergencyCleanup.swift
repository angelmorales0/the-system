import Foundation

#if os(iOS)
import DeviceActivity
import ManagedSettings
#endif

/// Emergency quests are removed. Older builds may have left a walk or stretch lockdown, its saved quest and
/// settings, or the retired bedtime schedules in the App Group. This lifts and deletes all of it. Safe at every launch.
enum EmergencyCleanup {
    private static let storeName = "emergency"
    private static let keys = [
        "emergencySettings", "emergencyQuest", "emergencyLowStepsDayKey", "emergencyStretchDayKey",
        "emergencyLockdownKind", "emergencyLockdownEndsAt",
        "emergencyBedtimeTriggeredAt", "emergencyBedtimeHandledAt", "emergencyLockdownMinutes",
    ]

    static func run() {
        let defaults = PenaltyGroup.defaults
        keys.forEach { defaults.removeObject(forKey: $0) }
        #if os(iOS)
        ManagedSettingsStore(named: .init(storeName)).clearAllSettings()
        DeviceActivityCenter().stopMonitoring([DeviceActivityName("emergencyBedtime"), DeviceActivityName("emergencyRelease")])
        #endif
    }
}
