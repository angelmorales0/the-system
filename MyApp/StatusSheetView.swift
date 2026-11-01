import SwiftUI

/// The System's STATUS window: the overall level and XP, HP and fatigue, the seven stats, gold, and Full Recoveries.
/// Overall XP is the seven stat levels added up (0...2450); the level is that share of 146.
/// HP turns red when critical; the fatigue meter turns red at 80 or more.
/// Tapping a stat opens its targets, the gold opens the shop, and the gear opens the settings.
struct StatusSheetView: View {
    @EnvironmentObject private var store: GameStore
    @State private var selectedStat: Stat?
    @State private var showSettings = false
    @State private var showShop = false

    var body: some View {
        ZStack {
            QuestBackdrop()
            GeometryReader { proxy in
                ScrollView(showsIndicators: false) {
                    SystemPanel(padding: 14) {
                        StatusSheetContent(
                            level: store.statLevels.overallLevel,
                            xp: (store.statLevels.overallXP, StatLevelSet.overallMaxXP),
                            hp: store.hitPoints,
                            fatigue: store.fatigue,
                            stats: Stat.allCases.map { ($0, store.statLevels[$0]) },
                            fullRecoveryPoints: store.player.fullRecoveryBank,
                            gold: store.snapshot.gold,
                            onSelectStat: { selectedStat = $0; SystemSound.systemOpen.play() },
                            onSettings: { showSettings = true; SystemSound.systemOpen.play() },
                            onShop: { showShop = true; SystemSound.systemOpen.play() }
                        )
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
        .sheet(item: $selectedStat, onDismiss: { SystemSound.systemClose.play() }) { stat in
            StatTargetsSheet(stat: stat)
        }
        .sheet(isPresented: $showSettings, onDismiss: { SystemSound.systemClose.play() }) {
            StatusSettingsSheet()
        }
        .sheet(isPresented: $showShop, onDismiss: { SystemSound.systemClose.play() }) {
            ShopSheet()
        }
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
    let fullRecoveryPoints: Int
    var gold = 0
    var onSelectStat: (Stat) -> Void = { _ in }
    var onSettings: () -> Void = {}
    var onShop: () -> Void = {}
    var body: some View {
        VStack(spacing: 22) {
            StatusTitleBox()
                .overlay(alignment: .trailing) { settingsButton }
            levelRow
            StatusFrame {
                HStack(alignment: .center, spacing: 14) {
                    hpMeter
                    fatigueMeter
                }
            }
            StatusFrame {
                VStack(alignment: .trailing, spacing: 16) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 14) {
                        ForEach(Array(stride(from: 0, to: stats.count, by: 2)), id: \.self) { index in
                            GridRow {
                                StatCell(stat: stats[index].0, value: stats[index].1, onSelect: onSelectStat)
                                if index + 1 < stats.count {
                                    StatCell(stat: stats[index + 1].0, value: stats[index + 1].1, onSelect: onSelectStat)
                                } else {
                                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        goldButton
                        Spacer(minLength: 8)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("Full Recoveries:")
                                .font(.footnote)
                            Text(verbatim: "\(fullRecoveryPoints)")
                                .font(.subheadline.weight(.bold))
                                .monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }
            }
        }
    }

    /// "Gold: 12,340" that opens the shop.
    private var goldButton: some View {
        Button(action: onShop) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Gold:")
                    .font(.footnote)
                Text(verbatim: gold.formatted())
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .opacity(0.7)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Gold \(gold), open shop")
        .accessibilityAddTraits(.isButton)
    }

    private var settingsButton: some View {
        Button(action: onSettings) {
            Image(systemName: "gearshape")
                .font(.system(size: 20, weight: .light))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .shadow(color: QuestLight.cyan.opacity(0.5), radius: 4)
        .accessibilityLabel("Settings")
    }

    private var levelRow: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(spacing: 0) {
                Text(verbatim: "\(level)")
                    .font(.system(size: 64, weight: .light))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .shadow(color: QuestLight.cyan.opacity(0.5), radius: 6)
                Text("LEVEL")
                    .font(.footnote.weight(.medium))
                    .tracking(2)
            }
            .frame(minWidth: 96)
            .accessibilityElement(children: .combine)
            xpBar
                .frame(maxWidth: .infinity)
        }
    }

    /// "XP 1,230 / 2,450" with a bar: the stat levels added up, as a share of their max. The level is this share of 146.
    private var xpBar: some View {
        let step = max(xp.max, 1)
        let fraction = Double(min(max(xp.current, 0), step)) / Double(step)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("XP").font(.caption.weight(.bold)).tracking(1)
                Spacer(minLength: 4)
                Text(verbatim: xp.current.formatted()).font(.caption.weight(.bold))
                Text(verbatim: " / \(step.formatted())").font(.caption2).foregroundStyle(HPLight.normal.ink.opacity(0.8))
            }
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            GlowBar(fraction: fraction, light: .normal)
        }
        .foregroundStyle(HPLight.normal.ink.opacity(0.8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("XP")
        .accessibilityValue("\(xp.current) of \(step)")
    }

    private var hpMeter: some View {
        let light = HPLight.of(current: hp.current, max: hp.max)
        return HStack(spacing: 8) {
            HPCross(light: .normal)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("HP").font(.caption.weight(.bold)).tracking(1)
                    Spacer(minLength: 4)
                    Text(verbatim: "\(hp.current)").font(.caption.weight(.bold))
                    Text(verbatim: "/\(hp.max)").font(.caption2).foregroundStyle(light.ink.opacity(0.8))
                }
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                HPBar(current: hp.current, max: hp.max)
            }
        }
        .foregroundStyle(light.ink.opacity(0.8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("HP")
        .accessibilityValue(HitPoints.isCritical(current: hp.current, max: hp.max) ? "\(hp.current) of \(hp.max), critical" : "\(hp.current) of \(hp.max)")
    }

    private var fatigueMeter: some View {
        let red = Fatigue.isRed(fatigue)
        let light: HPLight = red ? .critical : .normal
        let fraction = Double(fatigue) / Fatigue.maxValue
        return HStack(spacing: 8) {
            FatigueRing(fraction: fraction, light: light)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("FATIGUE:").font(.caption.weight(.bold)).tracking(0.6)
                    Text(verbatim: "\(fatigue)").font(.caption.weight(.bold)).monospacedDigit()
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                GlowBar(fraction: fraction, light: light)
            }
        }
        .foregroundStyle(light.ink.opacity(0.8))
        .animation(.easeInOut(duration: 0.4), value: red)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fatigue")
        .accessibilityValue(red ? "\(fatigue) of 100, high" : "\(fatigue) of 100")
    }
}

/// "STATUS" in a thin glowing box, centered.
private struct StatusTitleBox: View {
    var body: some View {
        Text("STATUS")
            .font(.system(size: 22, weight: .regular))
            .tracking(3)
            .padding(.horizontal, 26)
            .frame(height: 42)
            .background(QuestLight.cyan.opacity(0.04))
            .overlay { Rectangle().stroke(QuestLight.ink.opacity(0.55), lineWidth: 0.8) }
            .shadow(color: QuestLight.cyan.opacity(0.35), radius: 4)
            .frame(maxWidth: .infinity)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A thin glowing frame around one group of the window.
private struct StatusFrame<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(QuestLight.cyan.opacity(0.03))
            .overlay { Rectangle().stroke(QuestLight.ink.opacity(0.35), lineWidth: 0.7) }
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

/// "STR: 142" with the stat's icon. Tapping it opens the stat's targets.
private struct StatCell: View {
    let stat: Stat
    let value: Int
    var onSelect: (Stat) -> Void = { _ in }

    var body: some View {
        Button {
            onSelect(stat)
        } label: {
            label
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(stat.fullName) \(value), show targets")
    }

    private var label: some View {
        HStack(spacing: 8) {
            Image(systemName: Self.icon(stat))
                .font(.system(size: 15, weight: .regular))
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(verbatim: "\(stat.rawValue): \(value)")
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
                                       stats: Stat.allCases.map { ($0, 140) }, fullRecoveryPoints: 7)
                }
                SystemPanel(padding: 14) {
                    StatusSheetContent(level: 61, hp: (511, 3_602), fatigue: 86,
                                       stats: Stat.allCases.map { ($0, 140) }, fullRecoveryPoints: 0)
                }
            }
            .padding(.horizontal, 18)
        }
    }
    .preferredColorScheme(.dark)
}
