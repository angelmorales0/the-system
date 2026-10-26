import Foundation

struct ModePickerInput: Equatable {
    var spendingFullRecovery: Bool
    var isSunday: Bool
    var readinessBand: ReadinessBand
    var sleepPerformance: Int?
}

struct ModeDecision: Equatable {
    var selectedMode: QuestMode
    var reasonCodes: [String]
    var lockedByRules: Bool
}

/// Rules-only day mode. The LLM is not allowed to override this once it exists.
/// An open penalty does not pick a mode; `PenaltyQuests` adds its rows to the day.
enum ModePicker {
    static func decide(_ input: ModePickerInput) -> ModeDecision {
        if input.spendingFullRecovery {
            return lock(.fullRecovery, ["full_recovery_spent"])
        }
        if input.isSunday && input.readinessBand == .red {
            return lock(.recovery, ["sunday_red"])
        }
        if input.readinessBand == .red {
            return lock(.recovery, ["readiness_red"])
        }
        if let sleep = input.sleepPerformance, sleep < 60 {
            return lock(.recovery, ["sleep_low"])
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

        expect(sample(spendingFullRecovery: true, readinessBand: .green), .fullRecovery, ["full_recovery_spent"])
        expect(sample(isSunday: true, readinessBand: .red), .recovery, ["sunday_red"])
        expect(sample(readinessBand: .red), .recovery, ["readiness_red"])
        expect(sample(sleepPerformance: 59), .recovery, ["sleep_low"])
        expect(sample(sleepPerformance: 60), .performanceTraining, ["default_training"])
        expect(sample(sleepPerformance: nil), .performanceTraining, ["default_training"])
        expect(sample(readinessBand: .yellow), .performanceTraining, ["default_training"])
        expect(sample(isSunday: true, readinessBand: .green), .performanceTraining, ["default_training"])
        return errors
    }

    private static func lock(_ mode: QuestMode, _ reasons: [String]) -> ModeDecision {
        ModeDecision(selectedMode: mode, reasonCodes: reasons, lockedByRules: true)
    }

    private static func sample(
        spendingFullRecovery: Bool = false,
        isSunday: Bool = false,
        readinessBand: ReadinessBand = .green,
        sleepPerformance: Int? = 80
    ) -> ModePickerInput {
        ModePickerInput(
            spendingFullRecovery: spendingFullRecovery,
            isSunday: isSunday,
            readinessBand: readinessBand,
            sleepPerformance: sleepPerformance
        )
    }
}
