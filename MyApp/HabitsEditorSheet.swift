import SwiftUI

/// Settings > HABITS: the Home by time, and the hand-marked Systems rows. Add, rename, order, remove, and turn each row's penalty on or off.
/// The rules (`HabitEditor.rules`) keep a change from helping on the day it is made.
struct HabitsEditorSheet: View {
    @EnvironmentObject private var store: GameStore
    @State private var newName = ""
    @State private var limited = false
    @State private var limit = 2
    @State private var newPenalty = true
    @State private var problem: String?
    @State private var renaming: HandHabit?
    @State private var renameText = ""
    @State private var removing: HandHabit?
    @FocusState private var typing: Bool
    /// The Home by time picked here, before it is saved. Nil shows tomorrow's time.
    @State private var homeByPick: Int?
    /// The Screen Time limit picked here, before it is saved. Nil shows tomorrow's limit.
    @State private var capPick: Int?

    private var today: String { store.snapshot.bundle.dayKey }
    private var tomorrow: String { QuestDay.key(byAddingDays: 1, to: today) }
    private var rows: [HandHabit] { store.snapshot.habits.handHabits(on: today) }

    var body: some View {
        QuestSheet(title: "Habits") {
            Text(HabitEditor.rules)
                .font(.footnote)
                .foregroundStyle(SystemTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(QuestLight.penalty)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("habitProblem")
            }
            homeBySection
            SystemDivider()
            screenTimeSection
            SystemDivider()
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, habit in
                    row(habit, index: index)
                    if index < rows.count - 1 {
                        Rectangle().fill(QuestLight.ink.opacity(0.2)).frame(height: 0.5)
                    }
                }
            }
            SystemDivider()
            addSection
        }
        .alert("Rename habit", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let habit = renaming { run { $0.renameHabit(id: habit.id, name: renameText) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Remove \(removing?.name ?? "this habit")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove from tomorrow", role: .destructive) {
                if let habit = removing { run { $0.removeHabit(id: habit.id) } }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("Mark today as usual: today still counts. Tomorrow the row leaves the Systems page. Its past days stay in the record.")
        }
    }

    /// One row: its name and rules, the penalty checkbox, and the move, rename, and remove buttons.
    private func row(_ habit: HandHabit, index: Int) -> some View {
        let leaving = habit.endDay != nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(habit.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(QuestLight.ink.opacity(leaving ? 0.5 : 1))
                Spacer()
                iconButton("chevron.up", label: "Move \(habit.name) up", disabled: index == 0) { move(habit, -1) }
                iconButton("chevron.down", label: "Move \(habit.name) down", disabled: index == rows.count - 1) { move(habit, 1) }
            }
            Text(detail(habit))
                .font(.caption)
                .foregroundStyle(SystemTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if !leaving {
                HStack(spacing: 8) {
                    Toggle(isOn: Binding(
                        get: { habit.penaltyOnFromTomorrow },
                        set: { on in run { $0.setHabitPenalty(id: habit.id, on: on) } }
                    )) {
                        Text("PENALTY")
                            .font(.caption2.weight(.semibold))
                            .tracking(1)
                            .foregroundStyle(SystemTheme.muted)
                    }
                    .toggleStyle(QuestCheckToggleStyle())
                    .accessibilityHint("A fail on two days in a row opens the penalty. The change starts tomorrow.")
                    Spacer()
                    smallButton("RENAME") { renameText = habit.name; renaming = habit }
                    smallButton("REMOVE", color: QuestLight.penalty) { removing = habit }
                }
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }

    /// Home by: the time the phone must be home. A new time starts tomorrow and starts a new streak.
    private var homeBySection: some View {
        let habits = store.snapshot.habits
        let now = habits.homeByMinutes(on: today)
        let next = habits.homeByMinutes(on: tomorrow)
        let pick = homeByPick ?? next
        return VStack(alignment: .leading, spacing: 10) {
            QuestSectionTitle(text: "Home by")
            Stepper(value: Binding(get: { pick }, set: { homeByPick = $0 }), in: HomeBy.minutesRange, step: HomeBy.step) {
                Text(HomeBy.timeText(pick))
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(QuestLight.ink)
            }
            .accessibilityLabel("Home by time")
            .accessibilityValue(HomeBy.timeText(pick))
            Text(now == next ? "Today: \(HomeBy.timeText(now)). A new time starts tomorrow, and the row's streak starts again."
                 : "Today: \(HomeBy.timeText(now)). From tomorrow: \(HomeBy.timeText(next)). The row's streak starts again then.")
                .font(.caption2)
                .foregroundStyle(SystemTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if pick != next {
                Button {
                    run { $0.setHomeByTime(pick) } done: { homeByPick = nil }
                } label: {
                    Text("SAVE \(HomeBy.timeText(pick).uppercased()) FROM TOMORROW")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.8)
                        .foregroundStyle(QuestLight.ink)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .overlay { Rectangle().stroke(QuestLight.ink.opacity(0.6), lineWidth: 0.8) }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("saveHomeByButton")
            }
        }
    }

    /// Screen Time: the daily total limit. The app checks it; a new limit starts tomorrow.
    private var screenTimeSection: some View {
        let habits = store.snapshot.habits
        let now = habits.screenTimeCap(on: today)
        let next = habits.screenTimeCap(on: tomorrow)
        let pick = capPick ?? next
        return VStack(alignment: .leading, spacing: 10) {
            QuestSectionTitle(text: "Screen Time limit")
            Stepper(value: Binding(get: { pick }, set: { capPick = $0 }), in: ScreenTime.capRange, step: ScreenTime.capStep) {
                Text(ScreenTime.clock(pick))
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(QuestLight.ink)
            }
            .accessibilityLabel("Screen Time limit")
            .accessibilityValue(ScreenTime.clock(pick))
            Text((now == next ? "Today: \(ScreenTime.clock(now))." : "Today: \(ScreenTime.clock(now)). From tomorrow: \(ScreenTime.clock(next)).")
                 + " Phone and Mac minutes together. The row fails \(ScreenTime.graceMinutes) minutes past the limit."
                 + " Notices come at 50, 75, 90, 95, and 100% of it.")
                .font(.caption2)
                .foregroundStyle(SystemTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if pick != next {
                Button {
                    run { $0.setScreenTimeCap(pick) } done: { capPick = nil }
                } label: {
                    Text("SAVE \(ScreenTime.clock(pick).uppercased()) FROM TOMORROW")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.8)
                        .foregroundStyle(QuestLight.ink)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .overlay { Rectangle().stroke(QuestLight.ink.opacity(0.6), lineWidth: 0.8) }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("saveScreenTimeLimitButton")
            }
        }
    }

    private var addSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            QuestSectionTitle(text: "Add a habit")
            TextField("Name, for example Read 20 pages", text: $newName)
                .focused($typing)
                .foregroundStyle(QuestLight.ink)
                .padding(.horizontal, 8)
                .frame(minHeight: 40)
                .overlay { Rectangle().stroke(QuestLight.ink.opacity(0.4), lineWidth: 0.8) }
                .accessibilityIdentifier("newHabitName")
            Picker("Type", selection: $limited) {
                Text("Pass or Fail each day").tag(false)
                Text("At most N days a week").tag(true)
            }
            .pickerStyle(.segmented)
            if limited {
                Stepper("At most \(limit) day\(limit == 1 ? "" : "s") a week", value: $limit, in: 1...HabitEditor.maxLimit)
                    .foregroundStyle(QuestLight.ink)
                Text("Mark a day \"Did it\" when you did it. A day past the limit fails. A day you do not mark passes.")
                    .font(.caption2)
                    .foregroundStyle(SystemTheme.muted)
            } else {
                Text("Mark each day Pass or Fail. A day you do not mark fails.")
                    .font(.caption2)
                    .foregroundStyle(SystemTheme.muted)
            }
            Toggle(isOn: $newPenalty) {
                Text("A FAIL TWO DAYS IN A ROW OPENS THE PENALTY")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(SystemTheme.muted)
            }
            .toggleStyle(QuestCheckToggleStyle())
            Button {
                typing = false
                let name = newName
                run { $0.addHabit(name: name, weeklyLimit: limited ? limit : nil, opensPenalty: newPenalty) } done: { newName = "" }
            } label: {
                Text("ADD FROM TOMORROW")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(QuestLight.ink)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .overlay { Rectangle().stroke(QuestLight.ink.opacity(0.6), lineWidth: 0.8) }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("addHabitButton")
        }
    }

    /// "Pass or Fail · penalty on · starts Nov 24", and what changes tomorrow.
    private func detail(_ habit: HandHabit) -> String {
        var parts = [habit.weeklyLimit.map { "At most \($0) day\($0 == 1 ? "" : "s") a week" } ?? "Pass or Fail"]
        if habit.endDay != nil {
            parts.append("removed from tomorrow")
        } else {
            let now = habit.opensPenalty(on: today)
            let next = habit.opensPenalty(on: tomorrow)
            switch (now, next) {
            case (true, true): parts.append("penalty on")
            case (false, false): parts.append("no penalty")
            case (true, false): parts.append("penalty on today, off from tomorrow")
            case (false, true): parts.append("penalty from tomorrow")
            }
            if habit.firstDay > today { parts.append("starts \(Contract.dateText(habit.firstDay))") }
        }
        return parts.joined(separator: " · ")
    }

    private func run(_ change: (inout GameSnapshot) -> String?, done: () -> Void = {}) {
        problem = store.editHabits(change)
        if problem == nil {
            SystemSound.systemOpen.play()
            done()
        } else {
            SystemSound.questFail.play()
        }
    }

    private func move(_ habit: HandHabit, _ offset: Int) {
        run { $0.moveHabit(id: habit.id, by: offset); return nil }
    }

    private func iconButton(_ name: String, label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.caption.weight(.semibold))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(QuestLight.ink.opacity(disabled ? 0.2 : 0.8))
        .disabled(disabled)
        .accessibilityLabel(label)
    }

    private func smallButton(_ title: String, color: Color = QuestLight.ink, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(color)
                .padding(.horizontal, 10)
                .frame(minHeight: 32)
                .overlay { Rectangle().stroke(color.opacity(0.6), lineWidth: 0.8) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
