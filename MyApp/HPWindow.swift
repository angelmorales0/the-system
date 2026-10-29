import SwiftUI

/// The HP window's light: System blue normally, red once the player is injured (`HitPoints.isInjured`).
struct HPLight {
    let glow: Color
    let deep: Color
    let ink: Color

    static let normal = HPLight(glow: QuestLight.cyan, deep: QuestLight.blue, ink: QuestLight.ink)
    static let injured = HPLight(glow: QuestLight.penalty, deep: Color(red: 0.62, green: 0.02, blue: 0.12),
                                 ink: Color(red: 1, green: 0.88, blue: 0.9))

    static func of(current: Int, max: Int) -> HPLight {
        HitPoints.isInjured(current: current, max: max) ? .injured : .normal
    }
}

/// A glowing, outlined pill. The fill is current HP as a share of max.
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
                Capsule().fill(.black.opacity(0.45))
                Capsule()
                    .fill(LinearGradient(colors: [light.deep.opacity(0.85), light.glow, light.ink.opacity(0.95)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: Swift.max(proxy.size.height - 5, (proxy.size.width - 5) * fraction), height: proxy.size.height - 5)
                    .opacity(fraction > 0 ? 1 : 0)
                    .shadow(color: light.glow.opacity(0.9), radius: 6)
                    .offset(x: 2.5)
            }
            .overlay {
                Capsule().stroke(light.glow.opacity(0.55), lineWidth: 3).blur(radius: 3)
                Capsule().stroke(light.ink.opacity(0.8), lineWidth: 1)
            }
            .shadow(color: light.glow.opacity(0.45), radius: 8)
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.5), value: fraction)
        .accessibilityHidden(true)
    }
}

/// HP: a glowing cross, the bar, and "current/max" under its right end. Red with INJURED at or below 20%.
struct HPWindow: View {
    let current: Int
    let max: Int

    var body: some View {
        let injured = HitPoints.isInjured(current: current, max: max)
        let light = HPLight.of(current: current, max: max)
        HStack(alignment: .center, spacing: 14) {
            VStack(spacing: 3) {
                HPCross(light: light)
                    .frame(width: 26, height: 26)
                Text("HP")
                    .font(.system(.subheadline).weight(.bold))
                    .tracking(1)
            }
            .foregroundStyle(light.ink)
            .shadow(color: light.glow, radius: 6)

            VStack(alignment: .trailing, spacing: 6) {
                HPBar(current: current, max: max)
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    if injured {
                        Text("INJURED")
                            .font(.caption2.weight(.semibold))
                            .tracking(1.4)
                            .foregroundStyle(light.glow)
                    }
                    Spacer(minLength: 8)
                    Text(verbatim: "\(current)")
                        .font(.system(.subheadline).weight(.bold))
                    Text(verbatim: "/\(max)")
                        .font(.caption)
                        .foregroundStyle(light.ink.opacity(0.8))
                }
                .monospacedDigit()
                .foregroundStyle(light.ink)
                .shadow(color: light.glow.opacity(0.8), radius: 5)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background {
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
            ZStack {
                shape.fill(LinearGradient(colors: [light.deep.opacity(0.16), Color(red: 0.02, green: 0.05, blue: 0.08).opacity(0.86),
                                                   light.deep.opacity(0.12)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
                shape.fill(.black.opacity(0.35))
            }
        }
        .overlay {
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
            shape.stroke(light.glow.opacity(0.7), lineWidth: 4).blur(radius: 5)
            shape.stroke(light.glow.opacity(0.9), lineWidth: 1.2)
            shape.inset(by: 3).stroke(light.ink.opacity(0.22), lineWidth: 0.5)
        }
        .shadow(color: light.glow.opacity(0.35), radius: 12)
        .animation(.easeInOut(duration: 0.4), value: injured)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("HP")
        .accessibilityValue(injured ? "\(current) of \(max), injured" : "\(current) of \(max)")
    }
}

/// A plus sign drawn as an outlined, glowing cross.
struct HPCross: View {
    let light: HPLight

    var body: some View {
        CrossShape()
            .fill(LinearGradient(colors: [light.ink, light.glow], startPoint: .top, endPoint: .bottom))
            .overlay(CrossShape().stroke(light.ink.opacity(0.9), lineWidth: 0.8))
            .shadow(color: light.glow, radius: 6)
            .shadow(color: light.deep.opacity(0.8), radius: 10)
    }
}

private struct CrossShape: Shape {
    func path(in rect: CGRect) -> Path {
        let arm = rect.width * 0.34
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
