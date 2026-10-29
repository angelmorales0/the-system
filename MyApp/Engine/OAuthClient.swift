import Foundation

/// The two OAuth services. The owner registers their own app with each one and types its client ID and secret.
enum OAuthProvider: String, CaseIterable {
    case strava, whoop

    /// The app catches this scheme in `ASWebAuthenticationSession`. No Info.plist entry is needed for that.
    static let callbackScheme = "thesystem"

    /// Register this exact value with the service (WHOOP: Redirect URL; Strava: callback domain `localhost`).
    var redirectURI: String { "\(Self.callbackScheme)://localhost/\(rawValue)" }

    var authorizeURL: String {
        switch self {
        case .strava: "https://www.strava.com/oauth/authorize"
        case .whoop: "https://api.prod.whoop.com/oauth/oauth2/auth"
        }
    }

    var tokenURL: String {
        switch self {
        case .strava: "https://www.strava.com/oauth/token"
        case .whoop: "https://api.prod.whoop.com/oauth/oauth2/token"
        }
    }

    var scopes: String {
        switch self {
        case .strava: "activity:read_all"
        case .whoop: "offline read:recovery read:sleep read:cycles read:workout read:body_measurement"
        }
    }

    var clientIdItem: SecretStore.Item { self == .strava ? .stravaClientId : .whoopClientId }
    var clientSecretItem: SecretStore.Item { self == .strava ? .stravaClientSecret : .whoopClientSecret }
    var tokensItem: SecretStore.Item { self == .strava ? .stravaTokens : .whoopTokens }
    var connection: Connection { self == .strava ? .strava : .whoop }
    var title: String { connection.title }
}

/// OAuth on the phone: sign-in URL, code exchange, and refresh. Port of the backend's token handling.
/// Tokens stay in the Keychain. WHOOP rotates the refresh token on each use, so refreshes run one at a time.
enum OAuthClient {
    /// One refresh per provider at a time: a second WHOOP refresh with the old token would fail.
    private static var refreshing: [OAuthProvider: Task<String?, Never>] = [:]

    /// The sign-in page. `state` must come back unchanged; WHOOP needs at least 8 characters.
    static func authorizeURL(_ provider: OAuthProvider, clientId: String, state: String) -> URL? {
        var query = [
            ("client_id", clientId),
            ("redirect_uri", provider.redirectURI),
            ("response_type", "code"),
        ]
        if provider == .strava { query.append(("approval_prompt", "auto")) }
        query += [("scope", provider.scopes), ("state", state)]
        return OnDeviceHTTP.url(provider.authorizeURL, query)
    }

    static func newState() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// The code in the callback, or a message when the service refused or the state does not match.
    static func code(from callback: URL, provider: OAuthProvider, state: String) -> Result<String, OAuthError> {
        guard callback.absoluteString.hasPrefix(provider.redirectURI) else { return .failure(.message("The sign-in came back to the wrong address.")) }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        if let error = value("error") { return .failure(.message("\(provider.title) refused the sign-in: \(error).")) }
        guard value("state") == state else { return .failure(.message("The sign-in state did not match. Try again.")) }
        guard let code = value("code"), !code.isEmpty else { return .failure(.message("\(provider.title) sent no code.")) }
        return .success(code)
    }

    struct OAuthError: Error, Equatable {
        var text: String
        static func message(_ text: String) -> OAuthError { OAuthError(text: text) }
    }

    /// Trades the sign-in code for tokens and saves them.
    static func exchange(_ provider: OAuthProvider, code: String) async -> (ok: Bool, message: String) {
        guard let clientId = SecretStore.read(provider.clientIdItem), let secret = SecretStore.read(provider.clientSecretItem),
              let url = URL(string: provider.tokenURL) else { return (false, "Type the client ID and secret first.") }
        var body = ["grant_type": "authorization_code", "code": code, "client_id": clientId, "client_secret": secret]
        if provider == .whoop { body["redirect_uri"] = provider.redirectURI }
        guard let reply = await OnDeviceHTTP.postForm(url, body: body) else { return (false, "Cannot reach \(provider.title).") }
        guard (200..<300).contains(reply.status), let tokens = reply.json, tokens["access_token"]?.stringValue?.isEmpty == false else {
            return (false, "\(provider.title) token exchange failed (HTTP \(reply.status)).")
        }
        save(provider, tokens: tokens, previous: nil)
        return (true, "Signed in to \(provider.title).")
    }

    /// A working access token: the saved one, or a fresh one when it ends within a minute. Nil when refresh fails.
    static func accessToken(_ provider: OAuthProvider, now: Date = .now) async -> String? {
        guard let stored = tokens(provider) else { return nil }
        let token = stored["access_token"]?.stringValue ?? ""
        let expires = stored["expires_at"]?.doubleValue ?? 0
        if !token.isEmpty, expires == 0 || expires >= now.timeIntervalSince1970 + 60 {
            return token
        }
        guard stored["refresh_token"]?.stringValue?.isEmpty == false else { return nil }
        return await refresh(provider)
    }

    /// Exchanges the refresh token. WHOOP's reply has a new refresh token that replaces the old one.
    static func refresh(_ provider: OAuthProvider) async -> String? {
        if let running = refreshing[provider] { return await running.value }
        let task = Task<String?, Never> { await runRefresh(provider) }
        refreshing[provider] = task
        let token = await task.value
        refreshing[provider] = nil
        return token
    }

    private static func runRefresh(_ provider: OAuthProvider) async -> String? {
        guard let current = tokens(provider), let refreshToken = current["refresh_token"]?.stringValue, !refreshToken.isEmpty,
              let clientId = SecretStore.read(provider.clientIdItem), let secret = SecretStore.read(provider.clientSecretItem),
              let url = URL(string: provider.tokenURL) else { return nil }
        var body = ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientId, "client_secret": secret]
        if provider == .whoop { body["scope"] = provider.scopes }
        guard let reply = await OnDeviceHTTP.postForm(url, body: body), (200..<300).contains(reply.status),
              let fresh = reply.json, let access = fresh["access_token"]?.stringValue, !access.isEmpty else { return nil }
        save(provider, tokens: fresh, previous: current)
        return access
    }

    static func tokens(_ provider: OAuthProvider) -> JSONValue? {
        SecretStore.read(provider.tokensItem).flatMap { JSONValue.parse(Data($0.utf8)) }
    }

    private static func save(_ provider: OAuthProvider, tokens: JSONValue, previous: JSONValue?) {
        SecretStore.save(stored(tokens, previous: previous).sortedString(), for: provider.tokensItem)
    }

    /// Only the three token fields are kept. A reply without a refresh token keeps the old one.
    static func stored(_ tokens: JSONValue, previous: JSONValue?) -> JSONValue {
        let refresh = tokens["refresh_token"]?.stringValue ?? previous?["refresh_token"]?.stringValue ?? ""
        return .object([
            "access_token": .string(tokens["access_token"]?.stringValue ?? ""),
            "refresh_token": .string(refresh),
            "expires_at": .number(tokens["expires_at"]?.doubleValue ?? 0),
        ])
    }

    // MARK: - Self-check (runs in DEBUG at launch)

    static func check() -> [String] {
        var errors: [String] = []
        let url = authorizeURL(.whoop, clientId: "public-client", state: "abcdefgh")?.absoluteString ?? ""
        if !url.contains("client_id=public-client") || url.contains("client_secret") || !url.contains("scope=offline%20read:recovery")
            || !url.contains("redirect_uri=thesystem://localhost/whoop") {
            errors.append("the WHOOP sign-in URL should carry the client id, scopes, and redirect, and no secret: \(url)")
        }
        let strava = authorizeURL(.strava, clientId: "1", state: "abcdefgh")?.absoluteString ?? ""
        if !strava.hasPrefix("https://www.strava.com/oauth/authorize?") || !strava.contains("approval_prompt=auto") || !strava.contains("scope=activity:read_all") {
            errors.append("the Strava sign-in URL is wrong: \(strava)")
        }
        let back = URL(string: "thesystem://localhost/strava?state=abcdefgh&code=xyz&scope=read,activity:read_all")!
        if (try? code(from: back, provider: .strava, state: "abcdefgh").get()) != "xyz" {
            errors.append("the sign-in code should be read from the callback")
        }
        if case .success = code(from: back, provider: .strava, state: "other123") {
            errors.append("a callback with another state should be refused")
        }
        if case .success = code(from: URL(string: "thesystem://localhost/whoop?error=access_denied&state=abcdefgh")!, provider: .whoop, state: "abcdefgh") {
            errors.append("a refused sign-in should not give a code")
        }
        let kept = stored(.object(["access_token": .string("a2"), "expires_at": .number(10), "athlete": .object(["firstname": .string("private")])]),
                          previous: .object(["refresh_token": .string("r1")]))
        if kept["refresh_token"]?.stringValue != "r1" || kept.sortedString().contains("private") {
            errors.append("a refresh reply without a refresh token should keep the old one and drop other fields")
        }
        let rotated = stored(.object(["access_token": .string("a3"), "refresh_token": .string("r2")]), previous: .object(["refresh_token": .string("r1")]))
        if rotated["refresh_token"]?.stringValue != "r2" {
            errors.append("a rotated refresh token should replace the old one")
        }
        if OnDeviceHTTP.formEncoded(["scope": "offline read:recovery", "a": "x+y"]) != "a=x%2By&scope=offline%20read%3Arecovery" {
            errors.append("form body encoding wrong: \(OnDeviceHTTP.formEncoded(["scope": "offline read:recovery", "a": "x+y"]))")
        }
        return errors
    }
}
