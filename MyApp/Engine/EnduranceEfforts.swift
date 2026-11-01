import Foundation

/// Run and swim efforts for the END stat, from Strava activities and Apple Health workouts.
/// A recording near a race distance counts for it: at most 50 m short (GPS rounding, like the quest check) or up to
/// 15% long. Its time is the average pace over the race distance, which is never faster than the best split inside it.
enum EnduranceEfforts {
    static let mileMeters = 1_609.344
    static let fiveKMeters = 5_000.0
    static let tenKMeters = 10_000.0
    static let shortfallMeters = DistanceRule.toleranceMeters
    static let overshootShare = 1.15

    static let distances: [(RunDistance, Double)] = [(.mile, mileMeters), (.fiveK, fiveKMeters), (.tenK, tenKMeters)]

    static func runEfforts(_ events: [WorkoutEvent]) -> [RunEffort] {
        events.filter { $0.sportFamily == .run }.flatMap { event in
            distances.compactMap { distance, meters in
                seconds(for: meters, event).map { RunEffort(distance: distance, seconds: $0, date: event.start, source: source(event)) }
            }
        }
    }

    /// A 1-mile swim: 1,609 m, or 1,760 yd in a yard pool.
    static func swimEfforts(_ events: [WorkoutEvent]) -> [SwimEffort] {
        events.filter { $0.sport.lowercased().contains("swim") }.compactMap { event in
            seconds(for: mileMeters, event).map { SwimEffort(seconds: $0, date: event.start, source: source(event)) }
        }
    }

    /// The time over `meters` at the recording's average pace. Nil when the recording is not near that distance.
    static func seconds(for meters: Double, _ event: WorkoutEvent) -> Double? {
        guard let distance = event.distanceMeters, distance > 0, event.movingTimeSec > 0,
              distance + shortfallMeters >= meters, distance <= meters * overshootShare else { return nil }
        return event.movingTimeSec * meters / distance
    }

    static func source(_ event: WorkoutEvent) -> String {
        event.source == "strava" ? "Strava" : "Apple Health"
    }

    // MARK: - Self-check (runs in DEBUG at launch)

    static func check() -> [String] {
        var errors: [String] = []
        let now = EnduranceLevel.checkNow
        func event(_ sport: String, meters: Double?, seconds: Double, source: String = "strava", daysAgo: Int = 1) -> WorkoutEvent {
            let start = EnduranceLevel.daysAgo(daysAgo, from: now)
            return WorkoutEvent(source: source, externalId: "\(sport)-\(meters ?? 0)", sport: sport, start: start,
                                end: start.addingTimeInterval(seconds), movingTimeSec: seconds, distanceMeters: meters)
        }
        let runs = runEfforts([
            event("Run", meters: 10_200, seconds: 3_060),            // 10K at 5:00/km → 3000 s
            event("running", meters: 4_960, seconds: 1_240, source: "healthkit"), // 40 m short still counts
            event("Run", meters: 12_000, seconds: 3_600),            // too long for any distance
            event("Run", meters: 1_700, seconds: 400),               // a mile
            event("Ride", meters: 10_000, seconds: 1_200),           // not a run
            event("Run", meters: nil, seconds: 3_000),               // no distance
        ])
        let byDistance = Dictionary(grouping: runs, by: \.distance)
        if runs.count != 3 || abs((byDistance[.tenK]?.first?.seconds ?? 0) - 3_000) > 0.01
            || abs((byDistance[.fiveK]?.first?.seconds ?? 0) - 1_250) > 0.01
            || abs((byDistance[.mile]?.first?.seconds ?? 0) - 400 * mileMeters / 1_700) > 0.01 {
            errors.append("runs should scale to the race distance at average pace, got \(runs)")
        }
        if byDistance[.fiveK]?.first?.source != "Apple Health" || byDistance[.tenK]?.first?.source != "Strava" {
            errors.append("effort sources should name Strava or Apple Health")
        }
        let swims = swimEfforts([
            event("Swim", meters: 1_650, seconds: 1_500),
            event("swimming", meters: 800, seconds: 700, source: "healthkit"),
        ])
        if swims.count != 1 || abs((swims.first?.seconds ?? 0) - 1_500 * mileMeters / 1_650) > 0.01 {
            errors.append("only a swim near one mile should count, got \(swims)")
        }
        return errors
    }
}

/// One heart rate reading from Apple Health.
struct HeartRateSample: Equatable {
    var time: Date
    var bpm: Double
}

/// The longest unbroken stretch in heart-rate zone 2 inside one workout, from Apple Health heart rate samples.
/// Zone 2 is 60–70% of the max heart rate, and the max heart rate is 220 minus the age from the Health date of birth.
/// A stretch continues while the next in-zone sample comes within 60 seconds; a longer dip out of the zone ends it.
enum ZoneTwo {
    static let lowShare = 0.60
    static let highShare = 0.70
    static let maxGapSeconds = 60.0
    /// Shorter workouts cannot hold a zone 2 session worth scoring and are not read.
    static let minWorkoutSeconds = 20.0 * 60

    static func maxHeartRate(age: Int) -> Double { 220 - Double(age) }

    static func eligible(_ workout: WorkoutEvent) -> Bool {
        workout.sportFamily != .strength && workout.movingTimeSec >= minWorkoutSeconds
    }

    static func longestMinutes(_ samples: [HeartRateSample], maxHeartRate: Double) -> Double {
        let low = maxHeartRate * lowShare
        let high = maxHeartRate * highShare
        var longest = 0.0
        var runStart: Date?
        var last: Date?
        for sample in samples.sorted(by: { $0.time < $1.time }) {
            guard sample.bpm >= low, sample.bpm <= high else { continue }
            if let previous = last, let start = runStart, sample.time.timeIntervalSince(previous) <= maxGapSeconds {
                longest = max(longest, sample.time.timeIntervalSince(start))
            } else {
                runStart = sample.time
            }
            last = sample.time
        }
        return longest / 60
    }

    // MARK: - Self-check (runs in DEBUG at launch)

    static func check() -> [String] {
        var errors: [String] = []
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let maxHR = maxHeartRate(age: 30) // 190: zone 2 is 114–133
        func samples(_ minutes: Double, bpm: Double, from offset: Double = 0, every step: Double = 10) -> [HeartRateSample] {
            stride(from: 0, through: minutes * 60, by: step).map { HeartRateSample(time: start.addingTimeInterval(offset + $0), bpm: bpm) }
        }
        // 100 minutes in zone with a 30-second dip above it: one session.
        let steady = samples(50, bpm: 125) + samples(0.3, bpm: 150, from: 50 * 60 + 10) + samples(49.5, bpm: 120, from: 50 * 60 + 30)
        if abs(longestMinutes(steady, maxHeartRate: maxHR) - 100) > 0.01 {
            errors.append("a 30-second dip should not break a zone 2 session, got \(longestMinutes(steady, maxHeartRate: maxHR))")
        }
        // A 61-second gap splits it: the longer half counts.
        let split = samples(40, bpm: 125) + samples(30, bpm: 125, from: 40 * 60 + 61)
        if abs(longestMinutes(split, maxHeartRate: maxHR) - 40) > 0.01 {
            errors.append("a 61-second gap should split the session, got \(longestMinutes(split, maxHeartRate: maxHR))")
        }
        if longestMinutes(samples(60, bpm: 150), maxHeartRate: maxHR) != 0 || longestMinutes([], maxHeartRate: maxHR) != 0 {
            errors.append("time above zone 2 is not a zone 2 session")
        }
        if maxHR != 190 || abs(low(maxHR) - 114) > 0.01 {
            errors.append("max heart rate at 30 should be 190 with zone 2 from 114")
        }
        let run = WorkoutEvent(source: "healthkit", externalId: "r", sport: "running", start: start, end: start.addingTimeInterval(3_600), movingTimeSec: 3_600, distanceMeters: nil)
        var lift = run
        lift.sport = "traditionalStrengthTraining"
        var short = run
        short.movingTimeSec = 600
        if !eligible(run) || eligible(lift) || eligible(short) {
            errors.append("only cardio workouts of 20 minutes or more are read for zone 2")
        }
        return errors
    }

    private static func low(_ maxHR: Double) -> Double { maxHR * lowShare }
}
