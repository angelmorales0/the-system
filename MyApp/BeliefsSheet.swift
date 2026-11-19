import SwiftUI

/// The player's beliefs: who they decide to be, up to 10 lines. The quest screen shows one each day.
/// Edits save when the sheet closes, or with SAVE.
struct BeliefsSheet: View {
    @EnvironmentObject private var store: GameStore
    @Environment(\.dismiss) private var dismiss
    /// Each line has its own id, so deleting one never points a text field at a line that is gone.
    private struct Line: Identifiable {
        let id = UUID()
        var text: String
    }

    @State private var lines: [Line] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            QuestSheet(title: "Beliefs") {
                Text("Decide who you are. Your habits prove it each day. The quest screen shows one belief each morning.")
                    .font(.footnote)
                    .foregroundStyle(SystemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 12) {
                    ForEach($lines) { $line in
                        let number = (lines.firstIndex { $0.id == line.id } ?? 0) + 1
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(number).")
                                .monospacedDigit()
                                .foregroundStyle(QuestLight.ink.opacity(0.7))
                            TextField("I am someone who…", text: $line.text, axis: .vertical)
                                .foregroundStyle(QuestLight.ink)
                                .accessibilityLabel("Belief \(number)")
                            Button {
                                let id = line.id
                                lines.removeAll { $0.id == id }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption)
                                    .foregroundStyle(QuestLight.ink.opacity(0.6))
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Delete belief \(number)")
                        }
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(QuestLight.ink.opacity(0.2)).frame(height: 0.5)
                        }
                    }
                }

                if lines.count < Beliefs.maxCount {
                    Button {
                        lines.append(Line(text: ""))
                    } label: {
                        boxLabel("ADD A BELIEF")
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    store.setBeliefs(lines.map(\.text))
                    dismiss()
                } label: {
                    boxLabel("SAVE")
                }
                .buttonStyle(.plain)
            }
            .font(.subheadline)
            .tint(SystemTheme.accent)
        }
        .onAppear {
            guard !loaded else { return }
            lines = store.snapshot.habits.beliefs.map { Line(text: $0) }
            loaded = true
        }
        .onDisappear { store.setBeliefs(lines.map(\.text)) }
    }

    private func boxLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(QuestLight.ink)
            .frame(maxWidth: .infinity, minHeight: 44)
            .overlay { Rectangle().stroke(QuestLight.ink.opacity(0.6), lineWidth: 0.8) }
            .contentShape(Rectangle())
    }
}

#Preview {
    BeliefsSheet()
        .environmentObject(GameStore(persistence: .memory))
}
