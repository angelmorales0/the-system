import Foundation

struct ModePickerInput: Equatable {
    var penaltyTier: Int
    var spendingFullRecovery: Bool
    var isSunday: Bool
    var readinessBand: ReadinessBand
    var sleepPerformance: Int?
    var activeTarget: Bool
    var calendarBusyMinutes: Int
}

struct ModeDecision: Equatable {
    var selectedMode: QuestMode
    var reasonCodes: [String]
    var lockedByRules: Bool
}

/// Rules-only day mode. The LLM is not allowed to override this once it exists.
enum ModePicker {
    static func decide(_ input: ModePickerInput) -> ModeDecision {
        if input.penaltyTier > 0 && !input.spendingFullRecovery {
            return lock(.penalty, ["penalty_active"])
        }
        if input.spendingFullRecovery {
            return lock(.fullRecovery, ["full_recovery_spent"])
        }
        if input.isSunday && input.readinessBand == .red {
            return lock(.recovery, ["sunday_red"])
        }
        if input.activeTarget && input.readinessBand != .red {
            return lock(.hybrid, ["target_active", "whoop_readiness_ok"])
        }
        if input.readinessBand == .red {
            return lock(.recovery, ["readiness_red"])
        }
        if let sleep = input.sleepPerformance, sleep < 60 {
            return lock(.recovery, ["sleep_low"])
        }
        if input.calendarBusyMinutes > 360 {
            // The written rule is `focus_deepwork | nutrition_focus`. Yellow takes the lighter nutrition day.
            if input.readinessBand == .yellow {
                return lock(.nutritionFocus, ["calendar_busy", "readiness_yellow"])
            }
            return lock(.focusDeepwork, ["calendar_busy"])
        }
        return lock(.performanceTraining, ["default_training"])
    }

    static func checkFixtures() -> [String] {
        var errors: [String] = []
        func expect(_ input: ModePickerInput, _ mode: QuestMode, _ reasons: [String]) {
            let decision = decide(input)
            if decision.selectedMode != mode || decision.reasonCodes != reasons || decision.lockedByRules != true {
                errors.append("expected \(mode.rawValue) \(reasons) got \(decision.selectedMode.rawValue) \(decision.reasonCodes) locked=\(decision.lockedByRules)")
            }
        }

        expect(sample(penaltyTier: 1), .penalty, ["penalty_active"])
        expect(sample(penaltyTier: 2, isSunday: true, readinessBand: .red), .penalty, ["penalty_active"])
        expect(sample(penaltyTier: 1, spendingFullRecovery: true), .fullRecovery, ["full_recovery_spent"])
        expect(sample(spendingFullRecovery: true, readinessBand: .green), .fullRecovery, ["full_recovery_spent"])
        expect(sample(isSunday: true, readinessBand: .red), .recovery, ["sunday_red"])
        expect(sample(isSunday: true, readinessBand: .red, activeTarget: true), .recovery, ["sunday_red"])
        expect(sample(readinessBand: .yellow, sleepPerformance: 50, activeTarget: true), .hybrid, ["target_active", "whoop_readiness_ok"])
        expect(sample(readinessBand: .green, activeTarget: true), .hybrid, ["target_active", "whoop_readiness_ok"])
        expect(sample(readinessBand: .red, activeTarget: true), .recovery, ["readiness_red"])
        expect(sample(readinessBand: .red, calendarBusyMinutes: 500), .recovery, ["readiness_red"])
        expect(sample(sleepPerformance: 59), .recovery, ["sleep_low"])
        expect(sample(sleepPerformance: 60), .performanceTraining, ["default_training"])
        expect(sample(sleepPerformance: nil), .performanceTraining, ["default_training"])
        expect(sample(readinessBand: .yellow, calendarBusyMinutes: 361), .nutritionFocus, ["calendar_busy", "readiness_yellow"])
        expect(sample(readinessBand: .green, calendarBusyMinutes: 400), .focusDeepwork, ["calendar_busy"])
        expect(sample(calendarBusyMinutes: 360), .performanceTraining, ["default_training"])
        expect(sample(isSunday: true, readinessBand: .green), .performanceTraining, ["default_training"])
        return errors
    }

    private static func lock(_ mode: QuestMode, _ reasons: [String]) -> ModeDecision {
        ModeDecision(selectedMode: mode, reasonCodes: reasons, lockedByRules: true)
    }

    private static func sample(
        penaltyTier: Int = 0,
        spendingFullRecovery: Bool = false,
        isSunday: Bool = false,
        readinessBand: ReadinessBand = .green,
        sleepPerformance: Int? = 80,
        activeTarget: Bool = false,
        calendarBusyMinutes: Int = 120
    ) -> ModePickerInput {
        ModePickerInput(
            penaltyTier: penaltyTier,
            spendingFullRecovery: spendingFullRecovery,
            isSunday: isSunday,
            readinessBand: readinessBand,
            sleepPerformance: sleepPerformance,
            activeTarget: activeTarget,
            calendarBusyMinutes: calendarBusyMinutes
        )
    }
}
