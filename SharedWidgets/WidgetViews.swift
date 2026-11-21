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

/// The tactical label of the app: small monospaced capitals with wide spacing, in the muted blue.
private struct Mono: View {
    let text: String
    var color: Color = WidgetPalette.muted
    var size: CGFloat = 9
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: size, weight: .medium, design: .monospaced))
            .tracking(1.6)
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

/// A box with a "[ TITLE ]" label and thin cyan lines, like the app's quest list and SYSTEMS box.
private struct TacBox<Content: View>: View {
    let title: String
    var trailing: String? = nil
    var trailingColor: Color = WidgetPalette.muted
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Mono(text: "[ \(title) ]")
                Spacer(minLength: 4)
                if let trailing { Mono(text: trailing, color: trailingColor).monospacedDigit() }
            }
            .padding(.bottom, 4)
            content
        }
        .padding(.horizontal, 7)
        .padding(.top, 6)
        .padding(.bottom, 3)
        .overlay { Rectangle().stroke(WidgetPalette.cyan.opacity(0.25), lineWidth: 0.5) }
    }
}

/// A row in a box: a hairline on top, as in the app.
private struct Hairline: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(alignment: .top) { Rectangle().fill(WidgetPalette.cyan.opacity(0.18)).frame(height: 0.5) }
    }
}

/// A thin outlined bar with a glowing fill, like the HP bar in the app's header.
private struct Bar: View {
    let fraction: Double
    var color: Color = WidgetPalette.cyan
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().stroke(color.opacity(0.4), lineWidth: 0.5)
                Rectangle().fill(color)
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                    .shadow(color: color, radius: 3)
            }
        }
        .frame(height: 4)
    }
}

/// One Systems day, a square cell like the app's: cyan done, red failed, an outline only when there is no mark.
/// Today has a second outline: red while it is not done yet.
private struct Day: View {
    let state: WidgetData.State?
    var width: CGFloat? = nil
    var height: CGFloat = 7
    var today = false
    var body: some View {
        let filled = state == .done || state == .failed
        let fill = state == .failed ? WidgetPalette.red : WidgetPalette.cyan
        Rectangle()
            .fill(filled ? fill : WidgetPalette.ink.opacity(0.04))
            .overlay { Rectangle().stroke(filled ? fill : WidgetPalette.ink.opacity(0.22), lineWidth: 0.5) }
            .frame(maxWidth: width ?? .infinity)
            .frame(width: width, height: height)
            .shadow(color: filled ? fill.opacity(0.8) : .clear, radius: 2)
            .overlay {
                if today {
                    Rectangle()
                        .stroke(state == .open ? WidgetPalette.red : WidgetPalette.ink.opacity(0.7), lineWidth: 0.8)
                        .padding(-2)
                }
            }
    }
}

/// "> ALL SYSTEMS BLUE", in the app's log style, for a list with nothing left.
private struct ClearLine: View {
    let lines: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(lines, id: \.self) { Mono(text: "> \($0)", color: WidgetPalette.cyan, size: 10) }
        }
        .shadow(color: WidgetPalette.cyan.opacity(0.7), radius: 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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
        let rows = Array(source.prefix(size == .large ? 10 : size == .medium ? 4 : 3))
        let red = data.redSystems.count
        let blue = data.systems.count - red
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Mono(text: size == .small ? "SYS // HABITS" : "SYSTEM // HABITS")
                Spacer(minLength: 4)
                Mono(text: onlyRed ? "\(red) RED" : "\(blue) / \(data.systems.count)",
                     color: red > 0 && onlyRed ? WidgetPalette.red : WidgetPalette.cyan)
            }
            if onlyRed && rows.isEmpty {
                ClearLine(lines: ["ALL SYSTEMS BLUE", "0 RED TODAY"])
            } else {
                TacBox(title: onlyRed ? "RED" : "SYSTEMS", trailing: size == .small ? nil : "7 DAYS") {
                    ForEach(Array(rows.enumerated()), id: \.element) { _, system in
                        row(system).modifier(Hairline())
                    }
                    if source.count > rows.count {
                        Mono(text: "+\(source.count - rows.count) more", color: WidgetPalette.dim)
                            .padding(.vertical, 3)
                            .modifier(Hairline())
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func row(_ system: WidgetData.System) -> some View {
        if size == .small {
            VStack(alignment: .leading, spacing: 4) {
                name(system)
                HStack(spacing: 3) { days(system, width: nil, height: 7) }
            }
            .padding(.vertical, 4)
        } else {
            HStack(spacing: 8) {
                name(system)
                Spacer(minLength: 4)
                HStack(spacing: 3) { days(system, width: size == .large ? 14 : 11, height: size == .large ? 8 : 7) }
                Text("\(system.streak)D")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(system.streak > 0 ? WidgetPalette.cyan : WidgetPalette.dim)
                    .frame(width: 24, alignment: .trailing)
            }
            .padding(.vertical, size == .large ? 7 : 4)
        }
    }

    private func name(_ system: WidgetData.System) -> some View {
        Text(system.name)
            .font(.system(size: size == .large ? 13 : 11))
            .foregroundStyle(system.today == .failed ? WidgetPalette.red : WidgetPalette.ink)
            .lineLimit(1)
    }

    @ViewBuilder
    private func days(_ system: WidgetData.System, width: CGFloat?, height: CGFloat) -> some View {
        ForEach(Array(system.week.enumerated()), id: \.offset) { index, state in
            let isToday = index == system.week.count - 1
            Day(state: isToday ? system.today : state, width: width, height: height, today: isToday)
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

/// The first open quest, the day's timer ring, and the penalty line, in the app's tactical layout:
/// a "SYSTEM // QUEST" label, the quest in a "[ DAILY QUEST ]" box, and "> " status lines under it.
struct NextQuestView: View {
    let data: WidgetData
    var size: WidgetSize = .small
    var now: Date = .now

    var body: some View {
        let remaining = data.ringRemaining(at: now)
        if size == .medium {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Mono(text: "SYSTEM // QUEST DAY")
                    questBox(titleSize: 18, boxTitle: "DAILY QUEST")
                    log(lines: 2)
                }
                VStack(spacing: 6) {
                    DayRing(remaining: remaining).frame(width: 66, height: 66)
                    countdown(size: 13, remaining: remaining)
                }
                .frame(width: 82)
                .frame(maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Mono(text: "SYS // QUEST")
                        countdown(size: 14, remaining: remaining)
                    }
                    Spacer(minLength: 2)
                    DayRing(remaining: remaining).frame(width: 30, height: 30)
                }
                questBox(titleSize: 15, boxTitle: "QUEST")
                log(lines: 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Hours, minutes, and seconds to the deadline, counting down on its own. It stops at 0:00.
    @ViewBuilder
    private func countdown(size: CGFloat, remaining: Double) -> some View {
        if let end = data.ringEnd {
            Text(timerInterval: min(now, end)...end, countsDown: true)
                .font(.system(size: size, weight: .semibold, design: .monospaced).monospacedDigit())
                .foregroundStyle(remaining < WidgetData.urgentFraction ? WidgetPalette.red : WidgetPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    @ViewBuilder
    private func questBox(titleSize: CGFloat, boxTitle: String) -> some View {
        if let row = data.questsLeft.first {
            TacBox(title: boxTitle, trailing: "\(data.requiredDone) / \(data.requiredCount)") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(row.title)
                            .font(.system(size: titleSize, weight: .medium))
                            .foregroundStyle(WidgetPalette.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Spacer(minLength: 2)
                    }
                    Text(row.progress)
                        .font(.system(size: 11, weight: .medium, design: .monospaced).monospacedDigit())
                        .foregroundStyle(WidgetPalette.cyan)
                        .lineLimit(1)
                    Bar(fraction: row.fraction)
                        .padding(.bottom, 3)
                }
                .padding(.top, 4)
                .modifier(Hairline())
            }
        } else {
            ClearLine(lines: ["DAILY QUEST CLEAR", "\(data.requiredDone) / \(data.requiredCount) DONE"])
        }
    }

    /// The app's status log: the quests that remain, then the penalty line with "PENALTY" in red.
    private func log(lines: Int) -> some View {
        let left = data.questsLeft.count
        return VStack(alignment: .leading, spacing: 3) {
            if lines > 1, left > 0 {
                Mono(text: "> \(left) quest\(left == 1 ? "" : "s") remain")
            }
            if left > 0 {
                (Text("> FAIL = ").foregroundColor(WidgetPalette.muted) + Text("PENALTY").foregroundColor(WidgetPalette.red))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(1.6)
                    .lineLimit(1)
            }
        }
    }
}
