import SwiftUI

/// The gym split, day by day, with the sets of each exercise and an optional mark. The player edits them here.
/// An edit saves at once. When today is that split day, today's open rows change too, and the Hevy routine follows.
/// An optional exercise may be skipped: it never misses the day, and the gym row shows it as `[0/0]`.
struct SplitEditorSheet: View {
    @EnvironmentObject private var store: GameStore
    /// The `GymSplit.Day.id` on screen. Today's split day opens first.
    @State private var dayId: String

    init(dayId: String? = nil) {
        _dayId = State(initialValue: dayId ?? GymSplit.rotation[0].id)
    }

    private var day: GymSplit.Day? { store.editedRotation.first { $0.id == dayId } }

    var body: some View {
        QuestSheet(title: "Gym split") {
            Text("Pick a day. Change the sets, or mark an exercise optional. Optional exercises never miss the day.")
                .font(.footnote)
                .foregroundStyle(SystemTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            dayPicker

            if let day {
                QuestSectionTitle(text: day.name)
                Text(day.focus)
                    .font(.footnote)
                    .foregroundStyle(SystemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 16) {
                    ForEach(day.exercises, id: \.exercise) { exercise in
                        row(exercise, day: day)
                    }
                }
            }
        }
        .font(.subheadline)
        .tint(SystemTheme.accent)
    }

    private var dayPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(GymSplit.rotation, id: \.id) { option in
                    Button {
                        dayId = option.id
                    } label: {
                        Text(option.name.uppercased())
                            .font(.caption2.weight(.semibold))
                            .tracking(0.8)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 34)
                            .foregroundStyle(option.id == dayId ? Color.black : QuestLight.ink)
                            .background(option.id == dayId ? QuestLight.ink : Color.clear)
                            .overlay { Rectangle().stroke(QuestLight.ink.opacity(0.6), lineWidth: 0.8) }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(option.id == dayId ? .isSelected : [])
                }
            }
        }
    }

    private func row(_ exercise: GymSplit.Exercise, day: GymSplit.Day) -> some View {
        let range = GymSplit.setRange(for: exercise.exercise)
        let reps = exercise.secondsPerSet.map { "\(Int($0))s" }
            ?? (exercise.minReps == exercise.maxReps ? "\(exercise.minReps)" : "\(exercise.minReps)-\(exercise.maxReps)")
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(exercise.exercise)
                    .foregroundStyle(QuestLight.ink)
                Spacer()
                Text("\(exercise.sets)×\(reps)")
                    .monospacedDigit()
                    .foregroundStyle(QuestLight.ink)
            }
            if let muscle = exercise.muscle {
                Text(muscle)
                    .font(.caption)
                    .foregroundStyle(SystemTheme.muted)
            }
            Stepper(value: Binding(
                get: { exercise.sets },
                set: { store.editSplit(day: day.id, exercise: exercise.exercise, sets: $0) }
            ), in: range) {
                Text("Sets: \(exercise.sets)")
                    .monospacedDigit()
                    .foregroundStyle(QuestLight.ink.opacity(0.85))
            }
            .accessibilityLabel("\(exercise.exercise) sets")
            Toggle(isOn: Binding(
                get: { exercise.optional },
                set: { store.editSplit(day: day.id, exercise: exercise.exercise, optional: $0) }
            )) {
                Text("Optional")
                    .foregroundStyle(QuestLight.ink.opacity(0.85))
            }
            .accessibilityLabel("\(exercise.exercise) optional")
        }
        .padding(.bottom, 4)
        .overlay(alignment: .bottom) {
            Rectangle().fill(QuestLight.ink.opacity(0.2)).frame(height: 0.5)
        }
    }
}

#Preview {
    NavigationStack { SplitEditorSheet() }
        .environmentObject(GameStore(persistence: .memory))
}
