import CryptoKit
import Foundation

/// One observation that can move a quest. Verifiers create these. A model cannot.
struct Evidence: Codable, Hashable, Equatable {
    var source: String
    var externalId: String
    var payloadHash: String
    var timestamp: Date
    /// The id of every recording of the workout behind this evidence: its Strava, WHOOP, and Apple Health copies.
    /// Nil for evidence that is not a workout, and on saves from before this field.
    var recordings: [String]? = nil

    static let workoutPrefix = "workout:"

    /// Same source and external id cannot clear a second quest on the same day.
    var reuseKey: String { "\(source)\u{1f}\(externalId)" }

    /// Every recording id this evidence stands for. One workout has one id per source, and the id that names it
    /// changes when a second source reports it later. A quest claims all of them, so the same run cannot clear
    /// a second quest under its other name.
    var workoutIds: Set<String> {
        var ids = Set(recordings ?? [])
        if externalId.hasPrefix(Self.workoutPrefix) { ids.insert(String(externalId.dropFirst(Self.workoutPrefix.count))) }
        return ids
    }

    static func make(source: String, externalId: String, payload: String, timestamp: Date, recordings: [String]? = nil) -> Evidence {
        Evidence(
            source: source,
            externalId: externalId,
            payloadHash: EvidenceHash.sha256(payload),
            timestamp: timestamp,
            recordings: recordings
        )
    }
}

struct EvidenceUse: Codable, Equatable {
    var dayKey: String
    var questId: String
    var evidence: Evidence
}

enum EvidenceHash {
    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
