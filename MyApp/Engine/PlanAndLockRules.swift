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
        // One-set sessions next to max days and volume days are not alike (a test, a day cut short): they fall, and
        // nothing declines. A lift that is always one set is a series, and three falling sessions of it are a decline.
        let withSingles = TrainingHistory.liftSummaries([pull(20, [18]), pull(16, [7, 7, 7, 7]), pull(13, [14, 8, 8]), pull(12, [9]), pull(11, [8, 8, 8, 8]),
                                                         pull(8, [15, 9, 9]), pull(6, [9, 9, 9, 9]), pull(3, [16, 9, 9]), pull(1, [7])],
                                                        today: "2026-10-22", zone: QuestDay.timeZone)
        let singleEntry = withSingles.json["pull up"]
        if TrainingHistory.fatigueSummary(withSingles.json, recovery: [])["decliningLifts"]?.arrayValue?.isEmpty != true
            || singleEntry?["fallingSeries"]?.arrayValue?.isEmpty != true || ["declining", "dropping"].contains(singleEntry?["trend"]?.stringValue ?? "") {
            errors.append("one-set sessions next to max days and volume days should make no falling series, got \(singleEntry?["trendByKind"]?.sortedString() ?? "")")
        }
        let onlySingles = TrainingHistory.liftSummaries([pull(9, [18]), pull(5, [12]), pull(1, [7])], today: "2026-10-22", zone: QuestDay.timeZone)
        let mostlySingles = TrainingHistory.liftSummaries([pull(25, [8, 8, 8]), pull(9, [18]), pull(5, [12]), pull(1, [7])], today: "2026-10-22", zone: QuestDay.timeZone)
        if TrainingHistory.fatigueSummary(onlySingles.json, recovery: [])["decliningLifts"]?.arrayValue?.count != 1
            || TrainingHistory.fatigueSummary(mostlySingles.json, recovery: [])["decliningLifts"]?.arrayValue?.count != 1 {
            errors.append("a lift whose usual work is one set should still show a decline")
        }
        // A max-day block that fell and ended 15 days ago, then one-set days that rise: nothing falls today.
        let endedBlock = TrainingHistory.liftSummaries([pull(21, [16, 9, 9]), pull(18, [14, 8, 8]), pull(15, [12, 7, 7]), pull(6, [10]), pull(3, [11]), pull(1, [12])],
                                                       today: "2026-10-22", zone: QuestDay.timeZone)
        let cutShort = TrainingHistory.liftSummaries([pull(21, [16, 9, 9]), pull(18, [14, 8, 8]), pull(15, [12, 7, 7]), pull(14, [8, 8, 8, 8]), pull(1, [12])],
                                                     today: "2026-10-22", zone: QuestDay.timeZone)
        // Volume days that fall inside the fatigue window, then two one-set days: the lift keeps the falling trend
        // and its advice. The one-set days do not hide it.
        let hidden = TrainingHistory.liftSummaries([pull(12, [12, 12, 12]), pull(9, [10, 10, 10]), pull(6, [8, 8, 8]), pull(3, [14]), pull(1, [10])],
                                                   today: "2026-10-22", zone: QuestDay.timeZone)
        if hidden.json["pull up"]?["trend"]?.stringValue != "dropping" || hidden.json["pull up"]?["advice"]?.stringValue?.contains("Deload") != true {
            errors.append("a series that falls now should give the lift its trend when the newest session is left out, got \(hidden.json["pull up"]?["trend"]?.stringValue ?? "")")
        }
        // Two series fall and the newest session is a left-out single set: the lift takes the one that falls most.
        func weightedPull(_ daysAgo: Int, _ kg: Double, _ reps: Int) -> HevyWorkout {
            let start = morning.addingTimeInterval(Double(-daysAgo) * 86_400)
            return HevyWorkout(id: "wpull-\(daysAgo)", title: "Gym", start: start, end: start.addingTimeInterval(3_600),
                               exercises: [HevyExercise(title: "Pull Up", templateId: nil, sets: Array(repeating: HevySet(type: "normal", reps: reps, weightKg: kg, rpe: nil, durationSec: nil), count: 3))])
        }
        let twoFall = TrainingHistory.liftSummaries([weightedPull(13, 30, 5), weightedPull(11, 10, 12), weightedPull(9, 32, 5), weightedPull(7, 10, 10),
                                                     weightedPull(5, 28, 5), weightedPull(3, 10, 8), pull(1, [10])], today: "2026-10-22", zone: QuestDay.timeZone)
        if twoFall.json["pull up"]?["fallingSeries"]?.arrayValue?.count != 2 || twoFall.json["pull up"]?["trend"]?.stringValue != "dropping" {
            errors.append("with two falling series the lift should take the one that drops, got \(twoFall.json["pull up"]?["trend"]?.stringValue ?? "") \(twoFall.json["pull up"]?["trendByKind"]?.sortedString() ?? "")")
        }
        for (name, history) in [("usual", endedBlock), ("left out", cutShort)] {
            if TrainingHistory.fatigueSummary(history.json, recovery: [])["decliningLifts"]?.arrayValue?.isEmpty != true
                || ["declining", "dropping"].contains(history.json["pull up"]?["trend"]?.stringValue ?? "") {
                errors.append("a falling block that ended 15 days ago is no decline today (\(name)), got \(history.json["pull up"]?["trend"]?.stringValue ?? "") \(history.json["pull up"]?["trendByKind"]?.sortedString() ?? "")")
            }
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

        // "No gym today": the added 10K stands for the lifts, so it takes no hand check and the run potion leaves it.
        var noGym = GameSnapshot.fresh(catalog: catalog, now: morning)
        _ = noGym.setNoGym(true, catalog: catalog, now: morning)
        let runRows = noGym.bundle.quests.filter { TrainingDay.isRaceRun($0) }
        if runRows.filter(\.allowsCheckOff).count != 1 || runRows.first(where: \.isNoGymRun)?.allowsCheckOff != false
            || noGym.potionTargets(.secondWind).contains(where: \.isNoGymRun) || noGym.potionTargets(.secondWind).count != 1 {
            errors.append("the added 10K of a no-gym day should take no hand check and no run potion")
        }

        // One real 10K and one hand check finish the two runs of a no-gym day in both orders: the real run fills the
        // added 10K, which comes first, and the day's run keeps its hand check.
        if runRows.first?.isNoGymRun != true { errors.append("the added 10K should come before the day's run") }
        func realRun(_ id: String) -> Evidence { Evidence.make(source: "strava", externalId: "workout:strava:\(id)", payload: id, timestamp: morning) }
        for handFirst in [true, false] {
            var day = noGym
            let dayRun = day.bundle.quests.first { TrainingDay.isRaceRun($0) && !$0.isNoGymRun }
            let firstOpen = { (snapshot: GameSnapshot) in snapshot.bundle.quests.first { TrainingDay.isRaceRun($0) && $0.status != .completed } }
            if handFirst, let dayRun { _ = day.applyLocalOverride(questId: dayRun.id, now: morning) }
            if let row = firstOpen(day) { _ = day.apply(.completed(evidence: realRun("order")), questId: row.id, now: morning) }
            if !handFirst, let dayRun { _ = day.applyLocalOverride(questId: dayRun.id, now: morning) }
            if firstOpen(day) != nil { errors.append("one real 10K and one hand check should finish a no-gym day's runs, hand check first: \(handFirst)") }
        }
        // A 7 km run on a no-gym day whose own run is a 5K: the 5K takes the run, and the added 10K, which is
        // checked first, shows none of it. A second, 3 km run that no row used does show there.
        var shortDay = noGym
        if let index = shortDay.bundle.quests.firstIndex(where: { TrainingDay.isRaceRun($0) && !$0.isNoGymRun }) {
            shortDay.bundle.quests[index].verification.params["minDistanceMeters"] = .number(5_000)
            shortDay.bundle.quests[index].progress.target = 5
            func run(_ id: String, meters: Double, after seconds: TimeInterval) -> WorkoutEvent {
                let start = morning.addingTimeInterval(seconds)
                return WorkoutEvent(source: "strava", externalId: id, sport: "Run", start: start, end: start.addingTimeInterval(2_400),
                                    movingTimeSec: 2_400, distanceMeters: meters)
            }
            func data(_ runs: [WorkoutEvent]) -> DayIntegrationSnapshot {
                DayIntegrationSnapshot.make(
                    whoop: .disconnected(dayKey: shortDay.bundle.dayKey, reason: ""),
                    strava: StravaDayReading(available: true, configured: true, reason: "", dayKey: shortDay.bundle.dayKey, activities: runs),
                    health: HealthDaySummary(access: .requested, workouts: [])
                )
            }
            func added(_ snapshot: GameSnapshot) -> Double? { snapshot.bundle.quests.first(where: \.isNoGymRun)?.progress.current }
            let seven = run("short-7", meters: 7_000, after: 3_600), three = run("short-3", meters: 3_000, after: 14_400)
            var one = shortDay
            for _ in 0..<2 { one.checkOpenRows(integrations: data([seven]), now: morning.addingTimeInterval(20_000), skipping: [.manualConfirm, .timerSession]) }
            if one.bundle.quests[index].status != .completed || added(one) != 0 {
                errors.append("a 7 km run that the day's 5K used should be no progress for the added 10K, got \(String(describing: added(one)))")
            }
            var two = shortDay
            two.checkOpenRows(integrations: data([seven, three]), now: morning.addingTimeInterval(20_000), skipping: [.manualConfirm, .timerSession])
            if two.bundle.quests[index].status != .completed || added(two) != 3 {
                errors.append("a 3 km run that no row used should show on the added 10K, got \(String(describing: added(two)))")
            }
        } else {
            errors.append("a no-gym day should hold the day's own run")
        }

        // Runs for the checks below: Strava's, or Apple Health's alone.
        let passNow = morning.addingTimeInterval(20_000)
        func recorded(_ source: String, _ id: String, meters: Double, after seconds: TimeInterval) -> WorkoutEvent {
            let start = morning.addingTimeInterval(seconds)
            return WorkoutEvent(source: source, externalId: id, sport: source == "strava" ? "Run" : "running", start: start,
                                end: start.addingTimeInterval(2_400), movingTimeSec: 2_400, distanceMeters: meters)
        }
        func dayData(strava: [WorkoutEvent], health: [WorkoutEvent] = []) -> DayIntegrationSnapshot {
            DayIntegrationSnapshot.make(
                whoop: .disconnected(dayKey: noGym.bundle.dayKey, reason: ""),
                strava: StravaDayReading(available: true, configured: true, reason: "", dayKey: noGym.bundle.dayKey, activities: strava),
                health: HealthDaySummary(access: .requested, workouts: health)
            )
        }
        func rowsText(_ snapshot: GameSnapshot) -> [String] {
            snapshot.bundle.quests.filter { $0.progress.unit == "km" }.map { "\($0.title) \($0.progress.current) \($0.status.rawValue)" }
        }
        let passSkips: Set<VerificationMethod> = [.manualConfirm, .timerSession]

        // A penalty day with a 5K: the 7 km run shows through Apple Health first, on the Penalty 10K. Strava has it
        // in a later pass and the 5K takes it. The penalty row then shows none of it, as in one pass.
        var owes = GameSnapshot.fresh(catalog: catalog, now: morning)
        owes.player.penaltyOpen = true
        owes.rebuildBundle(catalog: catalog, now: morning)
        if let index = owes.bundle.quests.firstIndex(where: { $0.kind == .daily && TrainingDay.isRaceRun($0) }),
           let penalty = PenaltyQuests.rows(in: owes.bundle).first {
            var twoPass = owes
            twoPass.bundle.quests[index].verification.params["minDistanceMeters"] = .number(5_000)
            twoPass.bundle.quests[index].progress.target = 5
            let inHealth = recorded("healthkit", "late-hk", meters: 7_000, after: 3_600), inStrava = recorded("strava", "late-strava", meters: 7_000, after: 3_620)
            twoPass.checkOpenRows(integrations: dayData(strava: [], health: [inHealth]), now: passNow, skipping: passSkips)
            let first = twoPass.bundle.quests.first { $0.id == penalty.id }?.progress.current
            twoPass.checkOpenRows(integrations: dayData(strava: [inStrava], health: [inHealth]), now: passNow, skipping: passSkips)
            if first != 7 || twoPass.bundle.quests[index].status != .completed || twoPass.bundle.quests.first(where: { $0.id == penalty.id })?.progress.current != 0 {
                errors.append("a run that a row used in a later pass should leave the row that showed it, got \(String(describing: first)) then \(rowsText(twoPass))")
            }
            // A 10 km run clears the penalty. The 7 km run that no row used shows on the day's 10K.
            var both = owes
            both.checkOpenRows(integrations: dayData(strava: [recorded("strava", "pen-10", meters: 10_020, after: 3_600), recorded("strava", "pen-7", meters: 7_000, after: 14_400)]),
                               now: passNow, skipping: passSkips)
            if both.player.penaltyOpen || both.bundle.quests[index].progress.current != 7 || both.bundle.quests[index].status == .completed {
                errors.append("a shorter run that no row used should show on the day's 10K after the penalty took the long one, got \(rowsText(both))")
            }
            // Apple Health gives no workouts in a later pass (the phone is locked), and Strava holds another run
            // that the 5K takes. The 7 km on the penalty row is from a run that no row used: it stays.
            var locked = owes
            locked.bundle.quests[index].verification.params["minDistanceMeters"] = .number(5_000)
            locked.bundle.quests[index].progress.target = 5
            locked.checkOpenRows(integrations: dayData(strava: [], health: [recorded("healthkit", "kept-hk", meters: 7_000, after: 3_600)]), now: passNow, skipping: passSkips)
            locked.checkOpenRows(integrations: dayData(strava: [recorded("strava", "kept-strava", meters: 5_200, after: 14_400)]), now: passNow, skipping: passSkips)
            if locked.bundle.quests[index].status != .completed || locked.bundle.quests.first(where: { $0.id == penalty.id })?.progress.current != 7 {
                errors.append("a pass whose source gives no workouts should take no progress away, got \(rowsText(locked))")
            }
            // The two sources measure one run differently: Apple Health 7.04 km first, then Strava alone 6.98 km.
            // It is one run by its time, so the penalty row gives it up when the 5K takes it.
            var twoSources = owes
            twoSources.bundle.quests[index].verification.params["minDistanceMeters"] = .number(5_000)
            twoSources.bundle.quests[index].progress.target = 5
            let fiveKDay = twoSources
            twoSources.checkOpenRows(integrations: dayData(strava: [], health: [recorded("healthkit", "src-hk", meters: 7_040, after: 3_600)]), now: passNow, skipping: passSkips)
            twoSources.checkOpenRows(integrations: dayData(strava: [recorded("strava", "src-strava", meters: 6_980, after: 3_620)]), now: passNow, skipping: passSkips)
            if twoSources.bundle.quests[index].status != .completed || twoSources.bundle.quests.first(where: { $0.id == penalty.id })?.progress.current != 0 {
                errors.append("one run that two sources measure differently should leave the row that showed it, got \(rowsText(twoSources))")
            }
            // Two runs of the same length: Strava's finished the 5K, and Apple Health's alone shows on the penalty row.
            // A pass with no Health data holds only the used run. The other run's progress stays.
            var sameLength = fiveKDay
            let usedRun = recorded("strava", "same-a", meters: 5_020, after: 3_600), freeRun = recorded("healthkit", "same-b", meters: 5_040, after: 14_400)
            sameLength.checkOpenRows(integrations: dayData(strava: [usedRun]), now: passNow, skipping: passSkips)
            sameLength.checkOpenRows(integrations: dayData(strava: [usedRun], health: [freeRun]), now: passNow, skipping: passSkips)
            let withHealth = sameLength.bundle.quests.first { $0.id == penalty.id }?.progress.current
            sameLength.checkOpenRows(integrations: dayData(strava: [usedRun]), now: passNow, skipping: passSkips)
            if withHealth != 5 || sameLength.bundle.quests.first(where: { $0.id == penalty.id })?.progress.current != 5 {
                errors.append("a used run of the same length should take no progress from the row that shows another run, got \(String(describing: withHealth)) then \(rowsText(sameLength))")
            }
        } else {
            errors.append("a penalty day should hold a penalty row and the day's run")
        }

        // A gym day whose run is a 5K, and a real 10 km run before "No gym today": the run fills the added 10K and
        // the 5K is open with its hand check. A 7 km run stays on the 5K. Off gives the gym day back. No cue plays,
        // and Beyond the Limit stays with the row that holds the run.
        var fiveK = GameSnapshot.fresh(catalog: catalog, now: morning)
        if let index = fiveK.bundle.quests.firstIndex(where: { $0.kind == .daily && TrainingDay.isRaceRun($0) }) {
            fiveK.bundle.quests[index].verification.params["minDistanceMeters"] = .number(5_000)
            fiveK.bundle.quests[index].progress.target = 5
            let dayId = fiveK.bundle.quests[index].id, addedId = NoGymDay.addedId(fiveK.bundle.dayKey)
            func status(_ snapshot: GameSnapshot, _ id: String) -> QuestStatus? { snapshot.bundle.quests.first { $0.id == id }?.status }
            for (meters, moves) in [(16_000.0, true), (10_020.0, true), (7_000.0, false)] {
                let data = dayData(strava: [recorded("strava", "five-\(Int(meters))", meters: meters, after: 3_600)])
                var day = fiveK
                day.checkOpenRows(integrations: data, now: passNow, skipping: passSkips)
                _ = day.checkHiddenQuests(integrations: data, now: passNow)
                let gymDay = day
                _ = day.setNoGym(true, catalog: catalog, now: passNow, integrations: data)
                if (status(day, addedId) == .completed) != moves || (status(day, dayId) == .completed) == moves {
                    errors.append("a real run of \(Int(meters)) m on a 5K before no gym: the added 10K should \(moves ? "" : "not ")take it, got \(rowsText(day))")
                }
                if SoundCues.sounds(from: gymDay, to: day).contains(.questComplete) { errors.append("no gym on should play no quest cue for a run that was done before") }
                if meters == 16_000, day.beyondTheLimitToday?.questId != addedId || gymDay.beyondTheLimitToday?.questId != dayId {
                    errors.append("Beyond the Limit should go with the run to the added 10K, got \(String(describing: day.beyondTheLimitToday?.questId))")
                }
                var again = day
                again.checkOpenRows(integrations: data, now: passNow, skipping: passSkips)
                if again.bundle != day.bundle { errors.append("the run that moved to the added 10K should not fill the 5K again, got \(rowsText(again))") }
                let on = day
                _ = day.setNoGym(false, catalog: catalog, now: passNow, integrations: data)
                if day.bundle.quests.map(\.id) != gymDay.bundle.quests.map(\.id) || status(day, dayId) != .completed || day.beyondTheLimitToday?.questId != gymDay.beyondTheLimitToday?.questId
                    || day.bundle.quests[index].progress.current != gymDay.bundle.quests[index].progress.current {
                    errors.append("no gym off should give the 5K day back with its run done, got \(rowsText(day))")
                }
                if SoundCues.sounds(from: on, to: day).contains(.questComplete) { errors.append("no gym off should play no quest cue for a run that was done before") }
            }
            // A 9.96 km run counts as 10 km. With no data at the switch nothing shows that, so the next pass with
            // the data moves the run. Off gives the 5K back with the distance it showed, 9.9 km.
            let near = dayData(strava: [recorded("strava", "five-near", meters: 9_960, after: 3_600)])
            var late = fiveK
            late.checkOpenRows(integrations: near, now: passNow, skipping: passSkips)
            _ = late.checkHiddenQuests(integrations: near, now: passNow)
            let nearDay = late
            _ = late.setNoGym(true, catalog: catalog, now: passNow)
            let atSwitch = status(late, addedId)
            late.checkOpenRows(integrations: near, now: passNow, skipping: passSkips)
            if atSwitch == .completed || status(late, addedId) != .completed || status(late, dayId) == .completed {
                errors.append("a 9.96 km run on a 5K should go to the added 10K in the first pass that has the data, got \(rowsText(late))")
            }
            _ = late.setNoGym(false, catalog: catalog, now: passNow, integrations: near)
            if late.bundle.quests[index].progress.current != nearDay.bundle.quests[index].progress.current || status(late, dayId) != .completed {
                errors.append("no gym off should give the 5K its own distance back, got \(rowsText(late)) expected \(rowsText(nearDay))")
            }
            // A 12 km run on the added 10K is under that row's 15 km. Off moves it to the 5K: it is still measured
            // against 10 km, so the switch pays no Beyond the Limit gold. On a gym day the same run on the 5K earns it.
            let twelve = dayData(strava: [recorded("strava", "five-12", meters: 12_000, after: 3_600)])
            var paid = fiveK
            _ = paid.setNoGym(true, catalog: catalog, now: passNow, integrations: twelve)
            paid.checkOpenRows(integrations: twelve, now: passNow, skipping: passSkips)
            _ = paid.checkHiddenQuests(integrations: twelve, now: passNow)
            let goldOn = paid.gold
            _ = paid.setNoGym(false, catalog: catalog, now: passNow, integrations: twelve)
            paid.checkOpenRows(integrations: twelve, now: passNow, skipping: passSkips)
            _ = paid.checkHiddenQuests(integrations: twelve, now: passNow)
            var direct = fiveK
            direct.checkOpenRows(integrations: twelve, now: passNow, skipping: passSkips)
            _ = direct.checkHiddenQuests(integrations: twelve, now: passNow)
            if status(paid, dayId) != .completed || paid.beyondTheLimitToday != nil || paid.gold != goldOn || direct.beyondTheLimitToday == nil {
                errors.append("no gym off should pay no Beyond the Limit gold for a 12 km run done on the added 10K, got \(rowsText(paid)) gold \(goldOn) -> \(paid.gold)")
            }
        } else {
            errors.append("a fresh day should hold a run")
        }

        // The run is the last open row. "No gym today" on, a real 10K on the added row, then off: the run is the
        // day's run and the day is complete. That plays the day cue, and no quest cue.
        var lastRow = GameSnapshot.fresh(catalog: catalog, now: morning)
        let proof = { (id: String) in Evidence.make(source: "plan_check", externalId: "plan:\(id)", payload: id, timestamp: morning) }
        for quest in lastRow.bundle.quests where !TrainingDay.isRaceRun(quest) {
            lastRow.apply(.completed(evidence: proof(quest.id)), questId: quest.id, now: morning)
        }
        _ = lastRow.setNoGym(true, catalog: catalog, now: morning)
        if let addedRow = lastRow.bundle.quests.first(where: \.isNoGymRun) {
            lastRow.apply(.completed(evidence: realRun("last-row")), questId: addedRow.id, now: morning)
            let beforeOff = lastRow
            _ = lastRow.setNoGym(false, catalog: catalog, now: morning)
            let cues = SoundCues.sounds(from: beforeOff, to: lastRow)
            // After the day cue played for this day, the same move is nothing new.
            if SoundCues.sounds(from: beforeOff, to: lastRow, dayCuePlayed: true).contains(.dayClear) {
                errors.append("a run that only moves should not play the day cue a second time")
            }
            if !beforeOff.missesRequiredSet || lastRow.missesRequiredSet || !cues.contains(.dayClear) || cues.contains(.questComplete) {
                errors.append("no gym off that completes the day should play the day cue, got \(cues) misses \(beforeOff.missesRequiredSet) -> \(lastRow.missesRequiredSet)")
            }
        } else {
            errors.append("a day with its lifts done should still get the added 10K")
        }

        // Pull-ups: a volume day whose reps fall off, and a session of one set, join no max-effort series.
        if TrainingHistory.repsKind([10, 8, 7, 6]) != "reps volume" || TrainingHistory.repsKind([16, 9, 9]) != "reps max"
            || TrainingHistory.repsKind([14, 8]) != "reps max" || TrainingHistory.repsKind([10]) != "reps single" {
            errors.append("a bodyweight session should be a max day only when its best set is far above the next one")
        }

        // A rest day keeps a finished penalty row. A new penalty that waits there is not closed by another row.
        var waits = GameSnapshot.fresh(catalog: catalog, now: morning)
        waits.player.penaltyOpen = true
        waits.rebuildBundle(catalog: catalog, now: morning)
        if let row = PenaltyQuests.rows(in: waits.bundle).first {
            waits.apply(.completed(evidence: Evidence.make(source: "plan_check", externalId: "plan:served", payload: "served", timestamp: morning)), questId: row.id, now: morning)
        }
        _ = waits.spendFullRecovery(catalog: catalog, now: morning)
        waits.player.penaltyOpen = true
        if let stretch = waits.bundle.quests.first(where: { $0.id == DailyStretch.questId }) {
            waits.apply(.completed(evidence: Evidence.make(source: "plan_check", externalId: "plan:stretch", payload: "stretch", timestamp: morning)), questId: stretch.id, now: morning)
        }
        waits.refreshIfNeeded(catalog: catalog, now: morning.addingTimeInterval(86_400))
        if !waits.player.penaltyOpen || PenaltyQuests.rows(in: waits.bundle).filter({ $0.status != .completed }).count != 1 {
            errors.append("a penalty that waits on a rest day should come back the next day, whatever row completes there")
        }

        // The Hevy check and the custom goals use one name rule, and a stand-in with its own row counts there only.
        func hevyData(_ title: String, sets: Int) -> DayIntegrationSnapshot {
            var data = DayIntegrationSnapshot.empty(dayKey: "2026-10-22")
            let done = Array(repeating: HevySet(type: "normal", reps: 10, weightKg: 40, rpe: nil, durationSec: nil), count: sets)
            data.hevy = HevyDayReading(available: true, configured: true, reason: "", dayKey: "2026-10-22",
                                       workouts: [HevyWorkout(id: "plan-hevy", title: "Gym", start: morning, end: morning.addingTimeInterval(3_600),
                                                              exercises: [HevyExercise(title: title, templateId: nil, sets: done)])])
            return data
        }
        func lift(_ exercise: String, sets: Int) -> Quest {
            Quest(id: "q_2026-10-22_\(exercise.lowercased())", title: exercise, kind: .daily, stat: .STR,
                  verification: VerificationSpec(method: .hevySets, params: ["exercise": .string(exercise), "sets": .number(Double(sets)), "minReps": .number(8)]),
                  deadline: morning, difficulty: .normal, mode: .performanceTraining, progress: QuestProgress(current: 0, target: Double(sets), unit: "sets"), status: .pending)
        }
        func completes(_ quest: Quest, _ data: DayIntegrationSnapshot, others: Set<String> = []) -> Bool {
            let context = VerificationContext(now: morning, dayKey: "2026-10-22", assignedAt: morning, manualConfirmsToday: 0, claimedKeys: [],
                                              timerElapsedSec: nil, userConfirmed: false, integrations: data, otherExercises: others)
            if case .completed = HevySetsVerifier().evaluate(quest: quest, context: context) { return true }
            return false
        }
        if !completes(lift("Hip-Thrust", sets: 3), hevyData("Hip Thrust (Barbell)", sets: 3)) {
            errors.append("a goal typed as Hip-Thrust should complete from Hevy's Hip Thrust (Barbell)")
        }
        if !completes(lift("Bicep Curl", sets: 4), hevyData("Hammer Curl (Dumbbell)", sets: 4))
            || completes(lift("Bicep Curl", sets: 4), hevyData("Hammer Curl (Dumbbell)", sets: 4), others: ["hammer curl"]) {
            errors.append("a stand-in should count for the lift, but not when it has its own row today")
        }

        // The repeat price holds on the first day a 30-day potion is free again.
        var shop = GameSnapshot.fresh(catalog: catalog, now: morning)
        shop.gold = 1_000_000
        _ = shop.usePotion(.gildedIndulgence)
        shop.bundle.dayKey = QuestDay.key(byAddingDays: Potion.repeatWindowDays, to: shop.bundle.dayKey)
        if shop.potionBlocker(.gildedIndulgence) != nil || shop.potionPrice(.gildedIndulgence) != Potion.gildedIndulgence.basePrice * 3 / 2 {
            errors.append("a second Gilded Indulgence on the first free day should cost 150%, got \(shop.potionPrice(.gildedIndulgence))")
        }

        // One history row that cannot be read costs that row, not the save.
        let savedUses = Data(#"[{"dayKey":"2026-10-01","potion":"ironblood"},{"dayKey":"2026-10-02","potion":"a potion that was removed"},{"dayKey":"2026-10-03","potion":"nightfall"}]"#.utf8)
        if (try? JSONDecoder().decode(LossyArray<PotionUse>.self, from: savedUses))?.elements.map(\.dayKey) != ["2026-10-01", "2026-10-03"] {
            errors.append("a list should drop only the elements it cannot read")
        }

        // The set limit: 3 for every lift and 4 for pull-ups, also for a plan or a saved day that asks for more.
        var wide = GameSnapshot.fresh(catalog: catalog, now: morning)
        for index in wide.bundle.quests.indices where wide.bundle.quests[index].verification.method == .hevySets && wide.bundle.quests[index].id != DailyStretch.questId {
            wide.bundle.quests[index].verification.params["sets"] = .number(5)
            wide.bundle.quests[index].progress.target = 5
            wide.bundle.quests[index].title = "\(wide.bundle.quests[index].verification.params["exercise"]?.stringValue ?? "Lift") 5×8"
        }
        wide.bundle = wide.finished(wide.bundle, catalog: catalog, now: morning)
        let capped = wide.bundle.quests.filter { $0.verification.method == .hevySets && $0.id != DailyStretch.questId }
        let wrong = capped.filter { row in
            let limit = GymSplit.maxSets(for: row.verification.params["exercise"]?.stringValue ?? "")
            return row.verification.params["sets"]?.doubleValue != Double(limit) || row.progress.target != Double(limit) || !row.title.contains("\(limit)×8")
        }
        if capped.isEmpty || !wrong.isEmpty || capped.first(where: { $0.title.hasPrefix("Pull Up") })?.progress.target != 4 {
            errors.append("a day should hold at most 3 sets a lift and 4 for pull-ups, got \(wrong.map(\.title))")
        }
        // The gym row adds up sets: a lift with 2 of 3 sets counts 2, a timed row counts its share, a done row all.
        var twoSets = lift("Bench Press", sets: 3)
        twoSets.progress.current = 2
        var hold = Quest(id: "q_2026-10-22_dead_hang", title: "Dead Hang 3×60s", kind: .daily, stat: .STR,
                         verification: VerificationSpec(method: .hevySets, params: ["exercise": .string("Dead Hang"), "sets": .number(3), "minDurationSec": .number(180)]),
                         deadline: morning, difficulty: .normal, mode: .performanceTraining, progress: QuestProgress(current: 1, target: 3, unit: "min"), status: .pending)
        if twoSets.liftSets != (2, 3) || hold.liftSets != (1, 3) { errors.append("the gym row should count the sets done of an open lift") }
        hold.status = .completed
        if hold.liftSets != (3, 3) { errors.append("a finished lift should count all its sets") }

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
