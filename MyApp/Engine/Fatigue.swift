import Foundation

/// The player's fatigue, 0...100. Workouts, a low WHOOP recovery, stress, and screen time raise it; time brings it down.
struct FatigueState: Codable, Equatable {
    var value: Double
    /// Decay and stress count from this moment.
    var updatedAt: Date
    /// Every recording id that already added fatigue, oldest first (the same dedupe as `HitPointState`).
    var countedWorkoutIds: [String] = []
    /// WHOOP day whose low recovery already added fatigue.
    var recoveryDayKey: String?
    /// Screen time day and the minutes of it that already added fatigue. Only the increase counts.
    var screenDayKey: String?
    var screenMinutesCounted: Int = 0
    /// Running HRV baseline (ms) for the stress score, and the WHOOP day it last took in.
    var hrvBaseline: Double?
    var hrvDayKey: String?

    static let keepIds = 300

    static func rested(now: Date) -> FatigueState {
        FatigueState(value: 0, updatedAt: now)
    }

    private enum CodingKeys: String, CodingKey {
        case value, updatedAt, countedWorkoutIds, recoveryDayKey, screenDayKey, screenMinutesCounted, hrvBaseline, hrvDayKey
    }

    init(value: Double, updatedAt: Date, countedWorkoutIds: [String] = [], recoveryDayKey: String? = nil,
         screenDayKey: String? = nil, screenMinutesCounted: Int = 0, hrvBaseline: Double? = nil, hrvDayKey: String? = nil) {
        self.value = value
        self.updatedAt = updatedAt
        self.countedWorkoutIds = countedWorkoutIds
        self.recoveryDayKey = recoveryDayKey
        self.screenDayKey = screenDayKey
        self.screenMinutesCounted = screenMinutesCounted
        self.hrvBaseline = hrvBaseline
        self.hrvDayKey = hrvDayKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decodeIfPresent(Double.self, forKey: .value) ?? 0
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
        countedWorkoutIds = try container.decodeIfPresent([String].self, forKey: .countedWorkoutIds) ?? []
        recoveryDayKey = try container.decodeIfPresent(String.self, forKey: .recoveryDayKey)
        screenDayKey = try container.decodeIfPresent(String.self, forKey: .screenDayKey)
        screenMinutesCounted = try container.decodeIfPresent(Int.self, forKey: .screenMinutesCounted) ?? 0
        hrvBaseline = try container.decodeIfPresent(Double.self, forKey: .hrvBaseline)
        hrvDayKey = try container.decodeIfPresent(String.self, forKey: .hrvDayKey)
    }
}

/// Pure fatigue math, so the store, the status sheet, and the check share it.
///   Decay       × 0.6 per day (40%/day of the current value), the days scaled by `HitPoints.regenMultiplier`
///               (recovery 0: × 0.5 speed, 50 or no reading: × 1, 100: × 1.5)
///   Workout     + 50 × the session's HP drain share (a 50 min run: +12.5, at most +30), once per session
///   Recovery    WHOOP recovery under 67: + 0.3 per point under 67 (recovery 20: +14.1), once per WHOOP day
///   Stress      score 0...100, see `stressScore`; above 30 it adds up to 1 point per hour: (stress − 30) / 70 per hour
///   Screen      + 1 per hour of new screen time today (phone + Mac, shared minutes once); only the increase counts
///   Red         at or above 80
enum Fatigue {
    static let maxValue = 100.0
    static let keepPerDay = 0.6
    static let perWorkoutDrain = 50.0
    static let lowRecoveryBelow = 67
    static let perRecoveryPoint = 0.3
    static let stressFloor = 30.0
    static let stressPerHourAtMax = 1.0
    static let perScreenHour = 1.0
    /// At or above this, the fatigue meter turns red.
    static let redAt = 80
    /// Stress weights when both signals exist.
    static let hrvWeight = 0.6
    static let strainWeight = 0.4
    /// HRV this far under the baseline is stress 100.
    static let hrvDropForMax = 0.30
    /// WHOOP day strain (0...21) counts from 10; 21 is stress 100.
    static let strainFrom = 10.0
    static let strainMax = 21.0
    /// Each WHOOP day moves the HRV baseline this share of the way to the new reading (about a two-week average).
    static let baselineWeight = 1.0 / 14

    static func isRed(_ value: Int) -> Bool { value >= redAt }

    /// Stress 0...100, derived because the app has no direct stress score:
    ///   HRV part     share of HRV under the running baseline, 30% under = 100 (at or above the baseline = 0)
    ///   Strain part  WHOOP day strain over 10, on a 10...21 scale (21 = 100)
    ///   Both         0.6 × HRV part + 0.4 × strain part. One alone counts by itself. Neither: nil.
    static func stressScore(hrv: Double?, hrvBaseline: Double?, dayStrain: Double?) -> Double? {
        var hrvPart: Double?
        if let hrv, let hrvBaseline, hrvBaseline > 0 {
            let drop = (hrvBaseline - hrv) / hrvBaseline
            hrvPart = min(max(drop / hrvDropForMax, 0), 1) * 100
        }
        let strainPart = dayStrain.map { min(max(($0 - strainFrom) / (strainMax - strainFrom), 0), 1) * 100 }
        switch (hrvPart, strainPart) {
        case let (h?, s?): return hrvWeight * h + strainWeight * s
        case let (h?, nil): return h
        case let (nil, s?): return s
        case (nil, nil): return nil
        }
    }

    /// Fatigue per hour from stress. 0 at or below the floor.
    static func stressPerHour(_ stress: Double?) -> Double {
        guard let stress, stress > stressFloor else { return 0 }
        return min((stress - stressFloor) / (100 - stressFloor), 1) * stressPerHourAtMax
    }

    /// Fatigue a WHOOP recovery adds once. 0 at 67 and over.
    static func recoveryHit(recoveryScore: Int) -> Double {
        guard recoveryScore < lowRecoveryBelow else { return 0 }
        return perRecoveryPoint * Double(lowRecoveryBelow - Swift.max(recoveryScore, 0))
    }

    /// Decays and adds stress for the time since the last update, then adds new sessions, a low recovery, and new screen time.
    /// `recoveryDayKey` is the WHOOP day of `recoveryScore` and `hrv`; only today's reading counts.
    static func update(
        _ state: FatigueState?,
        now: Date,
        recoveryScore: Int?,
        recoveryDayKey: String?,
        hrv: Double?,
        dayStrain: Double?,
        todayKey: String,
        workouts: [HPWorkout],
        screenDayKey: String,
        screenMinutes: Int
    ) -> FatigueState {
        var next = state ?? .rested(now: now)
        let todays = recoveryDayKey == todayKey
        let hours = Swift.max(0, now.timeIntervalSince(next.updatedAt) / 3600)
        let speed = HitPoints.regenMultiplier(recoveryScore: todays ? recoveryScore : nil)
        next.value *= pow(keepPerDay, hours / 24 * speed)
        let stress = stressScore(hrv: todays ? hrv : nil, hrvBaseline: next.hrvBaseline, dayStrain: dayStrain)
        next.value += stressPerHour(stress) * hours
        next.updatedAt = Swift.max(now, next.updatedAt)

        // The baseline takes today's HRV only after today's stress used yesterday's baseline.
        if todays, let hrv, hrv > 0, next.hrvDayKey != recoveryDayKey {
            next.hrvBaseline = next.hrvBaseline.map { $0 + (hrv - $0) * baselineWeight } ?? hrv
            next.hrvDayKey = recoveryDayKey
        }

        let counted = Set(next.countedWorkoutIds)
        for workout in workouts where !workout.ids.isEmpty && counted.isDisjoint(with: workout.ids) {
            next.value += perWorkoutDrain * workout.drainFraction
            next.countedWorkoutIds += workout.ids.filter { !next.countedWorkoutIds.contains($0) }
        }
        next.countedWorkoutIds = Array(next.countedWorkoutIds.suffix(FatigueState.keepIds))

        if let recoveryScore, todays, next.recoveryDayKey != recoveryDayKey {
            next.value += recoveryHit(recoveryScore: recoveryScore)
            next.recoveryDayKey = recoveryDayKey
        }

        if next.screenDayKey != screenDayKey {
            next.screenDayKey = screenDayKey
            next.screenMinutesCounted = 0
        }
        let newMinutes = Swift.max(0, screenMinutes - next.screenMinutesCounted)
        next.value += perScreenHour * Double(newMinutes) / 60
        next.screenMinutesCounted = Swift.max(next.screenMinutesCounted, screenMinutes)

        next.value = Swift.min(Swift.max(next.value, 0), maxValue)
        return next
    }

    // MARK: - Self-check (runs in DEBUG at launch)

    static func check() -> [String] {
        var errors: [String] = []
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.01 }
        let start = Date(timeIntervalSince1970: 1_000_000)
        let day = "2026-10-28"
        func run(_ state: FatigueState?, hours: Double = 0, recovery: Int? = nil, recoveryDay: String? = nil, hrv: Double? = nil,
                 strain: Double? = nil, workouts: [HPWorkout] = [], screenDay: String = day, screen: Int = 0) -> FatigueState {
            update(state, now: start.addingTimeInterval(hours * 3600), recoveryScore: recovery, recoveryDayKey: recoveryDay, hrv: hrv,
                   dayStrain: strain, todayKey: day, workouts: workouts, screenDayKey: screenDay, screenMinutes: screen)
        }

        if isRed(79) || !isRed(80) {
            errors.append("the fatigue meter should turn red at 80")
        }

        let tired = FatigueState(value: 50, updatedAt: start)
        if !near(run(tired, hours: 24).value, 30) {
            errors.append("fatigue should fall 40% in a day at a normal recovery")
        }
        let green = run(tired, hours: 24, recovery: 100, recoveryDay: day)
        let red = run(tired, hours: 24, recovery: 50, recoveryDay: day)
        if !(green.value < red.value) {
            errors.append("a high recovery should clear fatigue faster")
        }
        let back = run(tired, hours: -1)
        if back.value != 50 || back.updatedAt != start {
            errors.append("a clock that moved back should not decay or rewind the update time")
        }

        let session = HPWorkout(ids: ["strava:1", "healthkit:a"], drainFraction: 0.25)
        let once = run(nil, workouts: [session])
        let again = run(once, workouts: [HPWorkout(ids: ["whoop:z", "healthkit:a"], drainFraction: 0.25)])
        if !near(once.value, 12.5) || !near(again.value, 12.5) {
            errors.append("a workout should add fatigue once, even when a new source joins it")
        }

        let low = run(nil, recovery: 20, recoveryDay: day)
        let lowAgain = run(low, recovery: 20, recoveryDay: day)
        let yesterday = run(nil, recovery: 20, recoveryDay: "2026-10-27")
        let fine = run(nil, recovery: 67, recoveryDay: day)
        if !near(low.value, 14.1) || low.value != lowAgain.value || yesterday.value != 0 || fine.value != 0 {
            errors.append("only today's low recovery should add fatigue, once")
        }

        let screen = run(nil, screen: 120)
        let more = run(screen, screen: 180)
        let stale = run(more, screen: 90)
        let nextDay = run(stale, screenDay: "2026-10-29", screen: 60)
        if !near(screen.value, 2) || !near(more.value, 3) || !near(stale.value, 3) || !near(nextDay.value, 4) {
            errors.append("screen time should add 1 per hour, counting only the increase each day")
        }

        if stressScore(hrv: nil, hrvBaseline: nil, dayStrain: nil) != nil
            || !near(stressScore(hrv: 42, hrvBaseline: 60, dayStrain: nil) ?? -1, 100)
            || !near(stressScore(hrv: 70, hrvBaseline: 60, dayStrain: nil) ?? -1, 0)
            || !near(stressScore(hrv: nil, hrvBaseline: nil, dayStrain: 15.5) ?? -1, 50)
            || !near(stressScore(hrv: 51, hrvBaseline: 60, dayStrain: 21) ?? -1, 0.6 * 50 + 0.4 * 100) {
            errors.append("stress should mix the HRV drop under the baseline and day strain over 10")
        }
        let calm = FatigueState(value: 0, updatedAt: start, hrvBaseline: 60, hrvDayKey: "2026-10-27")
        let stressed = run(calm, hours: 10, hrv: 42, strain: 21)
        if !near(stressed.value, 10) || stressPerHour(30) != 0 {
            errors.append("full stress should add 1 point per hour, nothing at or under 30")
        }
        let learned = run(calm, recovery: 70, recoveryDay: day, hrv: 74)
        let learnedAgain = run(learned, recovery: 70, recoveryDay: day, hrv: 74)
        if !near(learned.hrvBaseline ?? 0, 61) || learnedAgain.hrvBaseline != learned.hrvBaseline {
            errors.append("the HRV baseline should take in each WHOOP day once")
        }

        let capped = run(nil, workouts: (1...5).map { HPWorkout(ids: ["strava:\($0)"], drainFraction: 0.6) })
        if capped.value != maxValue {
            errors.append("fatigue should never pass 100")
        }
        return errors
    }
}

extension GameSnapshot {
    /// Brings fatigue up to `now`: decay and stress, then today's new workouts, a low WHOOP recovery, and new screen time.
    mutating func applyFatigue(integrations: DayIntegrationSnapshot, now: Date) {
        let whoop = integrations.whoop
        let screen = screenTimeToday
        fatigue = Fatigue.update(
            fatigue,
            now: now,
            recoveryScore: readiness?.recoveryScore,
            recoveryDayKey: readiness?.capturedOn,
            hrv: readiness?.hrv,
            dayStrain: whoop.available && whoop.scored ? whoop.dayStrain : nil,
            todayKey: QuestDay.key(for: now),
            workouts: HitPoints.workouts(canonical: integrations.workouts, hevy: integrations.hevy.workouts),
            screenDayKey: screen.dayKey,
            screenMinutes: screen.totalMinutes
        )
    }
}
