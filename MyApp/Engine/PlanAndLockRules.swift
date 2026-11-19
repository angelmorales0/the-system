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
        // The series that only declines (heavy) has the newer session, so "the newest series" would pick it.
        let twoFall = TrainingHistory.liftSummaries([weightedPull(13, 10, 12), weightedPull(11, 30, 5), weightedPull(9, 10, 10), weightedPull(7, 32, 5),
                                                     weightedPull(5, 10, 8), weightedPull(3, 28, 5), pull(1, [10])], today: "2026-10-22", zone: QuestDay.timeZone)
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

        // The template: a blocked leg day with a full run window keeps the day with a light squat, and Lower Day keeps every lift.
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
        if deadPlan.count != 8 || !deadPlan.contains(where: { $0.hasPrefix("Farmers Walk") }) || deadPlan.contains(where: { $0.hasPrefix("Deadlift") }) {
            errors.append("the template should keep every Lower Day lift next to its 10K, got \(deadPlan)")
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
        // checked first, shows none of it.
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
            // The runs of the day add together: 7 km and 3 km finish the added 10K, which is checked first.
            // The day's 5K is open then, with its hand check.
            var two = shortDay
            for _ in 0..<2 { two.checkOpenRows(integrations: data([seven, three]), now: morning.addingTimeInterval(20_000), skipping: [.manualConfirm, .timerSession]) }
            if two.bundle.quests.first(where: \.isNoGymRun)?.status != .completed || two.bundle.quests[index].status == .completed || two.bundle.quests[index].progress.current != 0 {
                errors.append("7 km and 3 km should finish the added 10K and leave the day's 5K open, got \(two.bundle.quests.filter { $0.progress.unit == "km" }.map { "\($0.id) \($0.progress.current) \($0.status.rawValue)" })")
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

        // A penalty day: [Penalty 10K, the day's run]. The penalty row takes a run from any source, the day's run
        // takes Strava's. `fiveKDay` has a 5K as the day's run.
        var owes = GameSnapshot.fresh(catalog: catalog, now: morning)
        owes.player.penaltyOpen = true
        owes.rebuildBundle(catalog: catalog, now: morning)
        if let index = owes.bundle.quests.firstIndex(where: { $0.kind == .daily && TrainingDay.isRaceRun($0) }),
           let penalty = PenaltyQuests.rows(in: owes.bundle).first {
            var fiveKDay = owes
            fiveKDay.bundle.quests[index].verification.params["minDistanceMeters"] = .number(5_000)
            fiveKDay.bundle.quests[index].progress.target = 5
            func shows(_ snapshot: GameSnapshot) -> Double? { snapshot.bundle.quests.first { $0.id == penalty.id }?.progress.current }
            func done(_ snapshot: GameSnapshot, _ id: String) -> Bool { snapshot.bundle.quests.first { $0.id == id }?.status == .completed }
            let dayId = owes.bundle.quests[index].id
            /// Runs each pass two times. The second time must change nothing: rows and the notes of runs.
            func passes(_ snapshot: inout GameSnapshot, _ label: String, _ steps: [DayIntegrationSnapshot]) {
                for step in steps {
                    snapshot.checkOpenRows(integrations: step, now: passNow, skipping: passSkips)
                    let once = snapshot
                    snapshot.checkOpenRows(integrations: step, now: passNow, skipping: passSkips)
                    if snapshot.bundle != once.bundle || snapshot.progressLog != once.progressLog || snapshot.evidenceLog != once.evidenceLog {
                        errors.append("a second pass with the same data should change nothing (\(label)), got \(rowsText(once)) then \(rowsText(snapshot))")
                    }
                }
            }

            // The runs of the day add together. Two 5 km runs finish the Penalty 10K, and the day's 10K gets none
            // of them: one run counts for one row.
            var split = owes
            passes(&split, "two 5 km", [dayData(strava: [recorded("strava", "split-a", meters: 5_020, after: 3_600), recorded("strava", "split-b", meters: 5_000, after: 14_400)])])
            if split.player.penaltyOpen || !done(split, penalty.id) || done(split, dayId) || split.bundle.quests[index].progress.current != 0 {
                errors.append("two 5 km runs should finish the Penalty 10K and leave the day's 10K at 0, got \(rowsText(split))")
            }
            // 5 km and 4.9 km are 9.9 km: under the 10 km less the 50 m of tolerance. Both open rows show 9.9.
            var under = owes
            passes(&under, "9.9 km", [dayData(strava: [recorded("strava", "under-a", meters: 5_000, after: 3_600), recorded("strava", "under-b", meters: 4_900, after: 14_400)])])
            if done(under, penalty.id) || shows(under) != 9.9 || under.bundle.quests[index].progress.current != 9.9 {
                errors.append("5 km and 4.9 km should show 9.9 km on both open 10K rows, got \(rowsText(under))")
            }
            // A third run of 6 km: the penalty row takes the 6 km and the 5 km (11 km), and the 4.9 km stays for the day's 10K.
            passes(&under, "third run", [dayData(strava: [recorded("strava", "under-a", meters: 5_000, after: 3_600), recorded("strava", "under-b", meters: 4_900, after: 14_400),
                                                          recorded("strava", "under-c", meters: 6_000, after: 25_200)])])
            if !done(under, penalty.id) || done(under, dayId) || under.bundle.quests[index].progress.current != 4.9 {
                errors.append("the penalty row should take the longest runs it needs and leave the rest, got \(rowsText(under))")
            }
            // One run of 10 km finishes the row alone. The 7 km run stays for the day's 10K.
            var both = owes
            passes(&both, "10 and 7", [dayData(strava: [recorded("strava", "pen-10", meters: 10_020, after: 3_600), recorded("strava", "pen-7", meters: 7_000, after: 14_400)])])
            if both.player.penaltyOpen || both.bundle.quests[index].progress.current != 7 || done(both, dayId) {
                errors.append("a 10 km run should finish the penalty alone and leave the 7 km run for the day's 10K, got \(rowsText(both))")
            }
            // Two recordings of one run, in Strava and in Apple Health, are one run: 5 km, not 10.
            var copies = owes
            passes(&copies, "two sources", [dayData(strava: [recorded("strava", "copy-s", meters: 5_020, after: 3_620)], health: [recorded("healthkit", "copy-h", meters: 5_000, after: 3_600)])])
            if done(copies, penalty.id) || shows(copies) != 5 {
                errors.append("one run in two sources should count one time, got \(rowsText(copies))")
            }
            // A short run, and a second run that starts as the first one ends, are two runs: 1 km and 9 km finish the row.
            var restart = owes
            let falseStart = WorkoutEvent(source: "strava", externalId: "restart-a", sport: "Run", start: morning.addingTimeInterval(3_600),
                                          end: morning.addingTimeInterval(4_080), movingTimeSec: 480, distanceMeters: 1_000)
            let realRun = WorkoutEvent(source: "strava", externalId: "restart-b", sport: "Run", start: morning.addingTimeInterval(4_140),
                                       end: morning.addingTimeInterval(7_200), movingTimeSec: 3_000, distanceMeters: 9_000)
            passes(&restart, "restart", [dayData(strava: [falseStart, realRun])])
            if !done(restart, penalty.id) {
                errors.append("a short run and a run that starts as it ends should both count, got \(rowsText(restart))")
            }

            // One run shows through Apple Health first (7.04 km), then through Strava alone (6.98 km). It is one run
            // by its time, so the penalty row gives it up when the 5K takes it.
            var twoSources = fiveKDay
            passes(&twoSources, "health then strava", [dayData(strava: [], health: [recorded("healthkit", "src-hk", meters: 7_040, after: 3_600)])])
            let first = shows(twoSources)
            passes(&twoSources, "health then strava", [dayData(strava: [recorded("strava", "src-strava", meters: 6_980, after: 3_620)])])
            if first != 7 || !done(twoSources, dayId) || shows(twoSources) != 0 {
                errors.append("one run that two sources measure differently should leave the row that showed it, got \(String(describing: first)) then \(rowsText(twoSources))")
            }
            // Apple Health alone holds a 3 km run. A pass with no Health data (a locked phone) brings a 5.2 km Strava
            // run that the 5K takes. The penalty row keeps the 3 km: a source that gives no workouts takes nothing away.
            var locked = fiveKDay
            passes(&locked, "locked phone", [dayData(strava: [], health: [recorded("healthkit", "kept-hk", meters: 3_000, after: 3_600)]),
                                             dayData(strava: [recorded("strava", "kept-strava", meters: 5_200, after: 14_400)])])
            if !done(locked, dayId) || shows(locked) != 3 {
                errors.append("a pass whose source gives no workouts should take no progress away, got \(rowsText(locked))")
            }
            // The Health run and a later Strava run add up across passes, also when the pass lacks Health: 5.04 km
            // and 5.02 km finish the penalty.
            var across = fiveKDay
            passes(&across, "across passes", [dayData(strava: [], health: [recorded("healthkit", "sum-hk", meters: 5_040, after: 3_600)]),
                                              dayData(strava: [recorded("strava", "sum-strava", meters: 5_020, after: 14_400)])])
            if across.player.penaltyOpen || done(across, dayId) {
                errors.append("a Health run and a later Strava run should add up for the penalty, got \(rowsText(across))")
            }
            // Two runs from Apple Health in one pass, 5.5 km and 3 km: the row shows 8.5. A pass with no Health data
            // gives the Strava copy of the 5.5 km to the 5K. The row shows the 3 km, which no row used.
            var together = fiveKDay
            passes(&together, "pair", [dayData(strava: [], health: [recorded("healthkit", "pair-5", meters: 5_500, after: 3_600), recorded("healthkit", "pair-3", meters: 3_000, after: 14_400)])])
            let pair = shows(together)
            passes(&together, "pair", [dayData(strava: [recorded("strava", "pair-copy", meters: 5_500, after: 3_620)])])
            if pair != 8.5 || !done(together, dayId) || shows(together) != 3 {
                errors.append("a row should keep the run that no row used when another row takes one, got \(String(describing: pair)) then \(rowsText(together))")
            }
            // One run reads 5.02 km in Apple Health and 4.96 km in Strava. A pass with Strava alone adds a 2 km run.
            // The run is as long as its longest reading: 5.02 + 2 = 7.0 km, not 6.9.
            var readings = owes
            passes(&readings, "readings", [dayData(strava: [], health: [recorded("healthkit", "read-hk", meters: 5_020, after: 3_600)]),
                                           dayData(strava: [recorded("strava", "read-other", meters: 2_000, after: 14_400), recorded("strava", "read-strava", meters: 4_960, after: 3_620)])])
            if shows(readings) != 7 || readings.bundle.quests[index].progress.current != 6.9 {
                errors.append("a run keeps its longest reading when another source measures it shorter, got \(rowsText(readings))")
            }
            // The same runs give the same rows, whenever the app read them. 3 km, 2.5 km, and 6 km: read one by
            // one, the 5K is done by the first two, and the 6 km then gives all three to the penalty row, which
            // comes first. The 5K is open again, as after one read of all three.
            let parts = [recorded("strava", "part-3", meters: 3_000, after: 3_600), recorded("strava", "part-2", meters: 2_500, after: 14_400),
                         recorded("strava", "part-6", meters: 6_000, after: 25_200)]
            var oneByOne = fiveKDay, atOnce = fiveKDay
            passes(&oneByOne, "one by one", [dayData(strava: [parts[0]]), dayData(strava: Array(parts.prefix(2)))])
            let midway = done(oneByOne, dayId)
            passes(&oneByOne, "one by one", [dayData(strava: parts)])
            passes(&atOnce, "at once", [dayData(strava: parts)])
            if !midway || oneByOne.player.penaltyOpen || done(oneByOne, dayId) || oneByOne.bundle.quests != atOnce.bundle.quests {
                errors.append("runs read one by one should give the rows of one read, got \(rowsText(oneByOne)) and \(rowsText(atOnce))")
            }
            // A finished row changes a run for a longer one that comes later, so the next row gets the shorter one.
            let swap = [recorded("strava", "swap-9", meters: 9_350, after: 3_600), recorded("strava", "swap-5", meters: 5_190, after: 14_400),
                        recorded("healthkit", "swap-h", meters: 9_170, after: 25_200)]
            var swapped = fiveKDay
            passes(&swapped, "swap", [dayData(strava: Array(swap.prefix(2))), dayData(strava: Array(swap.prefix(2)), health: [swap[2]])])
            if swapped.player.penaltyOpen || !done(swapped, dayId) || shows(swapped) != 18.5 {
                errors.append("the penalty row should take the Health run and leave the Strava run to the 5K, got \(rowsText(swapped))")
            }
            // 7 km and 6 km finish the Penalty 10K together. The row shows 13 km.
            var thirteen = owes
            let seven = recorded("strava", "sum-7", meters: 7_000, after: 3_600), six = recorded("strava", "sum-6", meters: 6_000, after: 14_400)
            passes(&thirteen, "13 km", [dayData(strava: [seven, six])])
            if !done(thirteen, penalty.id) || shows(thirteen) != 13 {
                errors.append("a row that two runs finished should show their sum, got \(rowsText(thirteen))")
            }
            // A row that several runs finished has no one workout of its own: no part of it stands for the row.
            if let sumRow = thirteen.bundle.quests.first(where: { $0.id == penalty.id }),
               HiddenQuests.completingWorkout(for: sumRow, in: dayData(strava: [seven, six]).workouts) != nil {
                errors.append("a row that two runs finished should have no one completing workout")
            }
            // Strava holds a run in two parts that two rows used, and Apple Health then holds it whole. Each row
            // keeps its part: the whole workout is no row's own, so no row shows 15 km and nothing is unlocked.
            var twoRows = fiveKDay
            let partA = recorded("strava", "whole-a", meters: 10_000, after: 3_600), partB = recorded("strava", "whole-b", meters: 5_000, after: 6_300)
            let both15 = WorkoutEvent(source: "healthkit", externalId: "whole-h", sport: "running", start: morning.addingTimeInterval(3_600),
                                      end: morning.addingTimeInterval(8_700), movingTimeSec: 4_800, distanceMeters: 15_000)
            passes(&twoRows, "parts on two rows", [dayData(strava: [partA, partB])])
            let goldBefore = twoRows.gold
            passes(&twoRows, "parts on two rows", [dayData(strava: [partA, partB], health: [both15])])
            _ = twoRows.checkHiddenQuests(integrations: dayData(strava: [partA, partB], health: [both15]), now: passNow)
            let wholeUses = twoRows.evidenceLog.filter { $0.dayKey == twoRows.bundle.dayKey }
            if shows(twoRows) != 10 || twoRows.bundle.quests[index].progress.current != 5 || twoRows.gold != goldBefore || twoRows.beyondTheLimitToday != nil
                || wholeUses.count != 2 || GameSnapshot.sameWorkout(wholeUses[0].evidence, wholeUses[1].evidence) {
                errors.append("parts of one run on two rows should stay as they are when another source holds the run whole, got \(rowsText(twoRows)) gold \(twoRows.gold - goldBefore)")
            }
            // A long gym recording in Apple Health contains the run. They are two workouts: the time rule is for one sport.
            let gymTime = Evidence.make(source: "healthkit", externalId: "workout:healthkit:gym", payload: "gym", timestamp: morning.addingTimeInterval(9_000),
                                        recordings: ["healthkit:gym"], sessionStart: morning.addingTimeInterval(3_600), family: SportFamily.strength.rawValue)
            let runTime = Evidence.make(source: "strava", externalId: "workout:strava:inside", payload: "inside", timestamp: morning.addingTimeInterval(8_400),
                                        recordings: ["strava:inside"], sessionStart: morning.addingTimeInterval(5_400), family: SportFamily.run.rawValue)
            var sameSport = runTime
            sameSport.family = SportFamily.strength.rawValue
            if GameSnapshot.sameWorkout(gymTime, runTime) || !GameSnapshot.sameWorkout(gymTime, sameSport) {
                errors.append("a run inside a gym recording should be its own workout, and two recordings of one sport at that time one workout")
            }
            // A run that was cut in its source from 6 km to 4 km counts 4 km: with a second 4 km run, 8 km.
            var edited = owes
            passes(&edited, "edited", [dayData(strava: [recorded("strava", "edit", meters: 6_000, after: 3_600)]),
                                       dayData(strava: [recorded("strava", "edit", meters: 4_000, after: 3_600), recorded("strava", "edit-2", meters: 4_000, after: 14_400)])])
            if done(edited, penalty.id) || shows(edited) != 8 {
                errors.append("a run that was made shorter in its source should count its new length, got \(rowsText(edited))")
            }
            // One run in two sources is one run, also when the second device started 11 minutes late.
            var lateStart = owes
            let whole = WorkoutEvent(source: "healthkit", externalId: "late-h", sport: "running", start: morning.addingTimeInterval(3_600),
                                     end: morning.addingTimeInterval(5_400), movingTimeSec: 1_800, distanceMeters: 5_000)
            let late = WorkoutEvent(source: "strava", externalId: "late-s", sport: "Run", start: morning.addingTimeInterval(4_260),
                                    end: morning.addingTimeInterval(5_400), movingTimeSec: 1_140, distanceMeters: 3_100)
            passes(&lateStart, "late start", [dayData(strava: [], health: [whole]), dayData(strava: [late]), dayData(strava: [late], health: [whole])])
            if done(lateStart, penalty.id) || shows(lateStart) != 5 {
                errors.append("one run that a second device recorded from a late start should count one time, got \(rowsText(lateStart))")
            }
            // A stop and a new start in Strava (1 km and 9 km), and one Apple Health recording of the whole run that
            // reads 9.8 km: the parts add, so it is 10 km, one time.
            var whole10 = owes
            let cover = WorkoutEvent(source: "healthkit", externalId: "cover", sport: "running", start: morning.addingTimeInterval(3_600),
                                     end: morning.addingTimeInterval(7_200), movingTimeSec: 3_480, distanceMeters: 9_800)
            passes(&whole10, "parts and whole", [dayData(strava: [falseStart, realRun], health: [cover])])
            if !done(whole10, penalty.id) || whole10.bundle.quests[index].progress.current != 0 {
                errors.append("two parts in Strava and the whole run in Apple Health should be one run of 10 km, got \(rowsText(whole10))")
            }
            // Strava holds 5 km and 5 km, and another source alone holds two more of 5 km (its ids sort after
            // Strava's). The penalty row takes those, so the day's 10K, which needs Strava, is finished too.
            var four = owes
            passes(&four, "four runs", [dayData(strava: [recorded("strava", "four-s1", meters: 5_000, after: 3_600), recorded("strava", "four-s2", meters: 5_000, after: 10_800)],
                                                health: [recorded("whoop", "four-w1", meters: 5_000, after: 18_000), recorded("whoop", "four-w2", meters: 5_000, after: 25_200)])])
            if !done(four, penalty.id) || !done(four, dayId) {
                errors.append("of runs of one length the penalty row should take the ones Strava does not hold, got \(rowsText(four))")
            }
            // A penalty that opens after a run was done and counted does not take that run back.
            var midDay = GameSnapshot.fresh(catalog: catalog, now: morning)
            let early = dayData(strava: [recorded("strava", "early-10", meters: 10_020, after: 3_600)])
            midDay.checkOpenRows(integrations: early, now: passNow, skipping: passSkips)
            midDay.player.penaltyOpen = true
            midDay.bundle = PenaltyQuests.ensure(in: midDay.bundle, open: true, band: midDay.trainingBand, catalog: catalog, now: passNow)
            passes(&midDay, "penalty after the run", [early])
            if !midDay.player.penaltyOpen || !midDay.bundle.quests.contains(where: { $0.kind == .daily && TrainingDay.isRaceRun($0) && $0.status == .completed }) {
                errors.append("a penalty should not take back a run that was done and counted before it opened, got \(rowsText(midDay))")
            }
            // The same after a longer run: the 5K keeps the run it had before the penalty opened, the penalty row
            // shows only the new run, and a second pass changes nothing.
            var midFive = GameSnapshot.fresh(catalog: catalog, now: morning)
            if let at = midFive.bundle.quests.firstIndex(where: { $0.kind == .daily && TrainingDay.isRaceRun($0) }) {
                midFive.bundle.quests[at].verification.params["minDistanceMeters"] = .number(5_000)
                midFive.bundle.quests[at].progress.target = 5
                let sixBefore = recorded("strava", "mid-6", meters: 6_000, after: 3_600), later = recorded("strava", "mid-8", meters: 7_900, after: 28_800)
                midFive.checkOpenRows(integrations: dayData(strava: [sixBefore]), now: passNow, skipping: passSkips)
                midFive.player.penaltyOpen = true
                midFive.bundle = PenaltyQuests.ensure(in: midFive.bundle, open: true, band: midFive.trainingBand, catalog: catalog, now: passNow)
                passes(&midFive, "longer run after the penalty", [dayData(strava: [sixBefore, later])])
                let fiveRow = midFive.bundle.quests.first { $0.kind == .daily && TrainingDay.isRaceRun($0) }
                if !midFive.player.penaltyOpen || fiveRow?.status != .completed || fiveRow?.evidence.first?.workoutIds.contains("strava:mid-6") != true
                    || PenaltyQuests.rows(in: midFive.bundle).first?.progress.current != 7.9 {
                    errors.append("a row should keep the run it had before a penalty opened, got \(rowsText(midFive))")
                }
            }
            // A penalty opens after a 3 km run that no row has counted yet. Then 2 km (the 5K is done by 3 + 2) and
            // 8 km: the runs after the penalty reach 10 km with the 5K's, so the penalty takes them and the 5K is open.
            var afterOpen = GameSnapshot.fresh(catalog: catalog, now: morning)
            if let at = afterOpen.bundle.quests.firstIndex(where: { $0.kind == .daily && TrainingDay.isRaceRun($0) }) {
                afterOpen.bundle.quests[at].verification.params["minDistanceMeters"] = .number(5_000)
                afterOpen.bundle.quests[at].progress.target = 5
                let three = recorded("strava", "open-3", meters: 3_000, after: 3_600), two = recorded("strava", "open-2", meters: 2_000, after: 14_400)
                let eight = recorded("strava", "open-8", meters: 8_000, after: 25_200)
                afterOpen.checkOpenRows(integrations: dayData(strava: [three]), now: passNow, skipping: passSkips)
                afterOpen.player.penaltyOpen = true
                afterOpen.bundle = PenaltyQuests.ensure(in: afterOpen.bundle, open: true, band: afterOpen.trainingBand, catalog: catalog, now: passNow)
                passes(&afterOpen, "penalty after an uncounted run", [dayData(strava: [three, two]), dayData(strava: [three, two, eight])])
                if afterOpen.player.penaltyOpen {
                    errors.append("runs that no row had counted when the penalty opened should clear it, got \(rowsText(afterOpen))")
                }
            }
            // "No gym today" is on and the penalty is done by 5.2 + 5.1 km. A pass with Strava down brings an 11 km run
            // from Apple Health: the penalty takes it, and its two runs finish the added 10K in that same pass.
            var freed = owes
            let runA = recorded("strava", "freed-a", meters: 5_200, after: 3_600), runB = recorded("strava", "freed-b", meters: 5_100, after: 14_400)
            passes(&freed, "freed runs", [dayData(strava: [runA, runB])])
            _ = freed.setNoGym(true, catalog: catalog, now: passNow, integrations: dayData(strava: [runA, runB]))
            var strava = dayData(strava: [], health: [recorded("healthkit", "freed-big", meters: 11_000, after: 25_200)])
            strava.strava = StravaDayReading(available: false, configured: true, reason: "down", dayKey: freed.bundle.dayKey, activities: [])
            passes(&freed, "freed runs", [strava])
            if freed.bundle.quests.first(where: \.isNoGymRun)?.status != .completed || shows(freed) != 11 {
                errors.append("runs that the penalty gives up should finish the added 10K in the same pass, got \(rowsText(freed))")
            }
            // A penalty is lifted and its row goes. The day's 10K is then done by a run, and a penalty opens again
            // with a row of the same id: it is a new penalty, and that run was counted before it.
            var again = owes
            again.checkOpenRows(integrations: dayData(strava: []), now: passNow, skipping: passSkips)
            again.player.penaltyOpen = false
            again.bundle.quests.removeAll { $0.kind == .penalty }
            let counted = dayData(strava: [recorded("strava", "again-10", meters: 10_300, after: 3_600)])
            again.checkOpenRows(integrations: counted, now: passNow, skipping: passSkips)
            again.player.penaltyOpen = true
            again.bundle = PenaltyQuests.ensure(in: again.bundle, open: true, band: again.trainingBand, catalog: catalog, now: passNow.addingTimeInterval(60))
            passes(&again, "penalty opened again", [counted])
            if !again.player.penaltyOpen || !again.bundle.quests.contains(where: { $0.kind == .daily && TrainingDay.isRaceRun($0) && $0.status == .completed }) {
                errors.append("a penalty that opens again should not take the run that was counted before it, got \(rowsText(again))")
            }
            // A note that an earlier build saved with the km it showed still loads.
            let old = Data(#"{"dayKey":"2026-10-22","questId":"q","evidence":{"source":"strava","externalId":"workout:strava:x","payloadHash":"h","timestamp":0},"shown":7.2}"#.utf8)
            if (try? JSONDecoder().decode(ShownWorkout.self, from: old))?.meters != 7_200 {
                errors.append("a saved note with km should load as meters")
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
            // A 9.96 km run counts as 10 km. The 5K's own note of the run says so, so the switch moves it to the added
            // 10K with no data. Off gives the 5K back with the distance it showed, 9.9 km.
            let near = dayData(strava: [recorded("strava", "five-near", meters: 9_960, after: 3_600)])
            var late = fiveK
            late.checkOpenRows(integrations: near, now: passNow, skipping: passSkips)
            _ = late.checkHiddenQuests(integrations: near, now: passNow)
            let nearDay = late
            _ = late.setNoGym(true, catalog: catalog, now: passNow)
            let atSwitch = late
            late.checkOpenRows(integrations: near, now: passNow, skipping: passSkips)
            if status(atSwitch, addedId) != .completed || status(atSwitch, dayId) == .completed || late.bundle != atSwitch.bundle {
                errors.append("a 9.96 km run on a 5K should go to the added 10K at the switch, and a pass should change nothing, got \(rowsText(atSwitch)) then \(rowsText(late))")
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
            // The 5K takes a 6 km run on the gym day. "No gym today" goes on, and a 5 km run follows: the added 10K
            // is done by the two runs and the 5K is open, as when the setting goes on first. Off gives the runs to
            // the 5K, and on again gives them back.
            let sixKm = recorded("strava", "sum-6", meters: 6_000, after: 3_600), fiveKm = recorded("strava", "sum-5", meters: 5_000, after: 14_400)
            var later = fiveK
            later.checkOpenRows(integrations: dayData(strava: [sixKm]), now: passNow, skipping: passSkips)
            _ = later.setNoGym(true, catalog: catalog, now: passNow, integrations: dayData(strava: [sixKm]))
            later.checkOpenRows(integrations: dayData(strava: [sixKm, fiveKm]), now: passNow, skipping: passSkips)
            var onFirst = fiveK
            _ = onFirst.setNoGym(true, catalog: catalog, now: passNow)
            onFirst.checkOpenRows(integrations: dayData(strava: [sixKm, fiveKm]), now: passNow, skipping: passSkips)
            if status(later, addedId) != .completed || status(later, dayId) == .completed || rowsText(later) != rowsText(onFirst) {
                errors.append("runs before and after no gym on should give the day of no gym on first, got \(rowsText(later)) and \(rowsText(onFirst))")
            }
            _ = later.setNoGym(false, catalog: catalog, now: passNow, integrations: dayData(strava: [sixKm, fiveKm]))
            later.checkOpenRows(integrations: dayData(strava: [sixKm, fiveKm]), now: passNow, skipping: passSkips)
            let offDone = status(later, dayId) == .completed
            _ = later.setNoGym(true, catalog: catalog, now: passNow, integrations: dayData(strava: [sixKm, fiveKm]))
            later.checkOpenRows(integrations: dayData(strava: [sixKm, fiveKm]), now: passNow, skipping: passSkips)
            if !offDone || status(later, addedId) != .completed || status(later, dayId) == .completed {
                errors.append("no gym off and on again should give the two runs back to the added 10K, got \(rowsText(later))")
            }
            // The added 10K is done by 7 km and 3 km. Off gives both to the 5K, which shows 10 km: their sum, not the
            // 7 km of one part.
            var sumOff = fiveK
            let sevenKm = recorded("strava", "off-7", meters: 7_000, after: 3_600), threeKm = recorded("strava", "off-3", meters: 3_000, after: 14_400)
            _ = sumOff.setNoGym(true, catalog: catalog, now: passNow)
            sumOff.checkOpenRows(integrations: dayData(strava: [sevenKm, threeKm]), now: passNow, skipping: passSkips)
            _ = sumOff.setNoGym(false, catalog: catalog, now: passNow, integrations: dayData(strava: [sevenKm, threeKm]))
            if status(sumOff, dayId) != .completed || sumOff.bundle.quests[index].progress.current != 10 {
                errors.append("no gym off should give the 5K the sum of the two runs, got \(rowsText(sumOff))")
            }
            // The 5K then takes an 8 km run alone. It is a run of this 5K now, so it earns Beyond the Limit as on a
            // gym day: the 10 km the moved runs were measured against goes with them.
            let eightKm = recorded("strava", "off-8", meters: 8_000, after: 25_200)
            let withEight = dayData(strava: [sevenKm, threeKm, eightKm])
            sumOff.checkOpenRows(integrations: withEight, now: passNow, skipping: passSkips)
            _ = sumOff.checkHiddenQuests(integrations: withEight, now: passNow)
            if sumOff.bundle.quests[index].verification.params[HiddenQuests.baseParam] != nil || sumOff.beyondTheLimitToday?.questId != dayId {
                errors.append("a new run on the 5K should be measured against 5 km, got \(rowsText(sumOff)) unlock \(String(describing: sumOff.beyondTheLimitToday?.questId))")
            }
            // The added 10K is done by 5 km and 4.96 km: 9.96 km. Off moves both to the 5K, which shows their sum,
            // 9.9 km, not the 10 km the added row showed.
            var nearSum = fiveK
            let fiveFlat = recorded("strava", "near-5", meters: 5_000, after: 3_600), fourNine = recorded("strava", "near-496", meters: 4_960, after: 14_400)
            _ = nearSum.setNoGym(true, catalog: catalog, now: passNow)
            nearSum.checkOpenRows(integrations: dayData(strava: [fiveFlat, fourNine]), now: passNow, skipping: passSkips)
            let addedDone = status(nearSum, addedId) == .completed
            _ = nearSum.setNoGym(false, catalog: catalog, now: passNow, integrations: dayData(strava: [fiveFlat, fourNine]))
            if !addedDone || status(nearSum, dayId) != .completed || nearSum.bundle.quests[index].progress.current != 9.9 {
                errors.append("a finish that moves should show the sum of its runs, got \(rowsText(nearSum))")
            }
            // A 5K that holds one part of a run does not hold the whole run. Strava has the run in two parts
            // (5.5 km and 6 km) and the 5K took the 6 km. "No gym today" goes on, and a pass with Strava down
            // brings the whole run from Apple Health: the 5K keeps its part, and nothing moves to the added 10K.
            var onePart = fiveK
            let partFive = WorkoutEvent(source: "strava", externalId: "part-55", sport: "Run", start: morning.addingTimeInterval(3_600),
                                        end: morning.addingTimeInterval(5_400), movingTimeSec: 1_800, distanceMeters: 5_500)
            let partSix = WorkoutEvent(source: "strava", externalId: "part-60", sport: "Run", start: morning.addingTimeInterval(5_460),
                                       end: morning.addingTimeInterval(7_500), movingTimeSec: 2_040, distanceMeters: 6_000)
            let wholeRun = WorkoutEvent(source: "healthkit", externalId: "part-whole", sport: "running", start: morning.addingTimeInterval(3_600),
                                        end: morning.addingTimeInterval(7_500), movingTimeSec: 3_840, distanceMeters: 11_500)
            onePart.checkOpenRows(integrations: dayData(strava: [partFive, partSix]), now: passNow, skipping: passSkips)
            _ = onePart.setNoGym(true, catalog: catalog, now: passNow)
            for _ in 0..<2 { onePart.checkOpenRows(integrations: dayData(strava: [], health: [wholeRun]), now: passNow, skipping: passSkips) }
            let partUses = onePart.evidenceLog.filter { $0.dayKey == onePart.bundle.dayKey }
            if status(onePart, dayId) != .completed || status(onePart, addedId) == .completed || partUses.count != 1 {
                errors.append("a 5K that holds one part of a run should not give the whole run to the added 10K, got \(rowsText(onePart)) uses \(partUses.count)")
            }
            // Apple Health joins a run that the 5K holds by its Strava recording: the row takes the new recording too,
            // so it holds each recording of its run.
            var joined = fiveK
            let stravaOnly = recorded("strava", "join-s", meters: 6_000, after: 3_600), healthCopy = recorded("healthkit", "join-h", meters: 6_050, after: 3_600)
            joined.checkOpenRows(integrations: dayData(strava: [stravaOnly]), now: passNow, skipping: passSkips)
            joined.checkOpenRows(integrations: dayData(strava: [stravaOnly], health: [healthCopy]), now: passNow, skipping: passSkips)
            let joinedIds = joined.bundle.quests[index].evidence.reduce(into: Set<String>()) { $0.formUnion($1.workoutIds) }
            if !joinedIds.isSuperset(of: ["strava:join-s", "healthkit:join-h"]) || joined.evidenceLog.filter({ $0.dayKey == joined.bundle.dayKey }).count != 1 {
                errors.append("a finished row should take the new recording of its run, got \(joinedIds.sorted())")
            }
            // A penalty row and the 5K hold the two Strava parts of one run, and Apple Health holds the run whole.
            // "No gym today" on and off moves nothing and adds no km: the whole run is no row's own.
            var split = GameSnapshot.fresh(catalog: catalog, now: morning)
            split.player.penaltyOpen = true
            split.rebuildBundle(catalog: catalog, now: morning)
            if let at = split.bundle.quests.firstIndex(where: { $0.kind == .daily && TrainingDay.isRaceRun($0) }) {
                split.bundle.quests[at].verification.params["minDistanceMeters"] = .number(5_000)
                split.bundle.quests[at].progress.target = 5
                let tenPart = WorkoutEvent(source: "strava", externalId: "two-a", sport: "Run", start: morning.addingTimeInterval(3_600),
                                           end: morning.addingTimeInterval(6_600), movingTimeSec: 3_000, distanceMeters: 10_000)
                let fivePart = WorkoutEvent(source: "strava", externalId: "two-b", sport: "Run", start: morning.addingTimeInterval(6_660),
                                            end: morning.addingTimeInterval(8_400), movingTimeSec: 1_740, distanceMeters: 5_000)
                let all = WorkoutEvent(source: "healthkit", externalId: "two-h", sport: "running", start: morning.addingTimeInterval(3_600),
                                       end: morning.addingTimeInterval(8_400), movingTimeSec: 4_740, distanceMeters: 15_000)
                let parts = dayData(strava: [tenPart, fivePart]), withWhole = dayData(strava: [tenPart, fivePart], health: [all])
                split.checkOpenRows(integrations: parts, now: passNow, skipping: passSkips)
                split.checkOpenRows(integrations: withWhole, now: passNow, skipping: passSkips)
                let rowsBefore = rowsText(split)
                _ = split.setNoGym(true, catalog: catalog, now: passNow, integrations: withWhole)
                for _ in 0..<2 { split.checkOpenRows(integrations: withWhole, now: passNow, skipping: passSkips) }
                let addedOpen = split.bundle.quests.first(where: \.isNoGymRun)?.status != .completed
                _ = split.setNoGym(false, catalog: catalog, now: passNow, integrations: withWhole)
                split.checkOpenRows(integrations: withWhole, now: passNow, skipping: passSkips)
                if !addedOpen || rowsText(split) != rowsBefore || split.evidenceLog.filter({ $0.dayKey == split.bundle.dayKey }).count != 2 {
                    errors.append("parts of one run on two rows should not move to the added 10K, got \(rowsText(split)) before \(rowsBefore)")
                }
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
            // A row that is finished now and completes the day plays the day cue, also a second time that day.
            var byHand = beforeOff
            if let dayRun = byHand.bundle.quests.first(where: { TrainingDay.isRaceRun($0) && $0.status != .completed }) {
                _ = byHand.applyLocalOverride(questId: dayRun.id, now: morning)
                if SoundCues.sounds(from: beforeOff, to: byHand, dayCuePlayed: true) != [.dayClear] {
                    errors.append("a hand check that completes the day should play the day cue, got \(SoundCues.sounds(from: beforeOff, to: byHand, dayCuePlayed: true))")
                }
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

        // The repeat price holds 30 days later, when the 36-hour cooldown is long over.
        var shop = GameSnapshot.fresh(catalog: catalog, now: morning)
        shop.gold = 1_000_000
        _ = shop.usePotion(.gildedIndulgence, now: morning)
        shop.bundle.dayKey = QuestDay.key(byAddingDays: Potion.repeatWindowDays, to: shop.bundle.dayKey)
        if shop.potionBlocker(.gildedIndulgence, now: morning.addingTimeInterval(Double(Potion.repeatWindowDays) * 86_400)) != nil || shop.potionPrice(.gildedIndulgence) != Potion.gildedIndulgence.basePrice * 3 / 2 {
            errors.append("a second Gilded Indulgence on the first free day should cost 150%, got \(shop.potionPrice(.gildedIndulgence))")
        }

        // One history row that cannot be read costs that row, not the save.
        let savedUses = Data(#"[{"dayKey":"2026-10-01","potion":"ironblood"},{"dayKey":"2026-10-02","potion":"a potion that was removed"},{"dayKey":"2026-10-03","potion":"nightfall"}]"#.utf8)
        if (try? JSONDecoder().decode(LossyArray<PotionUse>.self, from: savedUses))?.elements.map(\.dayKey) != ["2026-10-01", "2026-10-03"] {
            errors.append("a list should drop only the elements it cannot read")
        }

        // The set limit: the split day's own sets (2, 3 for curls and lateral raises, 4 for pull-ups on Bench Day),
        // also for a plan or a saved day that asks for more.
        var wide = GameSnapshot.fresh(catalog: catalog, now: morning)
        for index in wide.bundle.quests.indices where wide.bundle.quests[index].verification.method == .hevySets && wide.bundle.quests[index].id != DailyStretch.questId {
            wide.bundle.quests[index].verification.params["sets"] = .number(5)
            wide.bundle.quests[index].progress.target = 5
            wide.bundle.quests[index].title = "\(wide.bundle.quests[index].verification.params["exercise"]?.stringValue ?? "Lift") 5×8"
        }
        wide.bundle = wide.finished(wide.bundle, catalog: catalog, now: morning)
        let capped = wide.bundle.quests.filter { $0.verification.method == .hevySets && $0.id != DailyStretch.questId }
        let benchDay = GymSplit.plannedDay(of: wide.bundle, goals: [], edits: [:])
        let wrong = capped.filter { row in
            let limit = benchDay.flatMap { GymSplit.exercise(of: row, in: $0)?.sets } ?? GymSplit.maxSets(for: row.verification.params["exercise"]?.stringValue ?? "")
            return row.verification.params["sets"]?.doubleValue != Double(limit) || row.progress.target != Double(limit) || !row.title.contains("\(limit)×8")
        }
        if capped.isEmpty || !wrong.isEmpty || capped.first(where: { $0.title.hasPrefix("Pull Up") })?.progress.target != 4
            || capped.first(where: { $0.title.hasPrefix("Bench Press") })?.progress.target != 2 || benchDay?.name != "Bench Day" {
            errors.append("a day should hold the split's sets: 2 for bench, 4 for pull-ups, got \(wrong.map(\.title))")
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
