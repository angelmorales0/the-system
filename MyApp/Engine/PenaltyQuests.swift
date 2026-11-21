import Foundation

/// An open penalty (`player.penaltyOpen`) adds red `kind: .penalty` rows to the top of the normal day.
/// It does not change the day mode. A Full Recovery day adds none; the penalty waits for the next day.
/// While a row is open, every app is locked (see `PenaltyEnforcement`), so a run in Strava or Apple Health clears it.
/// The row is a 10K run or 300 burpees, 50/50 by the quest day (see `choice(dayKey:)`). A run row can be swapped
/// for the burpees with "Unable to go outside" (`swapToBurpees`). Another missed day while it is open changes nothing.
enum PenaltyQuests {
    enum Choice: Equatable { case run, burpees }

    static let burpeeTemplateId = "penalty_burpees"
    static let burpeeTitle = "Penalty 300 Burpees"
    static let burpeeExercise = "Burpee"
    static let burpeeReps = 300

    /// Self-checks set this so the rows they test stay the run. Nil in the app.
    static var choiceOverride: Choice?

    /// 50/50 and stable for a day: the same day always gives the same penalty, so a relaunch cannot reroll it.
    static func choice(dayKey: String) -> Choice {
        if let choiceOverride { return choiceOverride }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "penalty|\(dayKey)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return (hash >> 7) % 2 == 0 ? .run : .burpees
    }

    static func isBurpees(_ quest: Quest) -> Bool {
        quest.kind == .penalty && quest.verification.method == .hevySets
    }

    /// The burpee penalty: 300 reps of Hevy's "Burpee", in one set or many, across the day's workouts.
    static func burpeeTemplate() -> QuestTemplate {
        QuestTemplate(
            id: burpeeTemplateId,
            title: burpeeTitle,
            kind: .penalty,
            stat: .END,
            verification: VerificationSpec(method: .hevySets, params: ["exercise": .string(burpeeExercise), "totalReps": .number(Double(burpeeReps))]),
            difficulty: .penalty,
            progress: QuestProgress(current: 0, target: Double(burpeeReps), unit: "reps")
        )
    }

    /// "Unable to go outside": the open run row becomes the burpee row. A finished or started run stays a run.
    /// Burpees count for one row: a day whose run is done as burpees keeps the run penalty.
    static func swapToBurpees(in bundle: QuestBundle, now: Date) -> QuestBundle {
        guard !bundle.quests.contains(where: { RunBurpees.isBurpeeRow($0) }), let index = bundle.quests.firstIndex(where: { $0.kind == .penalty && !isBurpees($0) && $0.status != .completed && $0.progress.current == 0 })
        else { return bundle }
        var copy = bundle
        var row = quest(from: burpeeTemplate(), bundle: bundle, now: now)
        var number = 2
        let base = row.id
        while copy.quests.contains(where: { $0.id == row.id }) {
            row.id = "\(base)_\(number)"
            number += 1
        }
        copy.quests[index] = row
        return copy
    }

    /// Adds the rows once, above the day's quests. Open penalty rows keep their progress.
    /// A penalty that opens after the day's penalty run is a new debt (a missed month, judged later that day):
    /// the finished row does not serve it, so it gets its own open row, with its own id.
    static func ensure(in bundle: QuestBundle, open: Bool, band: ReadinessBand, catalog: FallbackCatalog, now: Date) -> QuestBundle {
        guard open, bundle.mode != .fullRecovery, !bundle.quests.isEmpty,
              !bundle.quests.contains(where: { $0.kind == .penalty && $0.status != .completed }) else { return bundle }
        var copy = bundle
        var rows: [Quest] = []
        let templates = choice(dayKey: bundle.dayKey) == .run ? catalog.penaltyTemplates(band: band) : [burpeeTemplate()]
        for template in templates {
            var row = quest(from: template, bundle: bundle, now: now)
            var number = 2
            let base = row.id
            while (copy.quests + rows).contains(where: { $0.id == row.id }) {
                row.id = "\(base)_\(number)"
                number += 1
            }
            rows.append(row)
        }
        copy.quests.insert(contentsOf: rows, at: 0)
        return copy
    }

    static func rows(in bundle: QuestBundle) -> [Quest] {
        bundle.quests.filter { $0.kind == .penalty }
    }

    static func isCleared(in bundle: QuestBundle) -> Bool {
        let rows = rows(in: bundle)
        return !rows.isEmpty && rows.allSatisfy { $0.status == .completed }
    }

    private static func quest(from template: QuestTemplate, bundle: QuestBundle, now: Date) -> Quest {
        Quest(
            id: "q_\(bundle.dayKey)_\(template.id)",
            title: template.title,
            kind: .penalty,
            stat: template.stat,
            verification: template.verification,
            deadline: QuestDay.endOfDay(now),
            difficulty: .penalty,
            mode: bundle.mode,
            progress: QuestProgress(current: 0, target: template.progress.target, unit: template.progress.unit),
            status: .pending,
            evidence: [],
            assignedAt: now
        )
    }
}

extension GameSnapshot {
    /// Spends one banked Full Recovery token to end the open penalty: it closes and the penalty rows go.
    /// Today's own quests stay as they are, so the day is not a rest day.
    mutating func clearPenaltyWithFullRecovery() -> String {
        guard player.penaltyOpen else { return "No penalty is open." }
        guard player.fullRecoveryBank > 0 else { return "No Full Recovery token in the bank." }
        player.withdrawRecoveryToken()
        player.penaltyOpen = false
        bundle.quests.removeAll { $0.kind == .penalty }
        return "Full Recovery spent. The penalty is cleared. Today's quests stay."
    }
}

// MARK: - Self-check (runs in DEBUG at launch)

extension PenaltyQuests {
    static func check() -> [String] {
        var errors: [String] = []
        let saved = choiceOverride
        defer { choiceOverride = saved }

        // 50/50 over a year of days, and stable for each day.
        choiceOverride = nil
        var key = "2026-01-01"
        var runs = 0
        for _ in 0..<366 {
            if choice(dayKey: key) == .run { runs += 1 }
            if choice(dayKey: key) != choice(dayKey: key) { errors.append("the penalty for \(key) should not change") }
            key = QuestDay.key(byAddingDays: 1, to: key)
        }
        if !(150...216).contains(runs) { errors.append("about half the days should get the run, got \(runs)/366") }

        let catalog = FallbackCatalog.bundled()
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        func opened(_ pick: Choice) -> GameSnapshot {
            choiceOverride = pick
            var snapshot = GameSnapshot.fresh(catalog: catalog, now: now)
            snapshot.player.penaltyOpen = true
            snapshot.bundle = ensure(in: snapshot.bundle, open: true, band: .green, catalog: catalog, now: now)
            return snapshot
        }

        // A burpee day: one Hevy row of 300 reps.
        let burpeeDay = opened(.burpees)
        let burpeeRows = rows(in: burpeeDay.bundle)
        if burpeeRows.count != 1 || burpeeRows.first.map(isBurpees) != true || burpeeRows.first?.progress.target != 300 {
            errors.append("a burpee day should open one 300-burpee row, got \(burpeeRows.map(\.title))")
        }

        // A run day: "Unable to go outside" swaps the open run for the burpees, once.
        let runDay = opened(.run)
        let swapped = swapToBurpees(in: runDay.bundle, now: now)
        let swappedRows = rows(in: swapped)
        if rows(in: runDay.bundle).first.map(isBurpees) != false || swappedRows.count != 1 || swappedRows.first.map(isBurpees) != true
            || swapped.quests.count != runDay.bundle.quests.count {
            errors.append("unable to go outside should replace the run with the burpees, got \(swappedRows.map(\.title))")
        }
        if swapToBurpees(in: swapped, now: now) != swapped { errors.append("a burpee row should not swap again") }
        var started = runDay.bundle
        if let index = started.quests.firstIndex(where: { $0.kind == .penalty }) { started.quests[index].progress.current = 2.5 }
        if swapToBurpees(in: started, now: now) != started { errors.append("a run already under way should not swap") }

        // Hevy reps add up across sets and workouts: 120 + 100 is progress, 80 more clears it. Other exercises do not count.
        func hevy(_ sets: [[Int]]) -> DayIntegrationSnapshot {
            var day = DayIntegrationSnapshot.empty(dayKey: burpeeDay.bundle.dayKey)
            day.hevy = HevyDayReading(available: true, configured: true, reason: "", dayKey: burpeeDay.bundle.dayKey, workouts: sets.enumerated().map { index, reps in
                HevyWorkout(id: "w\(index)", title: "Penalty", start: now.addingTimeInterval(Double(index) * 3_600), end: now.addingTimeInterval(Double(index) * 3_600 + 1_800),
                            exercises: [HevyExercise(title: "Burpee", templateId: nil, sets: reps.map { HevySet(type: "normal", reps: $0) }),
                                        HevyExercise(title: "Push Up", templateId: nil, sets: [HevySet(type: "normal", reps: 50)])])
            })
            return day
        }
        guard let row = burpeeRows.first else { return errors }
        let verifier = HevySetsVerifier()
        let context = { (integrations: DayIntegrationSnapshot) in
            VerificationContext(now: now.addingTimeInterval(10_000), dayKey: burpeeDay.bundle.dayKey, assignedAt: now, manualConfirmsToday: 0,
                                claimedKeys: [], timerElapsedSec: nil, userConfirmed: false, integrations: integrations)
        }
        switch verifier.evaluate(quest: row, context: context(hevy([[60, 60], [100]]))) {
        case .progress(let current, _) where current == 220: break
        case let other: errors.append("220 burpees should be progress 220/300, got \(other)")
        }
        if case .completed = verifier.evaluate(quest: row, context: context(hevy([[60, 60], [100, 80]]))) {} else {
            errors.append("300 burpees across two workouts should clear the penalty")
        }
        let threat = PenaltyDecay.threatLine(generated: nil, dayKey: "2026-10-28", burpees: true)
        if !threat.hasSuffix(PenaltyDecay.burpeeEnding) || threat.contains("10 km") {
            errors.append("the burpee threat should ask for burpees, got \(threat)")
        }
        return errors
    }
}
