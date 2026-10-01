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
    static let storeName = "penalty"
    static let activityName = "penalty"
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

/// Foreground-only. The Device Activity monitor cannot reliably start a Live Activity.
enum PenaltyEnforcement {
    static func sync(penaltyVisible: Bool, tier: Int, questTitle: String, dayKey: String) {
        #if os(iOS)
        let defaults = PenaltyGroup.defaults
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
        _ = (penaltyVisible, tier, questTitle, dayKey)
        #endif
    }

    #if os(iOS)
    private static func applyShields() {
        let selection = PenaltySelectionStore.load()
        let store = ManagedSettingsStore(named: .init(PenaltyGroup.storeName))
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
