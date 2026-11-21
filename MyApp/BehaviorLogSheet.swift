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
                    // Saved as you type, so the Log written row turns cyan at once.
                    .onChange(of: text) { _, value in if loaded { store.setLogNote(value) } }

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
/// Hand-marked rows (No eating out, No caffeine, Only whole foods): tap today, then Pass (glowing white) or Fail (red)
/// in the bar that opens under the row. The day changes color at once.
struct SystemsPanel: View {
    let tracks: [SystemsView.Track]
    /// Called with a hand habit, the day, and the pick: true passed, false failed.
    var onMark: ((HandHabit, String, Bool) -> Void)? = nil
    @State private var picking: (habit: HandHabit, day: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { row, track in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(track.name)
                            .font(.footnote)
                        Spacer()
                        // The streak as "7D", or the row's own summary: "0/2 TRAVEL DAYS".
                        Text(track.summary?.uppercased() ?? "\(track.streak)D")
                            .font(TacticalIntro.mono)
                            .tracking(1.5)
                            .foregroundStyle(track.summary == nil && track.streak > 0 ? QuestLight.cyan : SystemTheme.muted)
                            .shadow(color: track.summary == nil && track.streak > 0 ? QuestLight.cyan.opacity(0.7) : .clear, radius: 3)
                    }
                    HStack(spacing: 3) {
                        ForEach(Array(track.marks.enumerated()), id: \.offset) { index, mark in
                            if let habit = track.handHabit, onMark != nil, index < track.dayKeys.count, track.dayKeys[index] == track.today {
                                let day = track.dayKeys[index]
                                let selected = picking?.habit == habit && picking?.day == day
                                Button { picking = selected ? nil : (habit, day) } label: {
                                    dot(mark, white: true)
                                        .overlay { if selected { RoundedRectangle(cornerRadius: 2).stroke(QuestLight.cyan, lineWidth: 1.5).padding(-2) } }
                                        .frame(maxWidth: .infinity, minHeight: 28)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(Contract.dateText(track.dayKeys[index])): \(label(mark))")
                            } else {
                                dot(mark, white: track.handHabit != nil)
                            }
                        }
                    }
                    if let picking, picking.habit == track.handHabit {
                        pickBar(picking)
                    }
                }
                .accessibilityElement(children: track.handHabit != nil ? .contain : .ignore)
                .accessibilityLabel(track.name)
                .accessibilityValue("\(track.streak) day streak, \(track.marks.filter { $0 == .done }.count) of the last \(track.marks.count) days done")
                .padding(.vertical, 10)
                .modifier(TacticalRowReveal(index: row, group: "systems"))
            }
        }
        .foregroundStyle(QuestLight.ink)
    }

    /// The day's two choices, under its row. A tap marks the day at once and closes the bar.
    private func pickBar(_ picking: (habit: HandHabit, day: String)) -> some View {
        HStack(spacing: 8) {
            Text(Contract.dateText(picking.day))
                .font(.caption.monospacedDigit())
                .foregroundStyle(QuestLight.ink.opacity(0.75))
            Spacer(minLength: 4)
            choice(picking.habit.choices.yes, color: QuestLight.ink) { mark(picking, true) }
            choice(picking.habit.choices.no, color: picking.habit.weeklyLimit == nil ? QuestLight.penalty : QuestLight.ink) { mark(picking, false) }
        }
    }

    private func choice(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(color)
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .overlay { Rectangle().stroke(color.opacity(0.7), lineWidth: 0.8) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Marks the day with no animation, so the color changes on the tap.
    private func mark(_ picking: (habit: HandHabit, day: String), _ passed: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            onMark?(picking.habit, picking.day, passed)
            self.picking = nil
        }
    }

    /// One day, a square cell like the dashes of the day ring: an empty day is only an outline.
    /// A hand-marked row shows a pass in glowing white.
    private func dot(_ mark: SystemsView.Mark, white: Bool) -> some View {
        let fill = white && mark == .done ? QuestLight.ink : color(mark)
        let glow = mark == .none ? Color.clear : fill.opacity(0.8)
        return Rectangle()
            .fill(fill)
            .overlay { Rectangle().stroke(mark == .none ? QuestLight.ink.opacity(0.22) : fill, lineWidth: 0.5) }
            .frame(maxWidth: .infinity)
            .frame(height: 8)
            .shadow(color: glow, radius: 3)
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
        case .none: QuestLight.ink.opacity(0.04)
        }
    }
}
