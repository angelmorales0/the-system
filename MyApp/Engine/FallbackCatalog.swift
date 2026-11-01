import Foundation

struct QuestTemplate: Codable, Equatable {
    var id: String
    var title: String
    var kind: QuestKind
    var stat: Stat
    var verification: VerificationSpec
    var difficulty: Difficulty
    var progress: QuestProgress
}

struct CatalogEntry: Codable, Equatable {
    var mode: QuestMode
    var readinessBands: [ReadinessBand]
    var headerLine: String
    var narrative: String
    var warnings: [String]
    var quests: [QuestTemplate]
}

/// Penalty rows for one or more readiness bands. They are added to the day; they are not a day mode.
struct PenaltyEntry: Codable, Equatable {
    var readinessBands: [ReadinessBand]
    var quests: [QuestTemplate]
}

struct FallbackCatalog {
    private var table: [QuestMode: [ReadinessBand: CatalogEntry]]
    private var penaltyTable: [ReadinessBand: [QuestTemplate]] = [:]
    /// The player's own STR goals (`StatTargets.custom`), so the offline split day trains them too. The store sets them.
    var strengthGoals: [CustomStrengthGoal] = []

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
        for entry in file.penaltyQuests ?? [] {
            for band in entry.readinessBands {
                penaltyTable[band] = entry.quests
            }
        }
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
        for band in ReadinessBand.allCases where penaltyTable[band] == nil {
            missing.append("penalty/\(band.rawValue)")
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
                difficulty: template.difficulty,
                mode: mode,
                progress: template.progress,
                status: .pending,
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

    /// Base (tier 1) penalty rows for the band. `PenaltyQuests` scales them by tier.
    func penaltyTemplates(band: ReadinessBand) -> [QuestTemplate] {
        if let match = penaltyTable[band] { return match }
        if let yellow = penaltyTable[.yellow] { return yellow }
        return Self.synthesizedPenalty(band: band)
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
                    kind: .daily,
                    stat: .FOC,
                    verification: VerificationSpec(method: .manualConfirm, params: ["prompt": .string("Confirm complete")]),
                    difficulty: .easy,
                    progress: QuestProgress(current: 0, target: 1, unit: "session")
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
                template("run_10k", "10K Run", .daily, .END, .stravaActivity, ["types": .array([.string("Run")]), "minDistanceMeters": .number(10_000)], .normal, 10, "km"),
                template("bench_press", "Bench Press", .daily, .STR, .hevySets, ["exercise": .string("Bench Press"), "sets": .number(4)], .normal, 4, "sets"),
                template("splits", "Splits", .daily, .AGI, .hevySets, ["exercise": .string("Splits"), "minDurationSec": .number(180)], .easy, 3, "min")
            ]
        )
    }

    /// Used only when the JSON catalog has no penalty rows. A flat 10K, like the bundled catalog.
    private static func synthesizedPenalty(band: ReadinessBand) -> [QuestTemplate] {
        [template("penalty_run", "Penalty 10K", .penalty, .END, .stravaActivity, ["types": .array([.string("Run")]), "minDistanceMeters": .number(TrainingDay.tenKMeters)], .penalty, 10, "km")]
    }

    private static func template(
        _ id: String,
        _ title: String,
        _ kind: QuestKind,
        _ stat: Stat,
        _ method: VerificationMethod,
        _ params: [String: JSONValue],
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
            difficulty: difficulty,
            progress: QuestProgress(current: 0, target: target, unit: unit)
        )
    }
}

private struct CatalogFile: Codable {
    var schemaVersion: Int
    var entries: [CatalogEntry]
    var penaltyQuests: [PenaltyEntry]?
}
