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
        return errors
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
