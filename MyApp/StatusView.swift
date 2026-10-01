import SwiftUI

struct StatusView: View {
    @EnvironmentObject private var store: GameStore

    private var stats: [RadarStat] {
        store.player.stats.radar.map { RadarStat(label: $0.label, value: $0.value) }
    }

    var body: some View {
        ScreenContainer {
            VStack(spacing: 0) {
                Spacer(minLength: 42)

                SystemPanel {
                    VStack(spacing: 20) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(store.player.statusDisplayName)
                                    .font(.title2.weight(.semibold))
                                    .tracking(1.2)
                                    .foregroundStyle(.white)
                                Text("LEVEL \(store.player.level)")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(SystemTheme.muted)
                            }
                            Spacer()
                        }

                        SystemProgressBar(progress: store.player.xpProgress, label: store.player.xpLabel)
                        SystemDivider()

                        RadarChart(stats: stats)
                            .frame(height: 310)
                            .padding(.vertical, 6)

                        SystemDivider()
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("FULL RECOVERY")
                                    .font(.caption.weight(.semibold))
                                    .tracking(1.1)
                                    .foregroundStyle(SystemTheme.muted)
                                Text("x\(store.player.fullRecoveryBank)")
                                    .font(.title2.weight(.bold))
                                    .foregroundStyle(.white)
                            }
                            Spacer()
                            Image(systemName: "bolt.fill")
                                .font(.title2)
                                .foregroundStyle(SystemTheme.cyan)
                                .shadow(color: SystemTheme.cyan.opacity(0.35), radius: 4)
                        }
                    }
                }
                .padding(.horizontal, 22)

                Spacer(minLength: 24)
            }
        }
    }
}

private struct RadarStat: Identifiable {
    var id: String { label }
    let label: String
    let value: Double
}

private struct RadarChart: View {
    let stats: [RadarStat]
    private let maximum = 160.0

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let radius = size * 0.31

            ZStack {
                Canvas { context, canvasSize in
                    let chartCenter = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                    let chartRadius = min(canvasSize.width, canvasSize.height) * 0.31

                    for level in 1...4 {
                        let fraction = CGFloat(level) / 4
                        context.stroke(
                            radarPath(center: chartCenter, radius: chartRadius * fraction, values: Array(repeating: 1, count: stats.count)),
                            with: .color(SystemTheme.cyan.opacity(level == 4 ? 0.40 : 0.16)),
                            lineWidth: level == 4 ? 1 : 0.6
                        )
                    }

                    for index in stats.indices {
                        let point = point(for: index, total: stats.count, center: chartCenter, radius: chartRadius)
                        var axis = Path()
                        axis.move(to: chartCenter)
                        axis.addLine(to: point)
                        context.stroke(axis, with: .color(SystemTheme.cyan.opacity(0.22)), lineWidth: 0.6)
                    }

                    let normalized = stats.map { min($0.value / maximum, 1) }
                    let dataPath = radarPath(center: chartCenter, radius: chartRadius, values: normalized)
                    context.fill(dataPath, with: .color(SystemTheme.cyan.opacity(0.24)))
                    context.stroke(dataPath, with: .color(SystemTheme.cyan), lineWidth: 1.5)

                    for index in stats.indices {
                        let valuePoint = point(for: index, total: stats.count, center: chartCenter, radius: chartRadius * CGFloat(normalized[index]))
                        context.fill(Path(ellipseIn: CGRect(x: valuePoint.x - 3, y: valuePoint.y - 3, width: 6, height: 6)), with: .color(.white))
                    }
                }

                ForEach(Array(stats.enumerated()), id: \.element.id) { index, stat in
                    let position = point(for: index, total: stats.count, center: center, radius: radius + 38)
                    VStack(spacing: 2) {
                        Text(stat.label).font(.caption.weight(.bold)).foregroundStyle(SystemTheme.muted)
                        Text("\(Int(stat.value))").font(.caption.monospacedDigit().weight(.medium)).foregroundStyle(.white)
                    }
                    .fixedSize()
                    .position(position)
                }
            }
        }
    }

    private func radarPath(center: CGPoint, radius: CGFloat, values: [Double]) -> Path {
        Path { path in
            for index in values.indices {
                let point = point(for: index, total: values.count, center: center, radius: radius * CGFloat(values[index]))
                index == 0 ? path.move(to: point) : path.addLine(to: point)
            }
            path.closeSubpath()
        }
    }

    private func point(for index: Int, total: Int, center: CGPoint, radius: CGFloat) -> CGPoint {
        let angle = (CGFloat(index) * .pi * 2 / CGFloat(total)) - .pi / 2
        return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }
}

#Preview {
    StatusView()
        .environmentObject(GameStore(persistence: .memory))
}
