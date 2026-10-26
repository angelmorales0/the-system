import Combine
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
    @Published private(set) var dayClock: DayClock
    /// Algorithm levels for the status radar. 0 until a stat's data arrives.
    @Published private(set) var statLevels: StatLevelSet = .empty
    /// One saved reading per day for the stat history charts.
    @Published private(set) var statHistory = StatLevelHistory()
    /// The emergency quest on screen. While it is active, it covers every page.
    @Published private(set) var emergency: EmergencyQuest?
    @Published private(set) var emergencySettings: EmergencySettings = .standard

    private let catalog: FallbackCatalog
    private let generator: any QuestGenerating
    private let persistence: GamePersistence
    private var ticker: Timer?
    private var integrations: DayIntegrationSnapshot = .empty(dayKey: "")
    private var refreshingIntegrations = false
    private var emergencyTicker: Timer?
    private var evaluatingEmergency = false
    private var lastStretchRefresh = Date.distantPast

    init(persistence: GamePersistence = .standard) {
        #if DEBUG
        let problems = VerificationFixtures.check() + QuestGenerationRules.check() + IntegrationRules.check() + PenaltyRules.check() + RecoveryLevel.check()
            + StrengthLevel.check() + EnduranceLevel.check() + IntelligenceLevel.check()
            + AgilityLevel.check() + FocusLevel.check() + FinanceLevel.check() + StatLevelSet.check()
            + HiddenQuestRules.check()
            + EmergencyRules.check() + DailyStretch.check() + TrainingDay.check() + ModePicker.checkFixtures()
        precondition(problems.isEmpty, problems.joined(separator: "\n"))
        let ringProblems = DayClockRules.check()
        precondition(ringProblems.isEmpty, ringProblems.joined(separator: "\n"))
        #endif

        let catalog = FallbackCatalog.bundled()
        self.catalog = catalog
        self.generator = QuestGenerateClient.make(catalog: catalog)
        self.persistence = persistence
        dayClock = DayClock.resolve(
            current: persistence == .standard ? DayClock.load() : nil,
            now: .now,
            boot: DayClock.bootTime()
        )
        switch persistence {
        case .memory:
            snapshot = GameSnapshot.fresh(catalog: catalog)
        case .standard:
            snapshot = GameSnapshot.loadFromUserDefaults() ?? GameSnapshot.fresh(catalog: catalog)
            snapshot.refreshIfNeeded(catalog: catalog)
            // A day saved before the Stretching row, the exercise-only Training rule, or penalty rows gets them now.
            snapshot.bundle = snapshot.finished(TrainingDay.exerciseOnly(snapshot.bundle) ?? snapshot.bundle, catalog: catalog, now: .now)
        }
        if persistence == .standard {
            statHistory = StatLevelHistory.load()
            statLevels = statHistory.latest ?? .empty
            emergencySettings = EmergencyStore.loadSettings()
            emergency = EmergencyStore.loadQuest()
        }
        advanceTimers(now: .now)
        evaluateConnectedVerifiers(now: .now)
        requestGenerationIfNeeded(now: .now)
        persist()
        ensureTicker()
        observeHealthUpdates()
        refreshIntegrations(now: .now)
        enforcePenalty()
        if persistence == .standard {
            EmergencyEnforcement.syncMonitoring(emergencySettings)
            observeStepUpdates()
            evaluateEmergencies(now: .now)
        }
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
        // The bedtime watch counts use of the selected apps, so a new selection restarts it.
        if persistence == .standard {
            EmergencyEnforcement.syncMonitoring(emergencySettings)
        }
    }

    // MARK: - Emergency quests

    func updateEmergencySettings(_ settings: EmergencySettings) {
        let turnedOn = (settings.bedtimeEnabled && !emergencySettings.bedtimeEnabled)
            || (settings.stepsEnabled && !emergencySettings.stepsEnabled)
            || (settings.stretchEnabled && !emergencySettings.stretchEnabled)
        emergencySettings = settings
        guard persistence == .standard else { return }
        EmergencyStore.save(settings)
        EmergencyEnforcement.syncMonitoring(settings)
        if turnedOn {
            EmergencyEnforcement.requestNotificationPermission()
        }
        evaluateEmergencies(now: .now)
    }

    /// Runs one emergency now, with the saved targets. A test can be ended early and never opens a penalty.
    func startEmergencyTest(_ kind: EmergencyKind, now: Date = .now) {
        guard emergency == nil else { return }
        let quest: EmergencyQuest
        switch kind {
        case .bedtimeLockdown: quest = EmergencyRules.bedtimeQuest(triggeredAt: now, settings: emergencySettings, isTest: true)
        case .lowSteps: quest = EmergencyRules.lowStepsQuest(now: now, settings: emergencySettings, isTest: true)
        case .skippedStretch: quest = EmergencyRules.stretchQuest(now: now, settings: emergencySettings, isTest: true)
        }
        begin(quest)
    }

    func endEmergencyTest() {
        guard let quest = emergency, quest.isTest else { return }
        finish(quest, message: "Emergency test ended.")
    }

    private func begin(_ quest: EmergencyQuest) {
        emergency = quest
        if persistence == .standard {
            EmergencyStore.save(quest)
            EmergencyEnforcement.applyLockdown(for: quest)
            EmergencyEnforcement.notify(quest)
        }
        ensureEmergencyTicker()
    }

    private func finish(_ quest: EmergencyQuest, message: String) {
        emergency = nil
        verificationNote = message
        if persistence == .standard {
            EmergencyStore.save(nil)
            EmergencyEnforcement.clearLockdown()
        }
        ensureEmergencyTicker()
    }

    private func settle(_ resolved: EmergencyQuest) {
        switch resolved.status {
        case .active:
            emergency = resolved
            if persistence == .standard { EmergencyStore.save(resolved) }
        case .completed:
            let message: String
            switch resolved.kind {
            case .bedtimeLockdown: message = "Emergency quest complete: the lockdown has ended."
            case .lowSteps: message = "Emergency quest complete: \(resolved.progressSteps.formatted()) steps walked."
            case .skippedStretch: message = "Emergency quest complete: \(Int(DailyStretch.minutes)) minutes stretched."
            }
            finish(resolved, message: message)
        case .failed:
            if EmergencyRules.opensPenalty(resolved) {
                snapshot.emergencyFailedDayKey = resolved.dayKey
                persist()
            }
            finish(resolved, message: resolved.isTest
                   ? "Emergency test failed. A test does not open a penalty."
                   : "Emergency quest failed. A penalty opens tomorrow.")
        }
    }

    /// Before a new day is judged, a walk whose deadline passed is settled on the steps it already has.
    private func settleExpiredEmergency(now: Date) {
        guard let quest = emergency, now >= quest.deadline else { return }
        settle(EmergencyRules.resolve(quest, now: now, stepsSinceStart: nil))
    }

    /// Reads the bedtime trigger and Health steps, then starts, advances, or ends an emergency.
    private func evaluateEmergencies(now: Date) {
        guard persistence == .standard, !evaluatingEmergency else { return }
        evaluatingEmergency = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.evaluatingEmergency = false }
            let settings = self.emergencySettings

            if let triggered = EmergencyStore.takeBedtimeTrigger(), self.emergency == nil {
                let quest = EmergencyRules.bedtimeQuest(triggeredAt: triggered, settings: settings)
                if quest.deadline > now {
                    // The monitor already locked the apps and posted the alert.
                    self.emergency = quest
                    EmergencyStore.save(quest)
                }
            }

            if let quest = self.emergency {
                var steps: Int?
                if quest.kind == .lowSteps {
                    steps = await HealthKitBridge.steps(from: quest.startedAt, to: min(now, quest.deadline))
                }
                // The quest may have ended while the steps loaded.
                guard self.emergency?.id == quest.id else { return }
                if quest.kind == .skippedStretch, now.timeIntervalSince(self.lastStretchRefresh) >= 60 {
                    // Hevy and Health stretch minutes arrive with the integration reload.
                    self.lastStretchRefresh = now
                    self.refreshIntegrations(now: now)
                }
                let stretchDone = quest.kind == .skippedStretch && DailyStretch.isDone(in: self.snapshot.bundle) == true
                let resolved = EmergencyRules.resolve(quest, now: now, stepsSinceStart: steps, stretchDone: stretchDone)
                self.settle(resolved)
                if resolved.status == .active, resolved.kind != .bedtimeLockdown,
                   EmergencyGroup.defaults.string(forKey: EmergencyGroup.lockdownKindKey) == nil {
                    // A bedtime release may have cleared the shared store. Put the distractor shields back.
                    EmergencyEnforcement.applyLockdown(for: resolved)
                }
                self.ensureEmergencyTicker()
                return
            }

            if EmergencyRules.shouldTriggerStretch(now: now, stretchDone: DailyStretch.isDone(in: self.snapshot.bundle),
                                                   settings: settings, lastTriggeredDayKey: EmergencyStore.stretchDayKey, active: nil) {
                EmergencyStore.stretchDayKey = QuestDay.key(for: now)
                self.begin(EmergencyRules.stretchQuest(now: now, settings: settings))
                return
            }

            guard settings.stepsEnabled else { return }
            let startOfDay = QuestDay.calendar.startOfDay(for: now)
            let stepsToday = await HealthKitBridge.steps(from: startOfDay, to: now)
            guard self.emergency == nil else { return }
            if EmergencyRules.shouldTriggerLowSteps(now: now, stepsToday: stepsToday, settings: settings,
                                                    lastTriggeredDayKey: EmergencyStore.lowStepsDayKey, active: nil) {
                EmergencyStore.lowStepsDayKey = QuestDay.key(for: now)
                self.begin(EmergencyRules.lowStepsQuest(now: now, settings: settings))
            }
        }
    }

    private func observeStepUpdates() {
        Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .stepsDidChange) {
                self?.evaluateEmergencies(now: .now)
            }
        }
    }

    /// While an emergency runs, re-check every 15 seconds: steps for a walk, the clock for a lockdown.
    private func ensureEmergencyTicker() {
        guard emergency != nil else {
            emergencyTicker?.invalidate()
            emergencyTicker = nil
            return
        }
        guard emergencyTicker == nil else { return }
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.evaluateEmergencies(now: .now)
            }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        emergencyTicker = timer
    }

    var player: PlayerState { snapshot.player }
    /// A hidden quest unlocked and not yet acknowledged. The quest screen shows its reveal window.
    var pendingHiddenReveal: HiddenQuestUnlock? { snapshot.pendingHiddenReveal }

    func acknowledgeHiddenReveal() {
        guard let reveal = snapshot.pendingHiddenReveal else { return }
        var next = snapshot
        next.markHiddenRevealSeen(id: reveal.id)
        snapshot = next
        persist()
    }
    var bundle: QuestBundle { snapshot.bundle }
    var goalQuests: [Quest] { bundle.goalQuests }

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
        settleExpiredEmergency(now: now)
        let previousDay = snapshot.bundle.dayKey
        var next = snapshot
        next.refreshIfNeeded(catalog: catalog, now: now)
        snapshot = next
        if snapshot.bundle.dayKey != previousDay {
            verificationNote = nil
        }
        dayClock = DayClock.resolve(current: dayClock, now: now, boot: DayClock.bootTime())
        advanceTimers(now: now)
        evaluateConnectedVerifiers(now: now)
        requestGenerationIfNeeded(now: now)
        persist()
        ensureTicker()
        refreshIntegrations(now: now)
        enforcePenalty()
        evaluateEmergencies(now: now)
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
                mercury: remote.mercury,
                hevy: remote.hevy
            )
            self.statLevels = StatLevelSet.compute(codeforces: remote.codeforces, financeMonths: remote.financeMonths, now: now)
            self.statHistory.record(self.statLevels, on: dayKey)
            if rebuilt {
                self.runningTimersRemoveMissing()
            }
            self.evaluateConnectedVerifiers(now: now)
            self.persist()
            self.enforcePenalty()
        }
    }

    private func enforcePenalty() {
        let open = PenaltyQuests.rows(in: snapshot.bundle).first(where: { $0.status != .completed })
        let visible = snapshot.player.penaltyTier > 0 && open != nil
        let title = open?.title ?? snapshot.bundle.headerLine
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
        guard let accepted = QuestSafety.accepting(bundle, context: context, assignedAt: now),
              let prepared = TrainingDay.exerciseOnly(accepted) else { return }
        var next = snapshot
        next.generatedBundle = prepared
        next.bundle = next.finished(prepared, catalog: catalog, now: now)
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
        if completed, next.runningTimers.isEmpty {
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
        next.checkHiddenQuests(integrations: integrations, now: now)
        snapshot = next
    }

    private func commit(_ result: VerificationResult, questId: String, now: Date) {
        let title = snapshot.bundle.quests.first(where: { $0.id == questId })?.title ?? "Quest"
        var next = snapshot
        let outcome = next.apply(result, questId: questId, now: now)
        next.checkHiddenQuests(integrations: integrations, now: now)
        snapshot = next
        clock = now
        note(for: outcome, title: title)
        persist()
        enforcePenalty()
    }

    private func note(for outcome: VerificationApply, title: String) {
        switch outcome {
        case .completed:
            verificationNote = nil
        case .rejected(let reason):
            verificationNote = "\(title): \(reason)"
        case .ignored, .updated:
            break
        }
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
            // The timer is on the main run loop, so it always fires on the main actor.
            MainActor.assumeIsolated {
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
        dayClock.save()
        statHistory.save()
    }

    private static func clockString(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
