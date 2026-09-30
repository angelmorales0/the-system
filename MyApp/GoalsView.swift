import SwiftUI

struct GoalMock: Identifiable { let id = UUID(); let title: String; let subtitle: String; let icon: String; let start: String; let current: String; let progress: Double }

struct GoalsView: View {
    private let goals = [GoalMock(title: "5:30 Mile", subtitle: "Run a sub 5:30 mile", icon: "figure.run", start: "6:18", current: "5:56", progress: 0.68), GoalMock(title: "145 lb", subtitle: "Reach 145 lb bodyweight", icon: "dumbbell.fill", start: "150.2 lb", current: "149.1 lb", progress: 0.36)]
    var body: some View {
        ScreenContainer {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    Spacer().frame(height: 52)
                    ForEach(goals) { goal in GoalCard(goal: goal) }
                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 22).padding(.bottom, 28)
            }
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

#Preview { GoalsView() }
