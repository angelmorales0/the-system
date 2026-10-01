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
        let minimum = quest.verification.params["minDurationSec"]?.doubleValue
            ?? (quest.progress.unit == "min" ? quest.progress.target * 60 : quest.progress.target)
        let matches = context.integrations.workouts.filter { workout in
            workout.members.contains { $0.source == "healthkit" } && IntegrationMatch.matchesActivity(workout, activity: activity) && workout.movingTimeSec + 0.001 >= minimum
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
        let minimum = quest.verification.params["minMovingTimeSec"]?.doubleValue
            ?? (quest.progress.unit == "min" ? quest.progress.target * 60 : 0)
        let matches = context.integrations.workouts.filter { workout in
            workout.members.contains { $0.source == "strava" }
                && IntegrationMatch.matches(workout, types: types)
                && workout.movingTimeSec + 0.001 >= minimum
        }
        return workoutResult(matches, quest: quest, context: context, source: "strava")
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
