import Foundation

/// A Training day is exercise only: runs, walks, and lifts, plus the fixed Stretching row and any penalty quests.
/// The catalog follows this already; generated bundles are filtered here, so a model cannot add
/// protein, spending, or a specific stretch such as Splits to a Training day.
enum TrainingDay {
    static let header = "Training"
    static let exerciseMethods: Set<VerificationMethod> = [.stravaActivity, .hevySets, .healthkitWorkout, .whoopStrain]

    /// Nil when nothing would be left, so the caller keeps its catalog bundle instead.
    static func exerciseOnly(_ bundle: QuestBundle) -> QuestBundle? {
        guard bundle.mode == .performanceTraining else { return bundle }
        var copy = bundle
        copy.headerLine = header
        copy.quests = bundle.quests.filter { $0.kind == .penalty || isExercise($0) }
        return copy.quests.contains(where: { $0.kind != .optional && $0.kind != .penalty }) ? copy : nil
    }

    static func isExercise(_ quest: Quest) -> Bool {
        if quest.id == DailyStretch.questId { return true }
        guard exerciseMethods.contains(quest.verification.method) else { return false }
        // One general Stretching row replaces specific stretches.
        let exercise = quest.verification.params["exercise"]?.stringValue ?? quest.title
        return !StretchTime.isStretchExercise(exercise) && !StretchTime.isStretchExercise(quest.title)
    }

    static func check() -> [String] {
        var errors: [String] = []
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func quest(_ id: String, _ title: String, _ method: VerificationMethod, _ params: [String: JSONValue] = [:], kind: QuestKind = .daily) -> Quest {
            Quest(id: id, title: title, kind: kind, stat: .STR, verification: VerificationSpec(method: method, params: params),
                  deadline: now, xp: 10, difficulty: .easy, mode: .performanceTraining,
                  progress: QuestProgress(current: 0, target: 1, unit: "session"), reward: nil, status: .pending,
                  grantedXP: 0, grantedStatPoints: 0, grantedRecoveryToken: false)
        }
        var bundle = QuestBundle.empty
        bundle.mode = .performanceTraining
        bundle.headerLine = "Performance Training"
        bundle.quests = [
            quest("run_10k", "10K Run", .stravaActivity),
            quest("bench_press", "Bench Press", .hevySets, ["exercise": .string("Bench Press"), "sets": .number(4)]),
            quest("splits", "Splits", .hevySets, ["exercise": .string("Splits"), "minDurationSec": .number(180)]),
            quest("protein", "Protein", .macrofactorProtein),
            quest("mobility", "Mobility", .timerSession),
            quest("light_spend", "Light Spend Cap", .mercurySpendUnder, kind: .optional),
            DailyStretch.quest(mode: .performanceTraining, now: now),
        ]
        let filtered = exerciseOnly(bundle)
        if filtered?.quests.map(\.id) != ["run_10k", "bench_press", DailyStretch.questId] {
            errors.append("a Training day should keep only exercise and Stretching, got \(String(describing: filtered?.quests.map(\.id)))")
        }
        if filtered?.headerLine != "Training" || QuestMode.performanceTraining.headerLine != "Training" {
            errors.append("a Training day should read [Daily Quest: Training has arrived.]")
        }
        var nothing = bundle
        nothing.quests = [quest("protein", "Protein", .macrofactorProtein)]
        if exerciseOnly(nothing) != nil {
            errors.append("a Training bundle with no exercise should fall back to the catalog")
        }
        var recovery = bundle
        recovery.mode = .recovery
        if exerciseOnly(recovery) != recovery {
            errors.append("other modes must not be filtered")
        }
        return errors
    }
}
