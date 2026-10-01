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
    private let persistence: GamePersistence
    private var ticker: Timer?

    init(persistence: GamePersistence = .standard) {
        #if DEBUG
        let problems = VerificationFixtures.check()
        precondition(problems.isEmpty, problems.joined(separator: "\n"))
        #endif

        let catalog = FallbackCatalog.bundled()
        self.catalog = catalog
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
        persist()
        ensureTicker()
    }

    var player: PlayerState { snapshot.player }
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
            var next = snapshot
            let outcome = next.applyLocalOverride(questId: id, now: now)
            snapshot = next
            clock = now
            note(for: outcome, title: quest.title)
            persist()
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
        persist()
        ensureTicker()
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
            let context = next.verificationContext(for: quest, now: now, timerElapsed: nil, userConfirmed: false)
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
