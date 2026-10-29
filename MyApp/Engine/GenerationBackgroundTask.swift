import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Extra time from iOS to finish a quest plan after the app leaves the screen. iOS ends it after about 30 seconds;
/// a plan that does not finish is tried again on the next open.
enum GenerationBackgroundTask {
    static func begin() -> Int {
        #if canImport(UIKit) && !os(watchOS)
        let box = Box()
        box.identifier = UIApplication.shared.beginBackgroundTask(withName: "quest-plan") {
            // Time is up: end the task so iOS does not stop the app. The plan is tried again on the next open.
            UIApplication.shared.endBackgroundTask(box.identifier)
            box.identifier = .invalid
        }
        return box.identifier.rawValue
        #else
        return 0
        #endif
    }

    #if canImport(UIKit) && !os(watchOS)
    /// Holds the task id for the expiry handler, which iOS calls on the main thread.
    private final class Box: @unchecked Sendable {
        var identifier = UIBackgroundTaskIdentifier.invalid
    }
    #endif

    static func end(_ raw: Int) {
        #if canImport(UIKit) && !os(watchOS)
        let identifier = UIBackgroundTaskIdentifier(rawValue: raw)
        if identifier != .invalid { UIApplication.shared.endBackgroundTask(identifier) }
        #endif
    }
}
