import Foundation

/// The day's 10K Run can be done as 300 burpees instead, logged in Hevy. The player picks it under the run row.
///
/// The row keeps its id, so rebuilds, the day's record, and the no-gym rules still see one workout row. While it is
/// burpees it is a Hevy rep row ("Burpee", 300 reps in any number of sets), and the day's Hevy routine holds it as
/// one set of 300. The swap icon on the row brings the run back while no burpee is logged.
/// Burpees count for one row only: a day whose penalty is burpees keeps its run, and the other way round.
struct BurpeeSwap: Codable, Equatable {
    var dayKey: String
    /// The run rows as they were before the swap, to give back on a switch back.
    var runs: [Quest]
}

enum RunBurpees {
    static let reps = 300
    static let title = "300 Burpees"
    /// The day's Hevy routine holds the burpees as one set of 300, from the row's `sets` and `reps` params.
    static let routineSets = 1
    /// The param that marks a burpee row made from a run.
    static let markKey = "replacesRun"

    static func isBurpeeRow(_ quest: Quest) -> Bool {
        quest.kind == .daily && quest.verification.method == .hevySets && quest.verification.params[markKey] != nil
    }

    /// An open 10K Run with no km logged yet.
    static func canSwap(_ quest: Quest) -> Bool {
        quest.kind == .daily && NoGymDay.isTenK(quest) && quest.status == .pending && quest.progress.current == 0
    }

    /// A burpee row with no burpee logged yet.
    static func canSwapBack(_ quest: Quest) -> Bool {
        isBurpeeRow(quest) && quest.status == .pending && quest.progress.current == 0
    }

    static func burpees(from run: Quest) -> Quest {
        var row = run
        row.title = title
        row.verification = VerificationSpec(method: .hevySets, params: [
            "exercise": .string(PenaltyQuests.burpeeExercise),
            "totalReps": .number(Double(reps)),
            "sets": .number(Double(routineSets)),
            "reps": .number(Double(reps)),
            markKey: .bool(true),
        ])
        row.progress = QuestProgress(current: 0, target: Double(reps), unit: "reps")
        row.status = .pending
        row.evidence = []
        return row
    }

    static func check() -> [String] {
        var errors: [String] = []
        let catalog = FallbackCatalog.bundled()
        guard let noon = QuestDay.date(from: "2026-11-24") else { return ["could not build the burpee day"] }
        var day = GameSnapshot.fresh(catalog: catalog, now: noon)
        day.bundle.quests.removeAll { $0.kind == .penalty }
        let run = { (quest: Quest) in NoGymDay.isTenK(quest) }
        guard let runId = day.bundle.quests.first(where: { $0.kind == .daily && run($0) })?.id ?? {
            // A day without a planned 10K: add one, as the planner writes it.
            var copy = day.bundle.quests.first { $0.kind == .daily } ?? day.bundle.quests[0]
            copy.id = "q_2026-11-24_run_10k_1"
            copy.title = TrainingDay.tenKTitle
            copy.kind = .daily
            copy.verification = VerificationSpec(method: .stravaActivity, params: ["types": .array([.string("Run")]), "minDistanceMeters": .number(TrainingDay.tenKMeters)])
            copy.progress = QuestProgress(current: 0, target: 10, unit: "km")
            copy.status = .pending
            day.bundle.quests.insert(copy, at: 0)
            return copy.id
        }() else { return ["no run row"] }

        // The swap: same id, a Hevy rep row of 300 burpees, and the run is kept for a switch back.
        if day.swapRunToBurpees(id: runId) != nil { errors.append("an open 10K should become burpees") }
        guard let row = day.bundle.quests.first(where: { $0.id == runId }) else { return errors + ["the swapped row should keep its id"] }
        if !isBurpeeRow(row) || row.progress.target != 300 || row.verification.params["exercise"]?.stringValue != "Burpee" {
            errors.append("the swapped row should be 300 Hevy burpees, got \(row.title) \(row.verification.params)")
        }
        if TrainingDay.isStrength(row) || !TrainingDay.isExercise(row) {
            errors.append("a burpee row should stay an exercise row but not a lift")
        }
        // A rebuild of the day keeps the swap.
        let rebuilt = day.finished(day.bundle.replacing(runId, with: day.burpeeSwap?.runs.first), catalog: catalog, now: noon)
        if rebuilt.quests.first(where: { $0.id == runId }).map({ isBurpeeRow($0) }) != true { errors.append("a rebuilt day should keep the burpees") }
        // The day's Hevy routine holds the burpees as one set of 300.
        let plan = HevyRoutine.plan(for: day.bundle, history: [], templates: ["burpee": "T1"])
        let burpee = plan?.exercises.first { $0.name == "Burpee" }
        if burpee?.templateId != "T1" || burpee?.sets.count != 1 || burpee?.sets.first?.repsLow != 300 {
            errors.append("the Hevy routine should hold one set of 300 burpees, got \(String(describing: burpee))")
        }
        // 300 reps in Hevy, in any sets, complete the row.
        var hevy = DayIntegrationSnapshot.empty(dayKey: day.bundle.dayKey)
        hevy.hevy = HevyDayReading(available: true, configured: true, reason: "", dayKey: day.bundle.dayKey, workouts: [
            HevyWorkout(id: "w1", title: "Workout", start: noon, end: noon.addingTimeInterval(1800), exercises: [
                HevyExercise(title: "Burpee", templateId: "T1", sets: [120, 100, 80].map { HevySet(type: "normal", reps: $0) }),
            ]),
        ])
        let context = VerificationContext(now: noon.addingTimeInterval(3600), dayKey: day.bundle.dayKey, assignedAt: noon, manualConfirmsToday: 0,
                                          timerElapsedSec: nil, userConfirmed: false, integrations: hevy)
        if case .completed = HevySetsVerifier().evaluate(quest: row, context: context) {} else {
            errors.append("300 burpees in Hevy should complete the row")
        }
        // The switch back gives the run as it was.
        var back = day
        if back.swapBurpeesToRun(id: runId) != nil || back.bundle.quests.first(where: { $0.id == runId }).map(run) != true || back.burpeeSwap?.runs.isEmpty != true {
            errors.append("an untouched burpee row should switch back to the 10K")
        }
        // A started row stays as it is.
        var started = day
        if let index = started.bundle.quests.firstIndex(where: { $0.id == runId }) { started.bundle.quests[index].progress.current = 20 }
        if started.swapBurpeesToRun(id: runId) == nil { errors.append("a burpee row with reps logged should not switch back") }
        // Burpees count for one row: a burpee penalty keeps the run a run.
        var owed = back
        PenaltyQuests.choiceOverride = .burpees
        owed.player.penaltyOpen = true
        owed.bundle = PenaltyQuests.ensure(in: owed.bundle, open: true, band: .green, catalog: catalog, now: noon)
        PenaltyQuests.choiceOverride = nil
        if owed.swapRunToBurpees(id: runId) == nil { errors.append("a day with burpee penalty should keep its run") }
        if !PenaltyQuests.swapToBurpees(in: day.bundle, now: noon).quests.filter({ PenaltyQuests.isBurpees($0) }).isEmpty {
            errors.append("a day with burpees for its run should keep a run penalty")
        }
        return errors
    }
}

private extension QuestBundle {
    func replacing(_ id: String, with quest: Quest?) -> QuestBundle {
        guard let quest, let index = quests.firstIndex(where: { $0.id == id }) else { return self }
        var copy = self
        copy.quests[index] = quest
        return copy
    }
}

extension GameSnapshot {
    /// Turns the open 10K Run `id` into 300 burpees. Nil when done, else the reason it did not change.
    mutating func swapRunToBurpees(id: String) -> String? {
        guard let index = bundle.quests.firstIndex(where: { $0.id == id }), RunBurpees.canSwap(bundle.quests[index]) else {
            return "Only an open 10K Run with no km logged can become burpees."
        }
        guard !bundle.quests.contains(where: { PenaltyQuests.isBurpees($0) }) else {
            return "Today's penalty is burpees. Burpees count for one quest only, so the run stays a run."
        }
        var swap = burpeeSwap?.dayKey == bundle.dayKey ? burpeeSwap ?? BurpeeSwap(dayKey: bundle.dayKey, runs: []) : BurpeeSwap(dayKey: bundle.dayKey, runs: [])
        swap.runs.removeAll { $0.id == id }
        swap.runs.append(bundle.quests[index])
        burpeeSwap = swap
        bundle.quests[index] = RunBurpees.burpees(from: bundle.quests[index])
        return nil
    }

    /// Gives the 10K Run back for the burpee row `id`, while no burpee is logged.
    mutating func swapBurpeesToRun(id: String) -> String? {
        guard let index = bundle.quests.firstIndex(where: { $0.id == id }), RunBurpees.canSwapBack(bundle.quests[index]),
              let swap = burpeeSwap, swap.dayKey == bundle.dayKey, let run = swap.runs.first(where: { $0.id == id }) else {
            return "Burpees are logged for this quest, so it stays burpees."
        }
        bundle.quests[index] = run
        burpeeSwap?.runs.removeAll { $0.id == id }
        return nil
    }

    /// A day that is built again keeps its burpee rows: the planner writes the runs again with the same ids.
    func keepingBurpeeSwaps(_ bundle: QuestBundle) -> QuestBundle {
        guard let swap = burpeeSwap, swap.dayKey == bundle.dayKey else { return bundle }
        var copy = bundle
        for run in swap.runs {
            guard let index = copy.quests.firstIndex(where: { $0.id == run.id }), RunBurpees.canSwap(copy.quests[index]) else { continue }
            copy.quests[index] = RunBurpees.burpees(from: copy.quests[index])
        }
        return copy
    }
}
