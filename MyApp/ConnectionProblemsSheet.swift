import SwiftUI

/// The connections that stopped working, each with why, and the Connections rows to fix them.
struct ConnectionProblemsSheet: View {
    @EnvironmentObject private var store: GameStore

    var body: some View {
        NavigationStack {
            QuestSheet(title: "Connections") {
                if store.connectionProblems.isEmpty {
                    Text("Every connection works.")
                        .font(.footnote)
                        .foregroundStyle(QuestLight.ink.opacity(0.8))
                } else {
                    Text("These stopped working. Quests that need them cannot complete until you fix them.")
                        .font(.footnote)
                        .foregroundStyle(SystemTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(store.connectionProblems) { problem in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(problem.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(QuestLight.penalty)
                            Text(problem.detail)
                                .font(.caption)
                                .foregroundStyle(QuestLight.ink.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .overlay { Rectangle().stroke(QuestLight.penalty.opacity(0.6), lineWidth: 0.8) }
                    }
                }
                QuestSectionTitle(text: "Fix")
                Text("Tap a service to type its key again, sign in again, or test it. Screen Time and location are in the iPhone Settings app.")
                    .font(.caption)
                    .foregroundStyle(SystemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                ConnectionRows()
            }
            .font(.subheadline)
            .tint(SystemTheme.accent)
        }
    }
}

/// The red warning when a connection stopped working. Tap it for the list and the fix. Empty when all work.
struct ConnectionBanner: View {
    @EnvironmentObject private var store: GameStore
    @State private var showing = false

    var body: some View {
        if !store.connectionProblems.isEmpty {
            Button {
                SystemSound.systemOpen.play()
                showing = true
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CONNECTION DOWN")
                            .font(.caption2.weight(.bold))
                            .tracking(1.2)
                        Text("\(ConnectionAlerts.names(store.connectionProblems)). Tap to see and fix.")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(QuestLight.penalty)
                .padding(10)
                .background(Color.black.opacity(0.55))
                .overlay { Rectangle().stroke(QuestLight.penalty.opacity(0.8), lineWidth: 1) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("connectionProblemsBanner")
            .sheet(isPresented: $showing, onDismiss: { SystemSound.systemClose.play(); store.checkConnections() }) {
                ConnectionProblemsSheet()
            }
        }
    }
}

#Preview {
    ConnectionProblemsSheet()
        .environmentObject(GameStore(persistence: .memory))
}
