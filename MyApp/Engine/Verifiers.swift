import Foundation

/// Local rules for confirms and timers. Live adapters replace the stubs later.
enum VerificationPolicy {
    static let maxManualConfirmsPerDay = 3
    static let manualConfirmDelay: TimeInterval = 30
}

struct VerificationContext: Equatable {
    var now: Date
    var dayKey: String
    var assignedAt: Date
    var manualConfirmsToday: Int
    /// `reuseKey` values already claimed today by a different quest.
    var claimedKeys: Set<String>
    var timerElapsedSec: TimeInterval?
    var userConfirmed: Bool
}

enum VerificationResult: Equatable {
    case unchanged
    case progress(current: Double, evidence: Evidence)
    case completed(evidence: Evidence)
    case failed(reason: String)
    case incomplete(reason: String)
}

enum VerificationApply: Equatable {
    case ignored
    case updated
    case completed
    case rejected(String)
}

protocol Verifier {
    var method: VerificationMethod { get }
    func evaluate(quest: Quest, context: VerificationContext) -> VerificationResult
}

enum VerifierRegistry {
    static func verifier(for method: VerificationMethod) -> any Verifier {
        switch method {
        case .manualConfirm:
            return ManualConfirmVerifier()
        case .timerSession:
            return TimerSessionVerifier()
        case .whoopStrain:
            // TODO: Phase 5 — WHOOP cycle or workout strain, SCORED, compared with the quest minimum.
            return IncompleteVerifier(method: method, reason: "WHOOP strain is not connected")
        case .whoopRecovery:
            // TODO: Phase 5 — WHOOP recovery score. REC on Status stays a rolling composite, not this score.
            return IncompleteVerifier(method: method, reason: "WHOOP recovery is not connected")
        case .stravaActivity:
            // TODO: Phase 5 — Strava activity whose type and moving time match the quest.
            return IncompleteVerifier(method: method, reason: "Strava is not connected")
        case .healthkitWorkout:
            // TODO: Phase 3 — HealthKit workout matching type and duration for this local day.
            return IncompleteVerifier(method: method, reason: "HealthKit workouts are not connected")
        case .healthkitNutrition:
            // TODO: Phase 3 — HealthKit dietary samples. MacroFactor writes Apple Health; there is no MacroFactor API.
            return IncompleteVerifier(method: method, reason: "HealthKit nutrition is not connected")
        case .macrofactorProtein:
            // TODO: Phase 3 — dietary protein from HealthKit, preferring samples written by MacroFactor.
            return IncompleteVerifier(method: method, reason: "Protein verification is not connected")
        case .mercurySpendUnder:
            // TODO: Phase 7 — Mercury discretionary debits for this local day. The token stays on the backend.
            return IncompleteVerifier(method: method, reason: "Mercury is not connected")
        case .screenTimeLimit:
            // TODO: Phase 7 — DeviceActivity thresholds for distractors or deep work. No Screen Time OAuth in this slice.
            return IncompleteVerifier(method: method, reason: "Screen Time is not connected")
        }
    }
}

/// Tap confirm. Face ID can gate this later; the check today is the tap plus the rate limit.
struct ManualConfirmVerifier: Verifier {
    static let source = "manual_confirm"
    var method: VerificationMethod { .manualConfirm }

    func evaluate(quest: Quest, context: VerificationContext) -> VerificationResult {
        guard quest.verification.method == method else { return .unchanged }
        guard context.userConfirmed else { return .unchanged }
        let waited = context.now.timeIntervalSince(context.assignedAt)
        guard waited >= VerificationPolicy.manualConfirmDelay else {
            return .failed(reason: "Confirm unlocks 30 seconds after this quest is assigned.")
        }
        guard context.manualConfirmsToday < VerificationPolicy.maxManualConfirmsPerDay else {
            return .failed(reason: "Manual confirms are limited to 3 per day.")
        }
        let evidence = Evidence.make(
            source: Self.source,
            externalId: "manual:\(quest.id):\(context.dayKey)",
            payload: "confirm|\(quest.id)|\(context.dayKey)|\(context.now.timeIntervalSince1970)",
            timestamp: context.now
        )
        if context.claimedKeys.contains(evidence.reuseKey) {
            return .failed(reason: "That evidence was already used for another quest today.")
        }
        return .completed(evidence: evidence)
    }
}

/// In-app timer. Completes only after `minSec` of wall-clock time from the start tap.
struct TimerSessionVerifier: Verifier {
    static let source = "timer_session"
    var method: VerificationMethod { .timerSession }

    static func requiredSeconds(_ quest: Quest) -> TimeInterval {
        let raw = quest.verification.params["minSec"]?.doubleValue ?? 60
        return max(raw, 1)
    }

    func evaluate(quest: Quest, context: VerificationContext) -> VerificationResult {
        guard quest.verification.method == method else { return .unchanged }
        guard let elapsed = context.timerElapsedSec else { return .unchanged }
        let safeElapsed = max(0, elapsed)
        let required = Self.requiredSeconds(quest)
        let evidence = Evidence.make(
            source: Self.source,
            externalId: "timer:\(quest.id):\(context.dayKey)",
            payload: "timer|\(quest.id)|\(context.dayKey)|\(Int(safeElapsed.rounded(.down)))",
            timestamp: context.now
        )
        if context.claimedKeys.contains(evidence.reuseKey) {
            return .failed(reason: "That evidence was already used for another quest today.")
        }
        guard safeElapsed + 0.001 >= required else {
            return .progress(current: Self.displayCurrent(elapsed: safeElapsed, quest: quest), evidence: evidence)
        }
        return .completed(evidence: evidence)
    }

    private static func displayCurrent(elapsed: TimeInterval, quest: Quest) -> Double {
        let value: Double
        switch quest.progress.unit {
        case "s", "sec", "seconds":
            value = elapsed
        default:
            value = elapsed / 60
        }
        return min(max(value, 0), quest.progress.target)
    }
}

/// Live APIs are not connected. These never complete a quest.
struct IncompleteVerifier: Verifier {
    let method: VerificationMethod
    let reason: String

    func evaluate(quest: Quest, context: VerificationContext) -> VerificationResult {
        _ = context
        guard quest.verification.method == method else { return .unchanged }
        return .incomplete(reason: reason)
    }
}

extension VerificationMethod {
    /// Stubbed integrations still accept an on-device checkbox. Timer and manual confirm do not.
    var allowsLocalCheckbox: Bool {
        switch self {
        case .manualConfirm, .timerSession:
            return false
        default:
            return true
        }
    }
}

enum VerificationFixtures {
    static func check() -> [String] {
        var errors: [String] = []
        let assigned = Date(timeIntervalSince1970: 1_700_000_000)
        let dayKey = QuestDay.key(for: assigned)

        let timerQuest = sample(id: "timer", method: .timerSession, assignedAt: assigned)
        let short = TimerSessionVerifier().evaluate(
            quest: timerQuest,
            context: context(now: assigned, dayKey: dayKey, assignedAt: assigned, elapsed: 599)
        )
        if case .progress = short {
        } else {
            errors.append("timer 599s should progress, got \(short)")
        }
        let done = TimerSessionVerifier().evaluate(
            quest: timerQuest,
            context: context(now: assigned, dayKey: dayKey, assignedAt: assigned, elapsed: 600)
        )
        if case .completed = done {
        } else {
            errors.append("timer 600s should complete, got \(done)")
        }
        let idle = TimerSessionVerifier().evaluate(
            quest: timerQuest,
            context: context(now: assigned, dayKey: dayKey, assignedAt: assigned, elapsed: nil)
        )
        if case .unchanged = idle {
        } else {
            errors.append("timer without a start should stay unchanged")
        }

        let manualQuest = sample(id: "manual", method: .manualConfirm, assignedAt: assigned)
        let tooSoon = ManualConfirmVerifier().evaluate(
            quest: manualQuest,
            context: context(now: assigned.addingTimeInterval(10), dayKey: dayKey, assignedAt: assigned, confirmed: true)
        )
        if case .failed = tooSoon {
        } else {
            errors.append("manual confirm before 30s should fail")
        }
        let capped = ManualConfirmVerifier().evaluate(
            quest: manualQuest,
            context: context(
                now: assigned.addingTimeInterval(31),
                dayKey: dayKey,
                assignedAt: assigned,
                confirms: 3,
                confirmed: true
            )
        )
        if case .failed = capped {
        } else {
            errors.append("fourth manual confirm should fail")
        }
        let accepted = ManualConfirmVerifier().evaluate(
            quest: manualQuest,
            context: context(now: assigned.addingTimeInterval(31), dayKey: dayKey, assignedAt: assigned, confirmed: true)
        )
        if case .completed = accepted {
        } else {
            errors.append("manual confirm after 30s should complete")
        }

        let stub = VerifierRegistry.verifier(for: .stravaActivity).evaluate(
            quest: sample(id: "run", method: .stravaActivity, assignedAt: assigned),
            context: context(now: assigned, dayKey: dayKey, assignedAt: assigned, confirmed: true, elapsed: 9_999)
        )
        if case .incomplete = stub {
        } else {
            errors.append("strava stub should be incomplete")
        }
        for method in VerificationMethod.allCases where method.allowsLocalCheckbox {
            let result = VerifierRegistry.verifier(for: method).evaluate(
                quest: sample(id: method.rawValue, method: method, assignedAt: assigned),
                context: context(now: assigned, dayKey: dayKey, assignedAt: assigned, confirmed: true, elapsed: 9_999)
            )
            if case .completed = result {
                errors.append("\(method.rawValue) stub completed a quest")
            }
        }

        var bundle = QuestBundle(
            schemaVersion: 1,
            dayKey: dayKey,
            mode: .performanceTraining,
            headerLine: "Performance Training",
            narrative: "",
            quests: [timerQuest, manualQuest],
            warnings: [],
            generatedBy: "llm"
        )
        bundle.quests[0].status = .completed
        bundle.quests[0].evidence = [Evidence.make(source: "llm", externalId: "nope", payload: "x", timestamp: assigned)]
        bundle.quests[0].progress.current = 10
        bundle.quests[0].grantedXP = 40
        let stripped = bundle.strippingModelCompletion(assignedAt: assigned.addingTimeInterval(5))
        let cleaned = stripped.quests[0]
        if cleaned.status != .pending || !cleaned.evidence.isEmpty || cleaned.progress.current != 0 || cleaned.grantedXP != 0 {
            errors.append("model completion was not stripped")
        }
        if cleaned.assignedAt != assigned.addingTimeInterval(5) {
            errors.append("ingest should assign the quest locally")
        }

        var state = GameSnapshot(
            version: 1,
            player: .starter,
            signals: .placeholder,
            bundle: bundle.strippingModelCompletion(assignedAt: assigned),
            evidenceLog: [],
            runningTimers: []
        )
        let shared = Evidence.make(source: "strava", externalId: "act-1", payload: "run", timestamp: assigned)
        let first = state.apply(.completed(evidence: shared), questId: state.bundle.quests[0].id, now: assigned)
        let xp = state.player.xp
        let replay = state.apply(.completed(evidence: shared), questId: state.bundle.quests[0].id, now: assigned)
        let second = state.apply(.completed(evidence: shared), questId: state.bundle.quests[1].id, now: assigned)
        if first != .completed || replay != .ignored || state.player.xp != xp {
            errors.append("same evidence should grant XP once")
        }
        if case .rejected = second {
        } else {
            errors.append("evidence reuse across quests should be rejected, got \(second)")
        }
        let forged = Evidence(source: "llm", externalId: "done", payloadHash: "abc", timestamp: assigned)
        if case .rejected = state.apply(.completed(evidence: forged), questId: state.bundle.quests[1].id, now: assigned) {
        } else {
            errors.append("llm evidence should be rejected")
        }

        return errors
    }

    private static func sample(id: String, method: VerificationMethod, assignedAt: Date) -> Quest {
        Quest(
            id: id,
            title: id,
            kind: .daily,
            stat: .AGI,
            verification: VerificationSpec(method: method, params: ["minSec": .number(600), "prompt": .string("Confirm")]),
            deadline: assignedAt.addingTimeInterval(86_400),
            xp: 20,
            difficulty: .easy,
            mode: .performanceTraining,
            targetId: nil,
            progress: QuestProgress(current: 0, target: 10, unit: "min"),
            reward: nil,
            status: .pending,
            grantedXP: 0,
            grantedStatPoints: 0,
            grantedRecoveryToken: false,
            evidence: [],
            assignedAt: assignedAt
        )
    }

    private static func context(
        now: Date,
        dayKey: String,
        assignedAt: Date,
        confirms: Int = 0,
        confirmed: Bool = false,
        elapsed: TimeInterval? = nil
    ) -> VerificationContext {
        VerificationContext(
            now: now,
            dayKey: dayKey,
            assignedAt: assignedAt,
            manualConfirmsToday: confirms,
            claimedKeys: [],
            timerElapsedSec: elapsed,
            userConfirmed: confirmed
        )
    }
}
