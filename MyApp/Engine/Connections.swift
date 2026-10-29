import Foundation

/// One service the phone reads directly, with no server between.
nonisolated enum Connection: String, CaseIterable, Identifiable {
    case hevy, strava, whoop, codeforces, mercury, claude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hevy: "Hevy"
        case .strava: "Strava"
        case .whoop: "WHOOP"
        case .codeforces: "Codeforces"
        case .mercury: "Mercury"
        case .claude: "Claude"
        }
    }

    /// The Keychain items the owner types in for this service. Codeforces needs none: its handle is public.
    var typedSecrets: [SecretField] {
        switch self {
        case .hevy: [SecretField(item: .hevyApiKey, label: "API key")]
        case .strava: [SecretField(item: .stravaClientId, label: "Client ID"), SecretField(item: .stravaClientSecret, label: "Client secret")]
        case .whoop: [SecretField(item: .whoopClientId, label: "Client ID"), SecretField(item: .whoopClientSecret, label: "Client secret")]
        case .codeforces: []
        case .mercury: [SecretField(item: .mercuryToken, label: "Read Only API token")]
        case .claude: [SecretField(item: .anthropicApiKey, label: "Anthropic API key")]
        }
    }

    /// True when every value the service needs is saved. OAuth services also need a sign-in.
    var isSet: Bool {
        switch self {
        case .codeforces:
            return CodeforcesSettings.handle != nil
        case .strava:
            return typedSecrets.allSatisfy { SecretStore.has($0.item) } && SecretStore.has(.stravaTokens)
        case .whoop:
            return typedSecrets.allSatisfy { SecretStore.has($0.item) } && SecretStore.has(.whoopTokens)
        default:
            return typedSecrets.allSatisfy { SecretStore.has($0.item) }
        }
    }

    /// Removes every saved value for this service, tokens included.
    @MainActor func forget() {
        for field in typedSecrets { SecretStore.delete(field.item) }
        switch self {
        case .strava: SecretStore.delete(.stravaTokens)
        case .whoop: SecretStore.delete(.whoopTokens)
        case .codeforces: CodeforcesSettings.handle = nil
        case .mercury: MercuryClient.deleteLedger()
        default: break
        }
        ConnectionStatusStore.clear(self)
    }
}

nonisolated struct SecretField: Identifiable, Equatable {
    var item: SecretStore.Item
    var label: String
    var id: String { item.rawValue }
}

/// What the Connections screen shows on each row.
nonisolated enum ConnectionHealth: Equatable {
    case notSet
    case connected
    case error(String)

    var label: String {
        switch self {
        case .notSet: "Not set"
        case .connected: "Connected"
        case .error: "Error"
        }
    }
}

/// The result of the last test or fetch, per service. Only our own short messages are saved, never a key or a response body.
nonisolated enum ConnectionStatusStore {
    private static func key(_ connection: Connection) -> String { "com.angelmorales.thesystem.connection.\(connection.rawValue).status" }

    static func record(_ connection: Connection, ok: Bool, message: String = "", defaults: UserDefaults = .standard) {
        let text = ok ? "ok" : "error:" + ContextBuilder.redact(String(message.prefix(160)))
        defaults.set(text, forKey: key(connection))
    }

    static func clear(_ connection: Connection, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(connection))
    }

    static func health(_ connection: Connection, defaults: UserDefaults = .standard) -> ConnectionHealth {
        guard connection.isSet else { return .notSet }
        let saved = defaults.string(forKey: key(connection)) ?? "ok"
        if saved.hasPrefix("error:") { return .error(String(saved.dropFirst(6))) }
        return .connected
    }

    // MARK: - Self-check (runs in DEBUG at launch)

    static func check() -> [String] {
        var errors: [String] = []
        guard let defaults = UserDefaults(suiteName: "com.angelmorales.thesystem.selfcheck.connections") else { return errors }
        defaults.removePersistentDomain(forName: "com.angelmorales.thesystem.selfcheck.connections")
        record(.hevy, ok: false, message: "Hevy refused the key Bearer sk-test", defaults: defaults)
        if defaults.string(forKey: key(.hevy)) != "error:redacted" {
            errors.append("a status message with token-shaped text should be redacted")
        }
        record(.hevy, ok: true, defaults: defaults)
        if defaults.string(forKey: key(.hevy)) != "ok" {
            errors.append("a passing test should save ok")
        }
        defaults.removePersistentDomain(forName: "com.angelmorales.thesystem.selfcheck.connections")
        return errors
    }
}

/// The public Codeforces handle. It is not a secret, so it stays in UserDefaults.
nonisolated enum CodeforcesSettings {
    static let handleKey = "com.angelmorales.thesystem.codeforces.handle"

    static var handle: String? {
        get {
            let value = UserDefaults.standard.string(forKey: handleKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
        set {
            let value = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if value.isEmpty {
                UserDefaults.standard.removeObject(forKey: handleKey)
            } else {
                UserDefaults.standard.set(value, forKey: handleKey)
            }
        }
    }
}
