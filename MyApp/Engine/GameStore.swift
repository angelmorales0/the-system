import SwiftUI

enum GamePersistence {
    /// Saved on this device. Checkbox completion and XP survive relaunch.
    case standard
    /// Previews and checks. Does not touch UserDefaults.
    case memory
}

@MainActor
final class GameStore: ObservableObject {
    @Published private(set) var snapshot: GameSnapshot
    @Published private(set) var verificationNote: String?
    @Published private(set) var clock = Date()

    private let catalog: FallbackCatalog
    private let generator: any QuestGenerating
    private let persistence: GamePersistence
    private var ticker: Timer?
    private var integrations: DayIntegrationSnapshot = .empty(dayKey: "")
    private var refreshingIntegrations = false

    init(persistence: GamePersistence = .standard) {
        #if DEBUG
        let problems = VerificationFixtures.check() + TargetRules.check() + QuestGenerationRules.check() + IntegrationRules.check() + PenaltyRules.check()
        precondition(problems.isEmpty, problems.joined(separator: "\n"))
        #endif

        let catalog = FallbackCatalog.bundled()
        self.catalog = catalog
        self.generator = QuestGenerateClient.make(catalog: catalog)
        self.persistence = persistence
        switch persistence {
        case .memory:
            snapshot = GameSnapshot.fresh(catalog: catalog)
        case .standard:
            snapshot = GameSnapshot.loadFromUserDefaults() ?? GameSnapshot.fresh(catalog: catalog)
            snapshot.refreshIfNeeded(catalog: catalog)
        }
        advanceTimers(now: .now)
        evaluateConnectedVerifiers(now: .now)
        requestGenerationIfNeeded(now: .now)
        persist()
        ensureTicker()
        observeHealthUpdates()
        refreshIntegrations(now: .now)
        enforcePenalty()
    }

    func spendFullRecovery(now: Date = .now) {
        var next = snapshot
        let message = next.spendFullRecovery(catalog: catalog, now: now)
        snapshot = next
        verificationNote = message
        clock = now
        persist()
        enforcePenalty()
    }

    func saveDistractorSelection() {
        snapshot.hasDistractorSelection = PenaltySelectionStore.hasSelection
        persist()
        enforcePenalty()
    }

    var player: PlayerState { snapshot.player }
    var bundle: QuestBundle { snapshot.bundle }
    var goalQuests: [Quest] { bundle.goalQuests }
    var targets: [Target] { snapshot.targets }

    var targetBanner: String? {
        let dayKey = bundle.dayKey.isEmpty ? QuestDay.key(for: clock) : bundle.dayKey
        return snapshot.targetBanner(on: dayKey)
    }

    func saveTarget(_ target: Target, now: Date = .now) -> String? {
        var next = snapshot
        let message = next.upsertTarget(target, catalog: catalog, now: now)
        snapshot = next
        clock = now
        runningTimersRemoveMissing()
        publishTargetToast()
        persist()
        ensureTicker()
        return message
    }

    func activateTarget(id: String, now: Date = .now) -> String? {
        var next = snapshot
        let message = next.activateTarget(id: id, catalog: catalog, now: now)
        snapshot = next
        clock = now
        runningTimersRemoveMissing()
        publishTargetToast()
        persist()
        ensureTicker()
        return message
    }

    func abortTarget(id: String, now: Date = .now) {
        var next = snapshot
        next.abortTarget(id: id, catalog: catalog, now: now)
        snapshot = next
        clock = now
        runningTimersRemoveMissing()
        persist()
        ensureTicker()
    }

    func startInterviewPrep(now: Date = .now) -> String? {
        var target = Target.interviewPrep(starting: QuestDay.key(for: now))
        target.status = .active
        return saveTarget(target, now: now)
    }

    func rowLabel(for quest: Quest) -> String {
        guard quest.status != .completed,
              let started = snapshot.runningTimers.first(where: { $0.questId == quest.id })?.startedAt else {
            return quest.progress.bracketLabel
        }
        let elapsed = max(0, clock.timeIntervalSince(started))
        let required = TimerSessionVerifier.requiredSeconds(quest)
        return "[\(Self.clockString(elapsed))/\(Self.clockString(required))]"
    }

    func accessibilityValue(for quest: Quest) -> String {
        if quest.status == .completed { return "Completed" }
        if snapshot.runningTimers.contains(where: { $0.questId == quest.id }) { return "Timer running" }
        switch quest.verification.method {
        case .timerSession:
            return "Timer not started"
        case .manualConfirm:
            return "Not confirmed"
        default:
            return "Not completed"
        }
    }

    func handleQuestTap(id: String, now: Date = .now) {
        guard let quest = snapshot.bundle.quests.first(where: { $0.id == id }) else { return }
        if quest.status == .completed {
            var next = snapshot
            next.undoQuest(id: id)
            snapshot = next
            verificationNote = nil
            clock = now
            persist()
            ensureTicker()
            enforcePenalty()
            return
        }

        switch quest.verification.method {
        case .timerSession:
            beginTimer(questId: id, title: quest.title, now: now)
        case .manualConfirm:
            let context = snapshot.verificationContext(for: quest, now: now, timerElapsed: nil, userConfirmed: true)
            let result = ManualConfirmVerifier().evaluate(quest: quest, context: context)
            commit(result, questId: id, now: now)
        default:
            if quest.verification.method.allowsLocalCheckbox {
                var next = snapshot
                let outcome = next.applyLocalOverride(questId: id, now: now)
                snapshot = next
                clock = now
                note(for: outcome, title: quest.title)
                persist()
                enforcePenalty()
            } else {
                let context = snapshot.verificationContext(
                    for: quest,
                    now: now,
                    timerElapsed: nil,
                    userConfirmed: false,
                    integrations: integrations
                )
                let result = VerifierRegistry.verifier(for: quest.verification.method).evaluate(quest: quest, context: context)
                switch result {
                case .incomplete(let reason):
                    verificationNote = reason
                    clock = now
                case .unchanged:
                    verificationNote = "No matching sample yet."
                    clock = now
                case .failed, .progress, .completed:
                    commit(result, questId: id, now: now)
                }
            }
        }
    }

    func refreshForToday(now: Date = .now) {
        let previousDay = snapshot.bundle.dayKey
        var next = snapshot
        next.refreshIfNeeded(catalog: catalog, now: now)
        snapshot = next
        if snapshot.bundle.dayKey != previousDay {
            verificationNote = nil
        }
        advanceTimers(now: now)
        evaluateConnectedVerifiers(now: now)
        requestGenerationIfNeeded(now: now)
        persist()
        ensureTicker()
        refreshIntegrations(now: now)
        enforcePenalty()
    }

    private func observeHealthUpdates() {
        HealthKitBridge.startObservers()
        Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .healthDataDidChange) {
                self?.refreshIntegrations(now: .now)
            }
        }
    }

    private func refreshIntegrations(now: Date) {
        guard !refreshingIntegrations else { return }
        refreshingIntegrations = true
        let dayKey = QuestDay.key(for: now)
        Task { @MainActor [weak self] in
            let health = await HealthKitBridge.summary(on: now)
            let remote = await IntegrationClient.load(dayKey: dayKey)
            guard let self else { return }
            self.refreshingIntegrations = false
            var next = self.snapshot
            let rebuilt = next.applyWhoopReadiness(remote.whoop, catalog: self.catalog, now: now)
            next.applyFinance(remote.mercury)
            self.snapshot = next
            self.integrations = DayIntegrationSnapshot.make(
                whoop: remote.whoop,
                strava: remote.strava,
                health: health,
                mercury: remote.mercury
            )
            if rebuilt {
                self.runningTimersRemoveMissing()
            }
            self.evaluateConnectedVerifiers(now: now)
            self.persist()
            self.enforcePenalty()
        }
    }

    private func enforcePenalty() {
        let visible = snapshot.player.penaltyTier > 0 && snapshot.bundle.mode == .penalty
        let title = snapshot.bundle.quests.first(where: { $0.status != .completed })?.title ?? snapshot.bundle.headerLine
        PenaltyEnforcement.sync(
            penaltyVisible: visible,
            tier: snapshot.player.penaltyTier,
            questTitle: title,
            dayKey: snapshot.bundle.dayKey
        )
    }

    /// One attempt per local day. The catalog bundle stays on screen until a valid bundle returns.
    private func requestGenerationIfNeeded(now: Date) {
        let dayKey = QuestDay.key(for: now)
        guard snapshot.bundle.dayKey == dayKey else { return }
        guard snapshot.generationAttemptDayKey != dayKey else { return }
        var next = snapshot
        next.generationAttemptDayKey = dayKey
        snapshot = next
        let finished = snapshot.bundle.quests.contains { $0.status == .completed } || !snapshot.runningTimers.isEmpty
        let alreadyGenerated = ["mock", "llm", "template"].contains(snapshot.bundle.generatedBy)
        if finished || alreadyGenerated {
            if alreadyGenerated, snapshot.generatedBundle == nil {
                snapshot.generatedBundle = snapshot.bundle.strippingModelCompletion(assignedAt: now)
            }
            persist()
            return
        }
        persist()
        let context = ContextBuilder.make(snapshot: snapshot, now: now)
        Task { [weak self] in
            await self?.runGeneration(context: context, dayKey: dayKey)
        }
    }

    private func runGeneration(context: MorningContext, dayKey: String) async {
        let bundle = await generator.generate(context: context)
        guard bundle.generatedBy != "fallback" else { return }
        let now = Date()
        guard snapshot.bundle.dayKey == dayKey, snapshot.generationAttemptDayKey == dayKey else { return }
        guard !snapshot.bundle.quests.contains(where: { $0.status == .completed }) else { return }
        guard snapshot.runningTimers.isEmpty else { return }
        let decision = ModePicker.decide(snapshot.modeInput(now: now))
        guard decision.selectedMode == context.modeDecision.selectedMode else { return }
        guard let prepared = QuestSafety.accepting(bundle, context: context, assignedAt: now) else { return }
        var next = snapshot
        next.generatedBundle = prepared
        var installed = prepared
        if let target = next.activeTarget(on: now) {
            installed = installed.injecting(target, now: now)
        }
        next.bundle = installed
        snapshot = next
        runningTimersRemoveMissing()
        persist()
    }

    private func beginTimer(questId: String, title: String, now: Date) {
        if snapshot.runningTimers.contains(where: { $0.questId == questId }) { return }
        var next = snapshot
        next.runningTimers.removeAll()
        next.runningTimers.append(TimerRun(questId: questId, startedAt: now))
        snapshot = next
        clock = now
        let required = snapshot.bundle.quests.first(where: { $0.id == questId }).map { TimerSessionVerifier.requiredSeconds($0) } ?? 0
        verificationNote = "\(title) \(Self.clockString(0)) / \(Self.clockString(required))"
        persist()
        ensureTicker()
    }

    private func advanceTimers(now: Date) {
        clock = now
        guard !snapshot.runningTimers.isEmpty else { return }
        var next = snapshot
        var runningNote: String?
        var completed = false
        for run in snapshot.runningTimers {
            guard let quest = next.bundle.quests.first(where: { $0.id == run.questId }), quest.status != .completed else {
                next.runningTimers.removeAll { $0.questId == run.questId }
                continue
            }
            let elapsed = max(0, now.timeIntervalSince(run.startedAt))
            let context = next.verificationContext(for: quest, now: now, timerElapsed: elapsed, userConfirmed: false)
            let result = TimerSessionVerifier().evaluate(quest: quest, context: context)
            let outcome = next.apply(result, questId: quest.id, now: now)
            switch outcome {
            case .completed:
                completed = true
                next.runningTimers.removeAll { $0.questId == quest.id }
            case .rejected(let reason):
                runningNote = "\(quest.title): \(reason)"
                next.runningTimers.removeAll { $0.questId == quest.id }
            case .updated, .ignored:
                let required = TimerSessionVerifier.requiredSeconds(quest)
                runningNote = "\(quest.title) \(Self.clockString(elapsed)) / \(Self.clockString(required))"
            }
        }
        snapshot = next
        if let toast = next.targetToast {
            verificationNote = toast
            snapshot.targetToast = nil
        } else if completed, next.runningTimers.isEmpty {
            verificationNote = nil
        } else if let runningNote {
            verificationNote = runningNote
        }
        if next.runningTimers.isEmpty {
            ticker?.invalidate()
            ticker = nil
        }
        if completed {
            enforcePenalty()
        }
    }

    /// Foreground pass for adapters that can see evidence without a tap. Stubs return incomplete and change nothing.
    private func evaluateConnectedVerifiers(now: Date) {
        var next = snapshot
        for quest in snapshot.bundle.quests where quest.status != .completed {
            switch quest.verification.method {
            case .manualConfirm, .timerSession:
                continue
            default:
                break
            }
            let context = next.verificationContext(
                for: quest,
                now: now,
                timerElapsed: nil,
                userConfirmed: false,
                integrations: integrations
            )
            let result = VerifierRegistry.verifier(for: quest.verification.method).evaluate(quest: quest, context: context)
            switch result {
            case .progress, .completed:
                _ = next.apply(result, questId: quest.id, now: now)
            case .unchanged, .incomplete, .failed:
                break
            }
        }
        snapshot = next
    }

    private func commit(_ result: VerificationResult, questId: String, now: Date) {
        let title = snapshot.bundle.quests.first(where: { $0.id == questId })?.title ?? "Quest"
        var next = snapshot
        let outcome = next.apply(result, questId: questId, now: now)
        snapshot = next
        clock = now
        note(for: outcome, title: title)
        persist()
        enforcePenalty()
    }

    private func note(for outcome: VerificationApply, title: String) {
        switch outcome {
        case .completed:
            publishTargetToast()
        case .rejected(let reason):
            verificationNote = "\(title): \(reason)"
        case .ignored, .updated:
            break
        }
    }

    private func publishTargetToast() {
        guard let toast = snapshot.targetToast else {
            verificationNote = nil
            return
        }
        verificationNote = toast
        snapshot.targetToast = nil
    }

    private func runningTimersRemoveMissing() {
        let ids = Set(snapshot.bundle.quests.map(\.id))
        snapshot.runningTimers.removeAll { !ids.contains($0.questId) }
    }

    private func ensureTicker() {
        guard !snapshot.runningTimers.isEmpty else {
            ticker?.invalidate()
            ticker = nil
            return
        }
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.advanceTimers(now: .now)
                self?.persist()
            }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func persist() {
        guard persistence == .standard else { return }
        snapshot.saveToUserDefaults()
    }

    private static func clockString(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
