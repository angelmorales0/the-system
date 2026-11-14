import Foundation

/// Sport families used to decide that two recordings are the same session.
enum SportFamily: String, Codable, Equatable {
    case run, ride, strength, walk, other

    static func from(_ name: String) -> SportFamily {
        let value = name.lowercased()
        if value.contains("strength") || value.contains("weight") || value.contains("lift") || value.contains("traditionalstrength") {
            return .strength
        }
        if value.contains("ride") || value.contains("cycl") || value.contains("bike") {
            return .ride
        }
        if value.contains("walk") || value.contains("hike") {
            return .walk
        }
        if value.contains("run") || value.contains("trail") || value.contains("jog") {
            return .run
        }
        return .other
    }
}

/// One recording from Strava, WHOOP, or HealthKit. No tokens and no GPS trace.
struct WorkoutEvent: Codable, Equatable, Identifiable {
    var source: String
    var externalId: String
    var sport: String
    var start: Date
    var end: Date
    var movingTimeSec: Double
    var distanceMeters: Double?

    var id: String { "\(source):\(externalId)" }
    var sportFamily: SportFamily { SportFamily.from(sport) }
}

struct CanonicalWorkout: Equatable, Identifiable {
    var id: String
    var sportFamily: SportFamily
    var start: Date
    var end: Date
    var movingTimeSec: Double
    var distanceMeters: Double?
    /// `strava`, `whoop`, and `healthkit` members of this cluster.
    var sources: [String]
    /// Strava when it recorded the session, else WHOOP, else HealthKit.
    var preferredSource: String
    var members: [WorkoutEvent]
}

/// Same workout recorded by more than one source.
///
/// Two events match when they share a sport family and at least half of the shorter
/// one's time.
///
/// The canonical id prefers Strava (distance), then WHOOP (strain and zones),
/// then HealthKit when it is the only recorder. One canonical id can clear
/// only one quest per day.
enum WorkoutDedupe {
    static let pad: TimeInterval = 5 * 60
    static let maxStartGap: TimeInterval = 10 * 60

    static func sameSession(_ lhs: WorkoutEvent, _ rhs: WorkoutEvent) -> Bool {
        let family = lhs.sportFamily
        guard family != .other, family == rhs.sportFamily else { return false }
        return sameTime(lhs.start, lhs.end, rhs.start, rhs.end)
    }

    /// The time rule alone. Two recordings of one session cover the same time: they share at least half of the
    /// shorter one, whatever their starts (a second device can start late). A short run and a second run that
    /// starts as the first ends only touch: those are two runs, and both count.
    /// A recording with no length has no time to share: its start is at most 10 minutes from the other start, and
    /// the two overlap after 5 minutes of padding.
    static func sameTime(_ leftStart: Date, _ leftEnd: Date, _ rightStart: Date, _ rightEnd: Date) -> Bool {
        let shorter = min(leftEnd.timeIntervalSince(leftStart), rightEnd.timeIntervalSince(rightStart))
        if shorter > 0 {
            return min(leftEnd, rightEnd).timeIntervalSince(max(leftStart, rightStart)) >= shorter / 2
        }
        guard abs(leftStart.timeIntervalSince(rightStart)) <= maxStartGap else { return false }
        return leftStart.addingTimeInterval(-pad) <= rightEnd.addingTimeInterval(pad)
            && rightStart.addingTimeInterval(-pad) <= leftEnd.addingTimeInterval(pad)
    }

    static func canonical(_ events: [WorkoutEvent]) -> [CanonicalWorkout] {
        let unique = Dictionary(grouping: events, by: \.id).compactMap(\.value.first)
        guard !unique.isEmpty else { return [] }
        var parent = Array(unique.indices)
        func find(_ index: Int) -> Int {
            var cursor = index
            while parent[cursor] != cursor {
                parent[cursor] = parent[parent[cursor]]
                cursor = parent[cursor]
            }
            return cursor
        }
        for lhs in unique.indices {
            for rhs in unique.indices where rhs > lhs && sameSession(unique[lhs], unique[rhs]) {
                let left = find(lhs)
                let right = find(rhs)
                if left != right { parent[right] = left }
            }
        }
        let groups = Dictionary(grouping: unique.indices, by: find)
        return groups.values.map { indexes in
            cluster(indexes.map { unique[$0] })
        }.sorted { $0.start < $1.start }
    }

    /// Prefer Strava's distance, then WHOOP's strain recording, then the HealthKit sample.
    static func preferred(_ events: [WorkoutEvent]) -> WorkoutEvent {
        if let strava = events.first(where: { $0.source == "strava" }) { return strava }
        if let whoop = events.first(where: { $0.source == "whoop" }) { return whoop }
        return events[0]
    }

    private static func cluster(_ events: [WorkoutEvent]) -> CanonicalWorkout {
        let chosen = preferred(events)
        // One source can hold a session in parts (a stop and a new start), and another source can hold it whole.
        // The parts of one source add, copies in one source count one time, and the session is the longest
        // reading of any source.
        func longest(_ value: (WorkoutEvent) -> Double?) -> Double? {
            Dictionary(grouping: events, by: \.source).values.compactMap { recordings -> Double? in
                var parts: [[WorkoutEvent]] = []
                for recording in recordings.sorted(by: { ($0.start, $0.externalId) < ($1.start, $1.externalId) }) {
                    if let at = parts.firstIndex(where: { $0.contains { sameTime($0.start, $0.end, recording.start, recording.end) } }) {
                        parts[at].append(recording)
                    } else {
                        parts.append([recording])
                    }
                }
                let values = parts.compactMap { $0.compactMap(value).max() }
                return values.isEmpty ? nil : values.reduce(0, +)
            }.max()
        }
        let distance = longest(\.distanceMeters)
        let moving = longest { $0.movingTimeSec } ?? chosen.movingTimeSec
        return CanonicalWorkout(
            id: chosen.id,
            sportFamily: chosen.sportFamily,
            start: events.map(\.start).min() ?? chosen.start,
            end: events.map(\.end).max() ?? chosen.end,
            movingTimeSec: moving,
            distanceMeters: distance ?? chosen.distanceMeters,
            sources: Array(Set(events.map(\.source))).sorted(),
            preferredSource: chosen.source,
            members: events
        )
    }
}
