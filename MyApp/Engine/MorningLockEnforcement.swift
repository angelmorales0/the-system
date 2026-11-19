import Foundation

#if os(iOS)
import DeviceActivity
import FamilyControls
import ManagedSettings
#endif

/// The morning lock on the phone: its own shield store, next to the penalty's, with its own allowed apps
/// (the penalty's list while the morning list is empty).
/// The monitor starts it at 7:00 each day, also when the app is closed, unless the app wrote that today has no lock
/// (a rest day, or the workout is done). The app starts it earlier at an earlier wake time, and ends it.
/// The monitor repeats these strings in `MorningLockMonitor`; change them together.
enum MorningLockEnforcement {
    static let storeName = "morningLock"
    static let activityName = "morningLock"
    /// The quest day that has no lock: a rest day, or its workout is done.
    static let offDayKey = "morningLockOffDayKey"

    static func sync(lockNow: Bool, offToday: Bool, dayKey: String) {
        #if os(iOS)
        let defaults = PenaltyGroup.defaults
        if offToday {
            defaults.set(dayKey, forKey: offDayKey)
        } else if defaults.string(forKey: offDayKey) == dayKey {
            defaults.removeObject(forKey: offDayKey)
        }
        scheduleDailyStart()
        if lockNow {
            applyShields()
        } else {
            ManagedSettingsStore(named: .init(storeName)).clearAllSettings()
        }
        #else
        _ = (lockNow, offToday, dayKey)
        #endif
    }

    #if os(iOS)
    /// The morning list, or the penalty's list while the morning list is empty.
    static var allowedApps: Set<ApplicationToken> {
        let morning = PenaltySelectionStore.load(key: PenaltyGroup.morningAllowedSelectionKey).applicationTokens
        return morning.isEmpty ? PenaltySelectionStore.load(key: PenaltyGroup.allowedSelectionKey).applicationTokens : morning
    }

    /// Every app category except the allowed apps, and every website.
    private static func applyShields() {
        let allowed = allowedApps
        let store = ManagedSettingsStore(named: .init(storeName))
        store.shield.applications = nil
        store.shield.webDomains = nil
        store.shield.applicationCategories = .all(except: allowed)
        store.shield.webDomainCategories = .all()
    }

    /// A daily 15-minute window from 7:00. Its start runs the monitor, which turns the lock on.
    private static func scheduleDailyStart() {
        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: MorningLock.fallbackHour, minute: 0),
            intervalEnd: DateComponents(hour: MorningLock.fallbackHour, minute: 15),
            repeats: true
        )
        try? DeviceActivityCenter().startMonitoring(DeviceActivityName(activityName), during: schedule)
    }
    #endif
}
