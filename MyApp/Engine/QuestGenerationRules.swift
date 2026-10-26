import Foundation

enum QuestGenerationRules {
    static func check() -> [String] {
        var errors: [String] = []
        let dayKey = "2026-10-01"
        guard let now = QuestDay.date(from: dayKey) else {
            return ["quest day failed to parse"]
        }
        let catalog = (try? FallbackCatalog(data: Data(#"{"schemaVersion":1,"entries":[]}"#.utf8))) ?? FallbackCatalog.bundled()

        var snapshot = GameSnapshot.fresh(catalog: catalog, now: now)
        let training = ContextBuilder.make(snapshot: snapshot, now: now)
        if training.modeDecision.selectedMode != .performanceTraining || training.modeDecision.lockedByRules != true {
            errors.append("green morning should lock performance training")
        }
        if training.player.timezone != QuestDay.timeZone.identifier || training.player.localDate != dayKey {
            errors.append("context day should use the phone's time zone")
        }
        if training.whoop.available || training.mercury.available || training.focus.screenTimeAvailable {
            errors.append("live integrations should stay unavailable")
        }

        snapshot.player.penaltyTier = 1
        let penalty = ContextBuilder.make(snapshot: snapshot, now: now)
        if penalty.modeDecision.selectedMode != .performanceTraining || penalty.modeDecision.lockedByRules != true {
            errors.append("a penalty tier should keep the day's own mode: penalty quests are added on top")
        }
        snapshot.player.penaltyTier = 0
        snapshot.signals.spendingFullRecovery = true
        let recoverySpend = ContextBuilder.make(snapshot: snapshot, now: now)
        if recoverySpend.modeDecision.selectedMode != .fullRecovery {
            errors.append("full recovery spend should lock full_recovery")
        }
        snapshot.signals.spendingFullRecovery = false
        snapshot.signals.readinessBand = .red
        let red = ContextBuilder.make(snapshot: snapshot, now: now)
        if red.modeDecision.selectedMode != .recovery {
            errors.append("red readiness should lock recovery")
        }

        snapshot.signals = .placeholder
        snapshot.recentQuestTitles = ["keep sk-shouldNotLeaveDevice", "Mobility"]
        let morning = ContextBuilder.make(snapshot: snapshot, now: now)
        if let data = try? JSONEncoder().encode(morning), let encoded = String(data: data, encoding: .utf8) {
            // The time zone "America/Los_Angeles" contains "Angel". It is not the display name.
            let text = encoded.replacingOccurrences(of: "Los_Angeles", with: "")
            if text.contains("sk-") || text.contains("Angel") {
                errors.append("morning context leaked a secret or the display name")
            }
        } else {
            errors.append("morning context did not encode")
        }

        let mock = MockQuestGenerateClient(catalog: catalog).bundle(for: morning, now: now)
        if mock.generatedBy != "mock" || mock.mode != .performanceTraining {
            errors.append("mock should return the locked training bundle")
        }
        if mock.quests.contains(where: { $0.status != .pending || $0.progress.current != 0 || !$0.evidence.isEmpty }) {
            errors.append("mock should strip completion")
        }

        var overridden = mock
        overridden.mode = .recovery
        if QuestSafety.issues(in: overridden, context: morning).isEmpty {
            errors.append("locked training mode should reject a recovery bundle")
        }
        if QuestSafety.accepting(overridden, context: morning, assignedAt: now) != nil {
            errors.append("accepting should drop a mode override")
        }

        errors.append(contentsOf: legacyTargetSaveLoads(catalog: catalog, now: now))

        let yellow = sampleContext(mode: .performanceTraining, band: .yellow, dayKey: dayKey)
        var longRun = sampleBundle(mode: .performanceTraining, dayKey: dayKey, now: now)
        longRun.quests[0].title = "Long Run"
        longRun.quests[0].verification.params = ["types": .array([.string("Run")]), "minMovingTimeSec": .number(6000)]
        longRun.quests[0].progress = QuestProgress(current: 0, target: 100, unit: "min")
        if !QuestSafety.issues(in: longRun, context: yellow).contains(where: { $0.contains("90 minutes") }) {
            errors.append("yellow readiness should reject a run over 90 minutes")
        }

        let redContext = sampleContext(mode: .recovery, band: .red, dayKey: dayKey)
        var hardLift = sampleBundle(mode: .recovery, dayKey: dayKey, now: now)
        hardLift.quests[0].title = "Max Lift"
        hardLift.quests[0].stat = .STR
        hardLift.quests[0].difficulty = .hard
        if !QuestSafety.issues(in: hardLift, context: redContext).contains(where: { $0.contains("strength") }) {
            errors.append("red readiness should reject a hard strength quest")
        }

        var lowProtein = sampleBundle(mode: .performanceTraining, dayKey: dayKey, now: now)
        lowProtein.quests[0].title = "Protein"
        lowProtein.quests[0].verification = VerificationSpec(method: .macrofactorProtein, params: ["minProteinG": .number(40)])
        lowProtein.quests[0].progress = QuestProgress(current: 0, target: 40, unit: "g")
        if QuestSafety.issues(in: lowProtein, context: training).isEmpty {
            errors.append("protein below 80g should be rejected")
        }

        var starved = sampleBundle(mode: .performanceTraining, dayKey: dayKey, now: now)
        starved.narrative = "Starve through an all-nighter."
        if !QuestSafety.issues(in: starved, context: training).contains(where: { $0.contains("unsafe") }) {
            errors.append("unsafe phrasing should be rejected")
        }

        var cheapCalories = sampleBundle(mode: .recovery, dayKey: dayKey, now: now)
        cheapCalories.quests[0].verification.params = ["minKcal": .number(1200)]
        cheapCalories.quests[0].progress = QuestProgress(current: 0, target: 1200, unit: "kcal")
        let recoveryGreen = sampleContext(mode: .recovery, band: .green, dayKey: dayKey)
        if QuestSafety.issues(in: cheapCalories, context: recoveryGreen).isEmpty {
            errors.append("calorie target under 1500 should be rejected")
        }

        var debt = sampleBundle(mode: .recovery, dayKey: dayKey, now: now)
        debt.quests[0].verification = VerificationSpec(method: .mercurySpendUnder, params: ["maxDiscretionaryUsd": .number(-5)])
        debt.quests[0].progress = QuestProgress(current: 0, target: 1, unit: "usd")
        if QuestSafety.issues(in: debt, context: recoveryGreen).isEmpty {
            errors.append("negative mercury cap should be rejected")
        }

        if let decoded = decodeModelJSON() {
            let stripped = decoded.strippingModelCompletion(assignedAt: now.addingTimeInterval(5))
            let quest = stripped.quests[0]
            if quest.status != .pending || quest.progress.current != 0 || !quest.evidence.isEmpty || quest.grantedXP != 0 {
                errors.append("model JSON completion was not stripped")
            }
            if quest.assignedAt != now.addingTimeInterval(5) {
                errors.append("model JSON should be assigned locally")
            }
        } else {
            errors.append("model JSON without status should decode")
        }

        let base = QuestGenerateClient.resolvedBase(
            environment: [QuestGenerateClient.environmentKey: "http://127.0.0.1:8787"],
            defaults: "https://example.invalid"
        )
        if base?.absoluteString != "http://127.0.0.1:8787" {
            errors.append("environment base URL should win")
        }
        if QuestGenerateClient.resolvedBase(environment: [:], defaults: "ftp://files.example") != nil {
            errors.append("non-http base URL should be ignored")
        }
        if QuestGenerateClient.resolvedBase(environment: [:], defaults: nil) != nil {
            errors.append("missing base URL should use the mock")
        }
        if let base, !QuestGenerateClient.endpoint(base: base).path.hasSuffix("/v1/quests/generate") {
            errors.append("generate endpoint path mismatch")
        }

        var remembered = GameSnapshot.fresh(catalog: catalog, now: now)
        let previousTitles = remembered.bundle.quests.map(\.title)
        remembered.generationAttemptDayKey = remembered.bundle.dayKey
        remembered.generatedBundle = remembered.bundle
        if let tomorrow = QuestDay.calendar.date(byAdding: .day, value: 1, to: now) {
            remembered.refreshIfNeeded(catalog: catalog, now: tomorrow)
            if remembered.generationAttemptDayKey != nil || remembered.generatedBundle != nil {
                errors.append("a new quest day should allow one new generation")
            }
            if remembered.recentQuestTitles != Array(previousTitles.prefix(8)) {
                errors.append("previous titles should carry into the next morning context")
            }
        }

        let bundled = FallbackCatalog.bundled()
        if bundled.missingCoverage().isEmpty {
            for mode in QuestMode.allCases {
                for band in ReadinessBand.allCases {
                    let context = sampleContext(mode: mode, band: band, dayKey: dayKey)
                    let bundle = bundled.makeBundle(mode: mode, band: band, dayKey: dayKey, now: now)
                    var authored = bundle
                    authored.generatedBy = "mock"
                    let issues = QuestSafety.issues(in: authored, context: context)
                    if !issues.isEmpty {
                        errors.append("catalog \(mode.rawValue)/\(band.rawValue) failed safety: \(issues.joined(separator: ", "))")
                    }
                }
            }
        }
        return errors
    }

    /// Saves from before Targets were removed hold a `targets` array, Target quests, and the Hybrid mode.
    /// They must still load, so the player keeps level and XP.
    private static func legacyTargetSaveLoads(catalog: FallbackCatalog, now: Date) -> [String] {
        var saved = GameSnapshot.fresh(catalog: catalog, now: now)
        saved.player.xp = 77
        guard let data = try? saved.encoded(),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var bundle = json["bundle"] as? [String: Any],
              var quests = bundle["quests"] as? [[String: Any]],
              var targetQuest = quests.first else {
            return ["legacy save fixture did not build"]
        }
        targetQuest["id"] = "q_legacy_tgt"
        targetQuest["kind"] = "target_injection"
        targetQuest["targetId"] = "tgt_legacy"
        targetQuest["mode"] = "hybrid"
        quests.append(targetQuest)
        bundle["quests"] = quests
        bundle["mode"] = "hybrid"
        json["bundle"] = bundle
        json["targets"] = [["id": "tgt_legacy", "title": "Interview Prep"]]
        guard let legacy = try? JSONSerialization.data(withJSONObject: json) else {
            return ["legacy save fixture did not encode"]
        }
        guard let loaded = try? GameSnapshot.decoded(legacy) else {
            return ["a save with old Target data should still load"]
        }
        var errors: [String] = []
        if loaded.player.xp != 77 {
            errors.append("legacy save should keep XP")
        }
        if loaded.bundle.quests.contains(where: { $0.id == "q_legacy_tgt" }) || loaded.bundle.quests.count != quests.count - 1 {
            errors.append("legacy save should drop only the Target quest")
        }
        if loaded.bundle.mode != .performanceTraining {
            errors.append("legacy Hybrid mode should read as Performance Training")
        }
        return errors
    }

    private static func sampleContext(mode: QuestMode, band: ReadinessBand, dayKey: String) -> MorningContext {
        MorningContext(
            schemaVersion: 1,
            player: MorningPlayer(
                timezone: "America/Los_Angeles",
                localDate: dayKey,
                weekday: "Thursday",
                level: 42,
                xp: 3420,
                xpToNext: 5000,
                stats: .starter,
                fullRecoveryBank: 2,
                penaltyTier: 0,
                streaks: .unknown
            ),
            modeDecision: MorningModeDecision(
                ModeDecision(selectedMode: mode, reasonCodes: ["fixture"], lockedByRules: true)
            ),
            whoop: MorningWhoop(
                available: false,
                recoveryScore: nil,
                restingHr: nil,
                hrv: nil,
                sleepPerformance: nil,
                dayStrainYesterday: nil,
                readinessBand: band
            ),
            goalsBias: [],
            nutrition: MorningNutrition(source: "placeholder", available: false, proteinG: nil, proteinTargetG: 150, calories: nil, calorieTarget: nil, asOf: nil),
            mercury: MorningMercury(available: false, spendTodayUsd: nil, softDailyCapUsd: nil, discretionary7dUsd: nil, state: "unavailable"),
            focus: MorningFocus(screenTimeAvailable: false, distractingMinutesYesterday: nil, deepWorkMinutesYesterday: nil, pickupCountYesterday: nil),
            integrationsFreshness: .offline,
            recentQuestTitles: [],
            constraints: .standard
        )
    }

    private static func sampleBundle(mode: QuestMode, dayKey: String, now: Date) -> QuestBundle {
        let quest = Quest(
            id: "q_\(dayKey)_sample",
            title: "Sample Quest",
            kind: .daily,
            stat: .END,
            verification: VerificationSpec(method: .timerSession, params: ["minSec": .number(600)]),
            deadline: QuestDay.endOfDay(now),
            xp: 20,
            difficulty: .easy,
            mode: mode,
            progress: QuestProgress(current: 0, target: 10, unit: "min"),
            reward: nil,
            status: .pending,
            grantedXP: 0,
            grantedStatPoints: 0,
            grantedRecoveryToken: false
        )
        return QuestBundle(
            schemaVersion: 1,
            dayKey: dayKey,
            mode: mode,
            headerLine: mode.headerLine,
            narrative: "Train.",
            quests: [quest],
            warnings: [],
            generatedBy: "llm"
        )
    }

    private static func decodeModelJSON() -> QuestBundle? {
        let raw = """
        {"schemaVersion":1,"dayKey":"2026-10-01","mode":"recovery","narrative":"Rest.","quests":[{"id":"q_20261001_sleep","title":"Sleep Hygiene","kind":"daily","stat":"REC","verification":{"method":"timer_session","params":{"minSec":600}},"deadline":"2026-10-01T23:59:59Z","xp":20,"difficulty":"easy","mode":"performance_training","completed":true,"status":"completed","progress":{"current":9,"target":1,"unit":"session"},"evidence":[{"source":"llm","externalId":"nope","payloadHash":"abc","timestamp":"2026-10-01T12:00:00Z"}],"grantedXP":40}]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(QuestBundle.self, from: Data(raw.utf8))
    }
}
