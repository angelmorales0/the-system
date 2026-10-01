import Foundation

/// Assembles the JSON the quest generator sees. Secrets and raw feeds never go in.
enum ContextBuilder {
    private static let secretMarkers = ["sk-", "xai-", "bearer ", "api_key", "api-key", "apikey", "secret-token"]

    static func make(snapshot: GameSnapshot, now: Date = .now) -> MorningContext {
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
                level: player.level,
                xp: player.xp,
                xpToNext: player.xpToNext,
                stats: player.stats,
                fullRecoveryBank: player.fullRecoveryBank,
                penaltyTier: player.penaltyTier,
                streaks: .unknown
            ),
            modeDecision: MorningModeDecision(decision),
            whoop: MorningWhoop(
                available: readinessToday != nil,
                recoveryScore: readinessToday?.recoveryScore,
                restingHr: readinessToday?.restingHr,
                hrv: readinessToday?.hrv,
                sleepPerformance: snapshot.signals.sleepPerformance,
                dayStrainYesterday: nil,
                readinessBand: snapshot.signals.readinessBand
            ),
            calendar: MorningCalendar(
                busyMinutes: snapshot.signals.calendarBusyMinutes,
                focusBlocks: [],
                eventsHint: [],
                wakeWindow: nil
            ),
            activeTarget: snapshot.activeTarget(on: now).map { summary(of: $0, on: dayKey) },
            goalsBias: goalMocks,
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
            recentQuestTitles: snapshot.recentQuestTitles.prefix(8).map(redact),
            constraints: .standard
        )
    }

    /// Replaces token-shaped text before it can leave the device.
    static func redact(_ value: String) -> String {
        let lower = value.lowercased()
        if secretMarkers.contains(where: { lower.contains($0) }) {
            return "redacted"
        }
        return value
    }

    private static func summary(of target: Target, on dayKey: String) -> MorningTarget {
        let end = QuestDay.endOfDay(QuestDay.date(from: target.endsOn) ?? .now)
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = QuestDay.timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return MorningTarget(
            id: target.id,
            title: redact(target.title),
            kind: target.kind.rawValue,
            dayIndex: target.dayNumber(on: dayKey),
            totalDays: target.spanDays,
            endsAt: formatter.string(from: end),
            dailyRequirements: target.dailyRequirements.map { requirement in
                MorningRequirement(
                    templateId: requirement.id,
                    title: redact(requirement.title),
                    quota: requirement.quota,
                    stat: requirement.stat.rawValue,
                    verification: requirement.verification.rawValue
                )
            },
            progress: MorningTargetProgress(
                daysCleared: target.daysCleared,
                unitsDone: target.unitsDone,
                unitsGoal: target.unitsGoal
            )
        )
    }

    private static func weekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = QuestDay.timeZone
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }

    /// Same two cards Goals already shows. They are not loaded from an account.
    private static let goalMocks: [MorningGoalBias] = [
        MorningGoalBias(id: "goal_mile", title: "5:30 Mile", statHint: "END", progress: 0.68),
        MorningGoalBias(id: "goal_bw", title: "145 lb", statHint: "END", progress: 0.36),
    ]
}
