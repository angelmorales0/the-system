import ActivityKit
import Foundation

/// Keep this struct identical to `MyApp/Engine/PenaltyActivityAttributes.swift`.
struct PenaltyAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var questTitle: String
        var tier: Int
        var startedAt: Date
    }

    var dayKey: String
}
