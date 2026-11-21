import SwiftUI

/// The second page: the SYSTEMS window, the habit rows of the last 28 days in the tactical style.
/// The levels open from the LV and HP area on the quest window, in `LevelsWindow`.
struct StatusSheetView: View {
    @EnvironmentObject private var store: GameStore

    private var tracks: [SystemsView.Track] { store.systemsTracks }
    /// Rows that pass 90% or more of their judged days in view.
    private var active: Int { tracks.filter(\.isActive).count }
    /// Rows whose last day is a pass.
    private var passedToday: Int { tracks.filter { $0.marks.last == .done }.count }

    /// The log under the box: the habits at a 90% or higher pass rate.
    private var logLines: [String] { ["> \(active) ACTIVE"] }

    /// The quest day the box counts passes for: "NOV 21".
    private var dayNote: String {
        guard let date = QuestDay.date(from: store.bundle.dayKey) else { return store.bundle.dayKey }
        let formatter = DateFormatter()
        formatter.calendar = QuestDay.calendar
        formatter.timeZone = QuestDay.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date).uppercased()
    }

    var body: some View {
        ZStack {
            QuestBackdrop()
            GeometryReader { proxy in
                ScrollView(showsIndicators: false) {
                    SystemPanel(padding: 14) {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 8) {
                                TypewriterText("SYSTEM // HABITS")
                                Spacer(minLength: 8)
                                TypewriterText("\(active) ACTIVE", delay: 0.3)
                                    .foregroundStyle(QuestLight.ink)
                            }
                            .foregroundStyle(SystemTheme.muted)
                            .font(TacticalIntro.mono)
                            .tracking(2)
                            Rectangle().fill(QuestLight.cyan.opacity(0.25)).frame(height: 0.5)
                                .padding(.top, 10)
                                .padding(.bottom, 14)
                            TypewriterText("LAST 28 DAYS", delay: 0.5)
                                .foregroundStyle(SystemTheme.muted)
                                .font(TacticalIntro.mono)
                                .tracking(2)
                            TacticalQuestBox(title: "[ SYSTEMS ]", done: passedToday, total: tracks.count, note: dayNote) {
                                SystemsPanel(tracks: tracks) { store.setHandMark($0, $1, passed: $2) }
                            }
                            .padding(.top, 14)
                            TacticalLog(lines: logLines, delay: 2.0)
                                .padding(.top, 14)
                        }
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
}

/// The System's STATUS levels in the tactical style: the overall level and XP, HP and fatigue, the seven stats,
/// and the links to contracts and beliefs. Overall XP is the seven stat levels added up (0...2450); the level is
/// that share of 146. HP turns red when critical; fatigue turns red at 80 or more.
/// Tapping a stat opens its targets, and the gear opens the settings. The close button calls `onClose`.
struct LevelsWindow: View {
    @EnvironmentObject private var store: GameStore
    let onClose: () -> Void
    @State private var selectedStat: Stat?
    @State private var showSettings = false
    @State private var showBeliefs = false
    @State private var showContracts = false

    var body: some View {
        GeometryReader { proxy in
            ScrollView(showsIndicators: false) {
                SystemPanel(padding: 14) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 10) {
                            TypewriterText("SYSTEM // STATUS")
                                .font(TacticalIntro.mono)
                                .tracking(2)
                                .foregroundStyle(SystemTheme.muted)
                                .accessibilityAddTraits(.isHeader)
                            Spacer()
                            squareButton("gearshape", label: "Settings", id: "levelsSettingsButton") {
                                showSettings = true
                                SystemSound.systemOpen.play()
                            }
                            squareButton("xmark", label: "Close levels", id: "closeLevelsButton", action: onClose)
                        }
                        Rectangle().fill(QuestLight.cyan.opacity(0.25)).frame(height: 0.5)
                            .padding(.top, 10)
                            .padding(.bottom, 16)
                        StatusSheetContent(
                            level: store.statLevels.overallLevel,
                            xp: (store.statLevels.overallXP, StatLevelSet.overallMaxXP),
                            hp: store.hitPoints,
                            fatigue: store.fatigue,
                            stats: Stat.allCases.map { ($0, store.statLevels[$0]) },
                            onSelectStat: { selectedStat = $0; SystemSound.systemOpen.play() },
                            onBeliefs: { showBeliefs = true; SystemSound.systemOpen.play() },
                            onContracts: { showContracts = true; SystemSound.systemOpen.play() }
                        )
                    }
                }
                .frame(maxWidth: 460)
                .padding(.horizontal, 18)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity)
                .frame(minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .sheet(item: $selectedStat, onDismiss: { SystemSound.systemClose.play() }) { stat in
            StatTargetsSheet(stat: stat)
        }
        .sheet(isPresented: $showSettings, onDismiss: { SystemSound.systemClose.play() }) {
            StatusSettingsSheet()
        }
        .sheet(isPresented: $showBeliefs, onDismiss: { SystemSound.systemClose.play() }) {
            BeliefsSheet()
        }
        .sheet(isPresented: $showContracts, onDismiss: { SystemSound.systemClose.play() }) {
            ContractsSheet()
        }
    }

    /// A small cyan square with an icon, like the run swap: the gear and the close button.
    private func squareButton(_ icon: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(QuestLight.cyan)
                .shadow(color: QuestLight.cyan.opacity(0.8), radius: 3)
                .frame(width: 26, height: 26)
                .overlay { Rectangle().stroke(QuestLight.cyan.opacity(0.5), lineWidth: 0.5) }
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -9)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// The window's content, apart from the store, so the preview can show any values.
private struct StatusSheetContent: View {
    let level: Int
    /// Overall XP: the stat levels added up, out of their combined max.
    var xp: (current: Int, max: Int) = (0, StatLevelSet.overallMaxXP)
    let hp: (current: Int, max: Int)
    let fatigue: Int
    let stats: [(Stat, Int)]
    var onSelectStat: (Stat) -> Void = { _ in }
    var onBeliefs: () -> Void = {}
    var onContracts: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            levelBlock
            TacticalBox(title: "[ VITALS ]") {
                // HP on the left with its bar, fatigue on the right with its shutter ring.
                HStack(alignment: .center, spacing: 16) {
                    hpMeter
                    fatigueMeter
                }
                .padding(.vertical, 12)
                .modifier(TacticalRowReveal(index: 0, group: "levels"))
            }
            TacticalBox(title: "[ STATS ]") {
                VStack(spacing: 0) {
                    ForEach(Array(stats.enumerated()), id: \.offset) { index, entry in
                        StatRow(stat: entry.0, value: entry.1, onSelect: onSelectStat)
                            .modifier(TacticalRowReveal(index: index + 2, group: "levels"))
                    }
                }
            }
            TacticalBox(title: "[ ACCESS ]") {
                VStack(spacing: 0) {
                    linkButton("CONTRACTS", action: onContracts)
                        .modifier(TacticalRowReveal(index: 9, group: "levels"))
                    linkButton("BELIEFS", action: onBeliefs)
                        .modifier(TacticalRowReveal(index: 10, group: "levels"))
                }
            }
        }
    }

    /// The big level number, then "LEVEL" and the XP bar.
    private var levelBlock: some View {
        let step = max(xp.max, 1)
        let fraction = Double(min(max(xp.current, 0), step)) / Double(step)
        return HStack(alignment: .center, spacing: 18) {
            Text(verbatim: "\(level)")
                .font(.system(size: 60, weight: .ultraLight))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(QuestLight.ink)
                .shadow(color: QuestLight.cyan.opacity(0.6), radius: 6)
                .frame(minWidth: 80, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                TypewriterText("PLAYER LEVEL", delay: 0.3)
                    .foregroundStyle(SystemTheme.muted)
                HStack {
                    Text("XP")
                    Spacer()
                    Text(verbatim: "\(xp.current.formatted()) / \(step.formatted())")
                        .monospacedDigit()
                }
                .foregroundStyle(QuestLight.ink)
                TacticalBar(fraction: fraction)
            }
            .font(TacticalIntro.mono)
            .tracking(1.5)
        }
        .padding(.horizontal, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Level \(level)")
        .accessibilityValue("XP \(xp.current) of \(step)")
    }

    /// "HP  1000/1000" with a thin bar under it. Red when HP is critical.
    private var hpMeter: some View {
        let red = HitPoints.isCritical(current: hp.current, max: hp.max)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("HP")
                    .foregroundStyle(SystemTheme.muted)
                Spacer(minLength: 4)
                Text(verbatim: "\(hp.current)/\(hp.max)")
                    .monospacedDigit()
                    .foregroundStyle(red ? QuestLight.penalty : QuestLight.ink)
            }
            .font(TacticalIntro.mono)
            .tracking(1)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            TacticalBar(fraction: Double(hp.current) / Double(max(hp.max, 1)), red: red)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("HP")
        .accessibilityValue(red ? "\(hp.current) of \(hp.max), critical" : "\(hp.current) of \(hp.max)")
    }

    /// The fatigue shutter ring, then "FATIGUE" and its value. Red at 80 or more.
    private var fatigueMeter: some View {
        let red = Fatigue.isRed(fatigue)
        return HStack(spacing: 10) {
            FatigueRing(fraction: Double(fatigue) / Fatigue.maxValue, light: red ? .critical : .normal)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text("FATIGUE")
                    .foregroundStyle(SystemTheme.muted)
                Text(verbatim: "\(fatigue)/\(Int(Fatigue.maxValue))")
                    .monospacedDigit()
                    .foregroundStyle(red ? QuestLight.penalty : QuestLight.ink)
            }
            .font(TacticalIntro.mono)
            .tracking(1)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.4), value: red)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fatigue")
        .accessibilityValue(red ? "\(fatigue) of 100, high" : "\(fatigue) of 100")
    }

    /// A link row in the access box: contracts or beliefs.
    private func linkButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(TacticalIntro.mono)
                    .tracking(2)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(QuestLight.cyan)
            }
            .foregroundStyle(QuestLight.ink)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title.capitalized)
    }
}

/// A ring of slanted slots, like a shutter, that lights up clockwise with the fatigue share.
/// Drawn like the quest page's day timer, with fewer, longer, tilted dashes.
private struct FatigueRing: View {
    let fraction: Double
    let light: HPLight

    private static let slots = 12
    /// Each slot leans this much off the radius, so the ring reads as a shutter.
    private static let slant = Angle.degrees(32)

    var body: some View {
        let lit = Int((min(max(fraction, 0), 1) * Double(Self.slots)).rounded())
        Canvas { context, size in
            let radius = min(size.width, size.height) / 2
            let length = radius * 0.46
            for index in 0..<Self.slots {
                var slot = context
                slot.translateBy(x: size.width / 2, y: size.height / 2)
                slot.rotate(by: .degrees(Double(index) * 360 / Double(Self.slots)))
                // Move out to the middle of the ring's band, then tilt the dash around its own center.
                slot.translateBy(x: 0, y: -radius + length / 2 + 0.5)
                slot.rotate(by: Self.slant)
                let rect = CGRect(x: -1.3, y: -length / 2, width: 2.6, height: length)
                let path = Path(roundedRect: rect, cornerRadius: 0.7)
                // Slot 0 is at 12 o'clock and the index runs clockwise.
                let isLit = index < lit
                slot.fill(path, with: .color(light.glow.opacity(isLit ? light.fill + 0.1 : 0.16)))
                slot.stroke(path, with: .color(light.ink.opacity(isLit ? 0.5 : 0.25)), lineWidth: 0.4)
            }
        }
    }
}

/// One stat: its icon, "STR", the name, the level, and a thin bar of the level out of 350.
/// Tapping it opens the stat's targets.
private struct StatRow: View {
    let stat: Stat
    let value: Int
    var onSelect: (Stat) -> Void = { _ in }

    var body: some View {
        Button {
            onSelect(stat)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 10) {
                    Image(systemName: Self.icon(stat))
                        .font(.system(size: 13))
                        .foregroundStyle(QuestLight.cyan)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    Text(stat.rawValue)
                        .font(TacticalIntro.mono)
                        .tracking(1.5)
                        .foregroundStyle(QuestLight.ink)
                    Text(stat.fullName)
                        .font(.footnote)
                        .foregroundStyle(SystemTheme.muted)
                        .lineLimit(1)
                    Spacer()
                    Text(verbatim: "\(value)")
                        .font(TacticalIntro.mono)
                        .monospacedDigit()
                        .foregroundStyle(QuestLight.ink)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(SystemTheme.muted)
                }
                TacticalBar(fraction: Double(value) / Double(StatLevel.maxLevel))
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(stat.fullName) \(value), show targets")
    }

    static func icon(_ stat: Stat) -> String {
        switch stat {
        case .STR: "dumbbell.fill"
        case .END: "figure.run"
        case .INT: "brain.head.profile"
        case .AGI: "hare.fill"
        case .FOC: "scope"
        case .REC: "bed.double.fill"
        case .FIN: "dollarsign.circle"
        }
    }
}

#Preview("Status window") {
    ZStack {
        QuestBackdrop()
        ScrollView {
            VStack(spacing: 24) {
                SystemPanel(padding: 14) {
                    StatusSheetContent(level: 61, xp: (1_030, 2_450), hp: (2_911, 3_602), fatigue: 34,
                                       stats: Stat.allCases.map { ($0, 140) })
                }
                SystemPanel(padding: 14) {
                    StatusSheetContent(level: 61, hp: (511, 3_602), fatigue: 86,
                                       stats: Stat.allCases.map { ($0, 140) })
                }
            }
            .padding(.horizontal, 18)
        }
    }
    .preferredColorScheme(.dark)
}
