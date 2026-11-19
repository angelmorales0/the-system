import SwiftUI

/// The player's contracts: each one's terms and weekly record, and the screen to create and sign a new one.
/// A signed contract cannot be changed or cancelled before its end date.
struct ContractsSheet: View {
    @EnvironmentObject private var store: GameStore

    private var contracts: [Contract] { store.snapshot.habits.contracts.reversed() }

    var body: some View {
        NavigationStack {
            QuestSheet(title: "Contracts") {
                Text("A contract is a promise you sign on purpose. You pick the end date. You cannot change or cancel it before then. "
                     + Contract.stake)
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
            if active {
                Text("Line today: \(Contract.number((contract.lineLb(on: store.snapshot.bundle.dayKey) * 10).rounded() / 10)) lb")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(QuestLight.ink.opacity(0.85))
            }
            Text("Weeks kept: \(kept)/\(contract.checks.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(QuestLight.ink.opacity(0.85))
            // One dot a judged week: filled when kept, red when broken.
            HStack(spacing: 4) {
                ForEach(contract.checks, id: \.endDayKey) { check in
                    Circle()
                        .fill(check.kept ? QuestLight.cyan : QuestLight.penalty)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("\(Contract.dateText(check.endDayKey)): \(check.kept ? "kept" : "broken")")
                }
            }
        }
        .padding(12)
        .overlay { Rectangle().stroke(QuestLight.ink.opacity(0.4), lineWidth: 0.8) }
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

/// Sets up a contract: the rule, its numbers, and the end date. Then the player reads the terms and the stake and signs.
struct CreateContractView: View {
    @EnvironmentObject private var store: GameStore
    @Environment(\.dismiss) private var dismiss
    @State private var kind: Contract.Kind = .bodyWeight
    @State private var startWeight = ""
    @State private var targetWeight = "145"
    @State private var endDate = Calendar.current.date(byAdding: .month, value: 6, to: .now) ?? .now
    @State private var confirming = false
    @State private var problem: String?

    private var draft: Contract {
        Contract(id: UUID().uuidString, kind: kind, startDayKey: store.snapshot.bundle.dayKey, endDayKey: QuestDay.key(for: endDate),
                 startLb: Double(startWeight.replacingOccurrences(of: ",", with: ".")) ?? 0,
                 targetLb: Double(targetWeight.replacingOccurrences(of: ",", with: ".")) ?? 0, signedAt: .now)
    }

    var body: some View {
        QuestSheet(title: "Create a contract") {
            Picker("Rule", selection: $kind) {
                ForEach(Contract.Kind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            field("Start weight (lb)", text: $startWeight, hint: store.latestWeightLb.map { "Your newest weigh-in: \(Contract.number($0)) lb" })
            field("Target weight (lb)", text: $targetWeight, hint: nil)
            DatePicker("End date", selection: $endDate, in: Date.now.addingTimeInterval(7 * 86_400)..., displayedComponents: .date)
                .foregroundStyle(QuestLight.ink)

            QuestSectionTitle(text: "Terms")
            Text(draft.terms)
                .font(.footnote)
                .foregroundStyle(QuestLight.ink.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            Text(Contract.stake)
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
            Text("\(draft.title). You cannot change or cancel it before \(Contract.dateText(draft.endDayKey)).")
        }
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
