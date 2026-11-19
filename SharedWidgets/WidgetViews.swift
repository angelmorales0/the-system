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
        case .nextQuest: "The first open quest, the day's timer ring, and the penalty warning."
        case .redSystems: "The Systems rows that are not blue today, with their last 7 days."
        case .systemsGrid: "Every Systems row with its last 7 days."
        }
    }

    var sizes: [WidgetSize] {
        switch self {
        case .nextQuest: [.small, .medium]
        case .redSystems: [.small, .medium, .large]
        case .systemsGrid: [.medium, .large]
        }
    }

    @ViewBuilder
    func view(_ data: WidgetData, size: WidgetSize, now: Date = .now) -> some View {
        switch self {
        case .nextQuest: NextQuestView(data: data, size: size, now: now)
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

/// The quest screen's timer ring: 28 dashes, one goes dark each 1/28 of the quest day.
/// It turns penalty red under 15% of the day left.
struct DayRing: View {
    let remaining: Double

    var body: some View {
        let lit = Int((remaining * Double(WidgetData.ringSegments)).rounded(.up))
        let urgent = remaining < WidgetData.urgentFraction
        let tint = urgent ? WidgetPalette.red : WidgetPalette.ink
        Canvas { context, size in
            let dash = max(size.height * 0.15, 5)
            let width = max(size.width * 0.055, 2.2)
            for index in 0..<WidgetData.ringSegments {
                var segment = context
                segment.translateBy(x: size.width / 2, y: size.height / 2)
                segment.rotate(by: .degrees(Double(index) * 360 / Double(WidgetData.ringSegments)))
                let rect = CGRect(x: -width / 2, y: -size.height / 2 + 1, width: width, height: dash)
                let path = Path(roundedRect: rect, cornerRadius: width * 0.35)
                // The dark part grows clockwise from 12 o'clock, as on the quest screen.
                let isLit = index >= WidgetData.ringSegments - lit
                segment.fill(path, with: .color(tint.opacity(isLit ? 0.9 : 0.06)))
                segment.stroke(path, with: .color(tint.opacity(isLit ? 1 : 0.35)), lineWidth: 0.5)
            }
        }
        .shadow(color: urgent ? WidgetPalette.red.opacity(0.8) : WidgetPalette.cyan.opacity(0.8), radius: 3)
    }
}

/// The quest screen's warning, with "penalty" in red.
private struct WarningLine: View {
    let text: String
    var fontSize: CGFloat = 9

    var body: some View {
        let parts = text.components(separatedBy: "penalty")
        var line = Text("WARNING: ").foregroundColor(WidgetPalette.ink.opacity(0.8))
        for (index, part) in parts.enumerated() {
            line = line + Text(part).foregroundColor(WidgetPalette.ink.opacity(0.8))
            if index < parts.count - 1 { line = line + Text("penalty").foregroundColor(WidgetPalette.red) }
        }
        return line
            .font(.system(size: fontSize))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The first open quest, the day's timer ring, and the warning.
/// Small: the ring beside the label. Medium: a large ring with the time left inside it.
struct NextQuestView: View {
    let data: WidgetData
    var size: WidgetSize = .small
    var now: Date = .now

    var body: some View {
        let remaining = data.ringRemaining(at: now)
        let warning = data.warning ?? WidgetData.defaultWarning
        if size == .medium {
            VStack(spacing: 8) {
                HStack(alignment: .center, spacing: 14) {
                    quest(titleSize: 22)
                    VStack(spacing: 4) {
                        DayRing(remaining: remaining)
                            .frame(width: 64, height: 64)
                        Group {
                            if let end = data.ringEnd { Text(end, style: .timer) } else { Text("") }
                        }
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                        .multilineTextAlignment(.center)
                        .foregroundStyle(remaining < WidgetData.urgentFraction ? WidgetPalette.red : WidgetPalette.ink)
                        .frame(width: 80)
                    }
                }
                WarningLine(text: warning, fontSize: 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .center) {
                    Caption(text: "Next quest")
                    Spacer(minLength: 2)
                    DayRing(remaining: remaining).frame(width: 34, height: 34)
                }
                quest(titleSize: 18, showsCaption: false)
                WarningLine(text: warning, fontSize: 8.5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func quest(titleSize: CGFloat, showsCaption: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if showsCaption { Caption(text: "Next quest") }
            if let row = data.questsLeft.first {
                Text(row.title)
                    .font(.system(size: titleSize, weight: .bold))
                    .foregroundStyle(WidgetPalette.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline) {
                    Text(row.progress)
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                        .foregroundStyle(WidgetPalette.cyan)
                    Spacer(minLength: 2)
                    if data.questsLeft.count > 1 {
                        Text("+\(data.questsLeft.count - 1) more")
                            .font(.system(size: 9))
                            .foregroundStyle(WidgetPalette.dim)
                    }
                }
                Bar(fraction: row.fraction, height: 4)
            } else {
                ClearMark(title: "DAILY QUEST\nCLEAR")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
