import SwiftUI

/// Opens from a stat on the status radar. Lists the stat's max level targets; each one can be removed or added back.
struct StatTargetsSheet: View {
    let stat: Stat
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: GameStore

    /// Every target, removed ones included. A reading from history has no report yet, so it falls back to the empty one.
    private var report: StatLevelReport {
        store.statLevels.reports[stat] ?? StatLevelSet.empty.reports[stat] ?? StatLevelReport(stat: stat, requirements: [])
    }

    private var removed: Set<String> { store.statTargets.removed(for: stat) }

    /// Active targets with their weights scaled to 100.
    private var active: [StatRequirement] { report.removing(removed).requirements }

    private var removedTargets: [StatRequirement] { report.requirements.filter { removed.contains($0.category) } }

    var body: some View {
        NavigationStack {
            QuestSheet(title: stat.fullName) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("LEVEL \(store.statLevels[stat]) / \(StatLevel.maxLevel)")
                        .font(.title3.weight(.semibold))
                        .tracking(1.1)
                    note("\(active.count) of \(report.requirements.count) targets count. Meet every target that counts to reach \(StatLevel.maxLevel). A removed target's weight goes to the others.")
                }

                QuestSectionTitle(text: "Targets")
                VStack(spacing: 14) {
                    ForEach(active) { requirement in
                        row(requirement, isRemoved: false)
                    }
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
                        Text("\(Int(requirement.weight.rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(SystemTheme.muted)
                    }
                }
                if let goal = StatTargets.goals[requirement.category] {
                    Text(goal)
                        .font(.footnote)
                }
                note(requirement.detail)
                if !isRemoved {
                    SystemProgressBar(progress: requirement.progress)
                        .padding(.top, 4)
                }
            }
            toggleButton(requirement.category, isRemoved: isRemoved)
        }
        .opacity(isRemoved ? 0.6 : 1)
    }

    /// Boxed like the quest window's header boxes. The last active target cannot be removed.
    private func toggleButton(_ category: String, isRemoved: Bool) -> some View {
        Button {
            store.toggleStatTarget(category, in: stat)
        } label: {
            Text(isRemoved ? "ADD" : "REMOVE")
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .frame(width: 64, height: 28)
                .overlay { Rectangle().stroke(QuestLight.ink.opacity(0.6), lineWidth: 0.8) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isRemoved && active.count <= 1)
        .accessibilityLabel(isRemoved ? "Add \(category)" : "Remove \(category)")
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
