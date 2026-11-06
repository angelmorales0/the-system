import Foundation

/// A `Stretching [0/20min]` row on the daily quest screen, whether the bundle came from the catalog
/// or from generation. `StretchSplit` sets the day's stretches and minutes. A spent rest day has no row.
/// It checks itself off from timed Hevy stretches or an Apple Health flexibility workout (see `StretchTime`),
/// or when every stretch of the day is done. The player checks single stretches by hand; the row's own box has no tap.
/// Hand checks complete the row only. AGI levels still read Hevy.
enum DailyStretch {
    static let questId = "daily_stretching"
    static let title = "Stretching"
    /// Names the row's `StretchSplit.Day`. It stays in the history, so the rotation can read it.
    static let dayParam = "stretchDay"

    static func quest(mode: QuestMode, now: Date, day: StretchSplit.Day = StretchSplit.rotation[0]) -> Quest {
        Quest(
            id: questId,
            title: title,
            kind: .daily,
            stat: .AGI,
            verification: VerificationSpec(method: .hevySets, params: ["stretchMinutes": .number(day.minutes), dayParam: .string(day.id)]),
            deadline: QuestDay.endOfDay(now),
            difficulty: .easy,
            mode: mode,
            progress: QuestProgress(current: 0, target: day.minutes, unit: "min"),
            status: .pending,
            assignedAt: now
        )
    }

    /// Adds the row once, after the last required quest. An existing row keeps its progress.
    static func ensure(in bundle: QuestBundle, now: Date, day: StretchSplit.Day = StretchSplit.rotation[0]) -> QuestBundle {
        // A Full Recovery day has no rows of its own; it still gets Stretching.
        guard !bundle.quests.isEmpty || bundle.mode == .fullRecovery,
              !bundle.quests.contains(where: { $0.id == questId }) else { return bundle }
        var copy = bundle
        let insertAt = copy.quests.lastIndex(where: { $0.kind != .optional }).map { $0 + 1 } ?? copy.quests.count
        copy.quests.insert(quest(mode: bundle.mode, now: now, day: day), at: insertAt)
        return copy
    }

    /// Minutes logged so far, as the row shows them.

    /// True or false once the row exists; nil when today's bundle has none.

    static func check() -> [String] {
        var errors: [String] = []
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let other = Quest(id: "run_intervals", title: "Run", kind: .daily, stat: .END,
                          verification: VerificationSpec(method: .manualConfirm, params: [:]), deadline: now, difficulty: .easy, mode: .performanceTraining, progress: QuestProgress(current: 0, target: 1, unit: "session"),
                          status: .pending)
        var optional = other
        optional.id = "light_spend"
        optional.kind = .optional
        var bundle = QuestBundle.empty
        bundle.quests = [other, optional]
        let added = ensure(in: bundle, now: now)
        if added.quests.map(\.id) != ["run_intervals", questId, "light_spend"] {
            errors.append("Stretching should sit after the required quests, got \(added.quests.map(\.id))")
        }
        if added.quests.first(where: { $0.id == questId })?.progress.bracketLabel != "[0/20min]" {
            errors.append("Stretching should read [0/20min] on the first split day")
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

        // Hand checks: one stretch moves the row, unchecking lowers it, and the row completes only with every stretch.
        var snapshot = GameSnapshot.fresh(catalog: FallbackCatalog.bundled(), now: now)
        func row() -> Quest? { snapshot.bundle.quests.first { $0.id == questId } }
        guard let names = row().flatMap(StretchSplit.day(of:))?.stretches.map(\.name), names.count == 2 else {
            return errors + ["the first stretch day should have 2 stretches"]
        }
        snapshot.toggleStretch(names[0], doneInHevy: [])
        if row()?.progress.current != 10 || row()?.status != .pending || snapshot.stretchCompletion(doneInHevy: [], now: now) != nil {
            errors.append("one checked stretch should read 10 of 20 minutes and keep the row open")
        }
        snapshot.toggleStretch(names[0], doneInHevy: [])
        if row()?.progress.current != 0 || !snapshot.stretchesChecked.isEmpty {
            errors.append("unchecking a stretch should lower the row, got \(String(describing: row()?.progress.current))")
        }
        snapshot.toggleStretch(names[0], doneInHevy: [])
        if snapshot.stretchCompletion(doneInHevy: [names[1]], now: now) == nil {
            errors.append("a hand check and a stretch full in Hevy should finish the row together")
        }
        snapshot.toggleStretch(names[1], doneInHevy: [])
        if let result = snapshot.stretchCompletion(doneInHevy: [], now: now) {
            _ = snapshot.apply(result, questId: questId, now: now)
        }
        if row()?.status != .completed || row()?.progress.current != 20 {
            errors.append("every checked stretch should complete the row, got \(String(describing: row()?.status))")
        }
        let frozen = snapshot
        snapshot.toggleStretch(names[0], doneInHevy: [])
        if snapshot != frozen {
            errors.append("a completed row should not take more checks")
        }
        if let data = try? JSONEncoder().encode(frozen), (try? JSONDecoder().decode(GameSnapshot.self, from: data))?.stretchesChecked != Set(names) {
            errors.append("stretch checks should survive a save")
        }
        // A check from yesterday does not count today.
        snapshot.stretchChecks = StretchChecks(dayKey: "2000-01-01", names: names)
        if !snapshot.stretchesChecked.isEmpty {
            errors.append("stretch checks should last one quest day")
        }
        return errors
    }
}

/// One quest day of hand-checked stretches, by name.
struct StretchChecks: Codable, Equatable {
    var dayKey: String
    var names: [String]
}

extension GameSnapshot {
    private var stretchRow: Quest? { bundle.quests.first { $0.id == DailyStretch.questId } }

    /// Today's hand checks.
    var stretchesChecked: Set<String> {
        stretchChecks?.dayKey == bundle.dayKey ? Set(stretchChecks?.names ?? []) : []
    }

    /// The row reads the minutes of the stretches that are done. It only moves while the row is open.
    mutating func toggleStretch(_ name: String, doneInHevy: Set<String>) {
        guard let row = stretchRow, row.status == .pending, let day = StretchSplit.day(of: row),
              let index = bundle.quests.firstIndex(where: { $0.id == DailyStretch.questId }) else { return }
        var names = stretchesChecked
        if names.remove(name) == nil { names.insert(name) }
        stretchChecks = StretchChecks(dayKey: bundle.dayKey, names: names.sorted())
        let done = names.union(doneInHevy)
        let minutes = day.stretches.filter { done.contains($0.name) }.reduce(0) { $0 + $1.minutes }
        bundle.quests[index].progress.current = min(minutes, row.progress.target)
    }

    /// The result that completes the row, once every stretch of the day is done. Nil before that.
    func stretchCompletion(doneInHevy: Set<String>, now: Date) -> VerificationResult? {
        guard let row = stretchRow, row.status == .pending, let day = StretchSplit.day(of: row),
              Set(day.stretches.map(\.name)).isSubset(of: stretchesChecked.union(doneInHevy)) else { return nil }
        return .completed(evidence: Evidence.make(
            source: "manual_override",
            externalId: "stretches:\(bundle.dayKey)",
            payload: "stretches|\(bundle.dayKey)|\(day.id)",
            timestamp: now
        ))
    }
}
