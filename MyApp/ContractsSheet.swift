import SwiftUI

/// The player's contracts: each one's terms, punishment, and weekly record, and the screen to create and sign a new one.
/// A signed contract cannot be changed or cancelled before its end date.
struct ContractsSheet: View {
    @EnvironmentObject private var store: GameStore

    private var contracts: [Contract] { store.snapshot.habits.contracts.reversed() }

    var body: some View {
        NavigationStack {
            QuestSheet(title: "Contracts") {
                Text("A contract is a promise you sign on purpose. You cannot change or cancel it before its end date. "
                     + Contract.rules)
                    .font(.footnote)
                    .foregroundStyle(SystemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)

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
                Text("Line today: \(Contract.number((contract.lineLb(on: store.snapshot.bundle.dayKey) * 10).rounded() / 10)) lb")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(QuestLight.ink.opacity(0.85))
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
    @State private var punishment = Punishment.classic
    @State private var confirming = false
    @State private var problem: String?

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
            Picker("Kind", selection: $kind) {
                ForEach(Contract.Kind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            if kind == .habit {
                habitSection
            } else {
                field("Start weight (lb)", text: $startWeight, hint: store.latestWeightLb.map { "Your newest weigh-in: \(Contract.number($0)) lb" })
                field("Target weight (lb)", text: $targetWeight, hint: nil)
            }
            DatePicker("End date", selection: $endDate, in: Date.now.addingTimeInterval(7 * 86_400)..., displayedComponents: .date)
                .foregroundStyle(QuestLight.ink)

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
        .onAppear {
            if startWeight.isEmpty, let latest = store.latestWeightLb { startWeight = Contract.number(latest) }
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
