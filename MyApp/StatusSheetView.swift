import SwiftUI

/// The System's STATUS window: level, job and title, HP and fatigue, the seven stats, and Full Recovery points.
/// HP turns red when injured; the fatigue meter turns red at 80 or more.
struct StatusSheetView: View {
    @EnvironmentObject private var store: GameStore

    var body: some View {
        ZStack {
            QuestBackdrop()
            GeometryReader { proxy in
                ScrollView(showsIndicators: false) {
                    SystemPanel(padding: 14) {
                        StatusSheetContent(
                            level: store.statLevels.overallLevel,
                            hp: store.hitPoints,
                            fatigue: store.fatigue,
                            stats: Stat.allCases.map { ($0, store.statLevels[$0]) },
                            fullRecoveryPoints: store.player.fullRecoveryBank
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
    }
}

/// The window's content, apart from the store, so the preview can show any values.
private struct StatusSheetContent: View {
    let level: Int
    let hp: (current: Int, max: Int)
    let fatigue: Int
    let stats: [(Stat, Int)]
    let fullRecoveryPoints: Int
    /// The app has no jobs or titles yet.
    var job = "None"
    var title = "None"

    var body: some View {
        VStack(spacing: 22) {
            StatusTitleBox()
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
                                StatCell(stat: stats[index].0, value: stats[index].1)
                                if index + 1 < stats.count {
                                    StatCell(stat: stats[index + 1].0, value: stats[index + 1].1)
                                } else {
                                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Full Recovery Points:")
                            .font(.footnote)
                        Text(verbatim: "\(fullRecoveryPoints)")
                            .font(.subheadline.weight(.bold))
                            .monospacedDigit()
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var levelRow: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(spacing: 0) {
                Text(verbatim: "\(level)")
                    .font(.system(size: 64, weight: .light))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .shadow(color: QuestLight.cyan, radius: 10)
                Text("LEVEL")
                    .font(.footnote.weight(.medium))
                    .tracking(2)
            }
            .frame(minWidth: 96)
            .accessibilityElement(children: .combine)
            VStack(alignment: .leading, spacing: 10) {
                labeled("JOB", job)
                labeled("TITLE", title)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func labeled(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label + ":").font(.subheadline.weight(.semibold)).tracking(1.1)
            Text(value).font(.subheadline)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .accessibilityElement(children: .combine)
    }

    private var hpMeter: some View {
        let light = HPLight.of(current: hp.current, max: hp.max)
        return HStack(spacing: 8) {
            HPCross(light: light)
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
        .foregroundStyle(light.ink)
        .shadow(color: light.glow.opacity(0.8), radius: 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("HP")
        .accessibilityValue(HitPoints.isInjured(current: hp.current, max: hp.max) ? "\(hp.current) of \(hp.max), injured" : "\(hp.current) of \(hp.max)")
    }

    private var fatigueMeter: some View {
        let red = Fatigue.isRed(fatigue)
        let light: HPLight = red ? .injured : .normal
        let fraction = Double(fatigue) / Fatigue.maxValue
        return HStack(spacing: 8) {
            FatigueRing(fraction: fraction, light: light)
                .frame(width: 20, height: 20)
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
        .foregroundStyle(light.ink)
        .shadow(color: light.glow.opacity(0.8), radius: 5)
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
            .shadow(color: QuestLight.cyan.opacity(0.85), radius: 7)
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
            .overlay {
                Rectangle().stroke(QuestLight.cyan.opacity(0.35), lineWidth: 3).blur(radius: 3)
                Rectangle().stroke(QuestLight.ink.opacity(0.5), lineWidth: 0.7)
            }
    }
}

/// A ring that fills clockwise with the fatigue share.
private struct FatigueRing: View {
    let fraction: Double
    let light: HPLight

    var body: some View {
        ZStack {
            Circle().stroke(light.ink.opacity(0.3), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(LinearGradient(colors: [light.ink, light.glow], startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: light.glow, radius: 4)
        }
        .padding(1.5)
    }
}

/// "STR: 142" with the stat's icon.
private struct StatCell: View {
    let stat: Stat
    let value: Int

    var body: some View {
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
                    StatusSheetContent(level: 61, hp: (2_911, 3_602), fatigue: 34,
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
