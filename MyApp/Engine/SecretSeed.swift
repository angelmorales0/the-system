import Foundation

/// Seeds the connection keys from the build, so an install from Xcode never needs them typed in.
/// `scripts/make-secrets.sh` writes `Secrets.xcconfig` (gitignored) from `backend/.env`; `Config.xcconfig` carries each
/// value into the app's Info.plist under a `Seed…` key; the first launch saves each one whose Keychain item is empty.
/// A value typed in Status → Connections always wins: the seed never replaces a saved one. With no `Secrets.xcconfig`
/// every plist value is empty and nothing happens. OAuth tokens are not seeded: the sign-in on the phone makes them.
nonisolated enum SecretSeed {
    /// Info.plist key → Keychain item.
    static let items: [(infoKey: String, item: SecretStore.Item)] = [
        ("SeedAnthropicApiKey", .anthropicApiKey),
        ("SeedHevyApiKey", .hevyApiKey),
        ("SeedWhoopClientId", .whoopClientId),
        ("SeedWhoopClientSecret", .whoopClientSecret),
        ("SeedStravaClientId", .stravaClientId),
        ("SeedStravaClientSecret", .stravaClientSecret),
        ("SeedMercuryToken", .mercuryToken),
    ]
    /// The Codeforces handle is public and lives in UserDefaults, not the Keychain.
    static let codeforcesInfoKey = "SeedCodeforcesHandle"
    static var infoKeys: [String] { items.map(\.infoKey) + [codeforcesInfoKey] }

    /// The usable value in a plist entry, or nil: empty, whitespace, an unexpanded `$(...)` placeholder, or the example text is none.
    static func value(from raw: Any?) -> String? {
        guard let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.hasPrefix("$(") || text.contains("your-key-here") { return nil }
        return text
    }

    /// Saves each seeded value whose item is still empty. Returns the items it saved.
    @discardableResult
    static func apply(info: [String: Any]? = Bundle.main.infoDictionary) -> [SecretStore.Item] {
        var saved: [SecretStore.Item] = []
        for (infoKey, item) in items where !SecretStore.has(item) {
            guard let value = value(from: info?[infoKey]) else { continue }
            if SecretStore.save(value, for: item) { saved.append(item) }
        }
        if CodeforcesSettings.handle == nil, let handle = value(from: info?[codeforcesInfoKey]) {
            CodeforcesSettings.handle = handle
        }
        return saved
    }

    static func check() -> [String] {
        var errors: [String] = []
        if value(from: nil) != nil || value(from: "") != nil || value(from: "  \n") != nil { errors.append("an empty seed is no value") }
        if value(from: "$(ANTHROPIC_API_KEY)") != nil { errors.append("an unexpanded placeholder is no value") }
        if value(from: "sk-ant-your-key-here") != nil { errors.append("the example value is no value") }
        if value(from: " sk-ant-abc123 ") != "sk-ant-abc123" { errors.append("a real value should come through trimmed") }
        if Set(items.map(\.item)).count != items.count || Set(infoKeys).count != infoKeys.count { errors.append("each seed names one item once") }
        let typed = Set(Connection.allCases.flatMap { $0.typedSecrets.map(\.item) })
        if typed != Set(items.map(\.item)) { errors.append("the seed should cover exactly the typed secrets, got \(items.map(\.item)) for \(typed)") }
        for key in infoKeys where Bundle.main.infoDictionary?[key] == nil {
            errors.append("the app's Info.plist should carry \(key), even empty")
        }
        return errors
    }
}
