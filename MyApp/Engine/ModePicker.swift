import Foundation

struct ModePickerInput: Equatable {
    var spendingFullRecovery: Bool
    var readinessBand: ReadinessBand
    var sleepPerformance: Int?
    /// True when today rests (`GameSnapshot.restDue`): the planner picked it, or the seventh day is forced.
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
/// one Full Recovery day in every seven quest days, free, with no penalty. The planner picks the day
/// (`GameSnapshot.restAvailable`); after six trained days in a row the seventh is forced. Readiness and sleep
/// size the Training day through `trainingBand`; they never pick a different mode.
/// An open penalty does not pick a mode; `PenaltyQuests` adds its rows to the day.
enum ModePicker {
    /// Sleep performance under this drops the training band one step.
    static let lowSleepPerformance = 60
    /// At least one rest day in every run of this many quest days.
    static let restEveryDays = 7
    /// The planner may rest only after this many trained days in a row, so two rests never touch.
    static let restMinTrainedDays = 2
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
        if week.bundle.narrative != GameSnapshot.forcedRestNarrative { errors.append("the forced seventh day should show the seventh-day line, got \(week.bundle.narrative)") }
        if week.spendFullRecovery(catalog: catalog, now: day(6)).contains("tomorrow") || week.player.fullRecoveryBank != bank {
            errors.append("a token on a Rest Day should stay in the bank")
        }
        let gold = week.gold
        week.refreshIfNeeded(catalog: catalog, now: day(7))
        if week.player.penaltyOpen || week.gold != gold || week.bundle.mode != .performanceTraining {
            errors.append("the day after a Rest Day should train again with no penalty, got penalty \(week.player.penaltyOpen) mode \(week.bundle.mode)")
        }

        // The planner picks the rest day: not on day 1 or 2, open from day 3, closed for six days after it.
        var picked = GameSnapshot.fresh(catalog: catalog, now: dayOne)
        if picked.restAvailable(on: picked.bundle.dayKey) { errors.append("the planner should not rest on day 1") }
        for offset in 0..<2 {
            finishRequired(&picked, now: day(offset))
            picked.refreshIfNeeded(catalog: catalog, now: day(offset + 1))
        }
        if !picked.restAvailable(on: picked.bundle.dayKey) || picked.trainedDaysInARow(before: picked.bundle.dayKey) != 2 {
            errors.append("after two trained days the planner may rest, got \(picked.trainedDaysInARow(before: picked.bundle.dayKey)) days")
        }
        picked.plannerRestDayKey = picked.bundle.dayKey
        picked.rebuildBundle(catalog: catalog, now: day(2))
        if picked.bundle.mode != .fullRecovery || picked.bundle.headerLine != GameSnapshot.restDayHeader {
            errors.append("the planner's rest day should be a Rest Day, got \(picked.bundle.mode) \(picked.bundle.headerLine)")
        }
        // The Rest Day says why: the planner's reason, the fixed line when it gave none, the seventh-day line when forced.
        if picked.bundle.narrative != GameSnapshot.pickedRestNarrative { errors.append("a picked rest with no reason should show the fixed line, got \(picked.bundle.narrative)") }
        picked.plannerRestReason = "HRV 18% under baseline for three days. Rest to protect the next block."
        picked.rebuildBundle(catalog: catalog, now: day(2))
        if picked.bundle.narrative != picked.plannerRestReason || !picked.isRestDay { errors.append("a picked rest should show the planner's reason, got \(picked.bundle.narrative)") }

        picked.refreshIfNeeded(catalog: catalog, now: day(3))
        for offset in 3..<9 {
            if picked.bundle.mode != .performanceTraining { errors.append("day \(offset + 1) after a picked rest should train") }
            if picked.restAvailable(on: picked.bundle.dayKey) || !picked.restTaken(before: picked.bundle.dayKey) {
                errors.append("rest should not be open again while the pick sits in the last six days (day \(offset + 1))")
            }
            finishRequired(&picked, now: day(offset))
            picked.refreshIfNeeded(catalog: catalog, now: day(offset + 1))
        }
        // Day 10: the pick on day 3 left the six-day lookback, six trained days behind: forced.
        if picked.bundle.mode != .fullRecovery { errors.append("six trained days after the picked rest should force the next, got \(picked.bundle.mode)") }

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
        owed.player.penaltyOpen = true
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
        // "No gym today" adds one 10K that never counts: one run on a full window, two when the window needs one.
        var noGym = ran
        _ = noGym.setNoGym(true, catalog: catalog, now: dayOne)
        if noGym.bundle.quests.filter({ TrainingDay.isRaceRun($0) }).count != 1 {
            errors.append("a no-gym day on a full window should run only the added 10K, got \(noGym.bundle.quests.map(\.title))")
        }
        ran.questHistory.removeLast()
        ran.rebuildBundle(catalog: catalog, now: dayOne)
        if !ran.bundle.quests.contains(where: { TrainingDay.isRaceRun($0) }) { errors.append("40 km in six days should keep the run") }
        var noGymShort = ran
        _ = noGymShort.setNoGym(true, catalog: catalog, now: dayOne)
        if noGymShort.bundle.quests.filter({ TrainingDay.isRaceRun($0) }).count != 2 {
            errors.append("a no-gym day with 40 km behind it should run the window's 10K plus the added one, got \(noGymShort.bundle.quests.map(\.title))")
        }
        // Offline, a past no-gym day's added 10K comes off the window too.
        var discounted = ran
        discounted.questHistory.append(QuestDayRecord(dayKey: QuestDay.key(byAddingDays: -5, to: ran.bundle.dayKey), mode: .performanceTraining, trainingBand: .green,
                                                      noGym: true, generatedBy: "fallback", missedRequired: false, quests: [runRecord]))
        if discounted.loggedRunKm(before: discounted.bundle.dayKey) != 40 {
            errors.append("a no-gym day's single 10K should give the window nothing, got \(discounted.loggedRunKm(before: discounted.bundle.dayKey))")
        }
        return errors
    }
}

/// Today's rest signals from the data the phone already holds, weighed into one rest-or-train answer.
/// Online, the signals go to the planner in `rest.signals` and the planner decides. Offline, `saysRest`
/// decides in its place, so a bad run of days rests with or without a Claude key. One bad night never
/// rests on its own; two red mornings, critical HP, or a full fatigue meter do.
enum RestScore {
    struct Input: Equatable {
        var readinessBand: ReadinessBand?
        /// The training band the app recorded for yesterday's quest day.
        var yesterdayBand: ReadinessBand?
        var sleepPerformance: Int?
        var hrv: Double?
        var hrvBaseline: Double?
        /// 0...100.
        var fatigue: Int = 0
        var hpCritical = false
    }

    struct Result: Equatable {
        var points: Int
        var signals: [String]
        var saysRest: Bool { points >= RestScore.restAt }
        /// The one-sentence reason the Rest Day shows when the app, not the planner, picks the rest.
        var reason: String {
            let lead = signals.first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "The System calls a rest"
            return "\(lead). Rest to protect the next block."
        }
    }

    /// Points at or above this rest the day.
    static let restAt = 3
    static let highFatigue = 80
    static let raisedFatigue = 60
    /// HRV under this share of the running baseline counts as low.
    static let lowHrvShare = TrainingHistory.hrvDropShare

    static func score(_ input: Input) -> Result {
        var points = 0
        var signals: [String] = []
        func add(_ value: Int, _ text: String) {
            points += value
            signals.append(text)
        }
        if input.hpCritical { add(3, "HP is critical, under \(Int(HitPoints.criticalFraction * 100))% of max") }
        if input.fatigue >= highFatigue {
            add(3, "fatigue is at \(input.fatigue) of 100")
        } else if input.fatigue >= raisedFatigue {
            add(1, "fatigue is raised, \(input.fatigue) of 100")
        }
        switch input.readinessBand {
        case .red:
            if input.yesterdayBand == .red {
                add(3, "recovery in the red two mornings in a row")
            } else {
                add(2, "recovery in the red this morning")
            }
        case .yellow:
            add(1, "recovery in the yellow this morning")
        case .green, nil:
            break
        }
        if let sleep = input.sleepPerformance, sleep < ModePicker.lowSleepPerformance {
            add(1, "sleep performance \(sleep)%, under \(ModePicker.lowSleepPerformance)%")
        }
        if let hrv = input.hrv, let baseline = input.hrvBaseline, baseline > 0, hrv < baseline * lowHrvShare {
            add(1, "HRV \(Int(((1 - hrv / baseline) * 100).rounded()))% under its baseline")
        }
        return Result(points: points, signals: signals)
    }

    static func check() -> [String] {
        var errors: [String] = []
        func expect(_ input: Input, rest: Bool, _ label: String) {
            let result = score(input)
            if result.saysRest != rest { errors.append("\(label) should \(rest ? "rest" : "train"), got \(result.points) points \(result.signals)") }
        }
        expect(Input(), rest: false, "no data")
        expect(Input(readinessBand: .green, sleepPerformance: 45), rest: false, "one bad night")
        expect(Input(readinessBand: .red), rest: false, "one red morning")
        expect(Input(readinessBand: .red, yesterdayBand: .red), rest: true, "two red mornings")
        expect(Input(readinessBand: .red, sleepPerformance: 50), rest: true, "a red morning after a bad night")
        expect(Input(readinessBand: .yellow, sleepPerformance: 50), rest: false, "a yellow morning after a bad night")
        expect(Input(readinessBand: .yellow, sleepPerformance: 50, hrv: 40, hrvBaseline: 60), rest: true, "yellow, low sleep, and low HRV")
        expect(Input(readinessBand: .green, hrv: 59, hrvBaseline: 60), rest: false, "HRV just under baseline")
        expect(Input(fatigue: 80), rest: true, "fatigue at 80")
        expect(Input(fatigue: 79), rest: false, "fatigue at 79 alone")
        expect(Input(readinessBand: .red, fatigue: 60), rest: true, "a red morning with raised fatigue")
        expect(Input(hpCritical: true), rest: true, "critical HP")
        let two = score(Input(readinessBand: .red, yesterdayBand: .red))
        if two.reason != "Recovery in the red two mornings in a row. Rest to protect the next block." { errors.append("the reason should lead with the first signal, got \(two.reason)") }
        if score(Input()).reason != "The System calls a rest. Rest to protect the next block." { errors.append("a reason with no signals should still read, got \(score(Input()).reason)") }
        return errors
    }
}
