import SwiftUI

/// The third page: this month's quests. Mercury, Codeforces, and Monkeytype decide every row.
struct MonthlyQuestView: View {
    @EnvironmentObject private var store: GameStore

    var body: some View {
        let board = store.monthlyBoard
        ZStack {
            QuestBackdrop()
            GeometryReader { proxy in
                ScrollView(showsIndicators: false) {
                    QuestHologram {
                        content(board)
                            .padding(.horizontal, 34)
                            .padding(.top, 36)
                            .padding(.bottom, 34)
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
    }

    private var warning: AttributedString {
        var text = AttributedString("WARNING: Failure to complete a monthly quest will result in a penalty.")
        if let range = text.range(of: "penalty", options: .caseInsensitive) {
            text[range].foregroundColor = QuestLight.penalty
        }
        return text
    }

    private func content(_ board: MonthlyBoard) -> some View {
        VStack(spacing: 0) {
            QuestInfoHeader()
            Text("[Monthly Quest: \(board.monthName)\nhas arrived.]")
                .font(.system(.subheadline, design: .default).weight(.regular))
                .lineSpacing(5)
                .multilineTextAlignment(.center)
                .foregroundStyle(QuestLight.ink)
                .shadow(color: QuestLight.blue.opacity(0.7), radius: 5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 28)
            QuestSectionTitle(text: "Goal")
                .padding(.top, 30)
                .padding(.bottom, 16)
            VStack(spacing: 14) {
                ForEach(board.rows) { MonthlyQuestRowView(row: $0) }
            }
            Text(warning)
                .font(.system(.footnote, design: .default))
                .lineSpacing(9)
                .multilineTextAlignment(.center)
                .foregroundStyle(QuestLight.ink)
                .shadow(color: QuestLight.blue.opacity(0.7), radius: 6)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 30)
        }
    }
}

private struct MonthlyQuestRowView: View {
    let row: MonthlyQuestRow

    private var ink: Color {
        switch row.status {
        case .failed: QuestLight.penalty
        case .active where (row.share ?? 0) >= 0.8 && row.id == MonthlyQuests.budgetId: QuestLight.caution
        default: QuestLight.ink
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 11) {
                Text(row.title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(row.progress)
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
                QuestCheckbox(checked: row.status == .cleared)
                    .frame(width: 16, height: 17)
            }
            .font(.subheadline)
            .foregroundStyle(ink)
            .shadow(color: (row.status == .failed ? QuestLight.penalty : QuestLight.cyan).opacity(0.6), radius: 5)
            if let share = row.share {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(QuestLight.ink.opacity(0.18))
                        Rectangle().fill(ink).frame(width: proxy.size.width * share)
                    }
                }
                .frame(height: 3)
            }
            ForEach(row.lines, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(QuestLight.ink.opacity(0.8))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(row.id)
    }
}
