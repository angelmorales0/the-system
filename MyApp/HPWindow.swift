import SwiftUI

/// The HP window's light: a quiet System blue normally, red once HP is critical (`HitPoints.isCritical`).
/// Nothing glows. The normal state stays out of the way; the critical state is noticeable, not loud.
struct HPLight {
    let glow: Color
    let ink: Color
    /// How solid the bar's fill is.
    let fill: Double
    /// How visible the window's outline is.
    let frame: Double

    static let normal = HPLight(glow: SystemTheme.muted, ink: SystemTheme.ink, fill: 0.55, frame: 0.22)
    static let critical = HPLight(glow: QuestLight.penalty, ink: Color(red: 1, green: 0.86, blue: 0.88), fill: 0.85, frame: 0.55)

    static func of(current: Int, max: Int) -> HPLight {
        HitPoints.isCritical(current: current, max: max) ? .critical : .normal
    }
}

/// A thin, outlined pill. The fill is current HP as a share of max.
struct HPBar: View {
    let current: Int
    let max: Int

    var body: some View {
        GlowBar(fraction: max > 0 ? Double(current) / Double(max) : 0, light: HPLight.of(current: current, max: max))
    }
}

/// The HP bar's pill for any 0...1 share, in the given light. The fatigue meter uses it too.
struct GlowBar: View {
    let fraction: Double
    let light: HPLight

    var body: some View {
        let fraction = min(Swift.max(fraction, 0), 1)
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.07))
                Capsule()
                    .fill(light.glow.opacity(light.fill))
                    .frame(width: Swift.max(proxy.size.height - 4, (proxy.size.width - 4) * fraction), height: proxy.size.height - 4)
                    .opacity(fraction > 0 ? 1 : 0)
                    .offset(x: 2)
            }
            .overlay { Capsule().stroke(light.ink.opacity(0.22), lineWidth: 0.8) }
        }
        .frame(height: 10)
        .animation(.easeOut(duration: 0.5), value: fraction)
        .accessibilityHidden(true)
    }
}

/// HP: a small cross, the bar, and "current/max" under its right end. Red with CRITICAL at or below 20%.
struct HPWindow: View {
    let current: Int
    let max: Int

    var body: some View {
        let critical = HitPoints.isCritical(current: current, max: max)
        let light = HPLight.of(current: current, max: max)
        HStack(alignment: .center, spacing: 12) {
            VStack(spacing: 3) {
                HPCross(light: .normal)
                    .frame(width: 16, height: 16)
                Text("HP")
                    .font(.caption2.weight(.semibold))
                    .tracking(1)
            }
            .foregroundStyle(light.ink.opacity(0.75))

            VStack(alignment: .trailing, spacing: 5) {
                HPBar(current: current, max: max)
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    if critical {
                        Text("CRITICAL")
                            .font(.caption2.weight(.semibold))
                            .tracking(1.4)
                            .foregroundStyle(light.glow.opacity(0.9))
                    }
                    Spacer(minLength: 8)
                    Text(verbatim: "\(current)")
                        .font(.caption.weight(.semibold))
                    Text(verbatim: "/\(max)")
                        .font(.caption2)
                        .foregroundStyle(light.ink.opacity(0.55))
                }
                .monospacedDigit()
                .foregroundStyle(light.ink.opacity(0.8))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.black.opacity(0.28))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(light.glow.opacity(light.frame), lineWidth: 0.8)
        }
        .animation(.easeInOut(duration: 0.4), value: critical)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("HP")
        .accessibilityValue(critical ? "\(current) of \(max), critical" : "\(current) of \(max)")
    }
}

/// A plus sign drawn as a flat cross.
struct HPCross: View {
    let light: HPLight

    var body: some View {
        CrossShape()
            .fill(light.glow.opacity(0.85))
    }
}

private struct CrossShape: Shape {
    func path(in rect: CGRect) -> Path {
        let arm = rect.width * 0.26
        let near = (rect.width - arm) / 2
        let far = near + arm
        let points: [(CGFloat, CGFloat)] = [(near, 0), (far, 0), (far, near), (rect.width, near), (rect.width, far), (far, far),
                                            (far, rect.height), (near, rect.height), (near, far), (0, far), (0, near), (near, near)]
        return Path { p in
            p.addLines(points.map { CGPoint(x: rect.minX + $0.0, y: rect.minY + $0.1) })
            p.closeSubpath()
        }
    }
}

#Preview("HP window") {
    ZStack {
        QuestBackdrop()
        VStack(spacing: 28) {
            HPWindow(current: 2_911, max: 3_602)
            HPWindow(current: 511, max: 3_602)
            HPBar(current: 1_800, max: 3_602)
        }
        .padding(.horizontal, 18)
    }
    .preferredColorScheme(.dark)
}
