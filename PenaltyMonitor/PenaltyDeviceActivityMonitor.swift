import DeviceActivity
import FamilyControls
import ManagedSettings

/// Re-asserts distractor shields while a penalty is active. It does not start a Live Activity.
/// Interval end does not lift shields; only the main app clears them after the penalty quests are done.
/// This target is `nonisolated`. If the SDK marks these overrides isolated, drop the `nonisolated` keyword.
class PenaltyDeviceActivityMonitor: DeviceActivityMonitor {
    nonisolated override func intervalDidStart(for activity: DeviceActivityName) {
        _ = activity
        PenaltyMonitorShields.reassert()
    }

    nonisolated override func intervalDidEnd(for activity: DeviceActivityName) {
        _ = activity
        PenaltyMonitorShields.reassert()
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
