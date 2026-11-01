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

