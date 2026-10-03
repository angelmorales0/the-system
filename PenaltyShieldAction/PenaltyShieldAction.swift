import ManagedSettings

/// The shield button does not lift the block. The penalty clears only inside The System.
class PenaltyShieldAction: ShieldActionDelegate {
    override func handle(action: ShieldAction, for application: ApplicationToken, completionHandler: @escaping (ShieldActionResponse) -> Void) {
        _ = action
        completionHandler(.defer)
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
