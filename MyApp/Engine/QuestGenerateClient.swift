import Foundation

protocol QuestGenerating {
    /// Returns a schema-valid bundle for the locked mode, or a catalog bundle marked `fallback`.
    func generate(context: MorningContext) async -> QuestBundle
    /// Like `generate`, and also says when a fallback came from no reply at all, so the app can try again on the next open.
    func generateResult(context: MorningContext) async -> QuestGeneration
}

struct QuestGeneration {
    var bundle: QuestBundle
    /// True when the planner got no reply (offline, suspended, bad key). The catalog stays and the app may try again later.
    var retryLater: Bool
    /// True when the planner made today the week's rest day. `bundle` is then the catalog's and the app writes the Rest Day.
    var restToday = false
    /// The planner's one sentence on why today rests, or the app's own from `RestScore` offline.
    var restReason: String? = nil
}

extension QuestGenerating {
    func generateResult(context: MorningContext) async -> QuestGeneration {
        QuestGeneration(bundle: await generate(context: context), retryLater: false)
    }
}

/// Makes the quest generator. The app plans the day itself: no server, no key, and no model call.
enum QuestGenerateClient {
    /// The upper bound for the app's short network calls (Hevy, Strava, WHOOP, and the others).
    static let timeout: TimeInterval = 150

    static func make(catalog: FallbackCatalog) -> any QuestGenerating {
        OnDeviceQuestGenerateClient(catalog: catalog)
    }
}

/// The day from the catalog and the gym split: the split's sets and reps with no weights (the player picks them),
/// one 10K Run, and the day's narrative from `DailyLines`. Readiness does not cut sets.
struct MockQuestGenerateClient: QuestGenerating {
    var catalog: FallbackCatalog

    func generate(context: MorningContext) async -> QuestBundle {
        bundle(for: context, now: .now)
    }

    func bundle(for context: MorningContext, now: Date) -> QuestBundle {
        var built = splitDay(context: context, now: now)
        built.generatedBy = "mock"
        if let accepted = QuestSafety.accepting(built, context: context, assignedAt: now) {
            return accepted
        }
        return catalogFallback(context: context, now: now)
    }

    func catalogFallback(context: MorningContext, now: Date) -> QuestBundle {
        var built = splitDay(context: context, now: now)
        built.generatedBy = "fallback"
        return built
    }

    private func splitDay(context: MorningContext, now: Date) -> QuestBundle {
        let dayKey = context.player.localDate
        var built = catalog.makeBundle(mode: context.modeDecision.selectedMode, band: .green, dayKey: dayKey, now: now)
        if let today = context.split?.today {
            built = GymSplit.apply(today, to: built, now: now)
        }
        if built.mode == .performanceTraining { built.narrative = DailyLines.narrative(dayKey: dayKey) }
        return built
    }
}

/// Plans the day on the phone with the app's own rules. The app's rest signals pick the week's rest day when it is open.
struct OnDeviceQuestGenerateClient: QuestGenerating {
    var catalog: FallbackCatalog

    func generate(context: MorningContext) async -> QuestBundle {
        await generateResult(context: context).bundle
    }

    func generateResult(context: MorningContext) async -> QuestGeneration {
        let now = Date()
        let plan = MockQuestGenerateClient(catalog: catalog)
        if let rest = context.rest, rest.available, rest.scoreSaysRest {
            let reason = RestScore.Result(points: RestScore.restAt, signals: rest.signals).reason
            return QuestGeneration(bundle: plan.catalogFallback(context: context, now: now), retryLater: false, restToday: true, restReason: reason)
        }
        return QuestGeneration(bundle: plan.bundle(for: context, now: now), retryLater: false)
    }
}
