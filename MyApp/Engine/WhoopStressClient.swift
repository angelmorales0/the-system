import Foundation

/// WHOOP's real stress score, from the private iOS API that the WHOOP app itself calls.
/// Port of `backend/whoop_private` (auth.py, device.py, and `stress()` in client.py), cut down to stress only.
///
/// - Unofficial: the paths and shapes can change when WHOOP ships a new app, and using them may break
///   WHOOP's terms. It is for the owner's own account only.
/// - The developer OAuth token in `WhoopClient` cannot call this API. It needs a Cognito sign-in with the
///   WHOOP email and password. The password is used once to sign in and is never saved; only the Cognito
///   tokens go to the Keychain (`.whoopPrivateTokens`).
/// - When it is not signed in or a call fails, `stress` returns nil and fatigue uses its own estimate.
enum WhoopStressClient {
    static let base = "https://api.prod.whoop.com"
    static let authURL = "\(base)/auth-service/v3/whoop/"
    static let apiVersion = "7"
    /// WHOOP shows stress on a 0...3 gauge. Fatigue works in 0...100.
    static let gaugeMax = 3.0
    /// Refresh this many seconds before the access token runs out.
    static let refreshSkew: TimeInterval = 60

    // Captured from WHOOP iOS 5.52.0 (build 595097), like backend/whoop_private/constants.py.
    static let iosAppVersion = "5.52.0"
    static let iosBuildNumber = "595097"
    static let iosBundleName = "com.whoop.iphone"
    static let cognitoUserAgent = "aws-sdk-swift/1.5.86 ua/2.1 api/cognito_identity_provider#1.5.86 os/ios#26.3.1 lang/swift#5.10 m/D,N,Z,b"

    static var configured: Bool { SecretStore.has(.whoopPrivateTokens) }

    // MARK: - Stress

    /// Today's WHOOP stress on the fatigue scale (0...100), or nil.
    static func stress(dayKey: String) async -> Double? {
        guard configured, let token = await accessToken(),
              let url = OnDeviceHTTP.url("\(base)/health-service/v2/stress-bff/\(dayKey)", [("apiVersion", apiVersion)]),
              let reply = await OnDeviceHTTP.get(url, headers: dataHeaders(token: token), timeout: 12),
              (200..<300).contains(reply.status), let json = reply.json else { return nil }
        return stressScore(json)
    }

    /// Pure: the stress reply → 0...100. The gauge is the current level; without it, the newest graph point.
    /// Nil while WHOOP is still calibrating stress, or when the reply has no number.
    static func stressScore(_ reply: JSONValue) -> Double? {
        guard let root = reply.objectValue else { return nil }
        if root["stress_state"]?.stringValue == "CALIBRATING" || root["calibration_text_display"]?.stringValue != nil { return nil }
        var level = number(root["gauge"]?.objectValue?["gauge_score_display"]?.stringValue)
        if level == nil {
            let plots = root["stress_graph"]?.objectValue?["graph"]?.objectValue?["plots"]?.arrayValue ?? []
            let points = plots
                .flatMap { $0.objectValue?["plot"]?.objectValue?["segments"]?.arrayValue ?? [] }
                .flatMap { $0.objectValue?["points"]?.arrayValue ?? [] }
            level = points.compactMap { number($0.objectValue?["data_scrubber_details"]?.objectValue?["value_display"]?.stringValue) }.last
        }
        guard let level else { return nil }
        return min(max(level / gaugeMax, 0), 1) * 100
    }

    /// The first number in a display string such as "0.6" or "1,2 LOW".
    static func number(_ text: String?) -> Double? {
        guard let text, let range = text.replacingOccurrences(of: ",", with: "").range(of: #"-?\d+(\.\d+)?"#, options: .regularExpression) else { return nil }
        return Double(text.replacingOccurrences(of: ",", with: "")[range])
    }

    /// The headers the WHOOP iOS app puts on every data request, plus the Cognito bearer.
    static func dataHeaders(token: String) -> [String: String] {
        [
            "Authorization": "Bearer \(token)",
            "user-agent": "iOS",
            "x-whoop-device-platform": "iOS",
            "x-whoop-ios-version": iosAppVersion,
            "x-whoop-ios-build-number": iosBuildNumber,
            "x-whoop-bundle-name": iosBundleName,
            "x-whoop-installation-identifier": installationId,
            "x-whoop-time-zone": QuestDay.timeZone.identifier,
            "x-whoop-clock-format": "TWELVE_HOUR",
            "currency": "USD",
            "locale": "en_US",
            "accept-language": "en",
        ]
    }

    /// One uppercase UUID per install, like the WHOOP app. It is not a secret.
    static var installationId: String {
        let key = "whoopPrivateInstallationId"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let fresh = UUID().uuidString.uppercased()
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    // MARK: - Sign-in

    enum SignInStep: Equatable {
        case signedIn
        /// WHOOP sent a code by SMS, email, or an authenticator app. Pass it to `confirm`.
        case needsCode(challenge: String, session: String)
        case failed(String)
    }

    /// Cognito USER_PASSWORD_AUTH. The password goes to WHOOP's auth proxy only and is not kept.
    static func signIn(email: String, password: String) async -> SignInStep {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !password.isEmpty else { return .failed("Type the WHOOP email and password.") }
        let reply = await cognito("InitiateAuth", [
            "AuthFlow": .string("USER_PASSWORD_AUTH"),
            "AuthParameters": .object(["USERNAME": .string(email), "PASSWORD": .string(password)]),
            "ClientId": .string(""),
        ])
        return step(reply)
    }

    /// Answers an MFA challenge from `signIn`.
    static func confirm(email: String, code: String, challenge: String, session: String) async -> SignInStep {
        guard let codeKey = codeKeys[challenge] else { return .failed("WHOOP asked for an unknown check: \(challenge).") }
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return .failed("Type the code WHOOP sent.") }
        let reply = await cognito("RespondToAuthChallenge", [
            "ClientId": .string(""),
            "ChallengeName": .string(challenge),
            "Session": .string(session),
            "ChallengeResponses": .object(["USERNAME": .string(email.trimmingCharacters(in: .whitespacesAndNewlines)), codeKey: .string(code)]),
        ])
        return step(reply)
    }

    static let codeKeys = ["SMS_MFA": "SMS_MFA_CODE", "SOFTWARE_TOKEN_MFA": "SOFTWARE_TOKEN_MFA_CODE", "EMAIL_OTP": "EMAIL_OTP_CODE"]

    static func signOut() { SecretStore.delete(.whoopPrivateTokens) }

    /// Saves the tokens from a Cognito reply, or names the challenge or the error.
    private static func step(_ reply: (status: Int, json: JSONValue?)?) -> SignInStep {
        guard let reply else { return .failed("Cannot reach WHOOP.") }
        let object = reply.json?.objectValue ?? [:]
        if (200..<300).contains(reply.status), let result = object["AuthenticationResult"], let tokens = tokens(from: result, fallbackRefresh: nil) {
            save(tokens)
            return .signedIn
        }
        if (200..<300).contains(reply.status), let challenge = object["ChallengeName"]?.stringValue {
            guard codeKeys[challenge] != nil, let session = object["Session"]?.stringValue else {
                return .failed("WHOOP asked for a check this app cannot answer: \(challenge).")
            }
            return .needsCode(challenge: challenge, session: session)
        }
        let message = object["message"]?.stringValue ?? object["__type"]?.stringValue ?? "HTTP \(reply.status)"
        return .failed("WHOOP sign-in failed: \(message)")
    }

    // MARK: - Tokens

    struct Tokens: Equatable {
        var access: String
        var refresh: String
        var expiresAt: TimeInterval
    }

    /// A valid access token, refreshed when it is about to run out. Nil when not signed in or the refresh fails.
    static func accessToken(now: Date = .now) async -> String? {
        guard let saved = savedTokens() else { return nil }
        if saved.expiresAt - refreshSkew > now.timeIntervalSince1970 { return saved.access }
        guard !saved.refresh.isEmpty else { return nil }
        let reply = await cognito("InitiateAuth", [
            "AuthFlow": .string("REFRESH_TOKEN_AUTH"),
            "AuthParameters": .object(["REFRESH_TOKEN": .string(saved.refresh)]),
            "ClientId": .string(""),
        ])
        guard let reply, (200..<300).contains(reply.status),
              let result = reply.json?.objectValue?["AuthenticationResult"],
              let fresh = tokens(from: result, fallbackRefresh: saved.refresh) else { return nil }
        save(fresh)
        return fresh.access
    }

    /// Pure: tokens from an `AuthenticationResult`. Cognito usually leaves the refresh token out of a refresh reply.
    static func tokens(from result: JSONValue, fallbackRefresh: String?) -> Tokens? {
        guard let object = result.objectValue, let access = object["AccessToken"]?.stringValue, !access.isEmpty else { return nil }
        let refresh = object["RefreshToken"]?.stringValue ?? fallbackRefresh ?? ""
        return Tokens(access: access, refresh: refresh, expiresAt: jwtExpiry(access) ?? 0)
    }

    /// Pure: the `exp` claim of a JWT, in seconds since 1970.
    static func jwtExpiry(_ jwt: String) -> TimeInterval? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return JSONValue.parse(data)?.objectValue?["exp"]?.doubleValue
    }

    private static func savedTokens() -> Tokens? {
        guard let raw = SecretStore.read(.whoopPrivateTokens), let object = JSONValue.parse(Data(raw.utf8))?.objectValue,
              let access = object["access_token"]?.stringValue else { return nil }
        return Tokens(access: access, refresh: object["refresh_token"]?.stringValue ?? "", expiresAt: object["expires_at"]?.doubleValue ?? 0)
    }

    private static func save(_ tokens: Tokens) {
        let object: JSONValue = .object([
            "access_token": .string(tokens.access),
            "refresh_token": .string(tokens.refresh),
            "expires_at": .number(tokens.expiresAt),
        ])
        guard let data = try? JSONEncoder().encode(object), let text = String(data: data, encoding: .utf8) else { return }
        SecretStore.save(text, for: .whoopPrivateTokens)
    }

    /// POSTs one Cognito operation through WHOOP's auth proxy. No body or token is logged.
    private static func cognito(_ target: String, _ body: [String: JSONValue]) async -> (status: Int, json: JSONValue?)? {
        guard let url = URL(string: authURL), let data = try? JSONEncoder().encode(JSONValue.object(body)) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpBody = data
        for (name, value) in [
            "content-type": "application/x-amz-json-1.1",
            "x-amz-target": "AWSCognitoIdentityProviderService.\(target)",
            "amz-sdk-request": "attempt=1; max=1",
            "amz-sdk-invocation-id": UUID().uuidString.lowercased(),
            "user-agent": cognitoUserAgent,
            "accept": "*/*",
        ] { request.setValue(value, forHTTPHeaderField: name) }
        guard let (reply, response) = try? await OnDeviceHTTP.session(timeout: 15).data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return (http.statusCode, JSONValue.parse(reply))
    }

    // MARK: - Self-check (runs in DEBUG at launch). Fixture from backend/whoop_private/fixtures/stress.json.

    static func check() -> [String] {
        var errors: [String] = []
        func point(_ value: String) -> JSONValue {
            .object(["data_scrubber_details": .object(["primary_contextual_display": .string("9:00 AM"), "value_display": .string(value)])])
        }
        func graph(_ values: [String]) -> JSONValue {
            .object(["graph": .object(["plots": .array([.object(["plot": .object(["segments": .array([.object(["points": .array(values.map(point))])])])])])])])
        }
        let fixture: JSONValue = .object([
            "stress_state": .string("RELAXED"),
            "gauge": .object(["gauge_score_display": .string("0.6"), "gauge_subtext_display": .string("LOW")]),
            "stress_graph": graph(["0.4", "1.2", "0.8"]),
            "title": .string("Stress"),
        ])
        if let score = stressScore(fixture), abs(score - 20) > 0.01 {
            errors.append("a 0.6 of 3 gauge should be stress 20, got \(score)")
        } else if stressScore(fixture) == nil {
            errors.append("the stress fixture should decode")
        }
        let noGauge: JSONValue = .object(["stress_state": .string("HIGH"), "stress_graph": graph(["0.4", "2.4"])])
        if stressScore(noGauge).map({ abs($0 - 80) > 0.01 }) ?? true {
            errors.append("without a gauge, the newest graph point (2.4 of 3) should be stress 80")
        }
        if stressScore(.object(["stress_state": .string("CALIBRATING"), "gauge": .object(["gauge_score_display": .string("1.0")])])) != nil {
            errors.append("stress should be nil while WHOOP calibrates")
        }
        if stressScore(.object(["gauge": .object(["gauge_score_display": .string("4.5")])])) != 100 {
            errors.append("stress should clamp at 100")
        }
        // Header {"alg":"none"}, payload {"exp":1800000000}.
        let jwt = "eyJhbGciOiJub25lIn0.eyJleHAiOjE4MDAwMDAwMDB9.sig"
        if jwtExpiry(jwt) != 1_800_000_000 { errors.append("the JWT exp claim should decode") }
        let refreshed = tokens(from: .object(["AccessToken": .string(jwt)]), fallbackRefresh: "keep")
        if refreshed != Tokens(access: jwt, refresh: "keep", expiresAt: 1_800_000_000) {
            errors.append("a refresh reply without a refresh token should keep the old one")
        }
        if tokens(from: .object(["IdToken": .string("x")]), fallbackRefresh: nil) != nil {
            errors.append("a reply without an access token should not save tokens")
        }
        return errors
    }
}
