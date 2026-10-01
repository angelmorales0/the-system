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
/// Two events match when they share a sport family and their intervals overlap
/// after each side is padded by 5 minutes, and their start times are at most
/// 10 minutes apart. That is the ±5–10 minute window.
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
        guard abs(lhs.start.timeIntervalSince(rhs.start)) <= maxStartGap else { return false }
        let leftStart = lhs.start.addingTimeInterval(-pad)
        let leftEnd = lhs.end.addingTimeInterval(pad)
        let rightStart = rhs.start.addingTimeInterval(-pad)
        let rightEnd = rhs.end.addingTimeInterval(pad)
        return leftStart <= rightEnd && rightStart <= leftEnd
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
        let distance = events.compactMap(\.distanceMeters).max()
        let moving = events.map(\.movingTimeSec).max() ?? chosen.movingTimeSec
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
