import SwiftUI

/// The player's contracts: each one's terms, punishment, and weekly record, and the screen to create and sign a new one.
/// A signed contract cannot be changed or cancelled before its end date.
struct ContractsSheet: View {
    @EnvironmentObject private var store: GameStore

    private var contracts: [Contract] { store.snapshot.habits.contracts.reversed() }
    @State private var weighing = false
    @State private var weighInText = ""
    @State private var weighInProblem: String?

    /// The 145 lb contract waits here until a body weight contract is active.
    private var offerWeightGoal: Bool {
        !store.snapshot.habits.contracts.contains { $0.kind == .bodyWeight && $0.isActive(on: store.snapshot.bundle.dayKey) }
            && store.snapshot.bundle.dayKey < WeightGoal.endDayKey
    }

    var body: some View {
        NavigationStack {
            QuestSheet(title: "Contracts") {
                Text("A contract is a promise you sign on purpose. You cannot change or cancel it before its end date. "
                     + Contract.rules)
                    .font(.footnote)
                    .foregroundStyle(SystemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                if offerWeightGoal {
                    NavigationLink {
                        CreateContractView(kind: .bodyWeight, targetLb: WeightGoal.targetLb, endDayKey: WeightGoal.endDayKey)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("READY TO SIGN")
                                .font(.caption2.weight(.semibold))
                                .tracking(1)
                                .foregroundStyle(QuestLight.penalty)
                            Text("Reach \(Contract.number(WeightGoal.targetLb)) lb by \(Contract.dateText(WeightGoal.endDayKey))")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(QuestLight.ink)
                            Text("Type your start weight, pick the punishment, and sign. Weigh in every week.")
                                .font(.caption)
                                .foregroundStyle(SystemTheme.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .overlay { Rectangle().stroke(QuestLight.penalty.opacity(0.8), lineWidth: 1) }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("signWeightGoalButton")
                }

                NavigationLink {
                    CreateContractView()
                } label: {
                    boxLabel("CREATE A CONTRACT")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("createContractButton")

                if contracts.isEmpty {
                    Text("No contract signed yet.")
                        .font(.footnote)
                        .foregroundStyle(QuestLight.ink.opacity(0.7))
                } else {
                    ForEach(contracts) { contract in
                        contractCard(contract)
                    }
                }
            }
            .font(.subheadline)
            .tint(SystemTheme.accent)
            .alert("Log weigh-in", isPresented: $weighing) {
                TextField("Weight (lb)", text: $weighInText)
                    .keyboardType(.decimalPad)
                Button("Save") {
                    let lb = Double(weighInText.replacingOccurrences(of: ",", with: ".")) ?? 0
                    weighInProblem = store.logWeighIn(lb) ? nil : "Type a weight from 50 to 500 lb."
                    weighInText = ""
                }
                Button("Cancel", role: .cancel) { weighInText = "" }
            } message: {
                Text("Today's weight in lb. It counts toward this week's average.")
            }
        }
    }

    private func contractCard(_ contract: Contract) -> some View {
        let active = contract.isActive(on: store.snapshot.bundle.dayKey)
        let kept = contract.checks.filter(\.kept).count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(contract.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(QuestLight.ink)
                Spacer()
                Text(active ? "ACTIVE" : "ENDED")
                    .font(.caption2.weight(.semibold))
                    .tracking(1)
                    .foregroundStyle(active ? QuestLight.cyan : SystemTheme.muted)
            }
            Text(contract.terms)
                .font(.caption)
                .foregroundStyle(SystemTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if active, contract.kind == .habit {
                Text(weekText(contract))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(QuestLight.ink.opacity(0.85))
            } else if active {
                if let week = store.snapshot.weightWeek(contract) {
                    let line = Contract.number((week.lineLb * 10).rounded() / 10)
                    Text(week.average.map { "This week: \(Contract.number(($0 * 10).rounded() / 10)) lb average, line \(line) lb. "
                        + (week.onTrack == true ? "On track." : "Not on track.") }
                         ?? "This week: no weigh-in yet. The line is \(line) lb. A week with no weigh-in is broken.")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(week.onTrack == true ? QuestLight.cyan : QuestLight.penalty)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button { weighing = true } label: { boxLabel("LOG WEIGH-IN") }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("logWeighInButton")
                if let weighInProblem {
                    Text(weighInProblem)
                        .font(.caption)
                        .foregroundStyle(QuestLight.penalty)
                }
            }
            Text(contract.punishment.sentence)
                .font(.caption)
                .foregroundStyle(QuestLight.penalty)
                .fixedSize(horizontal: false, vertical: true)
            Text("Weeks kept: \(kept)/\(contract.checks.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(QuestLight.ink.opacity(0.85))
            // One dot a judged week: filled when kept, red when broken.
            HStack(spacing: 4) {
                ForEach(contract.checks, id: \.endDayKey) { check in
                    Circle()
                        .fill(check.kept ? QuestLight.cyan : QuestLight.penalty)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("\(Contract.dateText(check.endDayKey)): \(check.kept ? "kept" : "broken")"
                                            + (check.passedDays.map { ", \($0) of \(check.requiredDays ?? 0) days" } ?? ""))
                }
            }
        }
        .padding(12)
        .overlay { Rectangle().stroke(QuestLight.ink.opacity(0.4), lineWidth: 0.8) }
    }

    /// "This week: 3 days passed, 5 needed": from the week's start (or the start date) through today.
    private func weekText(_ contract: Contract) -> String {
        let today = store.snapshot.bundle.dayKey
        guard let period = contract.periods.first(where: { $0.start <= today && today <= $0.end }) else { return "" }
        var day = period.start
        var passed = 0
        while day <= today {
            if store.snapshot.habitPassed(contract.habitKey ?? "", on: day) { passed += 1 }
            day = QuestDay.key(byAddingDays: 1, to: day)
        }
        return "This week: \(passed) day\(passed == 1 ? "" : "s") passed, \(contract.requiredDays(start: period.start, end: period.end)) needed"
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

/// Sets up a contract: a habit or body weight, the standard, the end date, and the punishment.
/// Then the player reads the terms and signs.
struct CreateContractView: View {
    @EnvironmentObject private var store: GameStore
    @Environment(\.dismiss) private var dismiss
    @State private var id = UUID().uuidString
    @State private var kind: Contract.Kind = .habit
    @State private var habitKey = ContractHabits.homeBy
    @State private var newHabitName = ""
    @State private var daysPerWeek = 7
    @State private var startWeight = ""
    @State private var targetWeight = "145"
    @State private var endDate = Calendar.current.date(byAdding: .month, value: 1, to: .now) ?? .now
    /// True for a preset contract: its target and end date are set, not picked.
    private let preset: Bool

    init() { preset = false }

    /// A preset body weight contract: the target and the end date are fixed. The player types the start weight.
    init(kind: Contract.Kind, targetLb: Double, endDayKey: String) {
        preset = true
        _kind = State(initialValue: kind)
        _targetWeight = State(initialValue: Contract.number(targetLb))
        _endDate = State(initialValue: QuestDay.date(from: endDayKey).map { $0.addingTimeInterval(12 * 3600) } ?? .now)
    }
    @State private var punishment = Punishment.classic
    @State private var confirming = false
    @State private var problem: String?
    @FocusState private var typing: Bool

    private var options: [(key: String, name: String)] { ContractHabits.options(store.snapshot.habits) }

    private var habitName: String {
        habitKey == ContractHabits.new ? newHabitName : options.first { $0.key == habitKey }?.name ?? ""
    }

    private var draft: Contract {
        Contract(id: id, kind: kind, startDayKey: store.snapshot.bundle.dayKey, endDayKey: QuestDay.key(for: endDate),
                 startLb: Double(startWeight.replacingOccurrences(of: ",", with: ".")) ?? 0,
                 targetLb: Double(targetWeight.replacingOccurrences(of: ",", with: ".")) ?? 0, signedAt: .now,
                 habitKey: kind == .habit ? habitKey : nil, habitName: kind == .habit ? habitName : nil,
                 daysPerWeek: daysPerWeek, punishment: punishment)
    }

    var body: some View {
        QuestSheet(title: "Create a contract") {
            if !preset {
                Picker("Kind", selection: $kind) {
                    ForEach(Contract.Kind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            if kind == .habit {
                habitSection
            } else {
                field("Start weight (lb)", text: $startWeight, hint: store.latestWeightLb.map { "Your newest weigh-in: \(Contract.number($0)) lb" })
                if preset {
                    Text("Target: \(targetWeight) lb by \(Contract.dateText(QuestDay.key(for: endDate)))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(QuestLight.ink)
                } else {
                    field("Target weight (lb)", text: $targetWeight, hint: nil)
                }
                Text("Weigh in every week: Apple Health, or Log weigh-in on the contract. A week with no weigh-in is broken.")
                    .font(.caption2)
                    .foregroundStyle(SystemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !preset {
                DatePicker("End date", selection: $endDate, in: Date.now.addingTimeInterval(7 * 86_400)..., displayedComponents: .date)
                    .foregroundStyle(QuestLight.ink)
            }

            punishmentSection

            QuestSectionTitle(text: "Terms")
            Text(draft.terms)
                .font(.footnote)
                .foregroundStyle(QuestLight.ink.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            Text(punishment.isEmpty ? "Pick at least one punishment." : punishment.sentence)
                .font(.footnote)
                .foregroundStyle(QuestLight.penalty)
                .fixedSize(horizontal: false, vertical: true)

            if let problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(QuestLight.penalty)
            }

            Button {
                problem = draft.problem
                if problem == nil { confirming = true }
            } label: {
                Text("SIGN")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(QuestLight.ink)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .overlay { Rectangle().stroke(QuestLight.ink.opacity(0.6), lineWidth: 0.8) }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("signContractButton")
        }
        .font(.subheadline)
        .tint(SystemTheme.accent)
        // The number pad has no return key: Done closes it.
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { typing = false }
            }
        }
        .alert("Sign this contract?", isPresented: $confirming) {
            Button("Sign", role: .destructive) {
                if let refused = store.signContract(draft) {
                    problem = refused
                } else {
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(draft.title). \(punishment.sentence) You cannot change or cancel it before \(Contract.dateText(draft.endDayKey)).")
        }
    }

    @ViewBuilder
    private var habitSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Habit")
                .font(.caption)
                .foregroundStyle(SystemTheme.muted)
            Picker("Habit", selection: $habitKey) {
                ForEach(options, id: \.key) { Text($0.name).tag($0.key) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("contractHabitPicker")
        }
        if habitKey == ContractHabits.new {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Habit name, for example Read 20 pages", text: $newHabitName)
                    .focused($typing)
                    .foregroundStyle(QuestLight.ink)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 40)
                    .overlay { Rectangle().stroke(QuestLight.ink.opacity(0.4), lineWidth: 0.8) }
                Text("It becomes a row on the Systems page. You mark each day Pass or Fail there.")
                    .font(.caption2)
                    .foregroundStyle(SystemTheme.muted)
            }
        }
        Stepper("Days a week: \(daysPerWeek)/7", value: $daysPerWeek, in: 1...7)
            .foregroundStyle(QuestLight.ink)
    }

    private var punishmentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            QuestSectionTitle(text: "Punishment for each broken week")
            Stepper("Gold: \(punishment.gold == 0 ? "none" : String(FinanceLevel.usd(Double(punishment.gold)).dropFirst()))",
                    value: $punishment.gold, in: 0...Punishment.maxGold, step: Punishment.goldStep)
            Stepper("Full Recovery tokens: \(punishment.tokens)", value: $punishment.tokens, in: 0...3)
            Stepper("Rest days: \(punishment.restDays)", value: $punishment.restDays, in: 0...2)
            Toggle("Penalty 10K run", isOn: $punishment.penaltyRun)
        }
        .foregroundStyle(QuestLight.ink)
    }

    private func field(_ label: String, text: Binding<String>, hint: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(SystemTheme.muted)
            TextField(label, text: text)
                .keyboardType(.decimalPad)
                .focused($typing)
                .foregroundStyle(QuestLight.ink)
                .padding(.horizontal, 8)
                .frame(minHeight: 40)
                .overlay { Rectangle().stroke(QuestLight.ink.opacity(0.4), lineWidth: 0.8) }
            if let hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(SystemTheme.muted)
            }
        }
    }
}

#Preview {
    ContractsSheet()
        .environmentObject(GameStore(persistence: .memory))
}
