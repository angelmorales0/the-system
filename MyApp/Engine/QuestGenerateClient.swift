import Foundation

protocol QuestGenerating {
    /// Returns a schema-valid bundle for the locked mode, or a catalog bundle marked `fallback`.
    func generate(context: MorningContext) async -> QuestBundle
}

enum QuestGenerateError: Error {
    case rejected
    case transport
}

/// Picks the mock client unless a local http(s) base URL is configured.
enum QuestGenerateClient {
    static let defaultsKey = "com.angelmorales.thesystem.questGenerateBaseURL"
    static let environmentKey = "QUEST_GENERATE_BASE_URL"
    static let timeout: TimeInterval = 8

    static func make(catalog: FallbackCatalog) -> any QuestGenerating {
        let base = resolvedBase(
            environment: ProcessInfo.processInfo.environment,
            defaults: UserDefaults.standard.string(forKey: defaultsKey)
        )
        if let base {
            return HTTPQuestGenerateClient(baseURL: base, catalog: catalog)
        }
        return MockQuestGenerateClient(catalog: catalog)
    }

    static func resolvedBase(environment: [String: String], defaults: String?) -> URL? {
        let raw = environment[environmentKey] ?? defaults
        guard let raw, !raw.isEmpty, let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    static func endpoint(base: URL) -> URL {
        if base.path.contains("quests/generate") { return base }
        return base
            .appendingPathComponent("v1")
            .appendingPathComponent("quests")
            .appendingPathComponent("generate")
    }
}

struct MockQuestGenerateClient: QuestGenerating {
    var catalog: FallbackCatalog

    func generate(context: MorningContext) async -> QuestBundle {
        bundle(for: context, now: .now)
    }

    func bundle(for context: MorningContext, now: Date) -> QuestBundle {
        let mode = context.modeDecision.selectedMode
        let band = context.whoop.readinessBand
        var built = catalog.makeBundle(mode: mode, band: band, dayKey: context.player.localDate, now: now)
        built.generatedBy = "mock"
        if let target = context.activeTarget {
            built = built.injectingSummary(target, now: now)
        }
        if let accepted = QuestSafety.accepting(built, context: context, assignedAt: now) {
            return accepted
        }
        return catalogFallback(context: context, now: now)
    }
}

struct HTTPQuestGenerateClient: QuestGenerating {
    var baseURL: URL
    var catalog: FallbackCatalog
    var session: URLSession = HTTPQuestGenerateClient.makeSession()

    func generate(context: MorningContext) async -> QuestBundle {
        let now = Date()
        for _ in 0..<3 {
            do {
                let decoded = try await post(context)
                if let accepted = QuestSafety.accepting(decoded, context: context, assignedAt: now) {
                    return accepted
                }
            } catch QuestGenerateError.rejected {
                continue
            } catch {
                break
            }
        }
        return MockQuestGenerateClient(catalog: catalog).catalogFallback(context: context, now: now)
    }

    private func post(_ context: MorningContext) async throws -> QuestBundle {
        var request = URLRequest(url: QuestGenerateClient.endpoint(base: baseURL))
        request.httpMethod = "POST"
        request.timeoutInterval = QuestGenerateClient.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(context)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw QuestGenerateError.transport
        }
        guard let http = response as? HTTPURLResponse else { throw QuestGenerateError.transport }
        if http.statusCode == 422 { throw QuestGenerateError.rejected }
        guard (200..<300).contains(http.statusCode) else { throw QuestGenerateError.transport }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(QuestBundle.self, from: data)
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = QuestGenerateClient.timeout
        configuration.timeoutIntervalForResource = QuestGenerateClient.timeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }
}

extension MockQuestGenerateClient {
    fileprivate func catalogFallback(context: MorningContext, now: Date) -> QuestBundle {
        var built = catalog.makeBundle(
            mode: context.modeDecision.selectedMode,
            band: context.whoop.readinessBand,
            dayKey: context.player.localDate,
            now: now
        )
        if let target = context.activeTarget {
            built = built.injectingSummary(target, now: now)
        }
        built.generatedBy = "fallback"
        return built
    }
}

extension QuestBundle {
    /// Fills target rows from the redacted summary so a generated bundle keeps the day's requirements.
    func injectingSummary(_ target: MorningTarget, now: Date) -> QuestBundle {
        var copy = self
        let training = quests.filter { $0.kind != .targetInjection }
        let injected = target.dailyRequirements.map { requirement in
            quest(from: requirement, target: target, now: now)
        }
        copy.quests = injected + training
        return copy
    }

    private func quest(from requirement: MorningRequirement, target: MorningTarget, now: Date) -> Quest {
        let method = VerificationMethod(rawValue: requirement.verification) ?? .manualConfirm
        let stat = Stat(rawValue: requirement.stat) ?? .INT
        let quota = requirement.quota > 0 ? requirement.quota : 1
        let slug = requirement.templateId.isEmpty ? "req" : requirement.templateId
        var identifier = "q_\(dayKey)_tgt_\(target.id)_\(slug)"
        if identifier.count > 64 {
            identifier = String(identifier.prefix(64))
        }
        if identifier.count < 8 {
            identifier += "_quest"
        }
        return Quest(
            id: identifier,
            title: requirement.title,
            kind: .targetInjection,
            stat: stat,
            verification: VerificationSpec(method: method, params: ["prompt": .string("Confirm \(requirement.title)")]),
            deadline: QuestDay.endOfDay(now),
            xp: 40,
            difficulty: .normal,
            mode: mode,
            targetId: target.id,
            progress: QuestProgress(current: 0, target: quota, unit: "problems"),
            reward: nil,
            status: .pending,
            grantedXP: 0,
            grantedStatPoints: 0,
            grantedRecoveryToken: false,
            evidence: [],
            assignedAt: now
        )
    }
}
