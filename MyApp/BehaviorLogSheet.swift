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
                Text("What could you have done better today? Write it down, so you see the habit.")
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
/// Hand-marked rows (No eating out, No caffeine, Only whole foods): tap a day, then Pass (glowing white) or Fail (red).
struct SystemsPanel: View {
    let tracks: [SystemsView.Track]
    /// Called with a hand habit, the day, and the pick: true passed, false failed.
    var onMark: ((HandHabit, String, Bool) -> Void)? = nil
    @State private var picking: (habit: HandHabit, day: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(tracks) { track in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(track.name)
                            .font(.footnote.weight(.semibold))
                        Spacer()
                        Text(track.summary ?? "\(track.streak) day\(track.streak == 1 ? "" : "s")")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(track.summary == nil && track.streak > 0 ? QuestLight.cyan : QuestLight.ink.opacity(0.6))
                    }
                    HStack(spacing: 3) {
                        ForEach(Array(track.marks.enumerated()), id: \.offset) { index, mark in
                            if let habit = track.handHabit, onMark != nil, index < track.dayKeys.count {
                                Button { picking = (habit, track.dayKeys[index]) } label: {
                                    dot(mark, white: true)
                                        .frame(maxWidth: .infinity, minHeight: 28)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(Contract.dateText(track.dayKeys[index])): \(label(mark))")
                            } else {
                                dot(mark, white: false)
                            }
                        }
                    }
                }
                .accessibilityElement(children: track.handHabit != nil ? .contain : .ignore)
                .accessibilityLabel(track.name)
                .accessibilityValue("\(track.streak) day streak, \(track.marks.filter { $0 == .done }.count) of the last \(track.marks.count) days done")
            }
        }
        .foregroundStyle(QuestLight.ink)
        .confirmationDialog(picking.map { "\($0.habit.name): \(Contract.dateText($0.day))" } ?? "",
                            isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }),
                            titleVisibility: .visible) {
            if let picking {
                Button(picking.habit.choices.yes) { onMark?(picking.habit, picking.day, true) }
                Button(picking.habit.choices.no, role: picking.habit.weeklyLimit == nil ? .destructive : nil) {
                    onMark?(picking.habit, picking.day, false)
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    /// One day. A hand-marked row shows a pass in glowing white.
    private func dot(_ mark: SystemsView.Mark, white: Bool) -> some View {
        let fill = white && mark == .done ? QuestLight.ink : color(mark)
        return RoundedRectangle(cornerRadius: 1.5)
            .fill(fill)
            .frame(maxWidth: .infinity)
            .frame(height: 9)
            .shadow(color: white && mark == .done ? QuestLight.ink.opacity(0.9) : .clear, radius: 3)
    }

    private func label(_ mark: SystemsView.Mark) -> String {
        switch mark {
        case .done: "passed"
        case .missed: "failed"
        case .none: "not marked"
        }
    }

    private func color(_ mark: SystemsView.Mark) -> Color {
        switch mark {
        case .done: QuestLight.cyan
        case .missed: QuestLight.penalty
        case .none: QuestLight.ink.opacity(0.12)
        }
    }
}
