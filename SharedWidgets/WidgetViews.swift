import SwiftUI

/// The widget sizes the views lay out for. The extension maps WidgetKit's families to these, and the gallery draws each.
enum WidgetSize: String, CaseIterable {
    case small, medium, large
}

/// The widget designs, as plain SwiftUI. Each draws its content only: the extension adds the background
/// (`containerBackground`) and the gallery draws its own.
enum WidgetDesign: String, CaseIterable, Identifiable {
    case nextQuest, redSystems, systemsGrid

    var id: String { rawValue }

    var name: String {
        switch self {
        case .nextQuest: "Next Quest"
        case .redSystems: "Red Systems"
        case .systemsGrid: "Systems Week"
        }
    }

    var summary: String {
        switch self {
        case .nextQuest: "The first open quest, large, with its progress bar."
        case .redSystems: "The Systems rows that are not blue today, with their last 7 days."
        case .systemsGrid: "Every Systems row with its last 7 days."
        }
    }

    var sizes: [WidgetSize] {
        switch self {
        case .nextQuest: [.small]
        case .redSystems: [.small, .medium, .large]
        case .systemsGrid: [.medium, .large]
        }
    }

    @ViewBuilder
    func view(_ data: WidgetData, size: WidgetSize) -> some View {
        switch self {
        case .nextQuest: NextQuestView(data: data)
        case .redSystems: SystemsGridView(data: data, size: size, onlyRed: true)
        case .systemsGrid: SystemsGridView(data: data, size: size, onlyRed: false)
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

/// One Systems day: blue done, red failed, dim no mark. Today has an outline: red while it is not done yet.
private struct Day: View {
    let state: WidgetData.State?
    var side: CGFloat = 10
    var today = false
    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(state.map { $0 == .open ? WidgetPalette.ink.opacity(0.12) : WidgetPalette.color($0) } ?? WidgetPalette.ink.opacity(0.12))
            .frame(width: side, height: side)
            .shadow(color: state == .done ? WidgetPalette.cyan.opacity(0.7) : .clear, radius: 2)
            .overlay {
                if today {
                    RoundedRectangle(cornerRadius: 1.5)
                        .stroke(state == .open ? WidgetPalette.red : WidgetPalette.ink.opacity(0.8), lineWidth: state == .open ? 1.2 : 0.8)
                        .padding(-1.5)
                }
            }
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

// MARK: - Widgets

/// Every Systems row with its last 7 days, or (`onlyRed`) only the rows that are not blue today.
/// Small: the name over the 7 days, so the name has the full width.
struct SystemsGridView: View {
    let data: WidgetData
    let size: WidgetSize
    let onlyRed: Bool

    var body: some View {
        let source = onlyRed ? data.redSystems : data.systems
        let rows = Array(source.prefix(size == .large ? 10 : size == .medium ? 5 : 3))
        let red = data.redSystems.count
        VStack(alignment: .leading, spacing: size == .large ? 11 : size == .medium ? 5 : 6) {
            HStack {
                Caption(text: onlyRed ? (size == .small ? "Red systems" : "Red systems · 7 days") : "Systems · 7 days",
                        color: onlyRed && red > 0 ? WidgetPalette.red : WidgetPalette.cyan)
                Spacer(minLength: 4)
                Text(onlyRed ? "\(red) RED" : "\(data.systems.count - red)/\(data.systems.count) BLUE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(onlyRed ? (red > 0 ? WidgetPalette.red : WidgetPalette.cyan)
                                     : (red == 0 ? WidgetPalette.cyan : WidgetPalette.ink.opacity(0.7)))
                    .lineLimit(1)
            }
            if onlyRed && rows.isEmpty {
                ClearMark(title: "ALL SYSTEMS\nBLUE")
            } else {
                ForEach(rows, id: \.self) { system in
                    if size == .small {
                        VStack(alignment: .leading, spacing: 3) {
                            name(system)
                            HStack(spacing: 3) { days(system, side: 12) }
                        }
                    } else {
                        HStack(spacing: 8) {
                            name(system)
                            Spacer(minLength: 4)
                            HStack(spacing: 3) { days(system, side: size == .large ? 13 : 10) }
                            Text("\(system.streak)")
                                .font(.system(size: 10, weight: .bold).monospacedDigit())
                                .foregroundStyle(system.streak > 0 ? WidgetPalette.cyan : WidgetPalette.dim)
                                .frame(width: 16, alignment: .trailing)
                        }
                    }
                }
                if source.count > rows.count {
                    Text("+\(source.count - rows.count) more")
                        .font(.system(size: 10))
                        .foregroundStyle(WidgetPalette.dim)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func name(_ system: WidgetData.System) -> some View {
        Text(system.name)
            .font(.system(size: size == .large ? 13 : 11, weight: .medium))
            .foregroundStyle(system.today == .failed ? WidgetPalette.red : WidgetPalette.ink)
            .lineLimit(1)
    }

    @ViewBuilder
    private func days(_ system: WidgetData.System, side: CGFloat) -> some View {
        ForEach(Array(system.week.enumerated()), id: \.offset) { index, state in
            let isToday = index == system.week.count - 1
            Day(state: isToday ? system.today : state, side: side, today: isToday)
        }
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
