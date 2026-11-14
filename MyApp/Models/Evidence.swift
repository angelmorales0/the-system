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
    /// When that workout started; `timestamp` is its end. Nil for evidence that is not a workout.
    var sessionStart: Date? = nil
    /// The sport family of that workout (`SportFamily`): run, strength, and so on. Two workouts of different
    /// families are never one session by their time: a long gym recording can contain a run.
    /// Nil for evidence that is not a workout, and on saves from before this field.
    var family: String? = nil

    static let workoutPrefix = "workout:"

    /// The time the workout took. A later read can show the same session through another source alone, with none of
    /// the ids this evidence holds. Its time still matches, so it cannot clear a second quest.
    var session: DateInterval? {
        guard let sessionStart, sessionStart <= timestamp else { return nil }
        return DateInterval(start: sessionStart, end: timestamp)
    }

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

    static func make(source: String, externalId: String, payload: String, timestamp: Date, recordings: [String]? = nil,
                     sessionStart: Date? = nil, family: String? = nil) -> Evidence {
        Evidence(
            source: source,
            externalId: externalId,
            payloadHash: EvidenceHash.sha256(payload),
            timestamp: timestamp,
            recordings: recordings,
            sessionStart: sessionStart,
            family: family
        )
    }

    /// True when a workout of `family` at this time is the workout of this evidence: the same time
    /// (`WorkoutDedupe.sameTime`), and not another sport family.
    func isSession(start: Date, end: Date, family other: String?) -> Bool {
        guard let session else { return false }
        if let family, let other, family != other { return false }
        return WorkoutDedupe.sameTime(session.start, session.end, start, end)
    }
}

struct EvidenceUse: Codable, Equatable {
    var dayKey: String
    var questId: String
    var evidence: Evidence
}

/// The runs that finished rows held when a penalty row was first planned. A penalty that opens in the day cannot
/// be cleared by them: they were done and counted before it.
struct PenaltyStart: Codable, Equatable {
    var dayKey: String
    var questId: String
    var counted: [Evidence]
}

/// A workout that an open run row can count: no row has used it. `meters` is its longest reading.
struct ShownWorkout: Codable, Equatable {
    var dayKey: String
    var questId: String
    var evidence: Evidence
    var meters: Double
}

extension ShownWorkout {
    private enum CodingKeys: String, CodingKey { case dayKey, questId, evidence, meters, shown }

    /// An earlier build saved the km the row showed (`shown`), not the meters.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dayKey = try container.decode(String.self, forKey: .dayKey)
        questId = try container.decode(String.self, forKey: .questId)
        evidence = try container.decode(Evidence.self, forKey: .evidence)
        if let saved = try container.decodeIfPresent(Double.self, forKey: .meters) {
            meters = saved
        } else {
            meters = try container.decode(Double.self, forKey: .shown) * 1000
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(dayKey, forKey: .dayKey)
        try container.encode(questId, forKey: .questId)
        try container.encode(evidence, forKey: .evidence)
        try container.encode(meters, forKey: .meters)
    }
}

enum EvidenceHash {
    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
