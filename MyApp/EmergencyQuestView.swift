import SwiftUI

/// Covers every page while an emergency quest runs. It uses the daily quest window, with a threat line
/// and the System's penalty warning. A real emergency has no close button; only a test can end early.
struct EmergencyQuestView: View {
    @EnvironmentObject private var store: GameStore
    @Environment(\.dynamicTypeSize) private var typeSize
    let quest: EmergencyQuest

    var body: some View {
        ZStack {
            QuestBackdrop()
            GeometryReader { proxy in
                ScrollView(showsIndicators: false) {
                    QuestHologram {
                        content
                            .padding(.horizontal, 34)
                            .padding(.top, 36)
                            .padding(.bottom, 30)
                            .frame(minHeight: typeSize.isAccessibilitySize ? 900 : max(560, min(proxy.size.height * 0.80, 660)))
                    }
                    .frame(maxWidth: 460)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .accessibilityAddTraits(.isModal)
    }

    private var content: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let remaining = max(0, quest.deadline.timeIntervalSince(timeline.date))
            VStack(spacing: 0) {
                QuestInfoHeader()
                Spacer(minLength: 28)
                headlineView
                Spacer(minLength: 35)
                VStack(spacing: 3) {
                    Text("GOAL")
                        .font(.system(.title2, design: .default).weight(.medium))
                        .tracking(1.3)
                        .foregroundStyle(QuestLight.ink)
                        .shadow(color: QuestLight.cyan, radius: 7)
                    Rectangle().fill(QuestLight.ink.opacity(0.85)).frame(width: 59, height: 1)
                    Rectangle().fill(QuestLight.ink.opacity(0.48)).frame(width: 59, height: 0.5)
                }
                .accessibilityAddTraits(.isHeader)

                Spacer(minLength: 20)
                Text(threat)
                    .font(.subheadline)
                    .lineSpacing(6)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(QuestLight.ink)
                    .shadow(color: QuestLight.blue.opacity(0.7), radius: 5)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 22)
                goalRow(remaining: remaining)
                    .font(.subheadline)
                    .foregroundStyle(QuestLight.ink)
                    .shadow(color: QuestLight.cyan.opacity(0.6), radius: 5)
                    .frame(minHeight: 44)
                HStack {
                    Text(quest.kind == .bedtimeLockdown ? "Lockdown ends in" : "Time left")
                    Spacer()
                    Text(Self.clock(remaining))
                        .monospacedDigit()
                        .foregroundStyle(remaining < 300 ? QuestLight.penalty : QuestLight.ink)
                }
                .font(.subheadline)
                .foregroundStyle(QuestLight.ink.opacity(0.85))
                .frame(minHeight: 36)
                .accessibilityElement(children: .combine)

                Spacer(minLength: 34)
                Text(warning)
                    .font(.system(.footnote, design: .default))
                    .lineSpacing(9)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(QuestLight.ink)
                    .shadow(color: QuestLight.blue.opacity(0.7), radius: 6)
                    .fixedSize(horizontal: false, vertical: true)

                if quest.isTest {
                    Button("END TEST") { store.endEmergencyTest() }
                        .font(.caption.weight(.semibold))
                        .tracking(1.2)
                        .foregroundStyle(QuestLight.cyan)
                        .padding(.top, 22)
                }
            }
        }
    }

    /// `[Emergency Quest: Lights Out.]`, with the quest name in bold italic, as the System writes it.
    private var headlineView: some View {
        Text("[Emergency Quest: \(Text(quest.title).bold().italic()).]")
            .font(.subheadline)
            .multilineTextAlignment(.center)
            .foregroundStyle(QuestLight.ink)
            .shadow(color: QuestLight.blue.opacity(0.7), radius: 5)
    }

    private var threat: String {
        switch quest.kind {
        case .bedtimeLockdown:
            return "It is past the Player's bedtime, and the Player is still awake. A body without rest grows weak. Put the phone down and sleep. Every app is locked until the lockdown ends."
        case .lowSteps:
            return "The Player has barely moved today. A body left still begins to waste away. Stand up and walk now, before the time runs out. Your distractor apps stay locked until the walk is done."
        }
    }

    @ViewBuilder
    private func goalRow(remaining: TimeInterval) -> some View {
        HStack(spacing: 11) {
            switch quest.kind {
            case .bedtimeLockdown:
                Text("Put the phone down")
                    .frame(maxWidth: .infinity, alignment: .leading)
                QuestCheckbox(checked: remaining == 0)
                    .frame(width: 16, height: 17)
            case .lowSteps:
                Text("Walk")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("[\(quest.progressSteps.formatted())/\(quest.targetSteps.formatted()) steps]")
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
                QuestCheckbox(checked: quest.progressSteps >= quest.targetSteps)
                    .frame(width: 16, height: 17)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The System's exact wording.
    private var warning: AttributedString {
        var text = AttributedString("WARNING: If you do not complete this quest, you will receive an appropriate penalty.")
        if let range = text.range(of: "penalty") {
            text[range].foregroundColor = QuestLight.penalty
        }
        return text
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
