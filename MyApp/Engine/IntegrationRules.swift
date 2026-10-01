import Foundation

enum IntegrationRules {
    static func check() -> [String] {
        var errors: [String] = []
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let run = event("strava", "1", "Run", start, 30 * 60, 5000)
        let sameRun = event("healthkit", "hk-1", "running", start.addingTimeInterval(6 * 60), 28 * 60, 4800)
        let later = event("strava", "2", "Run", start.addingTimeInterval(40 * 60), 20 * 60, nil)
        let lift = event("healthkit", "hk-2", "traditionalStrengthTraining", start, 40 * 60, nil)
        if !WorkoutDedupe.sameSession(run, sameRun) {
            errors.append("a run recorded 6 minutes apart should dedupe")
        }
        if WorkoutDedupe.sameSession(run, later) {
            errors.append("runs 40 minutes apart should stay separate")
        }
        if WorkoutDedupe.sameSession(run, lift) {
            errors.append("a run and a lift at the same time are different sessions")
        }
        let clusters = WorkoutDedupe.canonical([run, sameRun, later, lift])
        if clusters.count != 3 {
            errors.append("expected 3 canonical workouts, got \(clusters.count)")
        }
        if let merged = clusters.first(where: { $0.members.count == 2 }) {
            if merged.preferredSource != "strava" || merged.distanceMeters != 5000 {
                errors.append("deduped run should prefer Strava distance")
            }
        } else {
            errors.append("the overlapping run was not clustered")
        }

        var player = PlayerState.starter
        let rec = player.stats.REC
        var snapshot = GameSnapshot(
            version: 1,
            player: player,
            signals: .placeholder,
            bundle: .empty,
            evidenceLog: [],
            runningTimers: []
        )
        snapshot.bundle.dayKey = "2026-10-01"
        let reading = WhoopDayReading(
            available: true,
            configured: true,
            reason: "",
            dayKey: "2026-10-01",
            recoveryScore: 80,
            restingHr: 54,
            hrv: 62,
            sleepPerformance: 90,
            dayStrain: 8,
            scored: true,
            workouts: []
        )
        let catalog = (try? FallbackCatalog(data: Data(#"{"schemaVersion":1,"entries":[]}"#.utf8))) ?? FallbackCatalog.bundled()
        _ = snapshot.applyWhoopReadiness(reading, catalog: catalog, now: QuestDay.date(from: "2026-10-01") ?? start)
        if snapshot.player.stats.REC != rec {
            errors.append("today's recovery score must not overwrite REC")
        }
        if snapshot.readiness?.band != .green || snapshot.readiness?.recoveryScore != 80 {
            errors.append("readiness should store the WHOOP score separately")
        }
        if snapshot.recoveryComposite.rollingAverage != nil {
            errors.append("one score is not a rolling REC composite")
        }
        player.stats.REC = rec
        if ReadinessBand.from(recoveryScore: 50) != .yellow || ReadinessBand.from(recoveryScore: 20) != .red {
            errors.append("WHOOP bands should be green/yellow/red at 67 and 34")
        }

        let day = DayIntegrationSnapshot.make(
            whoop: .disconnected(dayKey: "2026-10-01", reason: "TODO: WHOOP is not connected."),
            strava: .disconnected(dayKey: "2026-10-01", reason: "TODO: Strava is not connected."),
            health: .unavailable
        )
        let disconnected = StravaActivityVerifier().evaluate(
            quest: quest(method: .stravaActivity, params: ["types": .array([.string("Run")]), "minMovingTimeSec": .number(1200)]),
            context: context(day, now: start)
        )
        if case .incomplete(let reason) = disconnected {
            if !reason.contains("TODO") {
                errors.append("disconnected Strava should explain the TODO")
            }
        } else {
            errors.append("disconnected Strava must not complete, got \(disconnected)")
        }
        if VerificationMethod.stravaActivity.allowsLocalCheckbox || VerificationMethod.macrofactorProtein.allowsLocalCheckbox {
            errors.append("connected sources should not use the local checkbox")
        }

        var connected = day
        connected.strava = StravaDayReading(available: true, configured: true, reason: "", dayKey: "2026-10-01", activities: [run])
        connected.workouts = WorkoutDedupe.canonical([run])
        let cleared = StravaActivityVerifier().evaluate(
            quest: quest(method: .stravaActivity, params: ["types": .array([.string("Run")]), "minMovingTimeSec": .number(1200)]),
            context: context(connected, now: start)
        )
        if case .completed(let evidence) = cleared {
            if evidence.source != "strava" || !evidence.externalId.contains("strava:1") {
                errors.append("strava completion should cite the activity")
            }
        } else {
            errors.append("a long enough run should complete, got \(cleared)")
        }

        var health = HealthDaySummary.unavailable
        health.access = .requested
        health.proteinGrams = 160
        health.proteinPrefersMacroFactor = true
        let proteinDay = DayIntegrationSnapshot.make(
            whoop: .disconnected(dayKey: "2026-10-01", reason: ""),
            strava: .disconnected(dayKey: "2026-10-01", reason: ""),
            health: health
        )
        let protein = MacroFactorProteinVerifier().evaluate(
            quest: quest(method: .macrofactorProtein, params: ["minProteinG": .number(150)]),
            context: context(proteinDay, now: start)
        )
        if case .completed(let evidence) = protein {
            if evidence.source != "macrofactor" {
                errors.append("protein evidence should prefer MacroFactor")
            }
        } else {
            errors.append("150g protein should complete at 160g, got \(protein)")
        }
        var short = health
        short.proteinGrams = 40
        short.proteinPrefersMacroFactor = false
        let partialDay = DayIntegrationSnapshot(whoop: proteinDay.whoop, strava: proteinDay.strava, health: short, workouts: [])
        if case .progress = MacroFactorProteinVerifier().evaluate(
            quest: quest(method: .macrofactorProtein, params: ["minProteinG": .number(150)]),
            context: context(partialDay, now: start)
        ) {
        } else {
            errors.append("40g protein should be progress, not a completion")
        }
        let lockedOut = MacroFactorProteinVerifier().evaluate(
            quest: quest(method: .macrofactorProtein, params: ["minProteinG": .number(150)]),
            context: context(day, now: start)
        )
        if case .incomplete = lockedOut {
        } else {
            errors.append("protein without Health access must stay incomplete")
        }

        var duplicate = connected
        duplicate.health = HealthDaySummary(
            access: .requested,
            proteinGrams: 0,
            proteinPrefersMacroFactor: false,
            energyKcal: 0,
            bodyMassKg: nil,
            bodyMassPrefersMacroFactor: false,
            sleepAsleepHours: 0,
            workouts: [sameRun]
        )
        duplicate.workouts = WorkoutDedupe.canonical([run, sameRun])
        let hkRun = HealthKitWorkoutVerifier().evaluate(
            quest: quest(method: .healthkitWorkout, params: ["activityType": .string("running"), "minDurationSec": .number(600)]),
            context: context(duplicate, now: start)
        )
        if case .completed(let evidence) = hkRun {
            if evidence.externalId != "workout:strava:1" {
                errors.append("deduped HealthKit run should use the Strava canonical id, got \(evidence.externalId)")
            }
        } else {
            errors.append("HealthKit can see a deduped run, got \(hkRun)")
        }

        let spendQuest = quest(method: .mercurySpendUnder, params: ["maxDiscretionaryUsd": .number(40)])
        let unconfigured = MercurySpendUnderVerifier().evaluate(quest: spendQuest, context: context(day, now: start))
        if case .incomplete(let reason) = unconfigured {
            if !reason.contains("TODO") {
                errors.append("disconnected Mercury should explain the TODO")
            }
        } else {
            errors.append("disconnected Mercury must not complete, got \(unconfigured)")
        }
        if VerificationMethod.mercurySpendUnder.allowsLocalCheckbox {
            errors.append("mercury should not use the local checkbox")
        }
        var openDay = day
        openDay.mercury = reading(spent: 0, settled: false, pace: "NORMAL", ytd: 0)
        let early = MercurySpendUnderVerifier().evaluate(quest: spendQuest, context: context(openDay, now: start))
        if case .completed = early {
            errors.append("zero spend before the day settles must not complete")
        } else if case .progress = early {
        } else {
            errors.append("an open day under the cap should be progress, got \(early)")
        }
        var settledDay = day
        settledDay.mercury = reading(spent: 10, settled: true, pace: "NORMAL", ytd: 0)
        let clearedSpend = MercurySpendUnderVerifier().evaluate(quest: spendQuest, context: context(settledDay, now: start))
        if case .completed(let evidence) = clearedSpend {
            if evidence.source != "mercury" || evidence.externalId != "mercury:spend:2026-10-01" {
                errors.append("mercury completion should cite the day, got \(evidence.externalId)")
            }
        } else {
            errors.append("settled spend under the cap should complete, got \(clearedSpend)")
        }
        var overDay = day
        overDay.mercury = reading(spent: 50, settled: true, pace: "CRITICAL", ytd: 0)
        let over = MercurySpendUnderVerifier().evaluate(quest: spendQuest, context: context(overDay, now: start))
        if case .failed = over {
        } else {
            errors.append("spend over the cap should fail, got \(over)")
        }

        var rich = GameSnapshot(version: 1, player: .starter, signals: .placeholder, bundle: .empty)
        let recBefore = rich.player.stats.REC
        rich.player.stats.FIN = 110
        rich.applyFinance(reading(spent: 10, settled: true, pace: "NORMAL", ytd: 500_000))
        if rich.player.stats.FIN != 130 {
            errors.append("FIN projection should add 20 points, got \(rich.player.stats.FIN)")
        }
        if rich.player.stats.FIN == 500_000 {
            errors.append("FIN must not become the YTD dollar total")
        }
        rich.player.stats.FIN += 4
        rich.applyFinance(reading(spent: 10, settled: true, pace: "NORMAL", ytd: 500_000))
        if rich.player.stats.FIN != 134 {
            errors.append("applying the same snapshot should keep the quest grant, got \(rich.player.stats.FIN)")
        }
        if rich.player.stats.REC != recBefore {
            errors.append("finance projection must not touch REC")
        }
        rich.bundle.dayKey = "2026-10-01"
        if let when = QuestDay.date(from: "2026-10-01") {
            let morning = ContextBuilder.make(snapshot: rich, now: when)
            if !morning.mercury.available || morning.mercury.state != "NORMAL" || morning.mercury.spendTodayUsd != 10 {
                errors.append("morning context should carry the finance summary")
            }
            if let data = try? JSONEncoder().encode(morning), let encoded = String(data: data, encoding: .utf8), encoded.contains("secret-token") {
                errors.append("morning context leaked a mercury token")
            }
        }
        return errors
    }

    private static func reading(spent: Double, settled: Bool, pace: String, ytd: Double) -> MercuryDayReading {
        MercuryDayReading(
            available: true,
            configured: true,
            reason: "",
            dayKey: "2026-10-01",
            discretionarySpendUsd: spent,
            necessarySpendUsd: 0,
            capUsd: 40,
            paceState: pace,
            ytdIncomeUsd: ytd,
            ytdGoalUsd: 500_000,
            discretionary7dUsd: spent,
            underCap: spent <= 40,
            settled: settled,
            synced: true
        )
    }

    private static func event(_ source: String, _ id: String, _ sport: String, _ start: Date, _ seconds: TimeInterval, _ meters: Double?) -> WorkoutEvent {
        WorkoutEvent(
            source: source,
            externalId: id,
            sport: sport,
            start: start,
            end: start.addingTimeInterval(seconds),
            movingTimeSec: seconds,
            distanceMeters: meters
        )
    }

    private static func quest(method: VerificationMethod, params: [String: JSONValue]) -> Quest {
        Quest(
            id: "q_2026-10-01_\(method.rawValue)",
            title: method.rawValue,
            kind: .daily,
            stat: .END,
            verification: VerificationSpec(method: method, params: params),
            deadline: Date(timeIntervalSince1970: 1_700_000_000),
            xp: 20,
            difficulty: .easy,
            mode: .performanceTraining,
            targetId: nil,
            progress: QuestProgress(current: 0, target: 20, unit: "min"),
            reward: nil,
            status: .pending,
            grantedXP: 0,
            grantedStatPoints: 0,
            grantedRecoveryToken: false
        )
    }

    private static func context(_ integrations: DayIntegrationSnapshot, now: Date) -> VerificationContext {
        VerificationContext(
            now: now,
            dayKey: "2026-10-01",
            assignedAt: now,
            manualConfirmsToday: 0,
            claimedKeys: [],
            timerElapsedSec: nil,
            userConfirmed: false,
            integrations: integrations
        )
    }
}
