import SwiftUI

/// Opens from the Screen Time sheet. The Worker address and token that FocusTracker on each Mac also uses.
struct MacTrackerSettingsView: View {
    @State private var endpoint = MacScreenSettings.load().endpoint
    @State private var token = MacScreenSettings.load().token
    @State private var result = ""
    @State private var testing = false

    var body: some View {
        QuestSheet(title: "Mac tracker") {
            VStack(alignment: .leading, spacing: 12) {
                TextField("https://screentime.<you>.workers.dev", text: $endpoint)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("Token", text: $token)
                Button {
                    let settings = MacScreenSettings(endpoint: endpoint, token: token)
                    settings.save()
                    testing = true
                    Task {
                        result = await MacScreenClient.test(dayKey: QuestDay.key(for: .now), settings: settings)
                        testing = false
                    }
                } label: {
                    Text(testing ? "TESTING…" : "SAVE AND TEST")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.8)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .overlay { Rectangle().stroke(QuestLight.ink.opacity(0.6), lineWidth: 0.8) }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(testing)
                if !result.isEmpty {
                    note(result)
                }
                note("Run FocusTracker on each Mac with the same address and token. Every Mac counts as work: its minutes fill the Work line of the Screen Time quest. FOC counts the iPhone only.")
            }
        }
        .font(.subheadline)
        .tint(SystemTheme.accent)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(SystemTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}
