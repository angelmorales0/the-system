import SwiftUI

/// Opens from a stat on the status radar. Lists the stat's max level targets; each one can be removed or added back.
/// On STR, the player can also add an own goal (an exercise and a target) and delete it again.
struct StatTargetsSheet: View {
    let stat: Stat
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: GameStore

    @State private var adding = false
    @State private var name = ""
    @State private var kind: CustomStrengthGoal.Kind = .weightReps
    @State private var weight = ""
    @State private var reps = ""
    @State private var seconds = ""
    /// A `GymSplit.Day.id`, or `autoDay`.
    @State private var dayChoice = Self.autoDay
    @State private var lowerBody = false
    @State private var problem: String?

    private static let autoDay = "auto"

    /// Every target, removed ones included. A reading from history, or one made before a goal changed, has no matching
    /// report yet, so it falls back to a report from no data with the current targets.
    private var report: StatLevelReport {
        let fresh = StatLevelSet.compute(codeforces: .disconnected(reason: ""), financeMonths: [], targets: store.statTargets, now: .now)
        let fallback = fresh.reports[stat] ?? StatLevelReport(stat: stat, requirements: [])
        guard let current = store.statLevels.reports[stat],
              Set(current.requirements.map(\.category)) == Set(fallback.requirements.map(\.category)) else { return fallback }
        return current
    }

    private var removed: Set<String> { store.statTargets.removed(for: stat) }

    /// Active targets, with and without data, in display order.
    private var active: [StatRequirement] { report.removing(removed).requirements }

    /// The weight each active target with data really carries, scaled to 100 among them.
    private var countedWeights: [String: Double] {
        Dictionary(uniqueKeysWithValues: report.removing(removed).counted.map { ($0.category, $0.weight) })
    }

    private var removedTargets: [StatRequirement] { report.requirements.filter { removed.contains($0.category) } }

    var body: some View {
        NavigationStack {
            QuestSheet(title: stat.fullName) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("LEVEL \(store.statLevels[stat]) / \(StatLevel.maxLevel)")
                        .font(.title3.weight(.semibold))
                        .tracking(1.1)
                    note("\(countedWeights.count) of \(report.requirements.count) targets count. Meet every target that counts to reach \(StatLevel.maxLevel). A removed target's weight goes to the others, and so does the weight of a target with no data yet.")
                    if stat == .FOC {
                        NavigationLink {
                            FocusTrackingView()
                        } label: {
                            boxLabel(FocusTracking.isTracking ? "TRACKING SETTINGS" : "SET UP TRACKING")
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 6)
                    }
                    if stat == .AGI {
                        note("Every test is read from Hevy. Log each one as its own exercise, named as shown under the target, with the result as reps (cm, inches, or switches) or as a distance in metres. The newest result in 90 days counts.")
                    }
                }

                QuestSectionTitle(text: "Targets")
                VStack(spacing: 14) {
                    ForEach(active) { requirement in
                        row(requirement, isRemoved: false)
                    }
                }

                if stat == .STR {
                    QuestSectionTitle(text: "Your goals")
                    addGoal
                }

                if !removedTargets.isEmpty {
                    QuestSectionTitle(text: "Removed")
                    VStack(spacing: 14) {
                        ForEach(removedTargets) { requirement in
                            row(requirement, isRemoved: true)
                        }
                    }
                }
            }
            .font(.subheadline)
            .tint(SystemTheme.accent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func row(_ requirement: StatRequirement, isRemoved: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: requirement.passed ? "checkmark.square" : "square")
                .foregroundStyle(requirement.passed ? QuestLight.cyan : QuestLight.ink.opacity(0.6))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(requirement.category)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    if !isRemoved {
                        Text(countedWeights[requirement.category].map { "\(Int($0.rounded()))%" } ?? "NO DATA")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(SystemTheme.muted)
                    }
                }
                if let goal = store.statTargets.goal(for: requirement.category) {
                    Text(goal)
                        .font(.footnote)
                }
                if stat == .AGI, !AgilityHevy.hevyNames(forCategory: requirement.category).isEmpty {
                    note("Hevy: " + AgilityHevy.hevyNames(forCategory: requirement.category).joined(separator: ", "))
                }
                if let custom = store.statTargets.custom.first(where: { $0.category == requirement.category }) {
                    note("Your goal. Trained on \(GymSplit.day(id: custom.day)?.name ?? "its split day").")
                }
                note(requirement.detail)
                if !isRemoved {
                    SystemProgressBar(progress: requirement.progress)
                        .padding(.top, 4)
                }
            }
            if store.statTargets.isCustom(requirement.category) {
                deleteButton(requirement.category)
            } else {
                toggleButton(requirement.category, isRemoved: isRemoved)
            }
        }
        .opacity(isRemoved ? 0.6 : 1)
    }

    /// Boxed like the quest window's header boxes. The last active target cannot be removed.
    private func toggleButton(_ category: String, isRemoved: Bool) -> some View {
        Button {
            store.toggleStatTarget(category, in: stat)
        } label: {
            boxLabel(isRemoved ? "ADD" : "REMOVE", width: 64)
        }
        .buttonStyle(.plain)
        .disabled(!isRemoved && active.count <= 1)
        .accessibilityLabel(isRemoved ? "Add \(category)" : "Remove \(category)")
    }

    /// A custom goal is deleted, not removed. The last active target cannot be deleted.
    private func deleteButton(_ category: String) -> some View {
        Button {
            store.deleteStrengthGoal(category)
        } label: {
            boxLabel("DELETE", width: 64)
        }
        .buttonStyle(.plain)
        .disabled(active.count <= 1)
        .accessibilityLabel("Delete \(category)")
    }

    // MARK: - Add goal

    @ViewBuilder
    private var addGoal: some View {
        VStack(alignment: .leading, spacing: 12) {
            if adding {
                field("Exercise, as Hevy names it (Hip Thrust)", text: $name)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                Picker("Goal type", selection: $kind) {
                    ForEach(CustomStrengthGoal.Kind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                HStack(spacing: 10) {
                    switch kind {
                    case .weightReps:
                        field("Weight (lb)", text: $weight).keyboardType(.decimalPad)
                        field("Reps", text: $reps).keyboardType(.numberPad)
                    case .reps:
                        field("Reps in one set", text: $reps).keyboardType(.numberPad)
                    case .hold:
                        field("Seconds", text: $seconds).keyboardType(.numberPad)
                    }
                }
                HStack {
                    Text("Split day")
                    Spacer()
                    Picker("Split day", selection: $dayChoice) {
                        Text("Auto").tag(Self.autoDay)
                        ForEach(GymSplit.rotation, id: \.id) { day in
                            Text("\(day.name) (room \(GymSplit.room(on: day, goals: store.statTargets.custom)))").tag(day.id)
                        }
                    }
                    .pickerStyle(.menu)
                }
                if dayChoice == Self.autoDay {
                    Picker("Body half", selection: $lowerBody) {
                        Text("Upper body").tag(false)
                        Text("Lower body").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                note(placementNote)
                if let problem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(QuestLight.caution)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Button {
                        resetForm()
                    } label: {
                        boxLabel("CANCEL")
                    }
                    .buttonStyle(.plain)
                    Button {
                        save()
                    } label: {
                        boxLabel("SAVE GOAL")
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button {
                    adding = true
                } label: {
                    boxLabel("ADD GOAL")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add a strength goal")
                note("Add your own strength goal. It scores like the targets above, and its exercise joins a split day from the next plan on. On a full day it takes the place of a support exercise.")
            }
        }
        // A refusal is about the old fields. A change clears it.
        .onChange(of: [name, kind.rawValue, weight, reps, seconds, dayChoice, String(lowerBody)]) { _, _ in
            problem = nil
        }
    }

    /// The day the goal goes on: the picked day, or the auto day for the body half.
    private var chosenDay: GymSplit.Day? {
        dayChoice == Self.autoDay
            ? GymSplit.autoDay(lowerBody: lowerBody, goals: store.statTargets.custom)
            : GymSplit.day(id: dayChoice)
    }

    /// Says where the goal goes and what it replaces, so the full-day rule is clear before the player saves.
    private var placementNote: String {
        guard let day = chosenDay else {
            return "No \(lowerBody ? "lower" : "upper")-body day has room. Delete a goal or pick the other half."
        }
        let goals = store.statTargets.custom
        guard GymSplit.room(on: day, goals: goals) > 0 else {
            return "\(day.name) is full: no support exercise is left to give its place."
        }
        let draft = CustomStrengthGoal(exercise: name.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind, day: day.id)
        if let replaced = GymSplit.replaced(by: draft, goals: goals) {
            return "Goes on \(day.name) in place of \(replaced.exercise), a support exercise."
        }
        return "Goes on \(day.name)."
    }

    private func save() {
        guard let day = chosenDay else {
            problem = placementNote
            return
        }
        let goal = CustomStrengthGoal(
            exercise: name,
            kind: kind,
            targetLb: Double(weight.replacingOccurrences(of: ",", with: ".")) ?? 0,
            targetReps: Int(reps) ?? 0,
            targetSeconds: Double(seconds) ?? 0,
            day: day.id
        )
        if let refused = store.addStrengthGoal(goal) {
            problem = refused
        } else {
            resetForm()
        }
    }

    private func resetForm() {
        adding = false
        name = ""
        kind = .weightReps
        weight = ""
        reps = ""
        seconds = ""
        dayChoice = Self.autoDay
        lowerBody = false
        problem = nil
    }

    // MARK: - Parts

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .padding(.horizontal, 8)
            .frame(minHeight: 34)
            .overlay { Rectangle().stroke(QuestLight.ink.opacity(0.4), lineWidth: 0.8) }
    }

    /// Boxed like the quest window's header boxes.
    private func boxLabel(_ text: String, width: CGFloat? = nil) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .tracking(0.8)
            .frame(width: width, height: width == nil ? nil : 28)
            .frame(maxWidth: width == nil ? .infinity : nil, minHeight: width == nil ? 34 : nil)
            .overlay { Rectangle().stroke(QuestLight.ink.opacity(0.6), lineWidth: 0.8) }
            .contentShape(Rectangle())
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(SystemTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview {
    StatTargetsSheet(stat: .STR)
        .environmentObject(GameStore(persistence: .memory))
}
