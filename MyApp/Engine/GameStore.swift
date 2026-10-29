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
    /// Targets the player removed from each stat's score.
    @Published private(set) var statTargets = StatTargets()
    /// The emergency quest on screen. While it is active, it covers every page.
    @Published private(set) var emergency: EmergencyQuest?
    @Published private(set) var emergencySettings: EmergencySettings = .standard

    /// Carries the player's own STR goals (`statTargets.custom`), so the offline split day trains them.
    private var catalog: FallbackCatalog
    private let generator: any QuestGenerating
    private let persistence: GamePersistence
    private var ticker: Timer?
    private var integrations: DayIntegrationSnapshot = .empty(dayKey: "")
    private var refreshingIntegrations = false
    private var emergencyTicker: Timer?
    private var evaluatingEmergency = false
    private var lastStretchRefresh = Date.distantPast
    /// The last live stat inputs, so a target change can recalculate without a new fetch. Nil until the first refresh.
    private var statInputs: (codeforces: CodeforcesReading, financeMonths: [FinanceMonth], bodyMass: BodyMassReading?, focusDays: [FocusDay])?

    init(persistence: GamePersistence = .standard) {
        #if DEBUG
        let problems = VerificationFixtures.check() + QuestGenerationRules.check() + IntegrationRules.check() + PenaltyRules.check() + RecoveryLevel.check()
            + StrengthLevel.check() + EnduranceLevel.check() + IntelligenceLevel.check()
            + AgilityLevel.check() + FocusLevel.check() + FinanceLevel.check() + StatLevelSet.check() + StatTargets.check() + FocusTracking.check() + MacScreenClient.check()
            + HiddenQuestRules.check() + RecoveryHolidayRules.check() + ShopRules.check()
            + EmergencyRules.check() + DailyStretch.check() + TrainingDay.check() + ModePicker.checkFixtures() + GymSplit.check() + ScreenTimeRules.check()
            + NoGymDayRules.check() + PenaltyDecay.check() + SecretStore.check() + ConnectionStatusStore.check()
            + HevyClient.check() + OAuthClient.check() + StravaClient.check() + WhoopClient.check() + CodeforcesClient.check() + MercuryClient.check()
            + TrainingHistory.check() + QuestPlanner.check() + HitPoints.check()
        precondition(problems.isEmpty, problems.joined(separator: "\n"))
        let ringProblems = DayClockRules.check()
        precondition(ringProblems.isEmpty, ringProblems.joined(separator: "\n"))
        #endif

        // The targets load first: today's split day needs the player's own goals.
        let targets = persistence == .standard ? StatTargets.load() : StatTargets()
        var catalog = FallbackCatalog.bundled()
        catalog.strengthGoals = targets.custom
        self.catalog = catalog
        self.generator = QuestGenerateClient.make(catalog: catalog)
        self.persistence = persistence
        dayClock = DayClock.resolve(
            current: persistence == .standard ? DayClock.load() : nil,
            now: .now
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
            statTargets = targets
            statLevels = statHistory.latest ?? .empty
            emergencySettings = EmergencyStore.loadSettings()
            emergency = EmergencyStore.loadQuest()
        }
        advanceTimers(now: .now)
        evaluateConnectedVerifiers(now: .now)
        persist()
        ensureTicker()
        observeHealthUpdates()
        refreshIntegrations(now: .now)
        enforcePenalty()
        if persistence == .standard {
            EmergencyEnforcement.removeBedtime()
            ScreenTimeEnforcement.syncMonitoring()
            #if os(iOS)
            FocusTracking.syncMonitoring()
            #endif
            observeStepUpdates()
            evaluateEmergencies(now: .now)
        }
    }

    /// After the phone screen time picker saves, restart the daily count with the new apps.
    func savePhoneScreenSelection() {
        if persistence == .standard {
            ScreenTimeEnforcement.syncMonitoring()
        }
        refreshIntegrations(now: .now)
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

    func buy(_ item: ShopItem, now: Date = .now) {
        var next = snapshot
        let message = next.buy(item)
        snapshot = next
        verificationNote = message
        clock = now
        persist()
    }

    func drinkPotion(_ potion: Potion, questId: String, now: Date = .now) {
        var next = snapshot
        let message = next.drinkPotion(potion, questId: questId)
        snapshot = next
        verificationNote = message
        clock = now
        persist()
        enforcePenalty()
    }

    func setNoGym(_ on: Bool, now: Date = .now) {
        var next = snapshot
        let message = next.setNoGym(on, catalog: catalog, now: now)
        snapshot = next
        verificationNote = message
        clock = now
        persist()
        enforcePenalty()
    }

    /// After the owner saves or removes a key in Status → Connections: read the services again.
    func connectionsChanged() {
        allowGenerationAfterNewKey(now: .now)
        refreshIntegrations(now: .now)
    }

    /// A Claude key saved after this morning's offline plan: plan today again, if nothing is done yet.
    private func allowGenerationAfterNewKey(now: Date) {
        let dayKey = QuestDay.key(for: now)
        guard OnDeviceQuestGenerateClient.hasKey, snapshot.bundle.dayKey == dayKey,
              snapshot.generationAttemptDayKey == dayKey,
              ["mock", "fallback"].contains(snapshot.bundle.generatedBy),
              !snapshot.bundle.quests.contains(where: { $0.status == .completed }),
              snapshot.runningTimers.isEmpty else { return }
        var next = snapshot
        next.generationAttemptDayKey = nil
        next.generatedBundle = nil
        snapshot = next
        persist()
    }

    func saveDistractorSelection() {
        snapshot.hasDistractorSelection = PenaltySelectionStore.hasSelection
        persist()
        enforcePenalty()
    }

    // MARK: - Emergency quests

    /// Adds a removed target back to a stat, or removes an active one, then recalculates the stat level.
    func toggleStatTarget(_ category: String, in stat: Stat) {
        statTargets.toggle(category, in: stat)
        if persistence == .standard { statTargets.save() }
        recomputeStatLevels(now: .now)
        persist()
    }

    /// Adds the player's own STR goal. Returns why it was refused, or nil when it was saved.
    /// The STR level is calculated again at once. The split day trains it from the next plan on;
    /// today's quests stay as they are, so no logged set is lost.
    func addStrengthGoal(_ goal: CustomStrengthGoal) -> String? {
        var next = statTargets
        if let problem = next.add(goal) { return problem }
        saveStatTargets(next)
        return nil
    }

    /// Deletes one of the player's own STR goals, then calculates the STR level again.
    func deleteStrengthGoal(_ category: String) {
        var next = statTargets
        next.deleteCustom(category)
        saveStatTargets(next)
    }

    private func saveStatTargets(_ targets: StatTargets) {
        statTargets = targets
        catalog.strengthGoals = targets.custom
        if persistence == .standard { statTargets.save() }
        recomputeStatLevels(now: .now)
        persist()
    }

    /// Before the first refresh there are no live inputs; the next refresh applies the new targets.
    private func recomputeStatLevels(now: Date) {
        guard let statInputs else { return }
        statLevels = StatLevelSet.compute(
            codeforces: statInputs.codeforces,
            financeMonths: statInputs.financeMonths,
            bodyMass: statInputs.bodyMass.map { [$0] } ?? [],
            focusDays: statInputs.focusDays,
            targets: statTargets,
            now: now
        )
        statHistory.record(statLevels, on: QuestDay.key(for: now))
    }

    func updateEmergencySettings(_ settings: EmergencySettings) {
        let turnedOn = (settings.stepsEnabled && !emergencySettings.stepsEnabled)
            || (settings.stretchEnabled && !emergencySettings.stretchEnabled)
        emergencySettings = settings
        guard persistence == .standard else { return }
        EmergencyStore.save(settings)
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

    /// Reads Health steps and the Stretching quest, then starts, advances, or ends an emergency.
    private func evaluateEmergencies(now: Date) {
        guard persistence == .standard, !evaluatingEmergency else { return }
        evaluatingEmergency = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.evaluatingEmergency = false }
            let settings = self.emergencySettings

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
                if resolved.status == .active,
                   EmergencyGroup.defaults.string(forKey: EmergencyGroup.lockdownKindKey) == nil {
                    // Something cleared the shared store. Put the distractor shields back.
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
            let startOfDay = QuestDay.interval(for: now).start
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

    /// While an emergency runs, re-check every 15 seconds: steps for a walk, stretch minutes for a stretch.
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

    /// HP for the HP window. Before the first refresh: full, at the player's max.
    var hitPoints: (current: Int, max: Int) {
        let maxHP = snapshot.hitPoints?.max ?? HitPoints.maxHP(for: snapshot.player)
        var current = snapshot.hitPoints.map { Int($0.current.rounded(.down)) } ?? maxHP
        #if DEBUG
        // Launch with `-hpDebugPercent 15` to see the window at that share of max HP. Nothing is saved.
        if let percent = UserDefaults.standard.string(forKey: "hpDebugPercent").flatMap(Double.init) {
            current = Int((Double(maxHP) * min(max(percent, 0), 100) / 100).rounded(.down))
        }
        #endif
        return (current, maxHP)
    }
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
        if quest.skippedWithPotion { return "Skipped with a potion" }
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
        // A completed quest stays completed. There is no undo.
        guard quest.status != .completed else { return }

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
        dayClock = DayClock.resolve(current: dayClock, now: now)
        advanceTimers(now: now)
        evaluateConnectedVerifiers(now: now)
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

    /// Phone minutes that surely overlap Mac minutes today. Nil without the Macs' minute bitmap or the day's start.
    private static func screenOverlap(dayKey: String, macScreen: WorkScreenReading?) -> Int? {
        guard let active = macScreen?.activeMinutes(for: dayKey), let start = QuestDay.start(of: dayKey) else { return nil }
        return ScreenOverlap.minutes(phoneTimes: PhoneScreenGroup.times(for: dayKey), macActive: active, dayStart: start)
    }

    private func refreshIntegrations(now: Date) {
        guard !refreshingIntegrations else { return }
        refreshingIntegrations = true
        let dayKey = QuestDay.key(for: now)
        Task { @MainActor [weak self] in
            let health = await HealthKitBridge.summary(on: now)
            let bodyMass = await HealthKitBridge.latestBodyMass(days: EnduranceLevel.bodyWeightWindowDays, now: now)
            let remote = await IntegrationClient.load(dayKey: dayKey)
            let focusDays = FocusTracking.loadDays()
            let macScreen = await MacScreenClient.load(dayKey: dayKey)
            guard let self else { return }
            self.refreshingIntegrations = false
            var next = self.snapshot
            let rebuilt = next.applyWhoopReadiness(remote.whoop, catalog: self.catalog, now: now)
            next.applyScreenTime(
                phoneMinutes: PhoneScreenGroup.minutes(for: next.bundle.dayKey),
                workMinutes: macScreen?.minutes(for: next.bundle.dayKey),
                overlapMinutes: Self.screenOverlap(dayKey: next.bundle.dayKey, macScreen: macScreen)
            )
            next.applyFinance(remote.mercury)
            let day = DayIntegrationSnapshot.make(
                whoop: remote.whoop,
                strava: remote.strava,
                health: health,
                mercury: remote.mercury,
                hevy: remote.hevy
            )
            // After today's readiness, so a red recovery hits HP and sets the regeneration speed.
            next.applyHitPoints(integrations: day, now: now)
            self.snapshot = next
            self.integrations = day
            self.statInputs = (remote.codeforces, remote.financeMonths, bodyMass, focusDays)
            self.recomputeStatLevels(now: now)
            if rebuilt {
                self.runningTimersRemoveMissing()
            }
            self.evaluateConnectedVerifiers(now: now)
            // After today's readiness, sleep, and weight are in, so the generator plans from today's data.
            self.requestGenerationIfNeeded(now: now)
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
            shieldLine: open.map(Self.shieldLine) ?? title,
            dayKey: snapshot.bundle.dayKey,
            openDayKey: snapshot.missesRequiredSet ? snapshot.bundle.dayKey : nil
        )
    }

    /// "Penalty 10K [3.2/10km]", like the quest row.
    nonisolated static func shieldLine(_ quest: Quest) -> String {
        func number(_ value: Double) -> String {
            value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
        }
        return "\(quest.title) [\(number(quest.progress.current))/\(number(quest.progress.target))\(quest.progress.unit)]"
    }

    /// The penalty row still open today, or nil. While it exists, `PenaltyQuestView` covers every page.
    var openPenaltyQuest: Quest? {
        guard snapshot.player.penaltyTier > 0 else { return nil }
        return PenaltyQuests.rows(in: snapshot.bundle).first { $0.status != .completed }
    }

    /// When the open penalty started, as the enforcement saved it. Now, if it has not been saved yet.
    var penaltyStartedAt: Date {
        let saved = PenaltyGroup.defaults.double(forKey: PenaltyGroup.startedAtKey)
        return saved > 0 ? Date(timeIntervalSince1970: saved) : .now
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
        // An offline mock plan does not count once a Claude key is saved.
        let author = snapshot.bundle.generatedBy
        let alreadyGenerated = ["llm", "template"].contains(author) || (author == "mock" && !OnDeviceQuestGenerateClient.hasKey)
        if finished || alreadyGenerated {
            if alreadyGenerated, snapshot.generatedBundle == nil {
                snapshot.generatedBundle = snapshot.bundle.strippingModelCompletion(assignedAt: now)
            }
            persist()
            return
        }
        persist()
        let context = ContextBuilder.make(snapshot: snapshot, now: now, targets: statTargets, bodyMass: statInputs?.bodyMass)
        Task { [weak self] in
            await self?.runGeneration(context: context, dayKey: dayKey)
        }
    }

    /// Tries per local day when the planner gets no reply. Each later app open or refresh tries again.
    private static let generationRetriesPerDay = 3

    private func runGeneration(context: MorningContext, dayKey: String) async {
        // Planning can take two minutes. Ask iOS for time to finish if the app goes to the background.
        let background = GenerationBackgroundTask.begin()
        defer { GenerationBackgroundTask.end(background) }
        let result = await generator.generateResult(context: context)
        let bundle = result.bundle
        if result.retryLater {
            allowGenerationRetry(dayKey: dayKey)
            return
        }
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

    /// No reply came back: clear today's attempt so the next open or refresh plans again, up to the daily limit.
    private func allowGenerationRetry(dayKey: String) {
        let key = "com.angelmorales.thesystem.generationRetries.\(dayKey)"
        let used = UserDefaults.standard.integer(forKey: key)
        guard used < Self.generationRetriesPerDay, snapshot.generationAttemptDayKey == dayKey else { return }
        UserDefaults.standard.set(used + 1, forKey: key)
        var next = snapshot
        next.generationAttemptDayKey = nil
        snapshot = next
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
