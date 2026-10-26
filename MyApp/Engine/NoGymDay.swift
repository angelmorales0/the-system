import Foundation

/// "No gym today": the player cannot get to the gym, so the Training day doubles up on cardio.
/// Strength rows that are not finished give way to a second run, always a 10K. Finished work stays.
/// Penalty rows are not changed. The setting lasts for one quest day.
enum NoGymDay {
    static let secondTenKSlug = "run_10k_2"
    static let secondTenKTitle = TrainingDay.tenKTitle
    /// Runs the day should have: its own 5K or 10K, plus 10Ks up to this count.
    static let runCount = 2

    static func cardioOnly(_ bundle: QuestBundle, now: Date) -> QuestBundle {
        guard bundle.mode == .performanceTraining else { return bundle }
        var copy = bundle
        copy.quests.removeAll { isSwappable($0) && TrainingDay.isStrength($0) && $0.status != .completed }
        if !copy.quests.contains(where: { TrainingDay.isStrength($0) && $0.id != DailyStretch.questId }) {
            copy.headerLine = TrainingDay.header
        }
        let runs = copy.quests.filter { isSwappable($0) && TrainingDay.isRaceRun($0) }
        guard runs.count < runCount else { return copy }
        let template = runs.first { isTenK($0) }
        let added = (runs.count..<runCount).map { index in
            tenK(from: template, index: index, bundle: copy, now: now)
        }
        // After the day's own quests, before Stretching, optional rows, and penalty rows.
        let insertAt = copy.quests.firstIndex { $0.id == ScreenTime.questId || $0.id == DailyStretch.questId || $0.kind != .daily } ?? copy.quests.count
        copy.quests.insert(contentsOf: added, at: insertAt)
        return copy
    }

    /// True for a row this setting added, so turning it off can take the row away again.
    static func isAdded(_ quest: Quest, dayKey: String) -> Bool {
        quest.id == "q_\(dayKey)_\(secondTenKSlug)" || quest.id == "q_\(dayKey)_run_10k_1"
    }

    static func isTenK(_ quest: Quest) -> Bool {
        TrainingDay.isRaceRun(quest) && quest.verification.params["minDistanceMeters"]?.doubleValue == TrainingDay.tenKMeters
    }

    private static func isSwappable(_ quest: Quest) -> Bool {
        quest.kind == .daily && quest.id != DailyStretch.questId
    }

    /// A fresh copy of the day's 10K, or the catalog's 10K when the day has none.
    private static func tenK(from template: Quest?, index: Int, bundle: QuestBundle, now: Date) -> Quest {
        let slug = index == 0 ? "run_10k_1" : secondTenKSlug
        return Quest(
            id: "q_\(bundle.dayKey)_\(slug)",
            title: index == 0 ? "10K Run" : secondTenKTitle,
            kind: .daily,
            stat: .END,
            verification: template?.verification ?? VerificationSpec(
                method: .stravaActivity,
                params: ["types": .array([.string("Run")]), "minDistanceMeters": .number(TrainingDay.tenKMeters)]
            ),
            deadline: QuestDay.endOfDay(now),
            xp: template?.xp ?? 40,
            difficulty: template?.difficulty ?? .normal,
            mode: bundle.mode,
            progress: QuestProgress(current: 0, target: 10, unit: "km"),
            reward: nil,
            status: .pending,
            grantedXP: 0,
            grantedStatPoints: 0,
            grantedRecoveryToken: false,
            evidence: [],
            assignedAt: now
        )
    }
}

extension GameSnapshot {
    var noGymToday: Bool {
        noGymDayKey == bundle.dayKey
    }

    /// Turns "No gym today" on or off for the current quest day.
    mutating func setNoGym(_ on: Bool, catalog: FallbackCatalog, now: Date) -> String {
        guard bundle.mode == .performanceTraining else {
            return "Today is a Full Recovery day. There is no training to change."
        }
        if on {
            noGymDayKey = bundle.dayKey
            bundle = finished(bundle, catalog: catalog, now: now)
            return "No gym today. Strength quests are swapped for a second 10K."
        }
        noGymDayKey = nil
        var fresh = self
        fresh.rebuildBundle(catalog: catalog, now: now)
        let dayKey = bundle.dayKey
        var quests = bundle.quests.filter { !(NoGymDay.isAdded($0, dayKey: dayKey) && $0.status != .completed) }
        let lifts = fresh.bundle.quests.filter { lift in
            lift.kind == .daily && TrainingDay.isStrength(lift) && !quests.contains { $0.id == lift.id }
        }
        let insertAt = quests.firstIndex { $0.id == ScreenTime.questId || $0.id == DailyStretch.questId || $0.kind != .daily } ?? quests.count
        quests.insert(contentsOf: lifts, at: insertAt)
        bundle.quests = quests
        bundle.headerLine = fresh.bundle.headerLine
        return "Gym day again. Strength quests are back."
    }
}

enum NoGymDayRules {
    /// Stretching can be checked by Hevy too, so it is not a lift here.
    private static func isLift(_ quest: Quest) -> Bool {
        quest.id != DailyStretch.questId && TrainingDay.isStrength(quest)
    }

    static func check() -> [String] {
        var errors: [String] = []
        let catalog = FallbackCatalog.bundled()
        guard let now = QuestDay.date(from: "2026-10-01") else { return ["quest day failed to parse"] }
        var day = GameSnapshot.fresh(catalog: catalog, now: now)
        let before = day.bundle.quests.map(\.id)
        guard day.bundle.quests.contains(where: { isLift($0) }),
              day.bundle.quests.contains(where: { NoGymDay.isTenK($0) }) else {
            return ["the green Training day should have a lift and a 10K"]
        }

        _ = day.setNoGym(true, catalog: catalog, now: now)
        let ids = day.bundle.quests.map(\.id)
        if day.bundle.quests.contains(where: { isLift($0) }) {
            errors.append("no gym should remove the unfinished lifts, got \(ids)")
        }
        if day.bundle.quests.filter({ NoGymDay.isTenK($0) }).count != 2 {
            errors.append("no gym should give two 10K rows, got \(ids)")
        }
        if ids.last != DailyStretch.questId {
            errors.append("the second 10K should come before Stretching, got \(ids)")
        }
        if !day.noGymToday {
            errors.append("no gym should be on for today")
        }

        // A rebuild the same day, for example when WHOOP readiness arrives, keeps the swap.
        day.rebuildBundle(catalog: catalog, now: now)
        if day.bundle.quests.contains(where: { isLift($0) }) || day.bundle.quests.filter({ NoGymDay.isTenK($0) }).count != 2 {
            errors.append("a rebuild should keep the no-gym swap, got \(day.bundle.quests.map(\.id))")
        }
        let again = day.bundle
        _ = day.setNoGym(true, catalog: catalog, now: now)
        if day.bundle != again {
            errors.append("turning no gym on twice should change nothing")
        }

        _ = day.setNoGym(false, catalog: catalog, now: now)
        if day.bundle.quests.map(\.id) != before {
            errors.append("turning no gym off should restore the lifts, got \(day.bundle.quests.map(\.id)) expected \(before)")
        }

        // A lift already done stays done.
        var lifted = GameSnapshot.fresh(catalog: catalog, now: now)
        if let index = lifted.bundle.quests.firstIndex(where: { isLift($0) }) {
            lifted.bundle.quests[index].status = .completed
            let liftId = lifted.bundle.quests[index].id
            _ = lifted.setNoGym(true, catalog: catalog, now: now)
            if lifted.bundle.quests.first(where: { $0.id == liftId })?.status != .completed {
                errors.append("no gym must keep a finished lift")
            }
        }

        // The setting ends with the quest day.
        let tomorrow = now.addingTimeInterval(86_400)
        day.noGymDayKey = day.bundle.dayKey
        day.refreshIfNeeded(catalog: catalog, now: tomorrow)
        if day.noGymToday || !day.bundle.quests.contains(where: { isLift($0) }) {
            errors.append("no gym should end at the next quest day")
        }

        // A Full Recovery day is not changed.
        var rest = GameSnapshot.fresh(catalog: catalog, now: now)
        rest.signals.spendingFullRecovery = true
        rest.fullRecoveryDayKey = rest.bundle.dayKey
        rest.rebuildBundle(catalog: catalog, now: now)
        let restQuests = rest.bundle.quests
        _ = rest.setNoGym(true, catalog: catalog, now: now)
        if rest.bundle.quests != restQuests || rest.noGymToday {
            errors.append("no gym must not change a Full Recovery day")
        }
        return errors
    }
}
