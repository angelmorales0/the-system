import Foundation

/// A fixed `Stretching [0/10min]` row on every daily quest screen, whether the bundle came from the catalog
/// or from generation. Penalty days skip it: they already carry Mobility.
/// It checks itself off from timed Hevy stretches or an Apple Health flexibility workout (see `StretchTime`).
enum DailyStretch {
    static let questId = "daily_stretching"
    static let title = "Stretching"
    static let minutes = 10.0

    static func quest(mode: QuestMode, now: Date) -> Quest {
        Quest(
            id: questId,
            title: title,
            kind: .daily,
            stat: .AGI,
            verification: VerificationSpec(method: .hevySets, params: ["stretchMinutes": .number(minutes)]),
            deadline: QuestDay.endOfDay(now),
            xp: 15,
            difficulty: .easy,
            mode: mode,
            progress: QuestProgress(current: 0, target: minutes, unit: "min"),
            reward: nil,
            status: .pending,
            grantedXP: 0,
            grantedStatPoints: 0,
            grantedRecoveryToken: false,
            assignedAt: now
        )
    }

    /// Adds the row once, after the last required quest. An existing row keeps its progress.
    static func ensure(in bundle: QuestBundle, now: Date) -> QuestBundle {
        guard bundle.mode != .penalty, !bundle.quests.isEmpty,
              !bundle.quests.contains(where: { $0.id == questId }) else { return bundle }
        var copy = bundle
        let insertAt = copy.quests.lastIndex(where: { $0.kind != .optional }).map { $0 + 1 } ?? copy.quests.count
        copy.quests.insert(quest(mode: bundle.mode, now: now), at: insertAt)
        return copy
    }

    /// Minutes logged so far, as the row shows them.
    static func progressMinutes(in bundle: QuestBundle) -> Double {
        bundle.quests.first(where: { $0.id == questId })?.progress.current ?? 0
    }

    /// True or false once the row exists; nil when today's bundle has none.
    static func isDone(in bundle: QuestBundle) -> Bool? {
        bundle.quests.first(where: { $0.id == questId }).map { $0.status == .completed }
    }

    static func check() -> [String] {
        var errors: [String] = []
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let other = Quest(id: "run_intervals", title: "Run", kind: .daily, stat: .END,
                          verification: VerificationSpec(method: .manualConfirm, params: [:]), deadline: now, xp: 10,
                          difficulty: .easy, mode: .performanceTraining, progress: QuestProgress(current: 0, target: 1, unit: "session"),
                          reward: nil, status: .pending, grantedXP: 0, grantedStatPoints: 0, grantedRecoveryToken: false)
        var optional = other
        optional.id = "light_spend"
        optional.kind = .optional
        var bundle = QuestBundle.empty
        bundle.quests = [other, optional]
        let added = ensure(in: bundle, now: now)
        if added.quests.map(\.id) != ["run_intervals", questId, "light_spend"] {
            errors.append("Stretching should sit after the required quests, got \(added.quests.map(\.id))")
        }
        if added.quests.first(where: { $0.id == questId })?.progress.bracketLabel != "[0/10min]" {
            errors.append("Stretching should read [0/10min]")
        }

        // Stretch names: whole words only, so a split squat is not a stretch.
        for name in ["Hamstring Stretch", "Splits", "Front Split", "Pigeon Pose", "Couch Stretch (Bodyweight)", "Child's Pose"]
            where !StretchTime.isStretchExercise(name) {
            errors.append("\(name) should count as a stretch")
        }
        for name in ["Bulgarian Split Squat (Dumbbell)", "Split Squat", "Plank", "Bench Press (Barbell)"]
            where StretchTime.isStretchExercise(name) {
            errors.append("\(name) must not count as a stretch")
        }
        func timed(_ seconds: Double, type: String = "normal") -> HevySet {
            HevySet(type: type, reps: nil, weightKg: nil, rpe: nil, durationSec: seconds)
        }
        let lifting = HevyWorkout(id: "a", title: "Push Day", start: now, end: now, exercises: [
            HevyExercise(title: "Hamstring Stretch", sets: [timed(120), timed(60, type: "warmup")]),
            HevyExercise(title: "Plank", sets: [timed(90)]),
        ])
        let mobility = HevyWorkout(id: "b", title: "Evening Mobility", start: now, end: now, exercises: [
            HevyExercise(title: "Plank", sets: [timed(90)]),
            HevyExercise(title: "Pigeon Pose", sets: [timed(300)]),
        ])
        if StretchTime.hevySeconds([lifting]) != 120 || StretchTime.hevySeconds([lifting, mobility]) != 510 {
            errors.append("stretch time should count stretch sets, and every timed set in a mobility workout, without warm-ups")
        }
        let yoga = WorkoutEvent(source: "healthkit", externalId: "y", sport: "flexibility", start: now, end: now, movingTimeSec: 600)
        let walk = WorkoutEvent(source: "healthkit", externalId: "w", sport: "walking", start: now, end: now, movingTimeSec: 900)
        if StretchTime.healthSeconds([yoga, walk]) != 600 {
            errors.append("only Health flexibility workouts should count as stretch time")
        }
        if ensure(in: added, now: now).quests.count != added.quests.count {
            errors.append("Stretching must be added only once")
        }
        var penalty = bundle
        penalty.mode = .penalty
        if ensure(in: penalty, now: now).quests.contains(where: { $0.id == questId }) {
            errors.append("a penalty day must not add Stretching")
        }
        if isDone(in: added) != false || isDone(in: bundle) != nil {
            errors.append("isDone should be false when open and nil when missing")
        }
        return errors
    }
}
