import Foundation

#if os(iOS)
import ActivityKit
import DeviceActivity
import FamilyControls
import ManagedSettings
#endif

/// App Group shared with the Screen Time extensions. Replace this in every extension if the portal id changes.
enum PenaltyGroup {
    static let suiteName = "group.devplaceholder.HDDJMVMX.thesystem"
    static let penaltyActiveKey = "penaltyActive"
    static let selectionKey = "familyActivitySelection"
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

enum PenaltySelectionStore {
    static var hasSelection: Bool {
        PenaltyGroup.defaults.data(forKey: PenaltyGroup.selectionKey) != nil
    }

    #if os(iOS)
    static func load() -> FamilyActivitySelection {
        guard let data = PenaltyGroup.defaults.data(forKey: PenaltyGroup.selectionKey),
              let selection = try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: data) else {
            return FamilyActivitySelection()
        }
        return selection
    }

    static func save(_ selection: FamilyActivitySelection) {
        guard let data = try? PropertyListEncoder().encode(selection) else { return }
        let empty = selection.applicationTokens.isEmpty && selection.categoryTokens.isEmpty && selection.webDomainTokens.isEmpty
        if empty {
            PenaltyGroup.defaults.removeObject(forKey: PenaltyGroup.selectionKey)
        } else {
            PenaltyGroup.defaults.set(data, forKey: PenaltyGroup.selectionKey)
        }
    }
    #endif
}

/// A penalty locks every app and website. iOS keeps calls and emergency SOS open, and it does not let an app
/// block the Lock Screen or the Settings app. The Live Activity is foreground-only: the monitor cannot reliably start one.
enum PenaltyEnforcement {
    /// `openDayKey` is the quest day whose required set is still open, or nil when it is done or waived.
    static func sync(penaltyVisible: Bool, tier: Int, questTitle: String, dayKey: String, openDayKey: String?) {
        #if os(iOS)
        let defaults = PenaltyGroup.defaults
        if let openDayKey {
            defaults.set(openDayKey, forKey: PenaltyGroup.openDayKey)
        } else {
            defaults.removeObject(forKey: PenaltyGroup.openDayKey)
        }
        scheduleDawnCheck()
        if tier == 0 || !penaltyVisible {
            defaults.set(false, forKey: PenaltyGroup.penaltyActiveKey)
            if tier == 0 {
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
            await startOrUpdateLiveActivity(questTitle: questTitle, tier: tier, dayKey: dayKey, startedAt: started)
        }
        #else
        _ = (penaltyVisible, tier, questTitle, dayKey, openDayKey)
        #endif
    }

    #if os(iOS)
    /// Every app category and website, not only the distractor selection. The app cannot be deleted while it holds.
    private static func applyShields() {
        let store = ManagedSettingsStore(named: .init(PenaltyGroup.storeName))
        store.shield.applications = nil
        store.shield.webDomains = nil
        store.shield.applicationCategories = .all()
        store.shield.webDomainCategories = .all()
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

    private static func startOrUpdateLiveActivity(questTitle: String, tier: Int, dayKey: String, startedAt: Date) async {
        let stale = startedAt.addingTimeInterval(PenaltyGroup.liveActivityLimit)
        guard Date() < stale else { return }
        let state = PenaltyAttributes.ContentState(questTitle: questTitle, tier: tier, startedAt: startedAt)
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
