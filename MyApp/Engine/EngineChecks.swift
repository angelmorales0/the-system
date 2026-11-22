/// Every synchronous engine self-check. The app runs them at DEBUG launch; `scripts/engine-checks.sh` runs them in CI.
enum EngineChecks {
    static func run() -> [String] {
        PenaltyQuests.choiceOverride = .run
        let hold = PenaltyHold.firstDay
        PenaltyHold.firstDay = ""
        // The older checks were written for the run penalty and for days before the penalty hold ends.
        let ruleProblems = PenaltyQuests.check() + VerificationFixtures.check() + QuestGenerationRules.check() + IntegrationRules.check() + PenaltyRules.check() + RecoveryLevel.check()
            + StrengthLevel.check() + EnduranceLevel.check() + IntelligenceLevel.check()
            + AgilityLevel.check() + FocusLevel.check() + FinanceLevel.check() + StatLevelSet.check() + StatTargets.check() + FocusTracking.check() + MacScreenClient.check()
            + HiddenQuestRules.check() + RecoveryHolidayRules.check()
            + DailyStretch.check() + StretchSplit.check() + TrainingDay.check() + ModePicker.checkFixtures() + GymSplit.check() + ScreenTimeRules.check()
            + NoGymDayRules.check() + PenaltyDecay.check() + RestRules.check() + RestScore.check() + SecretStore.check() + SecretSeed.check() + ConnectionStatusStore.check() + ConnectionAlerts.check() + LevelAlerts.check()
            + HevyClient.check() + OAuthClient.check() + StravaClient.check() + WhoopClient.check() + CodeforcesClient.check() + MonkeytypeClient.check() + MercuryClient.check()
            + TrainingHistory.check() + HitPoints.check() + Fatigue.check()
            + AgilityHevy.check() + WhoopRecovery.check() + EnduranceEfforts.check() + ZoneTwo.check() + StatInputLoader.check()
            + EndedDayRules.check() + WorkoutClaimRules.check() + RebuiltRowRules.check() + PlanAndLockRules.check()
            + HevyRoutine.check() + HabitRules.check() + HabitEditor.check() + RunBurpees.check() + DailyLines.check()
        PenaltyHold.firstDay = hold
        PenaltyQuests.choiceOverride = nil
        return ruleProblems + PenaltyHold.check() + DayClockRules.check()
    }
}
