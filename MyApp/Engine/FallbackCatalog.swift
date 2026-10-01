import Foundation

struct QuestTemplate: Codable, Equatable {
    var id: String
    var title: String
    var kind: QuestKind
    var stat: Stat
    var verification: VerificationSpec
    var xp: Int
    var difficulty: Difficulty
    var targetId: String?
    var progress: QuestProgress
    var reward: QuestReward?
}

struct CatalogEntry: Codable, Equatable {
    var mode: QuestMode
    var readinessBands: [ReadinessBand]
    var headerLine: String
    var narrative: String
    var warnings: [String]
    var quests: [QuestTemplate]
}

struct FallbackCatalog {
    private var table: [QuestMode: [ReadinessBand: CatalogEntry]]

    init(data: Data) throws {
        let file = try JSONDecoder().decode(CatalogFile.self, from: data)
        guard file.schemaVersion == 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unsupported catalog schema"))
        }
        var table: [QuestMode: [ReadinessBand: CatalogEntry]] = [:]
        for entry in file.entries {
            for band in entry.readinessBands {
                table[entry.mode, default: [:]][band] = entry
            }
        }
        self.table = table
    }

    private init(table: [QuestMode: [ReadinessBand: CatalogEntry]]) {
        self.table = table
    }

    static func bundled() -> FallbackCatalog {
        // Synchronized Xcode groups may copy Resources/ into the bundle root or keep the folder.
        let urls = [
            Bundle.main.url(forResource: "FallbackCatalog", withExtension: "json"),
            Bundle.main.url(forResource: "FallbackCatalog", withExtension: "json", subdirectory: "Resources"),
        ]
        for url in urls.compactMap({ $0 }) {
            if let data = try? Data(contentsOf: url),
               let catalog = try? FallbackCatalog(data: data) {
                return catalog
            }
        }
        return FallbackCatalog(table: [:])
    }

    func missingCoverage(modes: [QuestMode] = QuestMode.allCases) -> [String] {
        var missing: [String] = []
        for mode in modes {
            for band in ReadinessBand.allCases where table[mode]?[band] == nil {
                missing.append("\(mode.rawValue)/\(band.rawValue)")
            }
        }
        return missing
    }

    func makeBundle(mode: QuestMode, band: ReadinessBand, dayKey: String, now: Date) -> QuestBundle {
        let entry = resolve(mode: mode, band: band)
        let deadline = QuestDay.endOfDay(now)
        let quests = entry.quests.map { template in
            Quest(
                id: "q_\(dayKey)_\(template.id)",
                title: template.title,
                kind: template.kind,
                stat: template.stat,
                verification: template.verification,
                deadline: deadline,
                xp: template.xp,
                difficulty: template.difficulty,
                mode: mode,
                targetId: template.targetId,
                progress: template.progress,
                reward: template.reward,
                status: .pending,
                grantedXP: 0,
                grantedStatPoints: 0,
                grantedRecoveryToken: false,
                evidence: [],
                assignedAt: now
            )
        }
        return QuestBundle(
            schemaVersion: 1,
            dayKey: dayKey,
            mode: mode,
            headerLine: entry.headerLine,
            narrative: entry.narrative,
            quests: quests,
            warnings: entry.warnings,
            generatedBy: "fallback"
        ).strippingModelCompletion(assignedAt: now)
    }

    private func resolve(mode: QuestMode, band: ReadinessBand) -> CatalogEntry {
        if let match = table[mode]?[band] { return match }
        if let yellow = table[mode]?[.yellow] { return yellow }
        if let any = table[mode]?.values.first { return any }
        return Self.synthesized(mode: mode, band: band)
    }

    /// Used only when the JSON catalog cannot be read. Green training matches the original rows.
    private static func synthesized(mode: QuestMode, band: ReadinessBand) -> CatalogEntry {
        if mode == .performanceTraining {
            return performanceTrainingGreen(band: band)
        }
        return CatalogEntry(
            mode: mode,
            readinessBands: [band],
            headerLine: mode.headerLine,
            narrative: "Offline fallback.",
            warnings: [QuestBundle.defaultWarning],
            quests: [
                QuestTemplate(
                    id: "manual",
                    title: mode.headerLine,
                    kind: mode == .penalty ? .penalty : .daily,
                    stat: .FOC,
                    verification: VerificationSpec(method: .manualConfirm, params: ["prompt": .string("Confirm complete")]),
                    xp: 20,
                    difficulty: mode == .penalty ? .penalty : .easy,
                    targetId: nil,
                    progress: QuestProgress(current: 0, target: 1, unit: "session"),
                    reward: nil
                )
            ]
        )
    }

    private static func performanceTrainingGreen(band: ReadinessBand) -> CatalogEntry {
        CatalogEntry(
            mode: .performanceTraining,
            readinessBands: [band],
            headerLine: QuestMode.performanceTraining.headerLine,
            narrative: "Train. The daily quest is waiting.",
            warnings: [QuestBundle.defaultWarning],
            quests: [
                template("run_intervals", "Run Intervals", .daily, .END, .stravaActivity, ["types": .array([.string("Run")]), "minMovingTimeSec": .number(1200)], 40, .normal, 6, "reps"),
                template("bench_press", "Bench Press", .daily, .STR, .healthkitWorkout, ["activityType": .string("traditionalStrengthTraining"), "sets": .number(4)], 40, .normal, 4, "sets"),
                template("mobility", "Mobility", .daily, .AGI, .timerSession, ["minSec": .number(600), "label": .string("Mobility")], 20, .easy, 10, "min"),
                template("protein", "Protein", .daily, .END, .macrofactorProtein, ["minProteinG": .number(150)], 25, .easy, 150, "g")
            ]
        )
    }

    private static func template(
        _ id: String,
        _ title: String,
        _ kind: QuestKind,
        _ stat: Stat,
        _ method: VerificationMethod,
        _ params: [String: JSONValue],
        _ xp: Int,
        _ difficulty: Difficulty,
        _ target: Double,
        _ unit: String
    ) -> QuestTemplate {
        QuestTemplate(
            id: id,
            title: title,
            kind: kind,
            stat: stat,
            verification: VerificationSpec(method: method, params: params),
            xp: xp,
            difficulty: difficulty,
            targetId: nil,
            progress: QuestProgress(current: 0, target: target, unit: unit),
            reward: nil
        )
    }
}

private struct CatalogFile: Codable {
    var schemaVersion: Int
    var entries: [CatalogEntry]
}
