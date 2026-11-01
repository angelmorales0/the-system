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
}

extension QuestGenerating {
    func generateResult(context: MorningContext) async -> QuestGeneration {
        QuestGeneration(bundle: await generate(context: context), retryLater: false)
    }
}

/// Makes the quest generator. Planning runs on the phone; no server or base URL is needed.
enum QuestGenerateClient {
    /// Claude thinks at high effort over 30 days of training, with up to 100 seconds for retries.
    /// The catalog quests stay on screen while it runs. Other short calls use this as their upper bound too.
    static let timeout: TimeInterval = 150

    static func make(catalog: FallbackCatalog) -> any QuestGenerating {
        OnDeviceQuestGenerateClient(catalog: catalog)
    }
}

struct MockQuestGenerateClient: QuestGenerating {
    var catalog: FallbackCatalog

    func generate(context: MorningContext) async -> QuestBundle {
        bundle(for: context, now: .now)
    }

    func bundle(for context: MorningContext, now: Date) -> QuestBundle {
        let mode = context.modeDecision.selectedMode
        let band = context.modeDecision.trainingBand
        var built = catalog.makeBundle(mode: mode, band: band, dayKey: context.player.localDate, now: now)
        if let today = context.split?.today {
            built = GymSplit.apply(today, to: built, band: band, now: now)
        }
        built.generatedBy = "mock"
        if let accepted = QuestSafety.accepting(built, context: context, assignedAt: now) {
            return accepted
        }
        return catalogFallback(context: context, now: now)
    }
}

extension MockQuestGenerateClient {
    func catalogFallback(context: MorningContext, now: Date) -> QuestBundle {
        var built = catalog.makeBundle(
            mode: context.modeDecision.selectedMode,
            band: context.modeDecision.trainingBand,
            dayKey: context.player.localDate,
            now: now
        )
        if let today = context.split?.today {
            built = GymSplit.apply(today, to: built, band: context.modeDecision.trainingBand, now: now)
        }
        built.generatedBy = "fallback"
        return built
    }
}

/// Plans the day on the phone: 30 days of Hevy, Strava, and WHOOP, then Claude with the key from the Keychain.
/// Without a key it is the offline mock. Every plan Claude writes is rejected → the template. No reply → the catalog stays.
struct OnDeviceQuestGenerateClient: QuestGenerating {
    var catalog: FallbackCatalog

    static var hasKey: Bool { SecretStore.has(.anthropicApiKey) }

    func generate(context: MorningContext) async -> QuestBundle {
        await generateResult(context: context).bundle
    }

    func generateResult(context: MorningContext) async -> QuestGeneration {
        let now = Date()
        let mock = MockQuestGenerateClient(catalog: catalog)
        guard let key = SecretStore.read(.anthropicApiKey) else {
            return QuestGeneration(bundle: mock.bundle(for: context, now: now), retryLater: false)
        }
        let fallback = QuestGeneration(bundle: mock.catalogFallback(context: context, now: now), retryLater: false)
        guard let body = JSONValue.from(context), QuestPlanner.validateRequest(body).isEmpty else { return fallback }
        let training = await TrainingHistory.build(context: body)
        let full = QuestPlanner.withHistory(body, training: training)
        let outcome = await QuestPlanner.claudeOrNone(full) { request, timeout in
            await QuestPlanner.callClaude(request, apiKey: key, timeout: timeout)
        }
        let raw: JSONValue
        switch outcome {
        case .accepted(let plan):
            raw = plan
        case .rest:
            return QuestGeneration(bundle: fallback.bundle, retryLater: false, restToday: true)
        case .rejected:
            raw = QuestPlanner.templateBundle(full)
        case .unreachable:
            return QuestGeneration(bundle: fallback.bundle, retryLater: true)
        }
        let bundle = QuestPlanner.sanitize(raw, full)
        guard QuestPlanner.validateBundle(bundle, full).isEmpty,
              let decoded = QuestPlanner.decodedBundle(bundle),
              let accepted = QuestSafety.accepting(decoded, context: context, assignedAt: Date()) else { return fallback }
        return QuestGeneration(bundle: accepted, retryLater: false)
    }
}

extension QuestPlanner {
    /// The sanitized bundle as the app's model. Nil when it does not decode.
    static func decodedBundle(_ bundle: JSONValue) -> QuestBundle? {
        bundle.decode(QuestBundle.self)
    }
}
