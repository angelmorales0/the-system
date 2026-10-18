import Foundation

struct HealthKitWorkoutVerifier: Verifier {
    var method: VerificationMethod { .healthkitWorkout }

    func evaluate(quest: Quest, context: VerificationContext) -> VerificationResult {
        guard quest.verification.method == method else { return .unchanged }
        switch context.integrations.health.access {
        case .unavailable:
            return .incomplete(reason: "TODO: HealthKit workouts are not available on this device.")
        case .notRequested:
            return .incomplete(reason: "TODO: Allow Health access for workouts.")
        case .requested:
            break
        }
        let activity = quest.verification.params["activityType"]?.stringValue
        let minDistance = DistanceRule.minimumMeters(quest)
        let minimum = quest.verification.params["minDurationSec"]?.doubleValue
            ?? (quest.progress.unit == "min" ? quest.progress.target * 60 : (minDistance == nil ? quest.progress.target : 0))
        let candidates = context.integrations.workouts.filter { workout in
            workout.members.contains { $0.source == "healthkit" } && IntegrationMatch.matchesActivity(workout, activity: activity)
        }
        let matches = candidates.filter { $0.movingTimeSec + 0.001 >= minimum && DistanceRule.meets($0, minDistance) }
        if matches.isEmpty, minDistance != nil {
            return DistanceRule.progress(candidates, quest: quest, context: context, source: "healthkit")
        }
        return workoutResult(matches, quest: quest, context: context, source: "healthkit")
    }
}

struct HealthKitNutritionVerifier: Verifier {
    var method: VerificationMethod { .healthkitNutrition }

    func evaluate(quest: Quest, context: VerificationContext) -> VerificationResult {
        guard quest.verification.method == method else { return .unchanged }
        guard context.integrations.health.access == .requested else {
            return .incomplete(reason: "TODO: Allow Health access for nutrition.")
        }
        let nutrient = quest.verification.params["nutrient"]?.stringValue?.lowercased() ?? ""
        if nutrient.contains("protein") || quest.progress.unit == "g" {
            return proteinResult(quest: quest, context: context, minimum: quest.verification.params["minProteinG"]?.doubleValue ?? quest.progress.target)
        }
        let minimum = quest.verification.params["minKcal"]?.doubleValue ?? quest.progress.target
        return scalarResult(
            current: context.integrations.health.energyKcal,
            minimum: minimum,
            quest: quest,
            context: context,
            source: "healthkit",
            externalId: "hk:energy:\(context.dayKey)"
        )
    }
}

struct MacroFactorProteinVerifier: Verifier {
    var method: VerificationMethod { .macrofactorProtein }

    func evaluate(quest: Quest, context: VerificationContext) -> VerificationResult {
        guard quest.verification.method == method else { return .unchanged }
        guard context.integrations.health.access == .requested else {
            return .incomplete(reason: "TODO: Allow Health access so MacroFactor protein can be read.")
        }
        let minimum = quest.verification.params["minProteinG"]?.doubleValue ?? quest.progress.target
        return proteinResult(quest: quest, context: context, minimum: minimum)
    }
}

struct WhoopStrainVerifier: Verifier {
    var method: VerificationMethod { .whoopStrain }

    func evaluate(quest: Quest, context: VerificationContext) -> VerificationResult {
        guard quest.verification.method == method else { return .unchanged }
        let reading = context.integrations.whoop
        guard reading.configured, reading.available, reading.scored, let strain = reading.dayStrain else {
            return .incomplete(reason: reading.reason.isEmpty ? "TODO: WHOOP strain is not connected." : reading.reason)
        }
        let minimum = quest.verification.params["minStrain"]?.doubleValue ?? quest.progress.target
        return scalarResult(
            current: strain,
            minimum: minimum,
            quest: quest,
            context: context,
            source: "whoop",
            externalId: "whoop:strain:\(context.dayKey)"
        )
    }
}

struct WhoopRecoveryVerifier: Verifier {
    var method: VerificationMethod { .whoopRecovery }

    func evaluate(quest: Quest, context: VerificationContext) -> VerificationResult {
        guard quest.verification.method == method else { return .unchanged }
        let reading = context.integrations.whoop
        guard reading.configured, reading.available, let score = reading.recoveryScore else {
            return .incomplete(reason: reading.reason.isEmpty ? "TODO: WHOOP recovery is not connected." : reading.reason)
        }
        let minimum = quest.verification.params["minRecoveryScore"]?.doubleValue ?? quest.progress.target
        return scalarResult(
            current: Double(score),
            minimum: minimum,
            quest: quest,
            context: context,
            source: "whoop",
            externalId: "whoop:recovery:\(context.dayKey)"
        )
    }
}

struct StravaActivityVerifier: Verifier {
    var method: VerificationMethod { .stravaActivity }

    func evaluate(quest: Quest, context: VerificationContext) -> VerificationResult {
        guard quest.verification.method == method else { return .unchanged }
        let reading = context.integrations.strava
        guard reading.configured, reading.available else {
            return .incomplete(reason: reading.reason.isEmpty ? "TODO: Strava is not connected." : reading.reason)
        }
        let types = IntegrationMatch.strings(quest.verification.params["types"])
        let minDistance = DistanceRule.minimumMeters(quest)
        let minimum = quest.verification.params["minMovingTimeSec"]?.doubleValue
            ?? (quest.progress.unit == "min" ? quest.progress.target * 60 : 0)
        let candidates = context.integrations.workouts.filter { workout in
            workout.members.contains { $0.source == "strava" } && IntegrationMatch.matches(workout, types: types)
        }
        let matches = candidates.filter { $0.movingTimeSec + 0.001 >= minimum && DistanceRule.meets($0, minDistance) }
        if matches.isEmpty, minDistance != nil {
            return DistanceRule.progress(candidates, quest: quest, context: context, source: "strava")
        }
        return workoutResult(matches, quest: quest, context: context, source: "strava")
    }
}

/// Counts today's working sets of one exercise in Hevy, or their total hold time. Params:
/// `exercise` (title without the equipment in brackets, so "Bench Press" matches "Bench Press (Barbell)"
/// but not "Incline Bench Press (Dumbbell)"), or `templateId`.
/// Set mode: `sets` (else the quest target); optional `minReps` and `minWeightKg` per set.
/// Time mode: `minDurationSec` sums the timed sets, for stretches such as "Splits [0/3min]".
/// Warm-up sets never count.
struct HevySetsVerifier: Verifier {
    var method: VerificationMethod { .hevySets }

    func evaluate(quest: Quest, context: VerificationContext) -> VerificationResult {
        guard quest.verification.method == method else { return .unchanged }
        let reading = context.integrations.hevy
        guard reading.configured, reading.available else {
            return .incomplete(reason: reading.reason.isEmpty ? "TODO: Hevy is not connected." : reading.reason)
        }
        let params = quest.verification.params
        let templateId = params["templateId"]?.stringValue
        let exercise = Self.baseName(params["exercise"]?.stringValue ?? quest.title)
        let minReps = params["minReps"]?.doubleValue ?? 1
        let minWeight = params["minWeightKg"]?.doubleValue
        let minDuration = params["minDurationSec"]?.doubleValue

        var total = 0.0
        var workoutIds: [String] = []
        var latest: Date?
        for workout in reading.workouts {
            let matching = workout.exercises.filter { entry in
                if let templateId { return entry.templateId == templateId }
                return Self.baseName(entry.title) == exercise
            }
            let sets = matching.flatMap(\.sets).filter { set in
                guard set.isWorking else { return false }
                if minDuration != nil { return (set.durationSec ?? 0) > 0 }
                guard Double(set.reps ?? 0) + 0.001 >= minReps else { return false }
                guard let minWeight else { return true }
                return (set.weightKg ?? 0) + 0.001 >= minWeight
            }
            guard !sets.isEmpty else { continue }
            total += minDuration != nil ? sets.reduce(0) { $0 + ($1.durationSec ?? 0) } : Double(sets.count)
            workoutIds.append(workout.id)
            latest = max(latest ?? workout.end, workout.end)
        }
        guard total > 0 else { return .unchanged }

        let key = templateId ?? exercise
        let mode = minDuration != nil ? "time" : "sets"
        let evidence = Evidence.make(
            source: "hevy",
            externalId: "hevy:\(mode):\(context.dayKey):\(key)",
            payload: "hevy|\(mode)|\(key)|\(context.dayKey)|\(total)|\(workoutIds.sorted().joined(separator: ","))",
            timestamp: latest ?? context.now
        )
        if context.claimedKeys.contains(evidence.reuseKey) {
            return .failed(reason: "Those sets were already used for another quest today.")
        }
        let target = minDuration ?? params["sets"]?.doubleValue ?? quest.progress.target
        guard total + 0.001 >= target else {
            // Time mode shows minutes or seconds, matching the quest's unit.
            let shown = minDuration != nil && quest.progress.unit == "min" ? total / 60 : total
            return .progress(current: min(shown, quest.progress.target), evidence: evidence)
        }
        return .completed(evidence: evidence)
    }

    /// "Bench Press (Barbell)" → "bench press". Hevy puts the equipment in brackets at the end.
    static func baseName(_ title: String) -> String {
        var name = title
        if let open = name.lastIndex(of: "("), name.hasSuffix(")") {
            name = String(name[..<open])
        }
        return name.trimmingCharacters(in: .whitespaces).lowercased()
    }
}

private func proteinResult(quest: Quest, context: VerificationContext, minimum: Double) -> VerificationResult {
    let source = context.integrations.health.proteinPrefersMacroFactor ? "macrofactor" : "healthkit"
    return scalarResult(
        current: context.integrations.health.proteinGrams,
        minimum: minimum,
        quest: quest,
        context: context,
        source: source,
        externalId: "hk:protein:\(context.dayKey)"
    )
}

private func workoutResult(_ matches: [CanonicalWorkout], quest: Quest, context: VerificationContext, source: String) -> VerificationResult {
    guard let workout = matches.max(by: { $0.movingTimeSec < $1.movingTimeSec }) else { return .unchanged }
    let evidence = Evidence.make(
        source: source,
        externalId: "workout:\(workout.id)",
        payload: "\(source)|\(workout.id)|\(context.dayKey)|\(Int(workout.movingTimeSec))",
        timestamp: workout.end
    )
    if context.claimedKeys.contains(evidence.reuseKey) {
        return .failed(reason: "That workout was already used for another quest today.")
    }
    return .completed(evidence: evidence)
}

private func scalarResult(
    current: Double,
    minimum: Double,
    quest: Quest,
    context: VerificationContext,
    source: String,
    externalId: String
) -> VerificationResult {
    let evidence = Evidence.make(
        source: source,
        externalId: externalId,
        payload: "\(source)|\(externalId)|\(context.dayKey)|\(current)",
        timestamp: context.now
    )
    if context.claimedKeys.contains(evidence.reuseKey) {
        return .failed(reason: "That evidence was already used for another quest today.")
    }
    guard current + 0.001 >= minimum else {
        guard current > 0 else { return .unchanged }
        return .progress(current: min(current, quest.progress.target), evidence: evidence)
    }
    return .completed(evidence: evidence)
}

struct MercurySpendUnderVerifier: Verifier {
    static let source = "mercury"
    var method: VerificationMethod { .mercurySpendUnder }

    func evaluate(quest: Quest, context: VerificationContext) -> VerificationResult {
        guard quest.verification.method == method else { return .unchanged }
        let reading = context.integrations.mercury
        guard reading.configured, reading.available, reading.synced else {
            let reason = reading.reason.isEmpty ? "TODO: Mercury is not connected." : reading.reason
            return .incomplete(reason: reason)
        }
        let cap = quest.verification.params["maxDiscretionaryUsd"]?.doubleValue ?? reading.capUsd
        let spent = reading.discretionarySpendUsd
        if spent > cap + 0.001 {
            return .failed(reason: "Discretionary spend is over the cap.")
        }
        let evidence = Evidence.make(
            source: Self.source,
            externalId: "mercury:spend:\(context.dayKey)",
            payload: "mercury|spend|\(context.dayKey)|\(spent)|\(cap)",
            timestamp: context.now
        )
        if context.claimedKeys.contains(evidence.reuseKey) {
            return .failed(reason: "That evidence was already used for another quest today.")
        }
        // $0 in the morning is not a clear. The backend marks the day settled at the settle hour, or once the day is past.
        guard reading.settled else {
            return .progress(current: min(max(spent, 0), quest.progress.target), evidence: evidence)
        }
        return .completed(evidence: evidence)
    }
}

/// Distance targets for runs and walks. Param: `minDistanceMeters`; the quest shows km (`[6.2/10km]`).
enum DistanceRule {
    /// GPS tracks round. A run within 50 m of the target counts.
    static let toleranceMeters = 50.0

    static func minimumMeters(_ quest: Quest) -> Double? {
        quest.verification.params["minDistanceMeters"]?.doubleValue
    }

    static func meets(_ workout: CanonicalWorkout, _ minimum: Double?) -> Bool {
        guard let minimum else { return true }
        return (workout.distanceMeters ?? 0) + toleranceMeters >= minimum
    }

    /// Km rounded down to one decimal, so 9.99 km never shows as 10.
    static func kilometers(_ meters: Double) -> Double {
        (max(meters, 0) / 100).rounded(.down) / 10
    }

    /// The longest matching workout that has not reached the distance yet, as partial progress.
    static func progress(_ candidates: [CanonicalWorkout], quest: Quest, context: VerificationContext, source: String) -> VerificationResult {
        guard let workout = candidates.filter({ ($0.distanceMeters ?? 0) > 0 }).max(by: { ($0.distanceMeters ?? 0) < ($1.distanceMeters ?? 0) }),
              let meters = workout.distanceMeters else { return .unchanged }
        let evidence = Evidence.make(
            source: source,
            externalId: "workout:\(workout.id)",
            payload: "\(source)|\(workout.id)|\(context.dayKey)|\(Int(meters))",
            timestamp: workout.end
        )
        return .progress(current: min(kilometers(meters), quest.progress.target), evidence: evidence)
    }
}

enum IntegrationMatch {
    static func strings(_ value: JSONValue?) -> [String] {
        guard case .array(let values)? = value else { return [] }
        return values.compactMap(\.stringValue)
    }

    static func matches(_ workout: CanonicalWorkout, types: [String]) -> Bool {
        if types.isEmpty { return true }
        return types.contains { type in
            let family = SportFamily.from(type)
            if family != .other && family == workout.sportFamily { return true }
            return workout.members.contains { $0.sport.lowercased() == type.lowercased() }
        }
    }

    static func matchesActivity(_ workout: CanonicalWorkout, activity: String?) -> Bool {
        guard let activity, !activity.isEmpty else { return true }
        let family = SportFamily.from(activity)
        if family != .other && family == workout.sportFamily { return true }
        return workout.members.contains { $0.sport.lowercased().contains(activity.lowercased()) }
    }
}
