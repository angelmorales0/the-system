import CryptoKit
import Foundation

/// One observation that can move a quest. Verifiers create these. A model cannot.
struct Evidence: Codable, Hashable, Equatable {
    var source: String
    var externalId: String
    var payloadHash: String
    var timestamp: Date

    /// Same source and external id cannot clear a second quest on the same day.
    var reuseKey: String { "\(source)\u{1f}\(externalId)" }

    static func make(source: String, externalId: String, payload: String, timestamp: Date) -> Evidence {
        Evidence(
            source: source,
            externalId: externalId,
            payloadHash: EvidenceHash.sha256(payload),
            timestamp: timestamp
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
