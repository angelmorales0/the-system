import SwiftUI

struct GoalMock: Identifiable { let id = UUID(); let title: String; let subtitle: String; let icon: String; let start: String; let current: String; let progress: Double }

private enum GoalSection: String, CaseIterable {
    case goals = "GOALS"
    case targets = "TARGETS"
}

struct GoalsView: View {
    @EnvironmentObject private var store: GameStore
    @State private var section = GoalSection.goals
    @State private var editor: EditorRoute?
    @State private var notice: String?

    private let goals = [GoalMock(title: "5:30 Mile", subtitle: "Run a sub 5:30 mile", icon: "figure.run", start: "6:18", current: "5:56", progress: 0.68), GoalMock(title: "145 lb", subtitle: "Reach 145 lb bodyweight", icon: "dumbbell.fill", start: "150.2 lb", current: "149.1 lb", progress: 0.36)]

    var body: some View {
        ScreenContainer {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    Spacer().frame(height: 52)
                    sectionControl
                    if let notice {
                        Text(notice)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(SystemTheme.muted)
                    }
                    if section == .goals {
                        ForEach(goals) { goal in GoalCard(goal: goal) }
                    } else {
                        targetSection
                    }
                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 22).padding(.bottom, 28)
            }
        }
        .sheet(item: $editor) { route in
            TargetEditor(existing: route.target) { notice = $0 }
        }
    }

    private var sectionControl: some View {
        HStack(spacing: 0) {
            ForEach(GoalSection.allCases, id: \.self) { item in
                Button {
                    section = item
                } label: {
                    Text(item.rawValue)
                        .font(.caption.weight(.bold))
                        .tracking(1.6)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(section == item ? SystemTheme.cyan : SystemTheme.muted)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(section == item ? SystemTheme.cyan : SystemTheme.cyan.opacity(0.25))
                                .frame(height: 1)
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var targetSection: some View {
        VStack(spacing: 18) {
            Button {
                if let message = store.startInterviewPrep() {
                    notice = message
                } else {
                    notice = "Interview Prep is active. Swipe back to System."
                }
            } label: {
                Text("START INTERVIEW PREP")
                    .font(.caption.weight(.bold))
                    .tracking(1.4)
                    .foregroundStyle(SystemTheme.cyan)
            }
            .buttonStyle(.plain)

            Button {
                editor = .create
            } label: {
                Text("NEW TARGET")
                    .font(.caption.weight(.bold))
                    .tracking(1.4)
                    .foregroundStyle(SystemTheme.muted)
            }
            .buttonStyle(.plain)

            ForEach(orderedTargets) { target in
                TargetCard(target: target, onEdit: { editor = .edit(target) }, notice: $notice)
            }
        }
    }

    private var orderedTargets: [Target] {
        store.targets.sorted { lhs, rhs in
            if lhs.status.sortRank != rhs.status.sortRank { return lhs.status.sortRank < rhs.status.sortRank }
            return lhs.startsOn < rhs.startsOn
        }
    }
}

private struct GoalCard: View {
    let goal: GoalMock
    var body: some View {
        SystemPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: goal.icon)
                        .font(.title3)
                        .foregroundStyle(SystemTheme.cyan)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(goal.title).font(.title3.weight(.semibold)).foregroundStyle(.white)
                        Text(goal.subtitle).font(.caption).foregroundStyle(SystemTheme.muted)
                    }
                }
                SystemDivider()
                StatLine(label: "Start", value: goal.start)
                StatLine(label: "Current", value: goal.current)
                HStack(alignment: .bottom, spacing: 12) {
                    SystemProgressBar(progress: goal.progress)
                        .frame(maxWidth: .infinity)
                    Text("\(Int(goal.progress * 100))%")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(SystemTheme.muted)
                }
            }
        }
    }
}

private struct TargetCard: View {
    @EnvironmentObject private var store: GameStore
    let target: Target
    var onEdit: () -> Void
    @Binding var notice: String?

    var body: some View {
        SystemPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "scope")
                        .font(.title3)
                        .foregroundStyle(SystemTheme.cyan)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(target.title).font(.title3.weight(.semibold)).foregroundStyle(.white)
                        Text("\(target.kind.title) · \(target.status.label)")
                            .font(.caption)
                            .foregroundStyle(SystemTheme.muted)
                    }
                }
                SystemDivider()
                StatLine(label: "Window", value: "\(target.startsOn) → \(target.endsOn)")
                StatLine(label: "Day", value: "\(target.dayNumber(on: store.bundle.dayKey))/\(target.spanDays)")
                StatLine(label: "Daily", value: target.dailyRequirements.map { "\($0.title) \(Int($0.quota))" }.joined(separator: ", "))
                HStack(alignment: .bottom, spacing: 12) {
                    SystemProgressBar(progress: target.progressFraction)
                        .frame(maxWidth: .infinity)
                    Text(target.progressLabel)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(SystemTheme.muted)
                }
                if target.status == .active || target.status == .scheduled || target.status == .draft {
                    HStack(spacing: 18) {
                        if target.status != .active {
                            cardButton("ACTIVATE") {
                                notice = store.activateTarget(id: target.id) ?? "\(target.title) is active. Swipe back to System."
                            }
                        }
                        cardButton("EDIT", action: onEdit)
                        cardButton("ABORT") {
                            store.abortTarget(id: target.id)
                            notice = "\(target.title) aborted."
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private func cardButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption2.weight(.bold))
                .tracking(1.1)
                .foregroundStyle(SystemTheme.cyan)
        }
        .buttonStyle(.plain)
    }
}

private enum EditorRoute: Identifiable {
    case create
    case edit(Target)

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let target): target.id
        }
    }

    var target: Target? {
        switch self {
        case .create: nil
        case .edit(let target): target
        }
    }
}

extension TargetStatus {
    fileprivate var sortRank: Int {
        switch self {
        case .active: 0
        case .scheduled: 1
        case .draft: 2
        case .completed: 3
        case .expired: 4
        case .aborted: 5
        }
    }
}

#Preview {
    GoalsView()
        .environmentObject(GameStore(persistence: .memory))
}
