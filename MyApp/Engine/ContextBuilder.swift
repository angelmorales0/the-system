import Foundation

/// Assembles the JSON the quest generator sees. Secrets and raw feeds never go in.
enum ContextBuilder {
    nonisolated private static let secretMarkers = ["sk-", "xai-", "bearer ", "api_key", "api-key", "apikey", "secret-token"]

    /// `targets` are the stat targets the player kept. `bodyMass` is the newest Apple Health weigh-in.
    /// `levels` are the stat levels on the Status page, so the planner sees the same numbers as the player.
    static func make(snapshot: GameSnapshot, now: Date = .now, targets: StatTargets = StatTargets(), bodyMass: BodyMassReading? = nil,
                     levels: StatLevelSet = .empty) -> MorningContext {
        let dayKey = QuestDay.key(for: now)
        let decision = ModePicker.decide(snapshot.modeInput(now: now))
        let player = snapshot.player
        let readinessToday = snapshot.readiness?.capturedOn == dayKey ? snapshot.readiness : nil
        let financeToday = snapshot.finance?.dayKey == dayKey ? snapshot.finance : nil
        return MorningContext(
            schemaVersion: 1,
            player: MorningPlayer(
                timezone: QuestDay.timeZone.identifier,
                localDate: dayKey,
                weekday: weekday(now),
                level: levels.overallLevel,
                maxLevel: StatLevelSet.overallMaxLevel,
                statLevels: Dictionary(uniqueKeysWithValues: Stat.allCases.map { ($0.rawValue, levels[$0]) }),
                maxStatLevel: StatLevel.maxLevel,
                fullRecoveryBank: player.fullRecoveryBank,
                penaltyOpen: player.penaltyOpen,
                streaks: .unknown
            ),
            modeDecision: MorningModeDecision(decision),
            whoop: MorningWhoop(
                available: readinessToday != nil,
                recoveryScore: readinessToday?.recoveryScore,
                restingHr: readinessToday?.restingHr,
                hrv: readinessToday?.hrv.map { Int($0.rounded()) },
                sleepPerformance: readinessToday?.sleepPerformance,
                dayStrainYesterday: nil,
                readinessBand: readinessToday?.band ?? .green
            ),
            nutrition: MorningNutrition(
                source: "placeholder",
                available: false,
                proteinG: nil,
                proteinTargetG: 150,
                calories: nil,
                calorieTarget: nil,
                asOf: nil
            ),
            mercury: MorningMercury(
                available: financeToday != nil,
                spendTodayUsd: financeToday?.discretionarySpendUsd,
                softDailyCapUsd: financeToday?.capUsd,
                discretionary7dUsd: financeToday?.discretionary7dUsd,
                state: financeToday?.paceState ?? "unavailable"
            ),
            focus: MorningFocus(
                // A saved picker selection is not minute data. Tokens stay in the App Group.
                screenTimeAvailable: false,
                distractingMinutesYesterday: nil,
                deepWorkMinutesYesterday: nil,
                pickupCountYesterday: nil
            ),
            integrationsFreshness: MorningFreshness(
                whoop: readinessToday == nil ? "unavailable" : "ok",
                strava: "unavailable",
                healthkit: "unavailable",
                mercury: financeToday == nil ? "unavailable" : "ok",
                screenTime: "unavailable"
            ),
            recentQuestTitles: snapshot.recentQuestTitles.prefix(8).map { redact($0) },
            constraints: constraints(noGym: snapshot.noGymDayKey == dayKey),
            recentDays: snapshot.questHistory.prefix(QuestDayRecord.keepDays).map { redacted($0) },
            goals: goals(targets: targets, bodyMass: bodyMass),
            split: MorningSplit(
                name: GymSplit.name,
                rotation: GymSplit.rotation.map(\.name),
                today: GymSplit.today(history: snapshot.questHistory, dayKey: dayKey, goals: targets.custom),
                lastDone: GymSplit.lastDone(history: snapshot.questHistory)
            ),
            rest: rest(snapshot: snapshot, dayKey: dayKey, readiness: readinessToday)
        )
    }

    /// The week's rest as the planner sees it, with the app's own rest signals from today's data.
    static func rest(snapshot: GameSnapshot, dayKey: String, readiness: ReadinessSnapshot?) -> MorningRest {
        let yesterday = QuestDay.key(byAddingDays: -1, to: dayKey)
        let hp = snapshot.hitPoints.map { (current: Int($0.current.rounded(.down)), max: $0.max) }
        let score = RestScore.score(RestScore.Input(
            readinessBand: readiness?.band,
            yesterdayBand: snapshot.questHistory.first { $0.dayKey == yesterday }?.trainingBand,
            sleepPerformance: readiness?.sleepPerformance,
            hrv: readiness?.hrv,
            hrvBaseline: snapshot.fatigue?.hrvBaseline,
            fatigue: snapshot.fatigue.map { Int($0.value.rounded()) } ?? 0,
            hpCritical: hp.map { HitPoints.isCritical(current: $0.current, max: $0.max) } ?? false
        ))
        return MorningRest(
            available: snapshot.restAvailable(on: dayKey),
            trainedDaysInARow: snapshot.trainedDaysInARow(before: dayKey),
            forcedAfterDays: ModePicker.restEveryDays - 1,
            fatigue: snapshot.fatigue.map { Int($0.value.rounded()) } ?? 0,
            hpPercent: hp.flatMap { $0.max > 0 ? Int((Double($0.current) / Double($0.max) * 100).rounded()) : nil },
            signals: score.signals,
            scoreSaysRest: score.saysRest
        )
    }

    private static func redacted(_ day: QuestDayRecord) -> QuestDayRecord {
        var copy = day
        copy.quests = day.quests.map { quest in
            var quest = quest
            quest.title = redact(quest.title)
            return quest
        }
        return copy
    }

    /// The real goals: every STR and END target the player kept, the player's own STR goals, the 7-day running km, and body weight.
    static func goals(targets: StatTargets, bodyMass: BodyMassReading?) -> MorningGoals {
        func goal(_ category: String) -> String { targets.goal(for: category) ?? category }
        var strength = StrengthLevel.lifts.map { lift in
            MorningStrengthTarget(
                category: lift.category,
                goal: goal(lift.category),
                aliases: lift.aliases,
                targetLb: lift.targetLb,
                targetReps: lift.targetReps,
                unit: lift.addedWeight ? "lb added" : lift.category == StrengthLevel.bulgarianSplitSquat.category ? "lb per hand" : "lb"
            )
        }
        strength += [StrengthLevel.pullUps, StrengthLevel.handstandPushUps, StrengthLevel.toesToBar].map { rule in
            MorningStrengthTarget(category: rule.category, goal: goal(rule.category), aliases: rule.aliases, targetLb: nil, targetReps: rule.targetReps, unit: "reps")
        }
        strength += [
            MorningStrengthTarget(category: "Pistol squats", goal: goal("Pistol squats"), aliases: StrengthLevel.pistolAliases, targetLb: nil, targetReps: Int(StrengthLevel.pistolBand.target), unit: "reps per leg"),
            MorningStrengthTarget(category: "Farmer's carry", goal: goal("Farmer's carry"), aliases: StrengthLevel.farmerAliases, targetLb: nil, targetReps: nil, unit: "lb per hand for time"),
            MorningStrengthTarget(category: "Dead hang", goal: goal("Dead hang"), aliases: StrengthLevel.hangAliases, targetLb: nil, targetReps: nil, unit: "seconds",
                                  targetSeconds: StrengthLevel.hangBand.target),
        ]
        strength += targets.custom.map { custom in
            MorningStrengthTarget(
                category: custom.category,
                goal: custom.goal,
                aliases: [custom.alias],
                targetLb: custom.kind == .weightReps ? custom.targetLb : nil,
                targetReps: custom.kind == .hold ? nil : custom.targetReps,
                unit: custom.kind == .weightReps ? "lb" : custom.kind == .reps ? "reps" : "seconds",
                targetSeconds: custom.kind == .hold ? custom.targetSeconds : nil,
                custom: true,
                splitDay: GymSplit.day(id: custom.day)?.name
            )
        }
        let endurance = EnduranceLevel.evaluate(efforts: [], swims: [], vo2: [], zoneTwo: [], now: .now).requirements
            .map(\.category)
            .filter { !targets.isRemoved($0, from: .END) && $0 != "Body weight" }
            .map { MorningTarget(category: $0, goal: goal($0)) }
        return MorningGoals(
            runKmPer7Days: TrainingDay.runKmPer7Days,
            focus: GymSplit.focusTargets.filter { !targets.isRemoved($0, from: .STR) },
            strength: strength.filter { !targets.isRemoved($0.category, from: .STR) },
            endurance: endurance,
            bodyWeight: MorningBodyWeight(
                targetLb: EnduranceLevel.bodyWeightTargetLb,
                toleranceLb: EnduranceLevel.bodyWeightToleranceLb,
                latestLb: bodyMass.map { ($0.pounds * 10).rounded() / 10 },
                measuredOn: bodyMass.map { QuestDay.key(for: $0.date) },
                source: bodyMass?.source
            )
        )
    }

    /// Replaces token-shaped text before it can leave the device.
    nonisolated static func redact(_ value: String) -> String {
        let lower = value.lowercased()
        if secretMarkers.contains(where: { lower.contains($0) }) {
            return "redacted"
        }
        return value
    }

    private static func weekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = QuestDay.timeZone
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }

    private static func constraints(noGym: Bool) -> MorningConstraints {
        var constraints = MorningConstraints.standard
        constraints.noGymToday = noGym
        return constraints
    }
}
