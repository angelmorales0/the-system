import Foundation

/// Self-checks for rules that cross files: the planner's day against the app's day, the penalty rows, and the
/// screen time overlap. Each one failed before its fix.
enum PlanAndLockRules {
    static func check() -> [String] {
        var errors: [String] = []
        let catalog = FallbackCatalog.bundled()
        guard let morning = QuestDay.start(of: "2026-10-22")?.addingTimeInterval(4 * 3_600) else { return ["could not build plan dates"] }

        // A penalty that opens after the day's penalty run is a new debt: it gets its own open row.
        var twice = GameSnapshot.fresh(catalog: catalog, now: morning)
        twice.player.penaltyOpen = true
        twice.rebuildBundle(catalog: catalog, now: morning)
        if let row = PenaltyQuests.rows(in: twice.bundle).first {
            let run = Evidence.make(source: "plan_check", externalId: "plan:penalty", payload: "penalty", timestamp: morning)
            twice.apply(.completed(evidence: run), questId: row.id, now: morning)
        }
        twice.player.penaltyOpen = true
        twice.bundle = PenaltyQuests.ensure(in: twice.bundle, open: true, band: twice.trainingBand, catalog: catalog, now: morning)
        let penaltyRows = PenaltyQuests.rows(in: twice.bundle)
        if penaltyRows.count != 2 || Set(penaltyRows.map(\.id)).count != 2 || penaltyRows.filter({ $0.status != .completed }).count != 1 {
            errors.append("a second penalty on one day should add its own open row, got \(penaltyRows.map { "\($0.id) \($0.status)" })")
        }
        if let other = twice.bundle.quests.first(where: { $0.kind == .daily && $0.status != .completed && $0.id != ScreenTime.questId }) {
            twice.apply(.completed(evidence: Evidence.make(source: "plan_check", externalId: "plan:other", payload: "other", timestamp: morning)), questId: other.id, now: morning)
        }
        if !twice.player.penaltyOpen { errors.append("a quest of the day should not close a penalty that has an open row") }

        // Screen time overlap: phone minutes before 5:00 cannot overlap the Macs, whose day starts at 5:00.
        if let dayStart = QuestDay.start(of: "2026-10-22") {
            var bitmap = Data(count: 180)
            for slot in 0..<240 { bitmap[slot >> 3] |= 1 << UInt8(slot & 7) }
            let early = [5: dayStart.addingTimeInterval(-175 * 60), 10: dayStart.addingTimeInterval(240 * 60)]
            if ScreenOverlap.minutes(phoneTimes: early, macActive: bitmap, dayStart: dayStart) != 0 {
                errors.append("phone minutes that can be before 5:00 are no sure overlap with the Macs")
            }
        }

        // The planner: heavy and light days of one lift are two series.
        func gym(_ daysAgo: Int, _ kg: Double, _ reps: Int) -> HevyWorkout {
            let start = morning.addingTimeInterval(Double(-daysAgo) * 86_400)
            let sets = Array(repeating: HevySet(type: "normal", reps: reps, weightKg: kg, rpe: nil, durationSec: nil), count: 3)
            return HevyWorkout(id: "plan-\(daysAgo)", title: "Gym", start: start, end: start.addingTimeInterval(3_600),
                               exercises: [HevyExercise(title: "Squat (Barbell)", templateId: nil, sets: sets)])
        }
        let lifts = TrainingHistory.liftSummaries([gym(15, 117.5, 5), gym(13, 95, 8), gym(10, 120, 5), gym(8, 97.5, 8), gym(5, 122.5, 5), gym(3, 100, 8)],
                                                  today: "2026-10-22", zone: QuestDay.timeZone)
        let heavy: JSONValue = .object(["mode": .string("performance_training"), "quests": .array([.object([
            "title": .string("Squat 3x5"),
            "verification": .object(["method": .string("hevy_sets"), "params": .object(["exercise": .string("Squat"), "sets": .number(3), "minReps": .number(5), "minWeightKg": .number(125)])]),
        ])])])
        if lifts.json["squat"]?["trend"]?.stringValue != "improving" || !TrainingHistory.limitProblems(heavy, .object(["lifts": lifts.json])).isEmpty {
            errors.append("a light squat day should not make the heavy squat read as declining")
        }

        // A 5-8 row whose top sets are 8s is one series: a real decline still stops a heavier row, and a lighter one passes.
        func row(_ daysAgo: Int, _ kg: Double, _ reps: Int) -> HevyWorkout {
            let start = morning.addingTimeInterval(Double(-daysAgo) * 86_400)
            let sets = Array(repeating: HevySet(type: "normal", reps: reps, weightKg: kg, rpe: nil, durationSec: nil), count: 3)
            return HevyWorkout(id: "row-\(daysAgo)", title: "Gym", start: start, end: start.addingTimeInterval(3_600),
                               exercises: [HevyExercise(title: "Bent Over Row (Barbell)", templateId: nil, sets: sets)])
        }
        let rows = TrainingHistory.liftSummaries([row(12, 70, 8), row(7, 70, 8), row(2, 65, 7)], today: "2026-10-22", zone: QuestDay.timeZone)
        func rowPlan(_ kg: Double) -> JSONValue {
            .object(["mode": .string("performance_training"), "quests": .array([.object([
                "title": .string("Bent Over Row 3x5-8"),
                "verification": .object(["method": .string("hevy_sets"), "params": .object(["exercise": .string("Bent Over Row"), "sets": .number(3), "minReps": .number(5), "minWeightKg": .number(kg)])]),
            ])])])
        }
        if TrainingHistory.limitProblems(rowPlan(75), .object(["lifts": rows.json])).isEmpty || !TrainingHistory.limitProblems(rowPlan(62.5), .object(["lifts": rows.json])).isEmpty {
            errors.append("a declining row should not get more weight, but less is fine, whatever the planned bottom reps")
        }
        // Pull-ups: the volume day's best set is under the max-effort day's. Both rise, so nothing falls.
        func pull(_ daysAgo: Int, _ reps: [Int]) -> HevyWorkout {
            let start = morning.addingTimeInterval(Double(-daysAgo) * 86_400)
            return HevyWorkout(id: "pull-\(daysAgo)", title: "Gym", start: start, end: start.addingTimeInterval(3_600),
                               exercises: [HevyExercise(title: "Pull Up", templateId: nil, sets: reps.map { HevySet(type: "normal", reps: $0, weightKg: nil, rpe: nil, durationSec: nil) })])
        }
        let pulls = TrainingHistory.liftSummaries([pull(16, [7, 7, 7, 7]), pull(13, [14, 8, 8]), pull(11, [8, 8, 8, 8]), pull(8, [15, 9, 9]), pull(6, [9, 9, 9, 9]), pull(3, [16, 9, 9]), pull(1, [10, 10, 10, 10])],
                                                  today: "2026-10-22", zone: QuestDay.timeZone)
        if TrainingHistory.fatigueSummary(pulls.json, recovery: [])["decliningLifts"]?.arrayValue?.isEmpty != true || pulls.json["pull up"]?["trend"]?.stringValue == "declining" {
            errors.append("pull-up volume days and max-effort days should not read as a decline, got \(pulls.json["pull up"]?["trendByKind"]?.sortedString() ?? "")")
        }

        // The run window: runs inside the GPS tolerance fill it, and a run the app counted without Strava counts.
        let short = TrainingHistory.runWindow((1...5).map { .object(["km": .number(9.96), "daysAgo": .number(Double($0)), "counts": .string("10K")]) }, goalKm: 50)
        if short["runsToday"]?.arrayValue?.isEmpty != true { errors.append("five 10Ks inside the GPS tolerance should fill the 50 km window") }
        let checked: JSONValue = .object(["dayKey": .string("2026-10-21"), "quests": .array([
            .object(["status": .string("completed"), "unit": .string("km"), "kind": .string("daily"), "target": .number(10)]),
        ])])
        let strava: [JSONValue] = (2...5).map { .object(["date": .string(OnDeviceTime.addDays("2026-10-22", -$0)), "km": .number(10), "daysAgo": .number(Double($0)), "counts": .string("10K")]) }
        if TrainingHistory.runWindow(TrainingHistory.withQuestRuns(strava, questDays: [checked], today: "2026-10-22"), goalKm: 50)["kmLast6Days"]?.doubleValue != 50 {
            errors.append("a run checked by hand should count toward the run window")
        }

        // The template: a blocked leg day with a full run window keeps the day with a light squat, and Deadlift Day keeps every lift.
        var body = QuestPlanner.setting(QuestPlanner.sampleRequest(), ["player", "localDate"], to: .string("2026-10-22"))
        body = QuestPlanner.setting(body, ["constraints", "maxRequiredQuests"], to: .number(Double(MorningConstraints.standard.maxRequiredQuests)))
        func split(_ day: GymSplit.Day) -> JSONValue {
            JSONValue.from(MorningSplit(name: GymSplit.name, rotation: GymSplit.rotation.map(\.name), today: day, lastDone: [:])) ?? .null
        }
        let fullWindow = TrainingHistory.runWindow((2...6).map { .object(["km": .number(10), "daysAgo": .number(Double($0)), "counts": .string("10K")]) }, goalKm: 50, legDay: true)
        var blocked = QuestPlanner.setting(body, ["split"], to: split(GymSplit.squat))
        blocked = QuestPlanner.setting(blocked, ["trainingHistory"], to: .object(["lifts": .object([:]), "runWindow": fullWindow, "strengthSessions": .array([
            .object(["daysAgo": .number(4), "heavyLower": .bool(true)]), .object(["daysAgo": .number(6), "heavyLower": .bool(true)]),
        ])]))
        blocked = QuestPlanner.setting(blocked, ["splitAdvice"], to: .string(QuestPlanner.splitAdvice(blocked)))
        let light = QuestPlanner.sanitize(QuestPlanner.templateBundle(blocked), blocked)
        if !QuestPlanner.titles(light).contains("Squat 3x8") || light["headerLine"]?.stringValue != "Squat Day" || !QuestPlanner.validateBundle(light, blocked).isEmpty {
            errors.append("a blocked leg day with a full run window should keep the day with a light squat, got \(QuestPlanner.titles(light)) \(QuestPlanner.validateBundle(light, blocked))")
        }
        var dead = QuestPlanner.setting(body, ["split"], to: split(GymSplit.deadlift))
        let oneRun = TrainingHistory.runWindow((1...4).map { .object(["km": .number(10), "daysAgo": .number(Double($0)), "counts": .string("10K")]) }, goalKm: 50, legDay: true)
        dead = QuestPlanner.setting(dead, ["trainingHistory"], to: .object(["lifts": .object([:]), "strengthSessions": .array([]), "runWindow": oneRun]))
        let deadPlan = QuestPlanner.titles(QuestPlanner.sanitize(QuestPlanner.templateBundle(dead), dead))
        if deadPlan.count != 9 || !deadPlan.contains(where: { $0.hasPrefix("Farmers Walk") }) {
            errors.append("the template should keep every Deadlift Day lift next to its 10K, got \(deadPlan)")
        }

        // The strict STR targets take no assisted set, and a nap is not the night's sleep.
        if !StrengthLevel.isAssisted("Pull Up (Assisted)") || !StrengthLevel.isAssisted("Chest Dip (Band)") || StrengthLevel.isAssisted("Pull Up (Weighted)") {
            errors.append("assisted and band sets should not count for a strict STR target")
        }
        let naps: JSONValue = .object(["records": .array([
            .object(["nap": .bool(true), "score": .object(["sleep_performance_percentage": .number(22)])]),
            .object(["nap": .bool(false), "score": .object(["sleep_performance_percentage": .number(88)])]),
        ])])
        if WhoopClient.reading(dayKey: "2026-10-22", recovery: nil, cycle: nil, sleep: naps, workouts: nil).sleepPerformance != 88 {
            errors.append("the day's sleep performance should come from the night, not a nap")
        }
        return errors
    }
}
