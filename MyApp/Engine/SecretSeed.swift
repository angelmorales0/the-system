import Foundation

/// Seeds the Anthropic API key from the build, so an install from Xcode never needs it typed in.
/// `Secrets.xcconfig` (gitignored) sets `ANTHROPIC_API_KEY`; the build writes it into the app's Info.plist as
/// `SeedAnthropicApiKey`; the first launch with an empty Keychain saves it there. A key typed in Status → Connections
/// always wins: the seed never replaces a saved key. With no `Secrets.xcconfig` the plist value is empty and nothing happens.
nonisolated enum SecretSeed {
    static let infoKey = "SeedAnthropicApiKey"

    /// The usable key in the plist value, or nil: empty, whitespace, or an unexpanded `$(...)` placeholder is no key.
    static func key(from raw: Any?) -> String? {
        guard let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.hasPrefix("$(") || text.contains("your-key-here") { return nil }
        return text
    }

    /// Saves the build's key when the Keychain has none. Returns true when it saved one.
    @discardableResult
    static func apply(info: [String: Any]? = Bundle.main.infoDictionary) -> Bool {
        guard !SecretStore.has(.anthropicApiKey), let key = key(from: info?[infoKey]) else { return false }
        return SecretStore.save(key, for: .anthropicApiKey)
    }

    static func check() -> [String] {
        var errors: [String] = []
        if key(from: nil) != nil || key(from: "") != nil || key(from: "  \n") != nil { errors.append("an empty seed is no key") }
        if key(from: "$(ANTHROPIC_API_KEY)") != nil { errors.append("an unexpanded placeholder is no key") }
        if key(from: "sk-ant-your-key-here") != nil { errors.append("the example value is no key") }
        if key(from: " sk-ant-abc123 ") != "sk-ant-abc123" { errors.append("a real value should come through trimmed") }
        if Bundle.main.infoDictionary?[infoKey] == nil { errors.append("the app's Info.plist should carry \(infoKey), even empty") }
        return errors
    }
}
