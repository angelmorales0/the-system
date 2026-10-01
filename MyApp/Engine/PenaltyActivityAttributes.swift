import Foundation

#if os(iOS)
import ActivityKit

/// Keep this struct identical to `PenaltyActivity/PenaltyActivityAttributes.swift`.
struct PenaltyAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var questTitle: String
        var tier: Int
        var startedAt: Date
    }

    var dayKey: String
}
#endif
