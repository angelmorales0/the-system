import Foundation

/// One hidden quest the player unlocked. Saved in the snapshot, so the reveal shows once and the log survives relaunch.
struct HiddenQuestUnlock: Codable, Equatable, Identifiable {
    var hiddenId: String
    var title: String
    var dayKey: String
    var questId: String
    var questTitle: String
    /// Measured value and the quest's own target, in `unit` (km).
    var achieved: Double
    var required: Double
    var unit: String
    /// False when the Full Recovery bank was already full.
    var grantedToken: Bool
    /// True after the player closes the reveal window.
    var seen: Bool
    var unlockedAt: Date

    var id: String { "\(hiddenId):\(dayKey)" }

    /// `[15/10km]`, the real distance against the daily target.
    var bracketLabel: String {
        QuestProgress(current: achieved, target: required, unit: unit).bracketLabel
    }

    /// Whole percent over the target: 15 km on a 10 km quest is 50.
    var percentOver: Int {
        guard required > 0 else { return 0 }
        return Int(((achieved / required - 1) * 100).rounded(.down))
    }
}

/// Hidden quests stay off the quest list until their condition is met.
/// Beyond the Limit: finish a distance quest (run or walk) at 150% of its target with the same workout.
enum HiddenQuests {
    static let beyondTheLimitId = "beyond_the_limit"
    static let beyondTheLimitTitle = "Beyond the Limit"
    static let factor = 1.5

    /// END distance quests checked by Strava or Apple Health. Penalty quests never count.
    static func isEligible(_ quest: Quest) -> Bool {
        guard quest.stat == .END, quest.kind != .penalty else { return false }
        guard quest.verification.method == .stravaActivity || quest.verification.method == .healthkitWorkout else { return false }
        return DistanceRule.minimumMeters(quest) != nil
    }

    /// The workout that completed the quest. Only that workout can unlock the hidden quest.
    static func completingWorkout(for quest: Quest, in workouts: [CanonicalWorkout]) -> CanonicalWorkout? {
        let ids = Set(quest.evidence.map(\.externalId).filter { $0.hasPrefix("workout:") }.map { String($0.dropFirst("workout:".count)) })
        return workouts.first { ids.contains($0.id) }
    }

    /// Distance in km against the target in km, when the workout reached 150%.
    static func beyondTheLimit(quest: Quest, workout: CanonicalWorkout) -> (achieved: Double, required: Double)? {
        guard let minimum = DistanceRule.minimumMeters(quest), minimum > 0, let meters = workout.distanceMeters else { return nil }
        guard meters + DistanceRule.toleranceMeters >= minimum * factor else { return nil }
        return (DistanceRule.kilometers(meters), minimum / 1000)
    }
}

extension GameSnapshot {
    /// Unlocks Beyond the Limit at most once per quest day. Not on a red day. Penalty rows never count.
    /// Returns the new unlock, or nil when nothing changed.
    @discardableResult
    mutating func checkHiddenQuests(integrations: DayIntegrationSnapshot, now: Date) -> HiddenQuestUnlock? {
        recordCompletedDistances(integrations: integrations)
        guard signals.readinessBand != .red else { return nil }
        guard !hiddenUnlocks.contains(where: { $0.hiddenId == HiddenQuests.beyondTheLimitId && $0.dayKey == bundle.dayKey }) else { return nil }
        for quest in bundle.quests where quest.status == .completed && HiddenQuests.isEligible(quest) {
            guard let workout = HiddenQuests.completingWorkout(for: quest, in: integrations.workouts),
                  let result = HiddenQuests.beyondTheLimit(quest: quest, workout: workout) else { continue }
            let granted = player.depositRecoveryToken()
            let unlock = HiddenQuestUnlock(
                hiddenId: HiddenQuests.beyondTheLimitId,
                title: HiddenQuests.beyondTheLimitTitle,
                dayKey: bundle.dayKey,
                questId: quest.id,
                questTitle: quest.title,
                achieved: result.achieved,
                required: result.required,
                unit: "km",
                grantedToken: granted,
                seen: false,
                unlockedAt: now
            )
            hiddenUnlocks.append(unlock)
            return unlock
        }
        return nil
    }

    /// A completed distance quest shows the real distance of the run that completed it: 15.2 km on the
    /// 10K Run reads `[15.2/10km]`. Completion alone stops at the target, so this lifts it afterwards.
    mutating func recordCompletedDistances(integrations: DayIntegrationSnapshot) {
        for index in bundle.quests.indices {
            let quest = bundle.quests[index]
            guard quest.status == .completed, DistanceRule.minimumMeters(quest) != nil, quest.progress.unit == "km",
                  let meters = HiddenQuests.completingWorkout(for: quest, in: integrations.workouts)?.distanceMeters else { continue }
            let km = DistanceRule.kilometers(meters)
            if km > quest.progress.current {
                bundle.quests[index].progress.current = km
            }
        }
    }

    /// Today's Beyond the Limit unlock, if any.
    var beyondTheLimitToday: HiddenQuestUnlock? {
        hiddenUnlocks.last { $0.hiddenId == HiddenQuests.beyondTheLimitId && $0.dayKey == bundle.dayKey }
    }

    /// The reveal window waits for this unlock.
    var pendingHiddenReveal: HiddenQuestUnlock? {
        hiddenUnlocks.last { !$0.seen && $0.dayKey == bundle.dayKey }
    }

    mutating func markHiddenRevealSeen(id: String) {
        for index in hiddenUnlocks.indices where hiddenUnlocks[index].id == id {
            hiddenUnlocks[index].seen = true
        }
    }
}

// MARK: - Self-check (runs in DEBUG at launch)

enum HiddenQuestRules {
    static func check() -> [String] {
        var errors: [String] = []
        let catalog = FallbackCatalog.bundled()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let dayKey = QuestDay.key(for: now)

        func run(km: Double, id: String = "strava:run-1") -> CanonicalWorkout {
            CanonicalWorkout(
                id: id,
                sportFamily: .run,
                start: now.addingTimeInterval(-7_200),
                end: now.addingTimeInterval(-3_600),
                movingTimeSec: km * 330,
                distanceMeters: km * 1000,
                sources: ["strava"],
                preferredSource: "strava",
                members: [WorkoutEvent(source: "strava", externalId: id, sport: "Run", start: now.addingTimeInterval(-7_200), end: now.addingTimeInterval(-3_600), movingTimeSec: km * 330, distanceMeters: km * 1000)]
            )
        }

        func integrations(_ workouts: [CanonicalWorkout]) -> DayIntegrationSnapshot {
            var snapshot = DayIntegrationSnapshot.empty(dayKey: dayKey)
            snapshot.strava = StravaDayReading(available: true, configured: true, reason: "", dayKey: dayKey, activities: workouts.flatMap(\.members))
            snapshot.workouts = workouts
            return snapshot
        }

        /// A fresh green Performance Training day with the 10K Run, completed by `workouts` through the real verifier.
        func day(_ workouts: [CanonicalWorkout], band: ReadinessBand = .green, bank: Int = 0) -> (GameSnapshot, DayIntegrationSnapshot, Quest?) {
            var signals = MorningSignals.placeholder
            signals.readinessBand = band
            var player = PlayerState.starter
            player.fullRecoveryBank = bank
            var snapshot = GameSnapshot.fresh(catalog: catalog, now: now, signals: signals, player: player)
            let data = integrations(workouts)
            guard let quest = snapshot.bundle.quests.first(where: { HiddenQuests.isEligible($0) }) else { return (snapshot, data, nil) }
            let context = snapshot.verificationContext(for: quest, now: now, timerElapsed: nil, userConfirmed: false, integrations: data)
            let result = VerifierRegistry.verifier(for: quest.verification.method).evaluate(quest: quest, context: context)
            snapshot.apply(result, questId: quest.id, now: now)
            return (snapshot, data, snapshot.bundle.quests.first { $0.id == quest.id })
        }

        // The green Performance Training day carries the 10K Run as a distance quest.
        var (fifteen, fifteenData, tenK) = day([run(km: 15.2)])
        if tenK?.title != "10K Run" || tenK?.progress.unit != "km" || tenK?.progress.target != 10 {
            errors.append("green Performance Training should have a 10K Run [0/10km], got \(String(describing: tenK?.title)) \(String(describing: tenK?.progress))")
        }
        if tenK?.status != .completed {
            errors.append("a 15.2 km run should complete the 10K Run, got \(String(describing: tenK?.status))")
        }
        // 15.2 km on a 10 km target unlocks Beyond the Limit and banks one token.
        let bankBefore = fifteen.player.fullRecoveryBank
        let unlock = fifteen.checkHiddenQuests(integrations: fifteenData, now: now)
        // The 10K Run row itself carries the extra distance.
        let tenKRow = fifteen.bundle.quests.first { $0.id == tenK?.id }
        if tenKRow?.progress.bracketLabel != "[15.2/10km]" || tenKRow?.status != .completed {
            errors.append("the 10K Run row should show [15.2/10km] after a 15.2 km run, got \(String(describing: tenKRow?.progress))")
        }
        if unlock == nil || unlock?.grantedToken != true || fifteen.player.fullRecoveryBank != bankBefore + 1 {
            errors.append("15.2 km should unlock Beyond the Limit and bank a token, got \(String(describing: unlock)) bank \(fifteen.player.fullRecoveryBank)")
        }
        if unlock?.bracketLabel != "[15.2/10km]" || unlock?.percentOver != 52 {
            errors.append("the unlock should show [15.2/10km] and 52%, got \(String(describing: unlock?.bracketLabel)) \(String(describing: unlock?.percentOver))")
        }
        if fifteen.pendingHiddenReveal?.id != unlock?.id {
            errors.append("a new unlock should wait for the reveal window")
        }
        // Once per day: a second check grants nothing.
        if fifteen.checkHiddenQuests(integrations: fifteenData, now: now) != nil || fifteen.player.fullRecoveryBank != bankBefore + 1 {
            errors.append("Beyond the Limit must unlock at most once per day")
        }
        fifteen.markHiddenRevealSeen(id: unlock?.id ?? "")
        if fifteen.pendingHiddenReveal != nil || fifteen.beyondTheLimitToday == nil {
            errors.append("a seen reveal should close but stay in today's log")
        }
        // The unlock survives a save and load.
        if let data = try? fifteen.encoded(), let loaded = try? GameSnapshot.decoded(data) {
            if loaded.hiddenUnlocks != fifteen.hiddenUnlocks {
                errors.append("hidden unlocks should survive a save and load")
            }
        } else {
            errors.append("the snapshot with a hidden unlock should encode and decode")
        }

        // 14.9 km completes the 10K Run but stays under 150%. The row still shows the real distance.
        var short = day([run(km: 14.9)])
        if short.2?.status != .completed || short.0.checkHiddenQuests(integrations: short.1, now: now) != nil {
            errors.append("14.9 km should complete the 10K Run but not unlock Beyond the Limit")
        }
        if short.0.bundle.quests.first(where: { $0.id == short.2?.id })?.progress.bracketLabel != "[14.9/10km]" {
            errors.append("14.9 km should show [14.9/10km] on the 10K Run row")
        }
        // 7.4 km is partial progress, shown in km.
        let partial = day([run(km: 7.46)])
        if partial.2?.status == .completed || partial.2?.progress.current != 7.4 || partial.2.map(\.progress.bracketLabel) != "[7.4/10km]" {
            errors.append("7.46 km should show [7.4/10km] and stay open, got \(String(describing: partial.2?.progress))")
        }

        // A red recovery day never unlocks it, but the row still shows the distance.
        var red = day([run(km: 16)], band: .red)
        if let quest = red.2, quest.status == .completed {
            if red.0.checkHiddenQuests(integrations: red.1, now: now) != nil {
                errors.append("a red recovery day must not unlock Beyond the Limit")
            }
            if red.0.bundle.quests.first(where: { $0.id == quest.id })?.progress.current != 16 {
                errors.append("a red recovery day should still show the real distance on the row")
            }
        }

        // A second, longer run that did not complete the quest does not count.
        var other = day([run(km: 10.1, id: "strava:run-a")])
        var withLonger = other.1
        withLonger.workouts.append(run(km: 20, id: "strava:run-b"))
        if other.2?.status == .completed, other.0.checkHiddenQuests(integrations: withLonger, now: now) != nil {
            errors.append("only the workout that completed the quest may unlock Beyond the Limit")
        }

        // A full bank still records the unlock, without a token.
        var full = day([run(km: 15)], bank: PlayerState.fullRecoveryCap)
        let fullUnlock = full.0.checkHiddenQuests(integrations: full.1, now: now)
        if fullUnlock == nil || fullUnlock?.grantedToken != false || full.0.player.fullRecoveryBank != PlayerState.fullRecoveryCap {
            errors.append("a full bank should unlock without a token, got \(String(describing: fullUnlock)) bank \(full.0.player.fullRecoveryBank)")
        }
        return errors
    }
}
