import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: GameStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedPage = 0

    var body: some View {
        // A paged TabView stops at the safe area, which leaves white bars above and below
        // each page. Let it fill the screen; the pages still receive the safe-area insets,
        // so their backgrounds bleed to the edges while the content stays clear of the notch.
        TabView(selection: $selectedPage) {
            SystemView()
                .environment(\.isSystemPageActive, selectedPage == 0)
                .tag(0)
            GoalsView()
                .environment(\.isSystemPageActive, selectedPage == 1)
                .tag(1)
            HistoryView()
                .environment(\.isSystemPageActive, selectedPage == 2)
                .tag(2)
            StatusView()
                .environment(\.isSystemPageActive, selectedPage == 3)
                .tag(3)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
        .background { SystemBackground() }
        // An active emergency quest covers every page until it ends.
        .overlay {
            if let emergency = store.emergency, emergency.status == .active {
                EmergencyQuestView(quest: emergency)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: store.emergency?.id)
        .tint(SystemTheme.accent)
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.refreshForToday()
            }
        }
    }
}

private struct SystemPageActiveKey: EnvironmentKey {
    static let defaultValue = true
}

private extension EnvironmentValues {
    var isSystemPageActive: Bool {
        get { self[SystemPageActiveKey.self] }
        set { self[SystemPageActiveKey.self] = newValue }
    }
}

enum SystemTheme {
    static let background = Color(red: 0.008, green: 0.014, blue: 0.038)
    static let panel = Color(red: 0.015, green: 0.06, blue: 0.13)
    static let accent = Color(red: 0.12, green: 0.70, blue: 1.0)
    static let green = Color(red: 0.15, green: 0.78, blue: 0.94)
    static let cyan = Color(red: 0.12, green: 0.70, blue: 1.0)
    static let ink = Color(red: 0.94, green: 0.97, blue: 1.0)
    static let muted = Color(red: 0.49, green: 0.72, blue: 0.98)
}

struct SystemBackground: View {
    var body: some View {
        ZStack {
            SystemTheme.background.ignoresSafeArea()
            LinearGradient(colors: [Color(red: 0.01, green: 0.02, blue: 0.07), SystemTheme.background, Color(red: 0.015, green: 0.04, blue: 0.10)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            // Layered light fields give the glass windows a deep, electric-blue scene to reveal.
            RadialGradient(colors: [SystemTheme.cyan.opacity(0.26), .clear], center: .topTrailing, startRadius: 0, endRadius: 330).ignoresSafeArea()
            RadialGradient(colors: [Color.indigo.opacity(0.34), .clear], center: .bottomLeading, startRadius: 20, endRadius: 380).ignoresSafeArea()
            NebulaThreads().opacity(0.58).ignoresSafeArea()
        }
    }
}

struct ScreenContainer<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { ZStack { SystemBackground(); content } }
}

struct SystemPanel<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(padding)
            // A light tint keeps the scene visible without the gray material wash.
            .background {
                LinearGradient(
                    colors: [SystemTheme.panel.opacity(0.24), SystemTheme.panel.opacity(0.10)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                PanelEnergyLines()
            }
            .clipShape(CutCornerRectangle(cut: 14))
            .overlay { SystemBorder() }
            .shadow(color: SystemTheme.cyan.opacity(0.16), radius: 12, x: 0, y: 5)
    }
}

/// Diffuse, overlapping wisps keep the glass texture soft and translucent.
private struct PanelEnergyLines: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isSystemPageActive) private var isPageActive
    @State private var animationStart = Date()
    @State private var patternSeed = Int.random(in: 0..<1_000_000_000)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30,
                                paused: reduceMotion || scenePhase != .active || !isPageActive)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSince(animationStart)
            energyCanvas(time: CGFloat(time))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { refreshPattern() }
        // Paged TabView can keep neighboring screens alive, so onAppear alone
        // doesn't guarantee a new pattern when returning to a cached page.
        .onChange(of: isPageActive) { _, active in
            if active { refreshPattern() }
        }
    }

    private func refreshPattern() {
        patternSeed = Int.random(in: 0..<1_000_000_000)
        animationStart = Date()
    }

    private func energyCanvas(time: CGFloat) -> some View {
        Canvas { context, size in
            let count = max(10, Int(size.height / 35))
            let blue = Color(red: 0.24, green: 0.43, blue: 1)

            for index in 0..<count {
                // The seed stays fixed between visits so animation frames never flicker.
                let seed = patternSeed + index * 17
                // Independent, continuous cycles avoid synchronized pulsing or loop jumps.
                let motionPhase = noise(seed + 6) * .pi * 2
                let drift = time * (0.16 + noise(seed + 7) * 0.12)
                let driftX = (sin(drift + motionPhase) - sin(motionPhase)) * 18
                let driftY = (cos(drift * 0.83 + motionPhase) - cos(motionPhase)) * 14
                let fadeCycle = time * (0.42 + noise(seed + 8) * 0.30) + motionPhase
                let visibility = reduceMotion ? 1.0 : Double(0.08 + 0.92 * (0.5 + 0.5 * sin(fadeCycle)))
                let origin = CGPoint(x: noise(seed) * size.width + driftX,
                                     y: noise(seed + 1) * size.height + driftY)
                let angle = (noise(seed + 2) - 0.5) * .pi * 1.4
                    + (sin(drift * 0.6 + motionPhase) - sin(motionPhase)) * 0.06
                let length = 120 + noise(seed + 3) * size.width * 0.85
                let amplitude = 12 + noise(seed + 4) * 28
                let phase = noise(seed + 5) * .pi * 2
                let broadFrequency = 1.7 + noise(seed + 9) * 0.8
                let fineFrequency = 4.5 + noise(seed + 10) * 1.6
                let direction = CGPoint(x: cos(angle), y: sin(angle))
                let start = CGPoint(x: origin.x - direction.x * length / 2,
                                    y: origin.y - direction.y * length / 2)
                let end = CGPoint(x: origin.x + direction.x * length / 2,
                                  y: origin.y + direction.y * length / 2)
                let shading = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [.clear, blue.opacity(0.10), blue.opacity(0.19),
                                      blue.opacity(0.07), .clear]),
                    startPoint: start, endPoint: end
                )
                var filaments = Path()
                for strand in 0..<7 {
                    let offset = CGFloat(strand - 3) * 1.4
                    var wisp = Path()
                    for step in 0...100 {
                        let t = CGFloat(step) / 100
                        let along = (t - 0.5) * length
                        let wave = sin(t * .pi * broadFrequency + phase) * amplitude
                            + sin(t * .pi * fineFrequency + phase * 1.7) * amplitude * 0.24
                        let feather = offset * (0.5 + 0.5 * sin(t * .pi * 3 + phase))
                            + sin(t * .pi * 9 + CGFloat(strand)) * 1.3
                        let across = wave + feather
                        let point = CGPoint(x: origin.x + direction.x * along - direction.y * across,
                                            y: origin.y + direction.y * along + direction.x * across)
                        if step == 0 { wisp.move(to: point) } else { wisp.addLine(to: point) }
                    }
                    filaments.addPath(wisp)
                }
                context.drawLayer { haze in
                    haze.addFilter(.blur(radius: 7))
                    haze.opacity = 0.45 * visibility
                    haze.stroke(filaments, with: shading, lineWidth: 3)
                }
                context.drawLayer { threads in
                    threads.addFilter(.blur(radius: 1.6))
                    threads.opacity = 0.55 * visibility
                    threads.stroke(filaments, with: shading, lineWidth: 0.65)
                }
            }
        }
    }

    private func noise(_ seed: Int) -> CGFloat {
        let value = sin(Double(seed) * 127.1 + 311.7) * 43758.5453
        return CGFloat(value - floor(value))
    }
}

struct SystemBorder: View {
    var body: some View {
        CutCornerRectangle(cut: 14)
            .stroke(LinearGradient(colors: [SystemTheme.cyan.opacity(0.92), .white.opacity(0.72), SystemTheme.cyan.opacity(0.48)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.2)
            .overlay {
                CutCornerRectangle(cut: 11)
                    .stroke(.white.opacity(0.18), lineWidth: 0.5)
                    .padding(3)
            }
    }
}

struct SystemTitle: View {
    let text: String
    var body: some View {
        HStack(spacing: 9) {
            Rectangle().fill(SystemTheme.cyan.opacity(0.54)).frame(height: 1)
            Text(text.uppercased()).font(.caption.weight(.bold)).tracking(2.4).foregroundStyle(SystemTheme.ink)
            Rectangle().fill(SystemTheme.cyan.opacity(0.54)).frame(height: 1)
        }
    }
}

struct SystemDivider: View {
    var body: some View {
        HStack(spacing: 6) {
            Rectangle().fill(SystemTheme.cyan.opacity(0.43)).frame(height: 1)
            Diamond().fill(SystemTheme.cyan).frame(width: 5, height: 5)
            Rectangle().fill(SystemTheme.cyan.opacity(0.43)).frame(height: 1)
        }
    }
}

struct SystemProgressBar: View {
    let progress: Double
    var label: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let label { Text(label).font(.caption.weight(.medium)).foregroundStyle(SystemTheme.muted) }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.black.opacity(0.35))
                    Capsule().fill(LinearGradient(colors: [SystemTheme.cyan.opacity(0.65), SystemTheme.accent], startPoint: .leading, endPoint: .trailing)).frame(width: proxy.size.width * min(max(progress, 0), 1)).shadow(color: SystemTheme.cyan.opacity(0.7), radius: 4)
                }.overlay(Capsule().stroke(SystemTheme.cyan.opacity(0.60), lineWidth: 1))
            }.frame(height: 10)
        }
    }
}

struct StatLine: View {
    let label: String; let value: String
    var body: some View {
        HStack { Text(label.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(SystemTheme.muted); Spacer(); Text(value).font(.subheadline.monospacedDigit().weight(.medium)).foregroundStyle(SystemTheme.ink) }
    }
}

private struct CutCornerRectangle: Shape {
    let cut: CGFloat
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX + cut, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cut))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cut))
            path.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + cut, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - cut))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cut))
            path.closeSubpath()
        }
    }
}

private struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY)); path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)); path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY)); path.addLine(to: CGPoint(x: rect.minX, y: rect.midY)); path.closeSubpath()
        }
    }
}

private struct NebulaThreads: View {
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            Path { path in
                path.move(to: CGPoint(x: -40, y: height * 0.20))
                path.addCurve(to: CGPoint(x: width + 50, y: height * 0.48), control1: CGPoint(x: width * 0.22, y: height * 0.05), control2: CGPoint(x: width * 0.62, y: height * 0.73))
                path.move(to: CGPoint(x: -25, y: height * 0.70))
                path.addCurve(to: CGPoint(x: width + 25, y: height * 0.25), control1: CGPoint(x: width * 0.35, y: height * 0.48), control2: CGPoint(x: width * 0.64, y: height * 0.60))
                path.move(to: CGPoint(x: width * 0.08, y: height + 20))
                path.addCurve(to: CGPoint(x: width * 0.92, y: -20), control1: CGPoint(x: width * 0.22, y: height * 0.60), control2: CGPoint(x: width * 0.74, y: height * 0.47))
            }
            .stroke(LinearGradient(colors: [.clear, SystemTheme.cyan.opacity(0.40), Color.indigo.opacity(0.54), .clear], startPoint: .leading, endPoint: .trailing), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .blur(radius: 3)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(GameStore(persistence: .memory))
}
