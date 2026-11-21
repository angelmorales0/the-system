import SwiftUI

// The tactical layout of the quest window: typed labels, a boxed quest list, and a status log.

/// Each text types one time per launch. A redraw, a new row, or a second visit to the screen shows it at once.
enum TacticalIntro {
    static var typed: Set<String> = []
    /// The row groups that already faded in this launch: the quest list and the SYSTEMS rows.
    static var shownGroups: Set<String> = []
    static let mono = Font.system(.caption2, design: .monospaced)
}

/// Types its text letter by letter. The letters not typed yet stay in the layout as clear text,
/// so the lines do not move while the text types.
struct TypewriterText: View {
    let text: AttributedString
    var delay: Double = 0
    var speed: Double = 0.025
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Int?

    init(_ text: AttributedString, delay: Double = 0, speed: Double = 0.025) {
        self.text = text
        self.delay = delay
        self.speed = speed
        _shown = State(initialValue: TacticalIntro.typed.contains(String(text.characters)) ? nil : 0)
    }

    init(_ string: String, delay: Double = 0, speed: Double = 0.025) {
        self.init(AttributedString(string), delay: delay, speed: speed)
    }

    private var key: String { String(text.characters) }

    var body: some View {
        Text(masked)
            .accessibilityLabel(Text(text))
            .task(id: key) {
                guard !reduceMotion, !TacticalIntro.typed.contains(key) else {
                    shown = nil
                    return
                }
                shown = 0
                try? await Task.sleep(for: .seconds(delay))
                let count = text.characters.count
                for index in 0...count {
                    if Task.isCancelled { return }
                    shown = index
                    try? await Task.sleep(for: .seconds(speed))
                }
                TacticalIntro.typed.insert(key)
                shown = nil
            }
    }

    private var masked: AttributedString {
        guard let shown, shown < text.characters.count else { return text }
        var copy = text
        let start = copy.index(copy.startIndex, offsetByCharacters: shown)
        copy[start..<copy.endIndex].foregroundColor = .clear
        return copy
    }
}

/// The top line: "SYSTEM // PLAYER", the level, and an HP bar, then the quest day. The level and HP open the levels.
struct TacticalHeader: View {
    @EnvironmentObject private var store: GameStore
    var onLevels: () -> Void = {}

    var body: some View {
        let hp = store.hitPoints
        let fraction = hp.max > 0 ? min(max(Double(hp.current) / Double(hp.max), 0), 1) : 0
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                TypewriterText("SYSTEM // PLAYER")
                    .foregroundStyle(SystemTheme.muted)
                Spacer(minLength: 8)
                // The level and HP open the levels window.
                Button(action: onLevels) {
                    HStack(spacing: 8) {
                        TypewriterText("LV \(store.statLevels.overallLevel)", delay: 0.3)
                            .foregroundStyle(QuestLight.ink)
                        ZStack(alignment: .leading) {
                            Rectangle().stroke(QuestLight.cyan.opacity(0.5), lineWidth: 0.5)
                            Rectangle().fill(fraction < 0.25 ? QuestLight.penalty : QuestLight.cyan)
                                .frame(width: 54 * fraction)
                                .shadow(color: QuestLight.cyan, radius: 3)
                        }
                        .frame(width: 54, height: 5)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, -14)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Level \(store.statLevels.overallLevel), HP \(hp.current) of \(hp.max)")
                .accessibilityHint("Opens the levels")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("levelsButton")
            }
            Rectangle().fill(QuestLight.cyan.opacity(0.25)).frame(height: 0.5)
                .padding(.top, 10)
                .padding(.bottom, 14)
            TypewriterText("QUEST DAY \(store.bundle.dayKey)", delay: 0.5)
                .foregroundStyle(SystemTheme.muted)
        }
        .font(TacticalIntro.mono)
        .tracking(2)
    }
}

/// The quest list in a thin box under "[ DAILY QUEST ]" and the count of finished quests.
struct TacticalQuestBox<Content: View>: View {
    var title = "[ DAILY QUEST ]"
    let done: Int
    let total: Int
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TypewriterText(title, delay: 0.8)
                Spacer()
                Text("\(done) / \(total)")
                    .monospacedDigit()
            }
            .font(TacticalIntro.mono)
            .tracking(2)
            .foregroundStyle(SystemTheme.muted)
            .padding(.bottom, 6)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 2)
        .overlay { Rectangle().stroke(QuestLight.cyan.opacity(0.25), lineWidth: 0.5) }
    }
}

/// A quest row in the tactical box: a hairline on top, and a fade-in one row after another at launch.
struct TacticalRowReveal: ViewModifier {
    let index: Int
    var group = "quests"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible: Bool

    init(index: Int, group: String = "quests") {
        self.index = index
        self.group = group
        _visible = State(initialValue: TacticalIntro.shownGroups.contains(group))
    }

    func body(content: Content) -> some View {
            content
                .overlay(alignment: .top) {
                    Rectangle().fill(QuestLight.cyan.opacity(0.18)).frame(height: 0.5)
                }
                .opacity(visible ? 1 : 0)
                .task {
                    guard !visible else { return }
                    if reduceMotion {
                        visible = true
                        return
                    }
                    try? await Task.sleep(for: .seconds(1.0 + Double(index) * 0.12))
                    withAnimation(.easeOut(duration: 0.3)) { visible = true }
                    TacticalIntro.shownGroups.insert(group)
                }
    }
}

/// The status log under the timer. Each line types after the one before it.
struct TacticalLog: View {
    let lines: [String]
    var delay = 2.6

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                TypewriterText(line, delay: delay + Double(index) * 0.9, speed: 0.03)
            }
        }
        .font(TacticalIntro.mono)
        .tracking(2)
        .foregroundStyle(SystemTheme.muted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A small square with an up-and-down swap arrow, after the run title: the 10K Run becomes 300 burpees, or the burpees the run.
/// It shows only while nothing is logged on the row, so a tap can always be undone with a second tap.
struct RunSwapButton: View {
    @EnvironmentObject private var store: GameStore
    let quest: Quest

    private var toBurpees: Bool { RunBurpees.canSwap(quest) }

    var body: some View {
        Button {
            SystemSound.systemOpen.play()
            store.setRunAsBurpees(id: quest.id, toBurpees)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(QuestLight.cyan)
                .shadow(color: QuestLight.cyan.opacity(0.8), radius: 3)
                .frame(width: 22, height: 22)
                .overlay { Rectangle().stroke(QuestLight.cyan.opacity(0.5), lineWidth: 0.5) }
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -8)
        .accessibilityLabel(toBurpees ? "Swap to \(RunBurpees.reps) burpees" : "Swap back to the 10K run")
        .accessibilityIdentifier("runSwapButton")
    }
}
