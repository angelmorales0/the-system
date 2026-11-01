import Foundation

#if os(iOS)
import ActivityKit
import DeviceActivity
import FamilyControls
import ManagedSettings
#endif

/// App Group shared with the Screen Time extensions. Replace this in every extension if the portal id changes.
enum PenaltyGroup {
    static let suiteName = "group.com.angelmorales.thesystem"
    static let penaltyActiveKey = "penaltyActive"
    static let selectionKey = "familyActivitySelection"
    /// Apps that stay open during a penalty: The System, Strava, and Spotify, picked by the player.
    static let allowedSelectionKey = "penaltyAllowedSelection"
    /// Apps that leave the Home Screen during a penalty. Allowed apps are never hidden.
    static let hiddenSelectionKey = "penaltyHiddenSelection"
    /// The open penalty row with its progress, for the shield: "Penalty 10K [3.2/10km]".
    static let shieldLineKey = "penaltyShieldLine"
    static let startedAtKey = "penaltyStartedAt"
    /// The quest day whose required set is still open. The monitor locks the phone at 5:00 when this day has ended.
    static let openDayKey = "penaltyOpenDayKey"
    static let storeName = "penalty"
    static let activityName = "penalty"
    /// Starts every day at `QuestDay.startHour`, so a missed day locks the phone even if the app stays closed.
    static let dawnActivityName = "penaltyDawn"
    /// ActivityKit removes a Live Activity after about 8 hours. Shields are separate and stay up.
    static let liveActivityLimit: TimeInterval = 8 * 60 * 60

    static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }
}

/// `key` is the distractor selection by default, or `allowedSelectionKey` / `hiddenSelectionKey`.
enum PenaltySelectionStore {
    static var hasSelection: Bool {
        PenaltyGroup.defaults.data(forKey: PenaltyGroup.selectionKey) != nil
    }

    #if os(iOS)
    /// `entireCategory` makes a new, empty selection list every app of a picked category, so whole categories can be hidden.
    static func load(key: String = PenaltyGroup.selectionKey, entireCategory: Bool = false) -> FamilyActivitySelection {
        guard let data = PenaltyGroup.defaults.data(forKey: key),
              let selection = try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: data) else {
            return FamilyActivitySelection(includeEntireCategory: entireCategory)
        }
        return selection
    }

    static func save(_ selection: FamilyActivitySelection, key: String = PenaltyGroup.selectionKey) {
        guard let data = try? PropertyListEncoder().encode(selection) else { return }
        let empty = selection.applicationTokens.isEmpty && selection.categoryTokens.isEmpty && selection.webDomainTokens.isEmpty
        if empty {
            PenaltyGroup.defaults.removeObject(forKey: key)
        } else {
            PenaltyGroup.defaults.set(data, forKey: key)
        }
    }
    #endif
}

/// A penalty locks every app and website except the allowed apps, and hides the hidden apps from the Home Screen.
/// iOS keeps calls and emergency SOS open, and it does not let an app block the Lock Screen or the Settings app. The Live Activity is foreground-only: the monitor cannot reliably start one.
enum PenaltyEnforcement {
    /// `openDayKey` is the quest day whose required set is still open, or nil when it is done or waived.
    /// `shieldLine` is the open penalty row with its progress, shown on every shield.
    /// `penaltyOpen` is the player's penalty flag; `penaltyVisible` adds that a penalty row is still open today.
    static func sync(penaltyVisible: Bool, penaltyOpen: Bool, questTitle: String, shieldLine: String, dayKey: String, openDayKey: String?) {
        #if os(iOS)
        let defaults = PenaltyGroup.defaults
        defaults.set(shieldLine, forKey: PenaltyGroup.shieldLineKey)
        if let openDayKey {
            defaults.set(openDayKey, forKey: PenaltyGroup.openDayKey)
        } else {
            defaults.removeObject(forKey: PenaltyGroup.openDayKey)
        }
        scheduleDawnCheck()
        if !penaltyOpen || !penaltyVisible {
            defaults.set(false, forKey: PenaltyGroup.penaltyActiveKey)
            if !penaltyOpen {
                defaults.removeObject(forKey: PenaltyGroup.startedAtKey)
            }
            clearShields()
            stopMonitoring()
            Task { await endLiveActivities() }
            return
        }
        if defaults.object(forKey: PenaltyGroup.startedAtKey) == nil {
            defaults.set(Date().timeIntervalSince1970, forKey: PenaltyGroup.startedAtKey)
        }
        defaults.set(true, forKey: PenaltyGroup.penaltyActiveKey)
        applyShields()
        startMonitoring()
        let started = Date(timeIntervalSince1970: defaults.double(forKey: PenaltyGroup.startedAtKey))
        Task {
            await startOrUpdateLiveActivity(questTitle: questTitle, dayKey: dayKey, startedAt: started)
        }
        #else
        _ = (penaltyVisible, penaltyOpen, questTitle, shieldLine, dayKey, openDayKey)
        #endif
    }

    #if os(iOS)
    /// Every app category except the allowed apps, and every website. The hidden apps leave the Home Screen.
    /// The app cannot be deleted while it holds. `PenaltyMonitorShields.lockEverything` repeats this rule.
    private static func applyShields() {
        let allowed = PenaltySelectionStore.load(key: PenaltyGroup.allowedSelectionKey).applicationTokens
        let hidden = PenaltySelectionStore.load(key: PenaltyGroup.hiddenSelectionKey).applicationTokens.subtracting(allowed)
        let store = ManagedSettingsStore(named: .init(PenaltyGroup.storeName))
        store.shield.applications = nil
        store.shield.webDomains = nil
        store.shield.applicationCategories = .all(except: allowed)
        store.shield.webDomainCategories = .all()
        store.application.blockedApplications = Set(hidden.map { Application(token: $0) })
        store.application.denyAppRemoval = true
    }

    /// A daily 15-minute window from 5:00. Its start runs the monitor, which locks the phone after a missed day.
    private static func scheduleDawnCheck() {
        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: QuestDay.startHour, minute: 0),
            intervalEnd: DateComponents(hour: QuestDay.startHour, minute: 15),
            repeats: true
        )
        try? DeviceActivityCenter().startMonitoring(DeviceActivityName(PenaltyGroup.dawnActivityName), during: schedule)
    }

    private static func clearShields() {
        ManagedSettingsStore(named: .init(PenaltyGroup.storeName)).clearAllSettings()
    }

    private static func startMonitoring() {
        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59),
            repeats: true
        )
        let center = DeviceActivityCenter()
        try? center.startMonitoring(DeviceActivityName(PenaltyGroup.activityName), during: schedule)
    }

    private static func stopMonitoring() {
        DeviceActivityCenter().stopMonitoring([DeviceActivityName(PenaltyGroup.activityName)])
    }

    private static func startOrUpdateLiveActivity(questTitle: String, dayKey: String, startedAt: Date) async {
        let stale = startedAt.addingTimeInterval(PenaltyGroup.liveActivityLimit)
        guard Date() < stale else { return }
        let state = PenaltyAttributes.ContentState(questTitle: questTitle, startedAt: startedAt)
        let content = ActivityContent(state: state, staleDate: stale)
        if let current = Activity<PenaltyAttributes>.activities.first {
            await current.update(content)
            return
        }
        _ = try? Activity.request(attributes: PenaltyAttributes(dayKey: dayKey), content: content, pushType: nil)
    }

    private static func endLiveActivities() async {
        for activity in Activity<PenaltyAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
    #endif
}
