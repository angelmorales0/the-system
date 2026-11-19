import SwiftUI

/// The widget sizes the views lay out for. The extension maps WidgetKit's families to these, and the gallery draws each.
enum WidgetSize: String, CaseIterable {
    case small, medium, large, circular, rectangular, inline
}

/// The widget designs, as plain SwiftUI. Each draws its content only: the extension adds the background
/// (`containerBackground`) and the gallery draws its own.
enum WidgetDesign: String, CaseIterable, Identifiable {
    case questsLeft, questList, redSystems, systemsGrid, dailyBoard, countdown, status, nextQuest, penalty
    case lockProgress, lockSummary, lockInline

    var id: String { rawValue }

    var name: String {
        switch self {
        case .questsLeft: "Quests Left"
        case .questList: "Quest List"
        case .redSystems: "Red Systems"
        case .systemsGrid: "Systems Week"
        case .dailyBoard: "Daily Board"
        case .countdown: "Countdown"
        case .status: "Status"
        case .nextQuest: "Next Quest"
        case .penalty: "Penalty Watch"
        case .lockProgress: "Lock: Quest Ring"
        case .lockSummary: "Lock: Today"
        case .lockInline: "Lock: One Line"
        }
    }

    var summary: String {
        switch self {
        case .questsLeft: "How many required quests are left, and their names."
        case .questList: "Today's quest screen: every row, its progress, and its box."
        case .redSystems: "Only the Systems rows that are not blue today."
        case .systemsGrid: "Every Systems row with its last 7 days."
        case .dailyBoard: "Quests left, red Systems, level, and time left, on one board."
        case .countdown: "Time left in the quest day, and what is still open."
        case .status: "Level, HP, level progress, and gold."
        case .nextQuest: "The first open quest, large, with its progress bar."
        case .penalty: "The open penalty, or how far you are from one."
        case .lockProgress: "A ring of required quests done."
        case .lockSummary: "Quests left and red Systems, on the lock screen."
        case .lockInline: "One line above the clock."
        }
    }

    var sizes: [WidgetSize] {
        switch self {
        case .questsLeft, .countdown, .status, .nextQuest, .penalty: [.small]
        case .questList: [.medium, .large]
        case .redSystems: [.small, .medium]
        case .systemsGrid: [.medium, .large]
        case .dailyBoard: [.large]
        case .lockProgress: [.circular]
        case .lockSummary: [.rectangular]
        case .lockInline: [.inline]
        }
    }

    @ViewBuilder
    func view(_ data: WidgetData, size: WidgetSize) -> some View {
        switch self {
        case .questsLeft: QuestsLeftView(data: data)
        case .questList: QuestListView(data: data, size: size)
        case .redSystems: RedSystemsView(data: data, size: size)
        case .systemsGrid: SystemsGridView(data: data, size: size)
        case .dailyBoard: DailyBoardView(data: data)
        case .countdown: CountdownView(data: data)
        case .status: StatusWidgetView(data: data)
        case .nextQuest: NextQuestView(data: data)
        case .penalty: PenaltyWatchView(data: data)
        case .lockProgress: LockProgressView(data: data)
        case .lockSummary: LockSummaryView(data: data)
        case .lockInline: LockInlineView(data: data)
        }
    }
}

// MARK: - Parts

private struct Caption: View {
    let text: String
    var color: Color = WidgetPalette.cyan
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(1.6)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// The quest screen's box: a check when done, an x when failed.
private struct Box: View {
    let state: WidgetData.State
    var side: CGFloat = 12
    var body: some View {
        ZStack {
            Rectangle().stroke(WidgetPalette.color(state).opacity(state == .open ? 0.6 : 1), lineWidth: 1)
            switch state {
            case .done: Image(systemName: "checkmark").font(.system(size: side * 0.7, weight: .heavy)).foregroundStyle(WidgetPalette.cyan)
            case .failed: Image(systemName: "xmark").font(.system(size: side * 0.6, weight: .heavy)).foregroundStyle(WidgetPalette.red)
            case .open: EmptyView()
            }
        }
        .frame(width: side, height: side)
    }
}

private struct Bar: View {
    let fraction: Double
    var color: Color = WidgetPalette.cyan
    var height: CGFloat = 4
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(WidgetPalette.ink.opacity(0.12))
                Rectangle().fill(color)
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                    .shadow(color: color.opacity(0.8), radius: 3)
            }
        }
        .frame(height: height)
    }
}

/// One Systems day: blue done, red failed, dim no mark.
private struct Day: View {
    let state: WidgetData.State?
    var side: CGFloat = 10
    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(state.map { $0 == .open ? WidgetPalette.ink.opacity(0.12) : WidgetPalette.color($0) } ?? WidgetPalette.ink.opacity(0.12))
            .frame(width: side, height: side)
            .shadow(color: state == .done ? WidgetPalette.cyan.opacity(0.7) : .clear, radius: 2)
    }
}

private struct ClearMark: View {
    let title: String
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(WidgetPalette.cyan)
                .shadow(color: WidgetPalette.cyan.opacity(0.8), radius: 6)
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .tracking(1.2)
                .multilineTextAlignment(.center)
                .foregroundStyle(WidgetPalette.ink)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private func systemWord(_ state: WidgetData.State) -> String {
    switch state {
    case .done: "PASS"
    case .open: "OPEN"
    case .failed: "FAILED"
    }
}

// MARK: - Home screen

/// Small: the count of required quests left, and the first three.
struct QuestsLeftView: View {
    let data: WidgetData
    var body: some View {
        let left = data.questsLeft
        VStack(alignment: .leading, spacing: 6) {
            Caption(text: "Daily Quest")
            if left.isEmpty {
                ClearMark(title: "DAILY QUEST\nCLEAR")
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(left.count)")
                        .font(.system(size: 44, weight: .heavy, design: .rounded))
                        .foregroundStyle(WidgetPalette.ink)
                        .shadow(color: WidgetPalette.cyan.opacity(0.6), radius: 6)
                    Text("LEFT")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(WidgetPalette.dim)
                }
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(left.prefix(3), id: \.self) { row in
                        HStack(spacing: 5) {
                            Box(state: row.state, side: 8)
                            Text(row.title).lineLimit(1)
                        }
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(WidgetPalette.ink)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Medium and large: the quest screen's rows.
struct QuestListView: View {
    let data: WidgetData
    let size: WidgetSize
    var body: some View {
        let rows = Array(data.quests.prefix(size == .large ? 9 : 4))
        VStack(alignment: .leading, spacing: size == .large ? 10 : 6) {
            HStack {
                Caption(text: "[Daily Quest: \(data.header)]")
                Spacer()
                Text("\(data.requiredDone)/\(data.requiredCount)")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(data.requiredDone == data.requiredCount ? WidgetPalette.cyan : WidgetPalette.ink)
            }
            if size == .large { Bar(fraction: data.requiredCount == 0 ? 0 : Double(data.requiredDone) / Double(data.requiredCount)) }
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 8) {
                    Text(row.title)
                        .lineLimit(1)
                        .foregroundStyle(row.state == .done ? WidgetPalette.dim : WidgetPalette.ink)
                        .strikethrough(row.state == .done, color: WidgetPalette.dim)
                    Spacer(minLength: 4)
                    Text(row.progress)
                        .font(.system(size: size == .large ? 13 : 12).monospacedDigit())
                        .foregroundStyle(row.state == .failed ? WidgetPalette.red : WidgetPalette.ink.opacity(0.75))
                    Box(state: row.state)
                }
                .font(.system(size: size == .large ? 15 : 13))
            }
            if data.quests.count > rows.count {
                Text("+\(data.quests.count - rows.count) more")
                    .font(.system(size: 10))
                    .foregroundStyle(WidgetPalette.dim)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Small and medium: only the Systems rows that are not blue today.
struct RedSystemsView: View {
    let data: WidgetData
    let size: WidgetSize
    var body: some View {
        let red = data.redSystems
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Caption(text: "Systems", color: red.isEmpty ? WidgetPalette.cyan : WidgetPalette.red)
                Spacer()
                if !red.isEmpty {
                    Text("\(red.count) RED")
                        .font(.system(size: 10, weight: .heavy))
                        .tracking(1)
                        .foregroundStyle(WidgetPalette.red)
                }
            }
            if red.isEmpty {
                ClearMark(title: "ALL SYSTEMS\nBLUE")
            } else {
                ForEach(red.prefix(size == .medium ? 5 : 4), id: \.self) { system in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(system.today == .failed ? WidgetPalette.red : Color.clear)
                            .overlay { Circle().stroke(system.today == .failed ? WidgetPalette.red : WidgetPalette.ink.opacity(0.7), lineWidth: 1) }
                            .frame(width: 7, height: 7)
                        Text(system.name)
                            .lineLimit(1)
                            .foregroundStyle(WidgetPalette.ink)
                        Spacer(minLength: 2)
                        if size == .medium {
                            Text(system.today == .failed ? "FAILED" : "NOT DONE")
                                .font(.system(size: 9, weight: .bold))
                                .tracking(0.8)
                                .foregroundStyle(system.today == .failed ? WidgetPalette.red : WidgetPalette.dim)
                        }
                    }
                    .font(.system(size: size == .medium ? 13 : 12, weight: .medium))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Medium and large: every Systems row with its last 7 days.
struct SystemsGridView: View {
    let data: WidgetData
    let size: WidgetSize
    var body: some View {
        let rows = Array(data.systems.prefix(size == .large ? 10 : 5))
        VStack(alignment: .leading, spacing: size == .large ? 11 : 5) {
            HStack {
                Caption(text: "Systems · 7 days")
                Spacer()
                Text("\(data.systems.count - data.redSystems.count)/\(data.systems.count) BLUE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(data.redSystems.isEmpty ? WidgetPalette.cyan : WidgetPalette.ink.opacity(0.7))
            }
            ForEach(rows, id: \.self) { system in
                HStack(spacing: 8) {
                    Text(system.name)
                        .font(.system(size: size == .large ? 13 : 11, weight: .medium))
                        .foregroundStyle(system.today == .failed ? WidgetPalette.red : WidgetPalette.ink)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    HStack(spacing: 3) {
                        ForEach(Array(system.week.enumerated()), id: \.offset) { index, state in
                            Day(state: index == system.week.count - 1 ? system.today : state, side: size == .large ? 13 : 10)
                                .overlay {
                                    if index == system.week.count - 1 {
                                        RoundedRectangle(cornerRadius: 1.5).stroke(WidgetPalette.ink.opacity(0.8), lineWidth: 0.8).padding(-1.5)
                                    }
                                }
                        }
                    }
                    Text("\(system.streak)")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(system.streak > 0 ? WidgetPalette.cyan : WidgetPalette.dim)
                        .frame(width: 16, alignment: .trailing)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Large: level and time left on top, then the quests left, then the red Systems.
struct DailyBoardView: View {
    let data: WidgetData
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("LV. \(data.level)")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(WidgetPalette.ink)
                Spacer()
                Text(data.dayEnds, style: .timer)
                    .font(.system(size: 18, weight: .semibold).monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(WidgetPalette.cyan)
            }
            Bar(fraction: data.levelProgress)
            Caption(text: data.questsLeft.isEmpty ? "Daily quest clear" : "Quests left · \(data.questsLeft.count)")
                .padding(.top, 4)
            ForEach(data.questsLeft.prefix(4), id: \.self) { row in
                HStack {
                    Box(state: row.state, side: 10)
                    Text(row.title).lineLimit(1)
                    Spacer()
                    Text(row.progress).font(.system(size: 12).monospacedDigit()).foregroundStyle(WidgetPalette.ink.opacity(0.7))
                }
                .font(.system(size: 14))
                .foregroundStyle(WidgetPalette.ink)
            }
            Caption(text: data.redSystems.isEmpty ? "All systems blue" : "Red systems · \(data.redSystems.count)",
                    color: data.redSystems.isEmpty ? WidgetPalette.cyan : WidgetPalette.red)
                .padding(.top, 4)
            ForEach(data.redSystems.prefix(4), id: \.self) { system in
                HStack {
                    Circle().fill(system.today == .failed ? WidgetPalette.red : WidgetPalette.ink.opacity(0.25)).frame(width: 8, height: 8)
                    Text(system.name).lineLimit(1)
                    Spacer()
                    Text(systemWord(system.today))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(system.today == .failed ? WidgetPalette.red : WidgetPalette.dim)
                }
                .font(.system(size: 14))
                .foregroundStyle(WidgetPalette.ink)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Small: time left in the quest day, and what is still open.
struct CountdownView: View {
    let data: WidgetData
    var body: some View {
        let urgent = !data.questsLeft.isEmpty
        VStack(alignment: .leading, spacing: 4) {
            Caption(text: "Day ends in", color: urgent ? WidgetPalette.red : WidgetPalette.cyan)
            Text(data.dayEnds, style: .timer)
                .font(.system(size: 30, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(WidgetPalette.ink)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Text("\(data.questsLeft.count)").font(.system(size: 18, weight: .bold)).foregroundStyle(urgent ? WidgetPalette.ink : WidgetPalette.cyan)
                Text("QUESTS").font(.system(size: 10, weight: .bold)).foregroundStyle(WidgetPalette.dim)
            }
            HStack(spacing: 4) {
                Text("\(data.redSystems.count)").font(.system(size: 18, weight: .bold)).foregroundStyle(data.redSystems.isEmpty ? WidgetPalette.cyan : WidgetPalette.red)
                Text("RED SYSTEMS").font(.system(size: 10, weight: .bold)).foregroundStyle(WidgetPalette.dim)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Small: level, HP, the bar to the next level, and gold.
struct StatusWidgetView: View {
    let data: WidgetData
    var body: some View {
        let hp = data.maxHP == 0 ? 0 : Double(data.hp) / Double(data.maxHP)
        VStack(alignment: .leading, spacing: 6) {
            Caption(text: "Status")
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("LV.").font(.system(size: 12, weight: .bold)).foregroundStyle(WidgetPalette.dim)
                Text("\(data.level)")
                    .font(.system(size: 38, weight: .heavy, design: .rounded))
                    .foregroundStyle(WidgetPalette.ink)
                    .shadow(color: WidgetPalette.cyan.opacity(0.6), radius: 6)
            }
            Bar(fraction: data.levelProgress)
            Spacer(minLength: 0)
            HStack {
                Text("HP").font(.system(size: 10, weight: .bold)).foregroundStyle(WidgetPalette.dim)
                Spacer()
                Text("\(data.hp)/\(data.maxHP)").font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(WidgetPalette.ink)
            }
            Bar(fraction: hp, color: hp < 0.3 ? WidgetPalette.red : Color(red: 0.25, green: 0.9, blue: 0.5))
            HStack(spacing: 4) {
                Image(systemName: "circle.hexagongrid.fill").font(.system(size: 10)).foregroundStyle(WidgetPalette.gold)
                Text("\(data.gold) G").font(.system(size: 12, weight: .bold).monospacedDigit()).foregroundStyle(WidgetPalette.gold)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Small: the first open quest, large.
struct NextQuestView: View {
    let data: WidgetData
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Caption(text: "Next quest")
            if let row = data.questsLeft.first {
                Text(row.title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(WidgetPalette.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Text(row.progress)
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(WidgetPalette.cyan)
                Bar(fraction: row.fraction, height: 5)
                if data.questsLeft.count > 1 {
                    Text("then \(data.questsLeft.count - 1) more")
                        .font(.system(size: 10))
                        .foregroundStyle(WidgetPalette.dim)
                }
            } else {
                ClearMark(title: "DAILY QUEST\nCLEAR")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Small: the open penalty, or the quests between you and one.
struct PenaltyWatchView: View {
    let data: WidgetData
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let penalty = data.penalty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(WidgetPalette.red)
                    .shadow(color: WidgetPalette.red.opacity(0.8), radius: 8)
                Text("PENALTY\nACTIVE")
                    .font(.system(size: 18, weight: .heavy))
                    .tracking(1)
                    .foregroundStyle(WidgetPalette.red)
                Spacer(minLength: 0)
                Text(penalty)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(WidgetPalette.ink)
                    .lineLimit(2)
            } else {
                let risk = data.penaltyRisk
                Image(systemName: risk == 0 ? "shield.checkered" : "shield.lefthalf.filled")
                    .font(.system(size: 26))
                    .foregroundStyle(risk == 0 ? WidgetPalette.cyan : WidgetPalette.gold)
                Text(risk == 0 ? "NO PENALTY" : "PENALTY AT\nMIDNIGHT")
                    .font(.system(size: 15, weight: .heavy))
                    .tracking(1)
                    .foregroundStyle(risk == 0 ? WidgetPalette.cyan : WidgetPalette.gold)
                Spacer(minLength: 0)
                Text(risk == 0 ? "Everything is done." : "\(risk) thing\(risk == 1 ? "" : "s") still open.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(WidgetPalette.ink)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Lock screen

/// Circular: a ring of required quests done.
struct LockProgressView: View {
    let data: WidgetData
    var body: some View {
        let fraction = data.requiredCount == 0 ? 0 : Double(data.requiredDone) / Double(data.requiredCount)
        ZStack {
            Circle().stroke(Color.white.opacity(0.25), lineWidth: 5)
            Circle().trim(from: 0, to: fraction)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: -1) {
                Text("\(data.requiredDone)/\(data.requiredCount)").font(.system(size: 15, weight: .bold).monospacedDigit())
                Text("QUEST").font(.system(size: 7, weight: .bold))
            }
        }
        .padding(3)
        .foregroundStyle(.white)
    }
}

/// Rectangular: quests left and red Systems.
struct LockSummaryView: View {
    let data: WidgetData
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(data.questsLeft.isEmpty ? "QUEST CLEAR" : "\(data.questsLeft.count) QUESTS LEFT")
                .font(.system(size: 14, weight: .heavy))
            Text(data.questsLeft.prefix(2).map(\.title).joined(separator: " · "))
                .font(.system(size: 12))
                .lineLimit(1)
            Text(data.redSystems.isEmpty ? "All systems blue" : "\(data.redSystems.count) red: " + data.redSystems.prefix(2).map(\.name).joined(separator: ", "))
                .font(.system(size: 12))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.white)
    }
}

/// Inline: one line above the clock.
struct LockInlineView: View {
    let data: WidgetData
    var body: some View {
        Text(data.penalty != nil ? "⚠ Penalty active" : "\(data.questsLeft.count) quests · \(data.redSystems.count) red systems")
            .foregroundStyle(.white)
    }
}
