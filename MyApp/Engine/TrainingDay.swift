import Foundation

/// A Training day is strength and 5K or 10K runs only, plus the fixed Stretching row and any penalty quests.
/// The catalog follows this already; generated bundles are filtered here, so a model cannot add
/// protein, spending, a walk, a run of another distance, or a specific stretch such as Splits to a Training day.
enum TrainingDay {
    static let header = "Training"
    static let exerciseMethods: Set<VerificationMethod> = [.stravaActivity, .hevySets, .healthkitWorkout, .whoopStrain]
    static let fiveKMeters = 5_000.0
    static let tenKMeters = 10_000.0
    /// The only run distances the app assigns, on Training days and in penalties. Two 10Ks on one day are two rows.
    static let runMeters: Set<Double> = [fiveKMeters, tenKMeters]
    /// A run quest reads only its distance. The player sets the pace.
    static let tenKTitle = "10K Run"
    static let fiveKTitle = "5K Run"

    /// Running km to keep in every 7-day window, today included. The backend plans today's runs from it.
    static let runKmPer7Days = 50

    /// Nil when nothing would be left, so the caller keeps its catalog bundle instead.
    static func exerciseOnly(_ bundle: QuestBundle) -> QuestBundle? {
        guard bundle.mode == .performanceTraining else { return bundle }
        var copy = bundle
        copy.quests = bundle.quests.filter { $0.kind == .penalty || isExercise($0) }.map { plainRunTitle($0) }
        // A split day keeps its name while it has lifts; anything else reads Training.
        let splitDay = GymSplit.day(named: bundle.headerLine) != nil && copy.quests.contains { isStrength($0) && $0.id != DailyStretch.questId }
        copy.headerLine = splitDay ? bundle.headerLine : header
        return copy.quests.contains(where: { $0.kind != .optional && $0.kind != .penalty }) ? copy : nil
    }

    static func isExercise(_ quest: Quest) -> Bool {
        if quest.id == DailyStretch.questId || quest.id == ScreenTime.questId { return true }
        // One general Stretching row replaces specific stretches.
        let exercise = quest.verification.params["exercise"]?.stringValue ?? quest.title
        guard !StretchTime.isStretchExercise(exercise), !StretchTime.isStretchExercise(quest.title) else { return false }
        return isRaceRun(quest) || isStrength(quest)
    }

    /// "10K Run" or "5K Run", whatever the generator wrote. Penalty rows keep their own titles.
    static func plainRunTitle(_ quest: Quest) -> Quest {
        guard quest.kind != .penalty, isRaceRun(quest) else { return quest }
        var copy = quest
        copy.title = quest.verification.params["minDistanceMeters"]?.doubleValue == tenKMeters ? tenKTitle : fiveKTitle
        return copy
    }

    /// A run checked by Strava or Apple Health at exactly 5 km or 10 km. Walks and runs that also accept walks do not count.
    static func isRaceRun(_ quest: Quest) -> Bool {
        let params = quest.verification.params
        guard let meters = params["minDistanceMeters"]?.doubleValue, runMeters.contains(meters) else { return false }
        switch quest.verification.method {
        case .stravaActivity:
            let types = IntegrationMatch.strings(params["types"]).map { $0.lowercased() }
            return !types.isEmpty && types.allSatisfy { $0 == "run" }
        case .healthkitWorkout:
            return params["activityType"]?.stringValue?.lowercased() == "running"
        default:
            return false
        }
    }

    /// A Hevy lift, or an Apple Health strength workout.
    static func isStrength(_ quest: Quest) -> Bool {
        switch quest.verification.method {
        case .hevySets:
            return true
        case .healthkitWorkout:
            return quest.verification.params["activityType"]?.stringValue?.lowercased().contains("strength") == true
        default:
            return false
        }
    }

    /// The most workouts a day holds. Each run is one workout; all the lifts together are one gym workout.
    static let maxWorkouts = 2

    /// Keeps the day at `maxWorkouts`. Runs are alike, so an extra run goes first: the 5K before a 10K, the last row first.
    /// Finished rows, penalty rows, Stretching, and Screen Time always stay.
    static func cappingWorkouts(_ bundle: QuestBundle) -> QuestBundle {
        var copy = bundle
        func isWorkout(_ quest: Quest) -> Bool { quest.kind == .daily && quest.id != DailyStretch.questId && quest.id != ScreenTime.questId }
        func isLift(_ quest: Quest) -> Bool { isWorkout(quest) && isStrength(quest) }
        func count() -> Int {
            copy.quests.filter { isWorkout($0) && isRaceRun($0) }.count + (copy.quests.contains(where: isLift) ? 1 : 0)
        }
        while count() > maxWorkouts {
            let open = copy.quests.indices.filter { isWorkout(copy.quests[$0]) && isRaceRun(copy.quests[$0]) && copy.quests[$0].status != .completed }
            let fiveK = open.last { copy.quests[$0].verification.params["minDistanceMeters"]?.doubleValue == fiveKMeters }
            guard let index = fiveK ?? open.last else { break }
            copy.quests.remove(at: index)
        }
        // Every run is done and the day is still over: the unstarted gym workout goes.
        if count() > maxWorkouts {
            copy.quests.removeAll { isLift($0) && $0.status != .completed }
        }
        return copy
    }

    static func check() -> [String] {
        var errors: [String] = []
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func quest(_ id: String, _ title: String, _ method: VerificationMethod, _ params: [String: JSONValue] = [:], kind: QuestKind = .daily) -> Quest {
            Quest(id: id, title: title, kind: kind, stat: .STR, verification: VerificationSpec(method: method, params: params),
                  deadline: now, difficulty: .easy, mode: .performanceTraining,
                  progress: QuestProgress(current: 0, target: 1, unit: "session"), status: .pending)
        }
        var bundle = QuestBundle.empty
        bundle.mode = .performanceTraining
        bundle.headerLine = "Performance Training"
        let tenK: [String: JSONValue] = ["types": .array([.string("Run")]), "minDistanceMeters": .number(tenKMeters)]
        bundle.quests = [
            quest("run_10k", "10K Run", .stravaActivity, tenK),
            quest("bench_press", "Bench Press", .hevySets, ["exercise": .string("Bench Press"), "sets": .number(4)]),
            quest("splits", "Splits", .hevySets, ["exercise": .string("Splits"), "minDurationSec": .number(180)]),
            quest("confirm", "Confirm", .manualConfirm),
            quest("mobility", "Mobility", .timerSession),
            quest("screen", "Screen Time", .screenTimeLimit, kind: .optional),
            quest("run_5k", "5K Run", .stravaActivity, ["types": .array([.string("Run")]), "minDistanceMeters": .number(fiveKMeters)]),
            quest("run_8k", "8K Run", .stravaActivity, ["types": .array([.string("Run")]), "minDistanceMeters": .number(8_000)]),
            quest("intervals", "Run Intervals", .stravaActivity, ["types": .array([.string("Run")]), "minMovingTimeSec": .number(1_200)]),
            quest("walk_10k", "10K Walk/Run", .stravaActivity, ["types": .array([.string("Run"), .string("Walk")]), "minDistanceMeters": .number(tenKMeters)]),
            quest("easy_walk", "Easy Walk", .healthkitWorkout, ["activityType": .string("walking"), "minDurationSec": .number(900)]),
            quest("strain", "Hit Strain", .whoopStrain, ["minStrain": .number(12)]),
            quest("second_10k", "Second 10K", .healthkitWorkout, ["activityType": .string("running"), "minDistanceMeters": .number(tenKMeters)]),
            quest("push", "Push Session", .healthkitWorkout, ["activityType": .string("traditionalStrengthTraining"), "minDurationSec": .number(1_800)]),
            DailyStretch.quest(mode: .performanceTraining, now: now),
        ]
        let filtered = exerciseOnly(bundle)
        if filtered?.quests.map(\.id) != ["run_10k", "bench_press", "run_5k", "second_10k", "push", DailyStretch.questId] {
            errors.append("a Training day should keep only 5K and 10K runs, strength, and Stretching, got \(String(describing: filtered?.quests.map(\.id)))")
        }
        if filtered?.quests.filter({ isRaceRun($0) }).map(\.title) != ["10K Run", "5K Run", "10K Run"] {
            errors.append("run quests should read only 10K Run or 5K Run, got \(String(describing: filtered?.quests.map(\.title)))")
        }
        if filtered?.headerLine != "Training" || QuestMode.performanceTraining.headerLine != "Training" {
            errors.append("a Training day should read [Daily Quest: Training has arrived.]")
        }
        var nothing = bundle
        nothing.quests = [quest("confirm", "Confirm", .manualConfirm)]
        if exerciseOnly(nothing) != nil {
            errors.append("a Training bundle with no exercise should fall back to the catalog")
        }
        var rest = bundle
        rest.mode = .fullRecovery
        if exerciseOnly(rest) != rest {
            errors.append("other modes must not be filtered")
        }

        // Two 10Ks and a gym day: one 10K goes. Stretching and Screen Time stay.
        let fiveK: [String: JSONValue] = ["types": .array([.string("Run")]), "minDistanceMeters": .number(fiveKMeters)]
        var heavy = bundle
        heavy.quests = [
            quest("run_10k", "10K Run", .stravaActivity, tenK),
            quest("bench_press", "Bench Press", .hevySets, ["exercise": .string("Bench Press")]),
            quest("row", "Barbell Row", .hevySets, ["exercise": .string("Barbell Row")]),
            quest("run_10k_2", "10K Run", .stravaActivity, tenK),
            quest(ScreenTime.questId, "Screen Time", .screenTimeLimit),
            DailyStretch.quest(mode: .performanceTraining, now: now),
        ]
        if cappingWorkouts(heavy).quests.map(\.id) != ["run_10k", "bench_press", "row", ScreenTime.questId, DailyStretch.questId] {
            errors.append("two 10Ks and lifts should become one 10K and lifts, got \(cappingWorkouts(heavy).quests.map(\.id))")
        }
        // A 10K and a 5K with lifts: the 5K goes.
        var mixed = heavy
        mixed.quests[0] = quest("run_5k", "5K Run", .stravaActivity, fiveK)
        if cappingWorkouts(mixed).quests.map(\.id) != ["bench_press", "row", "run_10k_2", ScreenTime.questId, DailyStretch.questId] {
            errors.append("a 10K, a 5K, and lifts should drop the 5K, got \(cappingWorkouts(mixed).quests.map(\.id))")
        }
        // A finished run stays; the open one goes.
        var started = heavy
        started.quests[3].status = .completed
        if cappingWorkouts(started).quests.map(\.id) != ["bench_press", "row", "run_10k_2", ScreenTime.questId, DailyStretch.questId] {
            errors.append("a finished run should stay, got \(cappingWorkouts(started).quests.map(\.id))")
        }
        // Both runs finished: the unstarted lifts go.
        started.quests[0].status = .completed
        if cappingWorkouts(started).quests.map(\.id) != ["run_10k", "run_10k_2", ScreenTime.questId, DailyStretch.questId] {
            errors.append("two finished runs should drop the unstarted lifts, got \(cappingWorkouts(started).quests.map(\.id))")
        }
        // Two runs and no gym, or one run and a gym day, already fit.
        var twoRuns = heavy
        twoRuns.quests.removeAll { isStrength($0) && $0.id != DailyStretch.questId }
        if cappingWorkouts(twoRuns) != twoRuns {
            errors.append("two runs with no lifts should not change")
        }
        return errors
    }
}
