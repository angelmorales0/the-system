import Foundation

struct ModePickerInput: Equatable {
    var spendingFullRecovery: Bool
    var readinessBand: ReadinessBand
    var sleepPerformance: Int?
    /// True when the six quest days before today had no rest day (`GameSnapshot.restDue`). Today then rests.
    var restDue = false
}

struct ModeDecision: Equatable {
    var selectedMode: QuestMode
    /// Band that sizes the Training day. WHOOP readiness, one step lower after a poor night.
    var trainingBand: ReadinessBand
    var reasonCodes: [String]
    var lockedByRules: Bool
}

/// Rules-only day mode. The LLM is not allowed to override this once it exists.
/// Every day is Performance Training unless a Full Recovery token is spent or the weekly rest is due:
/// one Full Recovery day in every seven quest days, free, with no penalty. Readiness and sleep
/// size the Training day through `trainingBand`; they never pick a different mode.
/// An open penalty does not pick a mode; `PenaltyQuests` adds its rows to the day.
enum ModePicker {
    /// Sleep performance under this drops the training band one step.
    static let lowSleepPerformance = 60
    /// At least one rest day in every run of this many quest days.
    static let restEveryDays = 7
    static let weeklyRestReason = "weekly_rest"

    static func decide(_ input: ModePickerInput) -> ModeDecision {
        let band = trainingBand(readiness: input.readinessBand, sleepPerformance: input.sleepPerformance)
        if input.spendingFullRecovery {
            return lock(.fullRecovery, band, ["full_recovery_spent"])
        }
        if input.restDue {
            return lock(.fullRecovery, band, [weeklyRestReason])
        }
        var reasons = ["readiness_\(input.readinessBand.rawValue)"]
        if band != input.readinessBand {
            reasons.append("sleep_low")
        }
        return lock(.performanceTraining, band, reasons)
    }

    /// Green, yellow, or red WHOOP readiness, one step lower when sleep performance is under 60%.
    static func trainingBand(readiness: ReadinessBand, sleepPerformance: Int?) -> ReadinessBand {
        guard let sleep = sleepPerformance, sleep < lowSleepPerformance else { return readiness }
        switch readiness {
        case .green: return .yellow
        case .yellow, .red: return .red
        }
    }

    static func checkFixtures() -> [String] {
        var errors: [String] = []
        func expect(_ input: ModePickerInput, _ mode: QuestMode, _ band: ReadinessBand, _ reasons: [String]) {
            let decision = decide(input)
            if decision.selectedMode != mode || decision.trainingBand != band || decision.reasonCodes != reasons || decision.lockedByRules != true {
                errors.append("expected \(mode.rawValue)/\(band.rawValue) \(reasons) got \(decision.selectedMode.rawValue)/\(decision.trainingBand.rawValue) \(decision.reasonCodes) locked=\(decision.lockedByRules)")
            }
        }

        expect(sample(spendingFullRecovery: true, readinessBand: .green), .fullRecovery, .green, ["full_recovery_spent"])
        expect(sample(readinessBand: .green, restDue: true), .fullRecovery, .green, [weeklyRestReason])
        expect(sample(readinessBand: .red, sleepPerformance: 40, restDue: true), .fullRecovery, .red, [weeklyRestReason])
        expect(sample(spendingFullRecovery: true, readinessBand: .green, restDue: true), .fullRecovery, .green, ["full_recovery_spent"])
        expect(sample(readinessBand: .green), .performanceTraining, .green, ["readiness_green"])
        expect(sample(readinessBand: .yellow), .performanceTraining, .yellow, ["readiness_yellow"])
        expect(sample(readinessBand: .red), .performanceTraining, .red, ["readiness_red"])
        expect(sample(readinessBand: .green, sleepPerformance: 59), .performanceTraining, .yellow, ["readiness_green", "sleep_low"])
        expect(sample(readinessBand: .yellow, sleepPerformance: 59), .performanceTraining, .red, ["readiness_yellow", "sleep_low"])
        expect(sample(readinessBand: .red, sleepPerformance: 40), .performanceTraining, .red, ["readiness_red"])
        expect(sample(readinessBand: .green, sleepPerformance: 60), .performanceTraining, .green, ["readiness_green"])
        expect(sample(readinessBand: .green, sleepPerformance: nil), .performanceTraining, .green, ["readiness_green"])
        return errors
    }

    private static func lock(_ mode: QuestMode, _ band: ReadinessBand, _ reasons: [String]) -> ModeDecision {
        ModeDecision(selectedMode: mode, trainingBand: band, reasonCodes: reasons, lockedByRules: true)
    }

    private static func sample(
        spendingFullRecovery: Bool = false,
        readinessBand: ReadinessBand = .green,
        sleepPerformance: Int? = 80,
        restDue: Bool = false
    ) -> ModePickerInput {
        ModePickerInput(
            spendingFullRecovery: spendingFullRecovery,
            readinessBand: readinessBand,
            sleepPerformance: sleepPerformance,
            restDue: restDue
        )
    }
}

/// The weekly rest day and the run rest, played out over real quest days.
enum RestRules {
    static func check() -> [String] {
        var errors: [String] = []
        let catalog = FallbackCatalog.bundled()
        guard let dayOne = QuestDay.start(of: "2026-10-05")?.addingTimeInterval(3_600) else { return ["could not build rest dates"] }
        func day(_ offset: Int) -> Date { dayOne.addingTimeInterval(Double(offset) * 86_400) }
        func finishRequired(_ snapshot: inout GameSnapshot, now: Date) {
            for quest in snapshot.bundle.quests where quest.kind != .optional && quest.status != .completed {
                let evidence = Evidence.make(source: "rest_check", externalId: "rest:\(quest.id)", payload: "rest|\(quest.id)", timestamp: now)
                snapshot.apply(.completed(evidence: evidence), questId: quest.id, now: now)
            }
        }

        // Six trained days, then the seventh rests: Full Recovery, "Rest Day", no token spent, no penalty, no gold.
        var week = GameSnapshot.fresh(catalog: catalog, now: dayOne)
        let bank = week.player.fullRecoveryBank
        for offset in 0..<6 {
            if week.bundle.mode != .performanceTraining { errors.append("day \(offset + 1) should train, got \(week.bundle.mode)") }
            finishRequired(&week, now: day(offset))
            week.refreshIfNeeded(catalog: catalog, now: day(offset + 1))
        }
        if week.bundle.mode != .fullRecovery || week.bundle.headerLine != GameSnapshot.restDayHeader || week.player.fullRecoveryBank != bank {
            errors.append("the seventh day should be a free Rest Day, got \(week.bundle.mode) \(week.bundle.headerLine) bank \(week.player.fullRecoveryBank - bank)")
        }
        if week.bundle.quests.contains(where: { TrainingDay.isRaceRun($0) || TrainingDay.isStrength($0) && $0.id != DailyStretch.questId }) {
            errors.append("a Rest Day should hold no run and no lifts, got \(week.bundle.quests.map(\.title))")
        }
        if week.spendFullRecovery(catalog: catalog, now: day(6)).contains("tomorrow") || week.player.fullRecoveryBank != bank {
            errors.append("a token on a Rest Day should stay in the bank")
        }
        let gold = week.gold
        week.refreshIfNeeded(catalog: catalog, now: day(7))
        if week.player.penaltyTier != 0 || week.gold != gold || week.bundle.mode != .performanceTraining {
            errors.append("the day after a Rest Day should train again with no penalty, got tier \(week.player.penaltyTier) mode \(week.bundle.mode)")
        }

        // A token spent mid-week counts as the rest, so the forced day moves out a week.
        var token = GameSnapshot.fresh(catalog: catalog, now: dayOne)
        token.player.fullRecoveryBank = 1
        for offset in 0..<3 {
            finishRequired(&token, now: day(offset))
            token.refreshIfNeeded(catalog: catalog, now: day(offset + 1))
        }
        _ = token.spendFullRecovery(catalog: catalog, now: day(3))
        if token.bundle.mode != .fullRecovery { errors.append("a quiet day 4 should take the token") }
        for offset in 3..<10 {
            finishRequired(&token, now: day(offset))
            token.refreshIfNeeded(catalog: catalog, now: day(offset + 1))
            if (4...9).contains(offset + 1), token.bundle.mode != .performanceTraining { errors.append("a token on day 4 should push the rest day to day 11, day \(offset + 2) rested") }
        }
        if token.bundle.mode != .fullRecovery { errors.append("the rest should fall seven days after the token day, got \(token.bundle.mode) on day 11") }

        // An open penalty is served first.
        var owed = GameSnapshot.fresh(catalog: catalog, now: dayOne)
        for offset in 0..<6 {
            finishRequired(&owed, now: day(offset))
            owed.refreshIfNeeded(catalog: catalog, now: day(offset + 1))
        }
        owed.player.penaltyTier = 1
        if owed.restDue(on: QuestDay.key(for: day(6))) { errors.append("a penalty should be served before the rest day") }

        // Run rest offline: 50 km in the last six quest days drops today's run rows and keeps the lifts.
        var ran = GameSnapshot.fresh(catalog: catalog, now: dayOne)
        let runRecord = QuestRecord(title: "10K Run", kind: .daily, stat: .END, method: .stravaActivity, params: [:], target: 10, done: 10, unit: "km", status: .completed)
        ran.questHistory = (1...5).map { daysAgo in
            QuestDayRecord(dayKey: QuestDay.key(byAddingDays: -daysAgo, to: ran.bundle.dayKey), mode: .performanceTraining, trainingBand: .green,
                           noGym: false, generatedBy: "fallback", missedRequired: false, quests: [runRecord])
        }
        ran.rebuildBundle(catalog: catalog, now: dayOne)
        if ran.bundle.quests.contains(where: { TrainingDay.isRaceRun($0) }) || !ran.bundle.quests.contains(where: { TrainingDay.isStrength($0) && $0.id != DailyStretch.questId }) {
            errors.append("50 km in six days should drop the run and keep the lifts, got \(ran.bundle.quests.map(\.title))")
        }
        ran.questHistory.removeLast()
        ran.rebuildBundle(catalog: catalog, now: dayOne)
        if !ran.bundle.quests.contains(where: { TrainingDay.isRaceRun($0) }) { errors.append("40 km in six days should keep the run") }
        return errors
    }
}
