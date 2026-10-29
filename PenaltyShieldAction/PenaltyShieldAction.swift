import Foundation
import ManagedSettings
import UserNotifications

/// The shield button does not lift the block. The penalty clears only inside The System.
/// A shield cannot open another app, so during a penalty the button posts a notification that opens The System,
/// then closes the blocked app.
class PenaltyShieldAction: ShieldActionDelegate {
    override func handle(action: ShieldAction, for application: ApplicationToken, completionHandler: @escaping (ShieldActionResponse) -> Void) {
        if action == .primaryButtonPressed { PenaltyOpenNotice.post() }
        completionHandler(.close)
    }

    override func handle(action: ShieldAction, for webDomain: WebDomainToken, completionHandler: @escaping (ShieldActionResponse) -> Void) {
        if action == .primaryButtonPressed { PenaltyOpenNotice.post() }
        completionHandler(.defer)
    }

    override func handle(action: ShieldAction, for category: ActivityCategoryToken, completionHandler: @escaping (ShieldActionResponse) -> Void) {
        if action == .primaryButtonPressed { PenaltyOpenNotice.post() }
        completionHandler(.defer)
    }
}

enum PenaltyOpenNotice {
    /// Mirrors `PenaltyGroup` and `EmergencyGroup` in the app. Keep the strings in step.
    static let suiteName = "group.devplaceholder.HDDJMVMX.thesystem"
    static let lockdownKindKey = "emergencyLockdownKind"
    static let shieldLineKey = "penaltyShieldLine"

    /// Only for a penalty shield. An emergency shield keeps its plain Close button.
    static func post() {
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        guard defaults.string(forKey: lockdownKindKey) == nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "PENALTY QUEST"
        content.body = "\(defaults.string(forKey: shieldLineKey) ?? "Penalty 10K"). Tap to open The System."
        content.interruptionLevel = .timeSensitive
        // One notice at a time: a new tap replaces the last one.
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "penalty-open", content: content, trigger: nil))
    }
}
