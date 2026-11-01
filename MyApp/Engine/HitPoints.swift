import Foundation

/// The player's HP. Workouts drain it, time brings it back, and a red WHOOP recovery hits it once.
struct HitPointState: Codable, Equatable {
    var current: Double
    var max: Int
    /// Regeneration counts from this moment.
    var updatedAt: Date
    /// Every recording id that already drained HP, oldest first. All members of a deduped session are kept,
    /// so a session counts once even when a later source changes its canonical id.
    var drainedWorkoutIds: [String] = []
    /// WHOOP day whose red recovery already hit HP.
    var recoveryHitDayKey: String?

    static let keepIds = 300

    static func full(max: Int, now: Date) -> HitPointState {
        HitPointState(current: Double(max), max: max, updatedAt: now)
    }

    private enum CodingKeys: String, CodingKey {
        case current, max, updatedAt, drainedWorkoutIds, recoveryHitDayKey
    }

    init(current: Double, max: Int, updatedAt: Date, drainedWorkoutIds: [String] = [], recoveryHitDayKey: String? = nil) {
        self.current = current
        self.max = max
        self.updatedAt = updatedAt
        self.drainedWorkoutIds = drainedWorkoutIds
        self.recoveryHitDayKey = recoveryHitDayKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        max = try container.decodeIfPresent(Int.self, forKey: .max) ?? HitPoints.baseHP
        current = try container.decodeIfPresent(Double.self, forKey: .current) ?? Double(max)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
        drainedWorkoutIds = try container.decodeIfPresent([String].self, forKey: .drainedWorkoutIds) ?? []
        recoveryHitDayKey = try container.decodeIfPresent(String.self, forKey: .recoveryHitDayKey)
    }
}

/// One session that drains HP. `ids` holds every recording of it.
struct HPWorkout: Equatable {
    var ids: [String]
    /// Share of max HP this session costs, 0...`HitPoints.maxDrainPerWorkout`.
    var drainFraction: Double
}

/// Pure HP math, so the store, the window, and the check share it.
///   Max HP      1000 + 20 × overall level + 4 × (STR + END + REC stat levels)
///   Drain       minutes × a sport rate (Hevy: 0.2%/min plus 0.5% per working set), at most 60% per session
///   Regen       max / 48 h, times 0.5 + recovery/100 (no WHOOP reading: × 1)
///   Red WHOOP   recovery under 34 costs 30% + 1.5% per point under 34, once per WHOOP day
///   Critical    at or below 20% of max
enum HitPoints {
    static let baseHP = 1_000
    static let hpPerLevel = 20
    static let hpPerStatPoint = 4
    /// From 0 to full in 48 hours at an average recovery.
    static let fullRegenHours = 48.0
    static let maxDrainPerWorkout = 0.6
    /// Share of max HP per Hevy set with reps.
    static let drainPerSet = 0.005
    static let redRecoveryBelow = 34
    static let redHitBase = 0.30
    static let redHitPerPoint = 0.015
    /// At or below this share of max HP, HP is critical and the HP window turns red.
    static let criticalFraction = 0.20

    static func isCritical(current: Int, max: Int) -> Bool {
        guard max > 0 else { return false }
        return Double(current) <= Double(max) * criticalFraction
    }

    /// Grows with the overall level (0...146) and the three body stat levels (0...350 each).
    /// 1000 with no data, 8120 with every stat at its max.
    static func maxHP(for levels: StatLevelSet) -> Int {
        baseHP + hpPerLevel * Swift.max(0, levels.overallLevel)
            + hpPerStatPoint * (levels[.STR] + levels[.END] + levels[.REC])
    }

    /// Share of max HP lost per minute of each sport.
    static func drainPerMinute(_ family: SportFamily) -> Double {
        switch family {
        case .run: 0.005
        case .strength: 0.004
        case .ride: 0.0035
        case .other: 0.003
        case .walk: 0.001
        }
    }

    /// 0.5 at recovery 0, 1 at 50, 1.5 at 100.
    static func regenMultiplier(recoveryScore: Int?) -> Double {
        guard let recoveryScore else { return 1 }
        return 0.5 + Double(Swift.min(Swift.max(recoveryScore, 0), 100)) / 100
    }

    /// Share of max HP a red recovery costs. 0 for yellow and green.
    static func recoveryHit(recoveryScore: Int) -> Double {
        guard recoveryScore < redRecoveryBelow else { return 0 }
        return redHitBase + redHitPerPoint * Double(redRecoveryBelow - Swift.max(recoveryScore, 0))
    }

    /// Today's sessions. A Hevy workout and a Strava, WHOOP, or Health recording of the same lift are one session.
    static func workouts(canonical: [CanonicalWorkout], hevy: [HevyWorkout]) -> [HPWorkout] {
        var sessions: [HPWorkout] = []
        var matched = Set<String>()
        for lift in hevy {
            let event = WorkoutEvent(source: "hevy", externalId: lift.id, sport: "strength", start: lift.start,
                                     end: lift.end, movingTimeSec: Swift.max(0, lift.end.timeIntervalSince(lift.start)))
            let minutes = event.movingTimeSec / 60
            let sets = lift.exercises.flatMap(\.sets).filter { $0.isWorking && ($0.reps ?? 0) > 0 }.count
            var ids = [event.id]
            // Hevy knows the sets, so its cost replaces the plain minutes of a matching recording.
            let cost = minutes * drainPerMinute(.strength) / 2 + Double(sets) * drainPerSet
            for workout in canonical where workout.members.contains(where: { WorkoutDedupe.sameSession($0, event) }) {
                matched.insert(workout.id)
                ids += workout.members.map(\.id)
            }
            sessions.append(HPWorkout(ids: ids, drainFraction: Swift.min(cost, maxDrainPerWorkout)))
        }
        for workout in canonical where !matched.contains(workout.id) {
            sessions.append(HPWorkout(ids: workout.members.map(\.id), drainFraction: drain(for: workout)))
        }
        return sessions
    }

    static func drain(for workout: CanonicalWorkout) -> Double {
        Swift.min(Swift.max(0, workout.movingTimeSec) / 60 * drainPerMinute(workout.sportFamily), maxDrainPerWorkout)
    }

    /// Regenerates for the time since the last update, then drains new sessions and a new red recovery.
    /// `recoveryDayKey` is the WHOOP day of `recoveryScore`; only today's reading can hit HP.
    static func update(
        _ state: HitPointState?,
        maxHP: Int,
        now: Date,
        recoveryScore: Int?,
        recoveryDayKey: String?,
        todayKey: String,
        workouts: [HPWorkout]
    ) -> HitPointState {
        var next = state ?? .full(max: maxHP, now: now)
        let ceiling = Double(maxHP)
        let hours = Swift.max(0, now.timeIntervalSince(next.updatedAt) / 3600)
        next.current += ceiling / fullRegenHours * hours * regenMultiplier(recoveryScore: recoveryScore)
        next.max = maxHP
        next.current = Swift.min(Swift.max(next.current, 0), ceiling)
        next.updatedAt = Swift.max(now, next.updatedAt)

        let drained = Set(next.drainedWorkoutIds)
        for workout in workouts where !workout.ids.isEmpty && drained.isDisjoint(with: workout.ids) {
            next.current -= ceiling * workout.drainFraction
            next.drainedWorkoutIds += workout.ids.filter { !next.drainedWorkoutIds.contains($0) }
        }
        next.drainedWorkoutIds = Array(next.drainedWorkoutIds.suffix(HitPointState.keepIds))

        if let recoveryScore, let recoveryDayKey, recoveryDayKey == todayKey,
           next.recoveryHitDayKey != recoveryDayKey, recoveryScore < redRecoveryBelow {
            next.current -= ceiling * recoveryHit(recoveryScore: recoveryScore)
            next.recoveryHitDayKey = recoveryDayKey
        }
        next.current = Swift.min(Swift.max(next.current, 0), ceiling)
        return next
    }

    // MARK: - Self-check (runs in DEBUG at launch)

    static func check() -> [String] {
        var errors: [String] = []
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.01 }
        let start = Date(timeIntervalSince1970: 1_000_000)
        let day = "2026-10-28"

        if maxHP(for: .empty) != baseHP {
            errors.append("max HP with no data should be \(baseHP), got \(maxHP(for: .empty))")
        }
        let allMax = StatLevelSet(levels: Dictionary(uniqueKeysWithValues: Stat.allCases.map { ($0, StatLevel.maxLevel) }))
        if maxHP(for: allMax) != baseHP + hpPerLevel * StatLevelSet.overallMaxLevel + hpPerStatPoint * 3 * StatLevel.maxLevel {
            errors.append("max HP should be 1000 + 20 × overall level + 4 × (STR + END + REC), got \(maxHP(for: allMax))")
        }
        var stronger = StatLevelSet.empty
        stronger.levels[.STR] = 100
        if maxHP(for: stronger) <= maxHP(for: .empty) {
            errors.append("max HP should grow with the stat levels")
        }
        if isCritical(current: 721, max: 3_600) || !isCritical(current: 720, max: 3_600) || isCritical(current: 0, max: 0) {
            errors.append("HP should be critical at or below 20% of max")
        }

        let empty = HitPointState(current: 0, max: 1_000, updatedAt: start)
        let twoDays = update(empty, maxHP: 1_000, now: start.addingTimeInterval(48 * 3600), recoveryScore: nil,
                             recoveryDayKey: nil, todayKey: day, workouts: [])
        if !near(twoDays.current, 1_000) {
            errors.append("HP should refill from 0 in 48 hours at a normal recovery")
        }
        let green = update(empty, maxHP: 1_000, now: start.addingTimeInterval(12 * 3600), recoveryScore: 90,
                           recoveryDayKey: "2026-10-27", todayKey: day, workouts: [])
        let low = update(empty, maxHP: 1_000, now: start.addingTimeInterval(12 * 3600), recoveryScore: 40,
                         recoveryDayKey: "2026-10-27", todayKey: day, workouts: [])
        if !(green.current > low.current) || !near(green.current, 1_000 / 48.0 * 12 * 1.4) {
            errors.append("a high recovery should regenerate faster")
        }
        let back = update(empty, maxHP: 1_000, now: start.addingTimeInterval(-3600), recoveryScore: nil,
                          recoveryDayKey: nil, todayKey: day, workouts: [])
        if back.current != 0 || back.updatedAt != start {
            errors.append("a clock that moved back should not regenerate or rewind the update time")
        }

        let run = HPWorkout(ids: ["strava:1", "healthkit:a"], drainFraction: 0.25)
        let full = HitPointState.full(max: 1_000, now: start)
        let once = update(full, maxHP: 1_000, now: start, recoveryScore: nil, recoveryDayKey: nil, todayKey: day, workouts: [run])
        let again = update(once, maxHP: 1_000, now: start, recoveryScore: nil, recoveryDayKey: nil, todayKey: day,
                           workouts: [HPWorkout(ids: ["whoop:z", "healthkit:a"], drainFraction: 0.25)])
        if !near(once.current, 750) || !near(again.current, 750) {
            errors.append("a workout should drain HP once, even when a new source joins it")
        }
        let wiped = update(full, maxHP: 1_000, now: start, recoveryScore: nil, recoveryDayKey: nil, todayKey: day,
                           workouts: [run, HPWorkout(ids: ["strava:2"], drainFraction: 0.6), HPWorkout(ids: ["strava:3"], drainFraction: 0.6)])
        if wiped.current != 0 {
            errors.append("HP should never fall below 0")
        }

        let red = update(full, maxHP: 1_000, now: start, recoveryScore: 20, recoveryDayKey: day, todayKey: day, workouts: [])
        let redAgain = update(red, maxHP: 1_000, now: start, recoveryScore: 20, recoveryDayKey: day, todayKey: day, workouts: [])
        let yesterday = update(full, maxHP: 1_000, now: start, recoveryScore: 20, recoveryDayKey: "2026-10-27", todayKey: day, workouts: [])
        let yellow = update(full, maxHP: 1_000, now: start, recoveryScore: 34, recoveryDayKey: day, todayKey: day, workouts: [])
        if !near(red.current, 1_000 * (1 - recoveryHit(recoveryScore: 20))) || red.current != redAgain.current
            || yesterday.current != 1_000 || yellow.current != 1_000 {
            errors.append("only today's red recovery should hit HP, once")
        }

        let minute: TimeInterval = 60
        let strava = WorkoutEvent(source: "strava", externalId: "9", sport: "Run", start: start, end: start.addingTimeInterval(50 * minute),
                                  movingTimeSec: 50 * minute, distanceMeters: 10_000)
        let liftRecording = WorkoutEvent(source: "healthkit", externalId: "h", sport: "TraditionalStrengthTraining",
                                         start: start.addingTimeInterval(3 * 3600), end: start.addingTimeInterval(3 * 3600 + 60 * minute),
                                         movingTimeSec: 60 * minute)
        let lift = HevyWorkout(id: "w1", title: "Push", start: start.addingTimeInterval(3 * 3600 + 2 * minute),
                               end: start.addingTimeInterval(3 * 3600 + 62 * minute), exercises: [
            HevyExercise(title: "Bench Press (Barbell)", templateId: nil, sets: [HevySet(type: "warmup", reps: 5, weightKg: 40, rpe: nil, durationSec: nil)]
                + Array(repeating: HevySet(type: "normal", reps: 5, weightKg: 100, rpe: nil, durationSec: nil), count: 20)),
        ])
        let sessions = workouts(canonical: WorkoutDedupe.canonical([strava, liftRecording]), hevy: [lift])
        if sessions.count != 2 || !sessions.contains(where: { $0.ids.contains("hevy:w1") && $0.ids.contains("healthkit:h") }) {
            errors.append("a Hevy lift and its Health recording should be one session")
        }
        if let session = sessions.first(where: { $0.ids.contains("hevy:w1") }), !near(session.drainFraction, 60 * 0.002 + 20 * drainPerSet) {
            errors.append("a lift should drain by its minutes and its working sets")
        }
        if let session = sessions.first(where: { $0.ids.contains("strava:9") }), !near(session.drainFraction, 0.25) {
            errors.append("a 50 minute run should drain 25% of max HP")
        }
        return errors
    }
}

extension GameSnapshot {
    /// Brings HP up to `now`: regeneration, then today's new workouts and a red WHOOP recovery.
    /// `maxHP` comes from the stat levels (`HitPoints.maxHP(for:)`), which the store holds.
    mutating func applyHitPoints(integrations: DayIntegrationSnapshot, maxHP: Int, now: Date) {
        hitPoints = HitPoints.update(
            hitPoints,
            maxHP: maxHP,
            now: now,
            recoveryScore: readiness?.recoveryScore,
            recoveryDayKey: readiness?.capturedOn,
            todayKey: QuestDay.key(for: now),
            workouts: HitPoints.workouts(canonical: integrations.workouts, hevy: integrations.hevy.workouts)
        )
    }
}
