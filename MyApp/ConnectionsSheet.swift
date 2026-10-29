import AuthenticationServices
import SwiftUI

/// Status → Connections. One row per service the phone reads directly, with its state and a Test button.
struct ConnectionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: GameStore
    @State private var health: [Connection: ConnectionHealth] = [:]
    @State private var testing: Set<Connection> = []

    var body: some View {
        NavigationStack {
            QuestSheet(title: "Connections") {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Connection.allCases) { connection in
                        row(connection)
                    }
                    note("Each key stays in this iPhone's Keychain. The app calls each service directly; no server is needed. See docs/ON_DEVICE_SETUP.md for where to get each key.")
                }
            }
            .font(.subheadline)
            .tint(SystemTheme.accent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        store.connectionsChanged()
                        dismiss()
                    }
                }
            }
            .onAppear(perform: reload)
        }
    }

    private func row(_ connection: Connection) -> some View {
        let state = health[connection] ?? .notSet
        return HStack(spacing: 10) {
            NavigationLink {
                ConnectionDetailView(connection: connection, onChange: reload)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(connection.title.uppercased())
                        .font(.caption.weight(.semibold))
                        .tracking(1.1)
                        .foregroundStyle(.white)
                    Text(state.label)
                        .font(.caption2)
                        .foregroundStyle(color(state))
                    if case .error(let message) = state, !message.isEmpty {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(SystemTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                test(connection)
            } label: {
                Text(testing.contains(connection) ? "…" : "TEST")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.8)
                    .frame(width: 64, height: 30)
                    .overlay { Rectangle().stroke(QuestLight.ink.opacity(0.6), lineWidth: 0.8) }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(testing.contains(connection) || state == .notSet)
        }
    }

    private func color(_ state: ConnectionHealth) -> Color {
        switch state {
        case .connected: SystemTheme.cyan
        case .notSet: SystemTheme.muted
        case .error: .red
        }
    }

    private func reload() {
        var next: [Connection: ConnectionHealth] = [:]
        for connection in Connection.allCases {
            next[connection] = ConnectionStatusStore.health(connection)
        }
        health = next
    }

    private func test(_ connection: Connection) {
        testing.insert(connection)
        Task {
            _ = await ConnectionTester.test(connection)
            testing.remove(connection)
            reload()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(SystemTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One service: type its keys once, save them to the Keychain, and test them. Saved values are never shown again.
struct ConnectionDetailView: View {
    let connection: Connection
    var onChange: () -> Void = {}
    @State private var typed: [String: String] = [:]
    @State private var handle = CodeforcesSettings.handle ?? ""
    @State private var result = ""
    @State private var working = false
    @State private var refresh = 0

    var body: some View {
        QuestSheet(title: connection.title) {
            VStack(alignment: .leading, spacing: 12) {
                if connection == .codeforces {
                    TextField("Codeforces handle", text: $handle)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                ForEach(connection.typedSecrets) { field in
                    SecureField(placeholder(field), text: binding(field))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                actionButton(working ? "WORKING…" : "SAVE AND TEST") { saveAndTest() }
                ConnectionExtras(connection: connection, refresh: refresh) { message in
                    result = message
                    refresh += 1
                    onChange()
                }
                if !result.isEmpty {
                    note(result)
                }
                note(ConnectionHelp.text(connection))
                actionButton("REMOVE") {
                    connection.forget()
                    typed = [:]
                    handle = ""
                    result = "Removed."
                    refresh += 1
                    onChange()
                }
            }
            .id(refresh)
        }
        .font(.subheadline)
        .tint(SystemTheme.accent)
        .navigationBarTitleDisplayMode(.inline)
        .disabled(working)
    }

    private func placeholder(_ field: SecretField) -> String {
        SecretStore.has(field.item) ? "\(field.label): saved (type to replace)" : field.label
    }

    private func binding(_ field: SecretField) -> Binding<String> {
        Binding(get: { typed[field.id] ?? "" }, set: { typed[field.id] = $0 })
    }

    private func saveAndTest() {
        for field in connection.typedSecrets {
            let value = (typed[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                SecretStore.save(value, for: field.item)
            }
        }
        if connection == .codeforces {
            CodeforcesSettings.handle = handle
        }
        typed = [:]
        working = true
        Task {
            let outcome = await ConnectionTester.test(connection)
            result = outcome.message
            working = false
            refresh += 1
            onChange()
        }
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .frame(maxWidth: .infinity, minHeight: 34)
                .overlay { Rectangle().stroke(QuestLight.ink.opacity(0.6), lineWidth: 0.8) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(SystemTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Settings that only one service has: OAuth sign-in, Mercury budget, Claude model.
struct ConnectionExtras: View {
    let connection: Connection
    let refresh: Int
    var onMessage: (String) -> Void

    var body: some View {
        switch connection {
        case .strava:
            OAuthSignIn(provider: .strava, onMessage: onMessage)
        case .whoop:
            OAuthSignIn(provider: .whoop, onMessage: onMessage)
        default:
            EmptyView()
        }
    }
}

/// Opens the service's sign-in page in a private browser sheet and catches `thesystem://localhost/...`.
struct OAuthSignIn: View {
    let provider: OAuthProvider
    var onMessage: (String) -> Void
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                signIn()
            } label: {
                Text(working ? "SIGNING IN…" : SecretStore.has(provider.tokensItem) ? "SIGN IN AGAIN" : "SIGN IN TO \(provider.title.uppercased())")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.8)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .overlay { Rectangle().stroke(SystemTheme.cyan.opacity(0.8), lineWidth: 0.8) }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(working)
            Text("Redirect: \(provider.redirectURI)")
                .font(.caption2.monospaced())
                .foregroundStyle(SystemTheme.muted)
                .textSelection(.enabled)
        }
    }

    private func signIn() {
        guard let clientId = SecretStore.read(provider.clientIdItem), SecretStore.has(provider.clientSecretItem) else {
            onMessage("Type and save the client ID and client secret first.")
            return
        }
        let state = OAuthClient.newState()
        guard let url = OAuthClient.authorizeURL(provider, clientId: clientId, state: state) else { return }
        working = true
        Task {
            defer { working = false }
            let callback: URL
            do {
                callback = try await webAuthenticationSession.authenticate(
                    using: url,
                    callbackURLScheme: OAuthProvider.callbackScheme,
                    preferredBrowserSession: .ephemeral
                )
            } catch {
                onMessage("Sign-in was cancelled.")
                return
            }
            switch OAuthClient.code(from: callback, provider: provider, state: state) {
            case .failure(let error):
                ConnectionStatusStore.record(provider.connection, ok: false, message: error.text)
                onMessage(error.text)
            case .success(let code):
                let outcome = await OAuthClient.exchange(provider, code: code)
                ConnectionStatusStore.record(provider.connection, ok: outcome.ok, message: outcome.message)
                onMessage(outcome.message)
            }
        }
    }
}

/// Short help under each service. Docs/ON_DEVICE_SETUP.md has the full steps.
enum ConnectionHelp {
    static func text(_ connection: Connection) -> String {
        switch connection {
        case .hevy:
            "Hevy Pro: open hevy.com/settings → Developer and copy the API key."
        case .strava:
            "Create an app at strava.com/settings/api. Set Authorization Callback Domain to localhost. Type its Client ID and Client Secret, save, then sign in."
        case .whoop:
            "Create an app at developer-dashboard.whoop.com. Add the redirect URI thesystem://localhost/whoop. Type its Client ID and Client Secret, save, then sign in."
        case .codeforces:
            "Your public Codeforces handle. No key is needed."
        case .mercury:
            "Mercury → Settings → Tokens → create a Read Only token."
        case .claude:
            "console.anthropic.com → API Keys. The key plans each morning's quests on this phone."
        }
    }
}
