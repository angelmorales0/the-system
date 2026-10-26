import Foundation

struct ModePickerInput: Equatable {
    var spendingFullRecovery: Bool
    var readinessBand: ReadinessBand
    var sleepPerformance: Int?
}

struct ModeDecision: Equatable {
    var selectedMode: QuestMode
    /// Band that sizes the Training day. WHOOP readiness, one step lower after a poor night.
    var trainingBand: ReadinessBand
    var reasonCodes: [String]
    var lockedByRules: Bool
}

/// Rules-only day mode. The LLM is not allowed to override this once it exists.
/// Every day is Performance Training unless a Full Recovery token is spent. Readiness and sleep
/// size the Training day through `trainingBand`; they never pick a different mode.
/// An open penalty does not pick a mode; `PenaltyQuests` adds its rows to the day.
enum ModePicker {
    /// Sleep performance under this drops the training band one step.
    static let lowSleepPerformance = 60

    static func decide(_ input: ModePickerInput) -> ModeDecision {
        let band = trainingBand(readiness: input.readinessBand, sleepPerformance: input.sleepPerformance)
        if input.spendingFullRecovery {
            return lock(.fullRecovery, band, ["full_recovery_spent"])
        }
        var reasons = ["readiness_\(input.readinessBand.rawValue)"]
        if band != input.readinessBand {
            reasons.append("sleep_low")
        }
        return lock(.performanceTraining, band, reasons)
    }

    /// Green, yellow, or red WHOOP readiness, one step lower when sleep performance is under 60%.
    static func trainingBand(readiness: ReadinessBand, sleepPerformance: Int?) -> ReadinessBand {
        guard let sleep = sleepPerformance, sleep < lowSleepPerformance else { return readiness }
        switch readiness {
        case .green: return .yellow
        case .yellow, .red: return .red
        }
    }

    static func checkFixtures() -> [String] {
        var errors: [String] = []
        func expect(_ input: ModePickerInput, _ mode: QuestMode, _ band: ReadinessBand, _ reasons: [String]) {
            let decision = decide(input)
            if decision.selectedMode != mode || decision.trainingBand != band || decision.reasonCodes != reasons || decision.lockedByRules != true {
                errors.append("expected \(mode.rawValue)/\(band.rawValue) \(reasons) got \(decision.selectedMode.rawValue)/\(decision.trainingBand.rawValue) \(decision.reasonCodes) locked=\(decision.lockedByRules)")
            }
        }

        expect(sample(spendingFullRecovery: true, readinessBand: .green), .fullRecovery, .green, ["full_recovery_spent"])
        expect(sample(readinessBand: .green), .performanceTraining, .green, ["readiness_green"])
        expect(sample(readinessBand: .yellow), .performanceTraining, .yellow, ["readiness_yellow"])
        expect(sample(readinessBand: .red), .performanceTraining, .red, ["readiness_red"])
        expect(sample(readinessBand: .green, sleepPerformance: 59), .performanceTraining, .yellow, ["readiness_green", "sleep_low"])
        expect(sample(readinessBand: .yellow, sleepPerformance: 59), .performanceTraining, .red, ["readiness_yellow", "sleep_low"])
        expect(sample(readinessBand: .red, sleepPerformance: 40), .performanceTraining, .red, ["readiness_red"])
        expect(sample(readinessBand: .green, sleepPerformance: 60), .performanceTraining, .green, ["readiness_green"])
        expect(sample(readinessBand: .green, sleepPerformance: nil), .performanceTraining, .green, ["readiness_green"])
        return errors
    }

    private static func lock(_ mode: QuestMode, _ band: ReadinessBand, _ reasons: [String]) -> ModeDecision {
        ModeDecision(selectedMode: mode, trainingBand: band, reasonCodes: reasons, lockedByRules: true)
    }

    private static func sample(
        spendingFullRecovery: Bool = false,
        readinessBand: ReadinessBand = .green,
        sleepPerformance: Int? = 80
    ) -> ModePickerInput {
        ModePickerInput(
            spendingFullRecovery: spendingFullRecovery,
            readinessBand: readinessBand,
            sleepPerformance: sleepPerformance
        )
    }
}
