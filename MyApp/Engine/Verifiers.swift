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
    var integrations: DayIntegrationSnapshot = .empty(dayKey: "")
    /// Workout recording ids already claimed today by a different quest (`Evidence.workoutIds`).
    var claimedWorkoutIds: Set<String> = []
    /// The workouts already claimed today by a different quest, for the match by time (`Evidence.isSession`).
    var claimedSessions: [Evidence] = []
    /// The exercises of the day's other Hevy rows, as `StrengthLevel.normalizedName` gives them.
    /// A stand-in lift that has its own row counts for that row, not for the lift it can stand in for.
    var otherExercises: Set<String> = []
    /// The exercises of the Hevy rows above this one today, in the same form. A muscle-group stand-in counts for the
    /// first row of its group only, so one set never fills two rows.
    var earlierExercises: Set<String> = []

    /// True when another quest already used this workout: one of its recordings, or a session at the same time.
    func claims(_ workout: CanonicalWorkout) -> Bool {
        claimedWorkoutIds.contains(workout.id)
    }
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
            return WhoopStrainVerifier()
        case .stravaActivity:
            return StravaActivityVerifier()
        case .hevySets:
            return HevySetsVerifier()
        case .healthkitWorkout:
            return HealthKitWorkoutVerifier()
        case .homeBy:
            return IncompleteVerifier(method: method, reason: "Home by updates from your phone's location. It completes when the phone is home at its time.")
        case .screenTimeLimit:
            // The row moves from Screen Time threshold events (phone) and the backend (work), not from a verifier.
            // It completes when the day ends under the cap, and fails as soon as the total goes over.
            return IncompleteVerifier(method: method, reason: "Screen Time updates from your phone and Mac readings. It completes when the day ends under 8 h 20 m.")
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
    /// No quest is checked off by hand. Connected sources, including Mercury and Screen Time, decide.
    var allowsLocalCheckbox: Bool {
        false
    }
}

extension Quest {
    /// The one hand check on a whole row: the day's 5K or 10K run, so a long bike ride can count in its place.
    /// Strava and Apple Health still complete it on their own. A penalty run never takes a hand check.
    /// The 10K that "No gym today" adds stands for the lifts, so it takes none either: with it, two hand checks
    /// would clear a whole training day with no workout done.
    /// A row the player may check by hand: only rows no service checks. Runs (Strava, Apple Health) and lifts (Hevy)
    /// fill themselves from the data.
    var allowsCheckOff: Bool {
        verification.method.allowsLocalCheckbox
    }

    /// Rows the app judges in the background: they are not in the quest list. Their results fill the Systems page.
    var isBackgroundRow: Bool { id == ScreenTime.questId || id == HomeBy.questId }

    /// A lift row that Hevy shows done today but the app could not count (for example, a measure Hevy logs another way).
    /// The player may check it off. `workouts` is today's Hevy log.
    func hevyShowsDone(_ workouts: [HevyWorkout]) -> Bool {
        guard verification.method == .hevySets, kind != .penalty, verification.params["stretchMinutes"] == nil, status == .pending else { return false }
        let templateId = verification.params["templateId"]?.stringValue
        let name = StrengthLevel.normalizedName(verification.params["exercise"]?.stringValue ?? title)
        return workouts.contains { workout in
            workout.exercises.contains { entry in
                (templateId.map { entry.templateId == $0 } ?? (StrengthLevel.normalizedName(entry.title) == name))
                    && entry.sets.contains(where: \.isWorking)
            }
        }
    }

    /// The 10K that "No gym today" added (`NoGymDay.addedId`).
    var isNoGymRun: Bool { id.hasSuffix("_" + NoGymDay.addedSlug) }
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
        let stripped = bundle.strippingModelCompletion(assignedAt: assigned.addingTimeInterval(5))
        let cleaned = stripped.quests[0]
        if cleaned.status != .pending || !cleaned.evidence.isEmpty || cleaned.progress.current != 0 {
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
        let replay = state.apply(.completed(evidence: shared), questId: state.bundle.quests[0].id, now: assigned)
        let second = state.apply(.completed(evidence: shared), questId: state.bundle.quests[1].id, now: assigned)
        if first != .completed || replay != .ignored {
            errors.append("same evidence should complete a quest once")
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

        // An old save can hold a removed method. It loads as a manual confirm.
        let removed = Data(#"{"method":"macrofactor_protein","params":{"minProteinG":150}}"#.utf8)
        if (try? JSONDecoder().decode(VerificationSpec.self, from: removed))?.method != .manualConfirm {
            errors.append("a removed verification method should load as a manual confirm")
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
            difficulty: .easy,
            mode: .performanceTraining,
            progress: QuestProgress(current: 0, target: 10, unit: "min"),
            status: .pending,
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
