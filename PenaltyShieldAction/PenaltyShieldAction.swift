import Foundation
import ManagedSettings

/// The shield button does not lift the block. The penalty clears only inside The System.
/// During an emergency lockdown the button closes the blocked app instead.
class PenaltyShieldAction: ShieldActionDelegate {
    override func handle(action: ShieldAction, for application: ApplicationToken, completionHandler: @escaping (ShieldActionResponse) -> Void) {
        _ = action
        completionHandler(Self.emergencyActive ? .close : .defer)
    }

    private static var emergencyActive: Bool {
        (UserDefaults(suiteName: "group.devplaceholder.HDDJMVMX.thesystem") ?? .standard).string(forKey: "emergencyLockdownKind") != nil
    }

    override func handle(action: ShieldAction, for webDomain: WebDomainToken, completionHandler: @escaping (ShieldActionResponse) -> Void) {
        _ = action
        completionHandler(.defer)
    }

    override func handle(action: ShieldAction, for category: ActivityCategoryToken, completionHandler: @escaping (ShieldActionResponse) -> Void) {
        _ = action
        completionHandler(.defer)
    }
}
