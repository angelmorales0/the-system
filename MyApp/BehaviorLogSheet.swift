import SwiftUI

/// The behavior log: one short note a day, "what I did that could be better", and the past notes.
/// Optional, never a penalty. The note saves when the sheet closes, or with SAVE.
struct BehaviorLogSheet: View {
    @EnvironmentObject private var store: GameStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var loaded = false

    private var past: [(day: String, note: String)] {
        store.snapshot.habits.log.filter { $0.key != store.snapshot.bundle.dayKey }
            .sorted { $0.key > $1.key }.prefix(30).map { ($0.key, $0.value) }
    }

    var body: some View {
        NavigationStack {
            QuestSheet(title: "Behavior log") {
                Text("What did you do today that could be better? Write it down, so the habit you do not see becomes one you see.")
                    .font(.footnote)
                    .foregroundStyle(SystemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("Today…", text: $text, axis: .vertical)
                    .lineLimit(4...10)
                    .foregroundStyle(QuestLight.ink)
                    .padding(8)
                    .overlay { Rectangle().stroke(QuestLight.ink.opacity(0.4), lineWidth: 0.8) }
                    .accessibilityLabel("Today's note")

                Button {
                    store.setLogNote(text)
                    dismiss()
                } label: {
                    Text("SAVE")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.8)
                        .foregroundStyle(QuestLight.ink)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .overlay { Rectangle().stroke(QuestLight.ink.opacity(0.6), lineWidth: 0.8) }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if !past.isEmpty {
                    QuestSectionTitle(text: "Past days")
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(past, id: \.day) { entry in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(Contract.dateText(entry.day))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(SystemTheme.muted)
                                Text(entry.note)
                                    .font(.footnote)
                                    .foregroundStyle(QuestLight.ink.opacity(0.9))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .font(.subheadline)
            .tint(SystemTheme.accent)
        }
        .onAppear {
            guard !loaded else { return }
            text = store.snapshot.habits.log[store.snapshot.bundle.dayKey] ?? ""
            loaded = true
        }
        .onDisappear { store.setLogNote(text) }
    }
}

/// The habits as streaks: one row a habit, one dot a day for the last 28 days (today last), and the current streak.
struct SystemsPanel: View {
    let tracks: [SystemsView.Track]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("The 1% steps of each day. Cyan: done. Red: missed. Dim: no rule or no data.")
                .font(.caption)
                .foregroundStyle(QuestLight.ink.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(tracks) { track in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(track.name)
                            .font(.footnote.weight(.semibold))
                        Spacer()
                        Text("\(track.streak) day\(track.streak == 1 ? "" : "s")")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(track.streak > 0 ? QuestLight.cyan : QuestLight.ink.opacity(0.6))
                    }
                    HStack(spacing: 3) {
                        ForEach(Array(track.marks.enumerated()), id: \.offset) { _, mark in
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(color(mark))
                                .frame(maxWidth: .infinity)
                                .frame(height: 9)
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(track.name)
                .accessibilityValue("\(track.streak) day streak, \(track.marks.filter { $0 == .done }.count) of the last \(track.marks.count) days done")
            }
        }
        .foregroundStyle(QuestLight.ink)
    }

    private func color(_ mark: SystemsView.Mark) -> Color {
        switch mark {
        case .done: QuestLight.cyan
        case .missed: QuestLight.penalty
        case .none: QuestLight.ink.opacity(0.12)
        }
    }
}
