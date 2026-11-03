import AuthenticationServices
import SwiftUI

/// Settings → Connections: one row per service with the quest checkbox, checked once the service is connected.
/// The Mac tracker row is checked while a Mac is sending screen time. Tap a row to open its setup page.
struct ConnectionRows: View {
    @EnvironmentObject private var store: GameStore
    @State private var health: [Connection: ConnectionHealth] = [:]
    @State private var mac: MacTrackerStatus?
    @State private var page: Page?

    private enum Page: Identifiable {
        case service(Connection)
        case macTracker

        var id: String {
            switch self {
            case .service(let connection): connection.rawValue
            case .macTracker: "macTracker"
            }
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Connection.allCases) { connection in
                row(connection.title, checked: health[connection] == .connected) { page = .service(connection) }
            }
            row("Mac tracker", checked: macReceiving) { page = .macTracker }
        }
        .onAppear(perform: reload)
        .task { await reloadMac() }
        .sheet(item: $page, onDismiss: {
            SystemSound.systemClose.play()
            store.connectionsChanged()
            reload()
            Task { await reloadMac() }
        }) { page in
            NavigationStack {
                Group {
                    switch page {
                    case .service(let connection): ConnectionDetailView(connection: connection, onChange: reload)
                    case .macTracker: MacTrackerSettingsView()
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { self.page = nil }
                    }
                }
            }
        }
    }

    private func row(_ title: String, checked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: { SystemSound.systemOpen.play(); action() }) {
            HStack(spacing: 11) {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(1.1)
                    .foregroundStyle(SystemTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                QuestCheckbox(checked: checked)
                    .frame(width: 16, height: 17)
            }
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(checked ? "Connected" : "Not connected")
    }

    private var macReceiving: Bool {
        if case .receiving = mac { return true }
        return false
    }

    private func reload() {
        var next: [Connection: ConnectionHealth] = [:]
        for connection in Connection.allCases {
            next[connection] = ConnectionStatusStore.health(connection)
        }
        health = next
    }

    private func reloadMac() async {
        let now = Date.now
        let dayKey = QuestDay.key(for: now)
        let settings = MacScreenSettings.load()
        let reading = settings.baseURL == nil ? nil : await MacScreenClient.load(dayKey: dayKey, settings: settings)
        mac = MacTrackerStatus.make(settings: settings, reading: reading, dayKey: dayKey, dayStart: QuestDay.start(of: dayKey), now: now)
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
            WhoopStressSignIn(onMessage: onMessage)
        case .mercury:
            MercurySettingsView()
        case .claude:
            ClaudeSettingsView()
        default:
            EmptyView()
        }
    }
}

/// WHOOP stress: a second sign-in, with the WHOOP email and password, for the private API that has stress.
/// The password stays in this view's memory for the one call and is cleared after; only the tokens are saved.
struct WhoopStressSignIn: View {
    var onMessage: (String) -> Void
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var challenge: (name: String, session: String)?
    @State private var working = false
    @State private var signedIn = WhoopStressClient.configured

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("STRESS (UNOFFICIAL API)")
                .font(.caption.weight(.semibold))
                .tracking(1.1)
                .foregroundStyle(.white)
                .padding(.top, 8)
            if signedIn {
                Text("Signed in.")
                    .font(.caption2)
                    .foregroundStyle(SystemTheme.cyan)
                button("SIGN OUT OF WHOOP STRESS") {
                    WhoopStressClient.signOut()
                    signedIn = false
                    onMessage("Signed out of WHOOP stress. Fatigue uses its own estimate.")
                }
            } else if let challenge {
                TextField("Code from WHOOP", text: $code)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                button(working ? "CHECKING…" : "CONFIRM CODE") {
                    run { await WhoopStressClient.confirm(email: email, code: code, challenge: challenge.name, session: challenge.session) }
                }
            } else {
                TextField("WHOOP email", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("WHOOP password", text: $password)
                    .textContentType(.password)
                button(working ? "SIGNING IN…" : "SIGN IN FOR STRESS") {
                    run { await WhoopStressClient.signIn(email: email, password: password) }
                }
            }
        }
        .disabled(working)
    }

    private func run(_ call: @escaping () async -> WhoopStressClient.SignInStep) {
        working = true
        Task {
            let step = await call()
            password = ""
            working = false
            switch step {
            case .signedIn:
                challenge = nil
                code = ""
                let stress = await WhoopStressClient.stress(dayKey: QuestDay.key(for: .now))
                signedIn = true
                onMessage(stress.map { "Signed in to WHOOP stress. Stress now: \(Int($0.rounded())) of 100." }
                          ?? "Signed in to WHOOP stress. WHOOP has no stress score for today yet.")
            case .needsCode(let name, let session):
                challenge = (name, session)
                onMessage("WHOOP sent a code. Type it to finish signing in.")
            case .failed(let message):
                challenge = nil
                onMessage(message)
            }
        }
    }

    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .frame(maxWidth: .infinity, minHeight: 34)
                .overlay { Rectangle().stroke(SystemTheme.cyan.opacity(0.8), lineWidth: 0.8) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

/// Mercury budget, tax reserve, settle hour, income filter, and category map. The backend read these from its environment.
/// The budget is set once and then locked for 3 months, so it cannot be moved to fit a bad month.
struct MercurySettingsView: View {
    @State private var settings = MercurySettings.load()
    @State private var budget = ""
    @State private var confirmBudget = false
    @State private var categories = MercurySettings.load().categoryText

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            QuestSectionTitle(text: "FIN settings")
            budgetRow
            Stepper("Tax reserve: \(Int((settings.taxReserveRate * 100).rounded()))%", value: $settings.taxReserveRate, in: 0...0.6, step: 0.05)
            Stepper("Day settles at \(settings.settleHour):00 (Los Angeles)", value: $settings.settleHour, in: 0...23)
            TextField("Income counterparty regex (empty = all)", text: $settings.incomeCounterpartyRegex)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Category map: Restaurants=necessary, one per line", text: $categories, axis: .vertical)
                .lineLimit(2...6)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("API base URL (empty = production)", text: $settings.baseURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
        }
        .onChange(of: settings) { _, _ in save() }
        .onChange(of: categories) { _, _ in save() }
        .confirmationDialog("Set the monthly budget to \(Self.usd(Double(budget.trimmingCharacters(in: .whitespaces)) ?? 0))?",
                            isPresented: $confirmBudget, titleVisibility: .visible) {
            Button("Set budget for 3 months") { setBudget() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It cannot be changed until \(Self.day(Calendar.current.date(byAdding: .month, value: MercurySettings.budgetLockMonths, to: .now) ?? .now)).")
        }
    }

    @ViewBuilder
    private var budgetRow: some View {
        if let amount = settings.budget, let unlock = settings.budgetUnlockDate(), !settings.canSetBudget() {
            VStack(alignment: .leading, spacing: 3) {
                Text("Monthly budget: \(Self.usd(amount))")
                Text("Locked until \(Self.day(unlock)).")
                    .font(.footnote)
                    .foregroundStyle(SystemTheme.muted)
            }
            .accessibilityElement(children: .combine)
        } else {
            HStack(spacing: 10) {
                TextField(settings.budget.map { "Monthly budget: \(Self.usd($0))" } ?? "Monthly budget (USD)", text: $budget)
                    .keyboardType(.decimalPad)
                Button("Set") { confirmBudget = true }
                    .disabled((Double(budget.trimmingCharacters(in: .whitespaces)) ?? 0) <= 0)
            }
        }
    }

    private func setBudget() {
        guard let amount = Double(budget.trimmingCharacters(in: .whitespaces)) else { return }
        var next = settings
        guard next.setBudget(amount) else { return }
        settings = next
        budget = ""
        save()
    }

    private func save() {
        var next = settings
        next.categoryMap = MercurySettings.categoryMap(from: categories)
        next.save()
    }

    private static func usd(_ amount: Double) -> String {
        "$" + (Int(amount.rounded())).formatted()
    }

    private static func day(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }
}

/// The model that plans the quests. Empty uses the default.
struct ClaudeSettingsView: View {
    @State private var model = UserDefaults.standard.string(forKey: QuestPlanner.modelKey) ?? ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Model (empty = \(QuestPlanner.defaultModel))", text: $model)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: model) { _, value in
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        UserDefaults.standard.removeObject(forKey: QuestPlanner.modelKey)
                    } else {
                        UserDefaults.standard.set(trimmed, forKey: QuestPlanner.modelKey)
                    }
                }
        }
    }
}
