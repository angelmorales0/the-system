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
            VStack(alignment: .leading, spacing: 0) {
                TypewriterText("SYSTEM // GYM SPLIT")
                    .font(TacticalIntro.mono)
                    .tracking(2)
                    .foregroundStyle(SystemTheme.muted)
                    .accessibilityAddTraits(.isHeader)
                Rectangle().fill(QuestLight.cyan.opacity(0.25)).frame(height: 0.5)
                    .padding(.top, 10)
                    .padding(.bottom, 12)
                Text("Pick a day. Change the sets, or mark an exercise optional. Optional exercises never miss the day.")
                    .font(.footnote)
                    .foregroundStyle(SystemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                dayPicker
                    .padding(.vertical, 14)
                if let day {
                    TacticalBox(title: "[ \(day.name.uppercased()) ]") {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(day.focus)
                                .font(.footnote)
                                .foregroundStyle(SystemTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.bottom, 8)
                            ForEach(Array(day.exercises.enumerated()), id: \.element.exercise) { index, exercise in
                                row(exercise, day: day)
                                    .modifier(TacticalRowReveal(index: index, group: "split"))
                            }
                        }
                    }
                    .id(day.id)
                }
            }
        }
        .font(.subheadline)
        .tint(SystemTheme.accent)
    }

    /// The split days as square tabs. The chosen day is cyan with a glow.
    private var dayPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(GymSplit.rotation, id: \.id) { option in
                    let chosen = option.id == dayId
                    Button {
                        dayId = option.id
                    } label: {
                        Text(option.name.uppercased())
                            .font(TacticalIntro.mono)
                            .tracking(1.5)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 34)
                            .foregroundStyle(chosen ? QuestLight.cyan : SystemTheme.muted)
                            .shadow(color: chosen ? QuestLight.cyan.opacity(0.8) : .clear, radius: 3)
                            .background(chosen ? QuestLight.cyan.opacity(0.1) : Color.clear)
                            .overlay { Rectangle().stroke(chosen ? QuestLight.cyan.opacity(0.7) : QuestLight.ink.opacity(0.25), lineWidth: 0.5) }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
            .padding(1)
        }
    }

    /// One exercise: its name and muscle, "3×8-12" in cyan, then the sets stepper and the optional box.
    private func row(_ exercise: GymSplit.Exercise, day: GymSplit.Day) -> some View {
        let range = GymSplit.setRange(for: exercise.exercise)
        let reps = exercise.secondsPerSet.map { "\(Int($0))s" }
            ?? (exercise.minReps == exercise.maxReps ? "\(exercise.minReps)" : "\(exercise.minReps)-\(exercise.maxReps)")
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(exercise.exercise)
                    .foregroundStyle(exercise.optional ? QuestLight.ink.opacity(0.7) : QuestLight.ink)
                Spacer()
                Text("\(exercise.sets)×\(reps)")
                    .font(TacticalIntro.mono)
                    .tracking(1)
                    .monospacedDigit()
                    .foregroundStyle(QuestLight.cyan)
                    .shadow(color: QuestLight.cyan.opacity(0.7), radius: 3)
            }
            if let muscle = exercise.muscle {
                Text(muscle.uppercased())
                    .font(TacticalIntro.mono)
                    .tracking(1.5)
                    .foregroundStyle(SystemTheme.muted)
            }
            HStack(spacing: 8) {
                Text("SETS")
                    .font(TacticalIntro.mono)
                    .tracking(1.5)
                    .foregroundStyle(SystemTheme.muted)
                stepButton("minus", enabled: exercise.sets > range.lowerBound) {
                    store.editSplit(day: day.id, exercise: exercise.exercise, sets: exercise.sets - 1)
                }
                Text("\(exercise.sets)")
                    .font(TacticalIntro.mono)
                    .monospacedDigit()
                    .foregroundStyle(QuestLight.ink)
                    .frame(minWidth: 18)
                stepButton("plus", enabled: exercise.sets < range.upperBound) {
                    store.editSplit(day: day.id, exercise: exercise.exercise, sets: exercise.sets + 1)
                }
                Spacer(minLength: 8)
                Toggle(isOn: Binding(
                    get: { exercise.optional },
                    set: { store.editSplit(day: day.id, exercise: exercise.exercise, optional: $0) }
                )) {
                    Text("OPTIONAL")
                        .font(TacticalIntro.mono)
                        .tracking(1.5)
                        .foregroundStyle(exercise.optional ? QuestLight.ink : SystemTheme.muted)
                }
                .toggleStyle(QuestCheckToggleStyle())
                .fixedSize()
                .accessibilityLabel("\(exercise.exercise) optional")
            }
            .accessibilityElement(children: .contain)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment where exercise.sets < range.upperBound:
                    store.editSplit(day: day.id, exercise: exercise.exercise, sets: exercise.sets + 1)
                case .decrement where exercise.sets > range.lowerBound:
                    store.editSplit(day: day.id, exercise: exercise.exercise, sets: exercise.sets - 1)
                default: break
                }
            }
        }
        .padding(.vertical, 10)
    }

    /// A small cyan square with a minus or a plus, like the run swap icon.
    private func stepButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(QuestLight.cyan)
                .frame(width: 24, height: 24)
                .overlay { Rectangle().stroke(QuestLight.cyan.opacity(0.5), lineWidth: 0.5) }
                .frame(width: 32, height: 44)
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : 0.3)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(icon == "plus" ? "One more set" : "One less set")
    }
}

#Preview {
    NavigationStack { SplitEditorSheet() }
        .environmentObject(GameStore(persistence: .memory))
}
