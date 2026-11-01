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
                .environment(\.isPageVisible, selectedPage == 0)
                .tag(0)
            StatusSheetView()
                .environment(\.isPageVisible, selectedPage == 1)
                .tag(1)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
        // Once per launch. An open penalty's own cue, a major one, cuts this short.
        .task { SystemSound.launch.play() }
        #if DEBUG
        // A paged TabView ignores its first selection, so the start page is set once it is on screen.
        .task { selectedPage = Self.startPage }
        #endif
        // Every page draws its own backdrop on top, so this one never needs to move.
        .background { SystemBackground(animated: false) }
        // An active emergency quest covers every page until it ends.
        .overlay {
            if let emergency = store.emergency, emergency.status == .active {
                EmergencyQuestView(quest: emergency)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: store.emergency?.id)
        // An open penalty covers every page until its run is verified.
        .overlay {
            if let penalty = store.openPenaltyQuest {
                PenaltyQuestView(quest: penalty, startedAt: store.penaltyStartedAt, tier: store.player.penaltyTier)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: store.openPenaltyQuest?.id)
        .tint(SystemTheme.accent)
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.refreshForToday()
            }
        }
    }

    /// The first page. Launch with `-startPage 1` in DEBUG to open on another page.
    private static var startPage: Int {
        #if DEBUG
        let page = UserDefaults.standard.integer(forKey: "startPage")
        return (0...1).contains(page) ? page : 0
        #else
        return 0
        #endif
    }
}

enum SystemTheme {
    static let background = Color(red: 0.008, green: 0.014, blue: 0.038)
    static let accent = Color(red: 0.12, green: 0.70, blue: 1.0)
    static let cyan = Color(red: 0.12, green: 0.70, blue: 1.0)
    static let ink = Color(red: 0.94, green: 0.97, blue: 1.0)
    static let muted = Color(red: 0.49, green: 0.72, blue: 0.98)
}

struct SystemBackground: View {
    var animated = true

    var body: some View {
        ZStack {
            SystemTheme.background.ignoresSafeArea()
            LinearGradient(colors: [Color(red: 0.01, green: 0.02, blue: 0.07), SystemTheme.background, Color(red: 0.015, green: 0.04, blue: 0.10)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            // Layered light fields give the glass windows a deep, electric-blue scene to reveal.
            RadialGradient(colors: [SystemTheme.cyan.opacity(0.26), .clear], center: .topTrailing, startRadius: 0, endRadius: 330).ignoresSafeArea()
            RadialGradient(colors: [Color.indigo.opacity(0.34), .clear], center: .bottomLeading, startRadius: 20, endRadius: 380).ignoresSafeArea()
            DriftingThreads(animated: animated).opacity(0.58).ignoresSafeArea()
        }
    }
}

struct ScreenContainer<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { ZStack { SystemBackground(); content } }
}

/// Every card in the app uses the daily quest window: the same glass, circuitry, stepped rails,
/// electric beams, and ink text with a cyan glow. The padding clears the rails and the beams.
struct SystemPanel<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content
    var body: some View {
        QuestHologram {
            content
                .foregroundStyle(QuestLight.ink)
                .shadow(color: QuestLight.cyan.opacity(0.45), radius: 4)
                .padding(.horizontal, padding + 12)
                .padding(.vertical, padding + 14)
        }
    }
}

/// A section heading inside a quest window, styled like the daily quest's GOAL.
struct QuestSectionTitle: View {
    let text: String
    var body: some View {
        VStack(spacing: 3) {
            Text(text.uppercased())
                .font(.system(.headline, design: .default).weight(.medium))
                .tracking(1.3)
                .foregroundStyle(QuestLight.ink)
                .shadow(color: QuestLight.cyan, radius: 7)
            Rectangle().fill(QuestLight.ink.opacity(0.85)).frame(width: 52, height: 1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A sheet laid out like the daily quest screen: quest backdrop, one quest window, boxed header.
struct QuestSheet<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        ZStack {
            QuestBackdrop()
            ScrollView(showsIndicators: false) {
                SystemPanel {
                    VStack(alignment: .leading, spacing: 18) {
                        QuestInfoHeader(title: title.uppercased())
                        content
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
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

private struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY)); path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)); path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY)); path.addLine(to: CGPoint(x: rect.minX, y: rect.midY)); path.closeSubpath()
        }
    }
}

/// Glowing wisps behind every window. Each curve sways on its own cycle (about 20 to 40 seconds),
/// so the scene never visibly loops. It pauses off screen, in the background, and with Reduce Motion.
struct DriftingThreads: View {
    /// False for a backdrop that is always covered, so it does not draw frames nobody sees.
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isPageVisible) private var isPageVisible

    private struct Wisp {
        var start: CGPoint, control1: CGPoint, control2: CGPoint, end: CGPoint
        var width: CGFloat, opacity: Double, speed: Double, phase: Double
    }

    /// Unit-space curves. The first three are the original threads; the last two are fainter depth layers.
    private static let wisps: [Wisp] = [
        Wisp(start: CGPoint(x: -0.10, y: 0.20), control1: CGPoint(x: 0.22, y: 0.05), control2: CGPoint(x: 0.62, y: 0.73), end: CGPoint(x: 1.12, y: 0.48), width: 2.5, opacity: 1, speed: 0.22, phase: 0),
        Wisp(start: CGPoint(x: -0.06, y: 0.70), control1: CGPoint(x: 0.35, y: 0.48), control2: CGPoint(x: 0.64, y: 0.60), end: CGPoint(x: 1.06, y: 0.25), width: 2.5, opacity: 1, speed: 0.16, phase: 2.1),
        Wisp(start: CGPoint(x: 0.08, y: 1.03), control1: CGPoint(x: 0.22, y: 0.60), control2: CGPoint(x: 0.74, y: 0.47), end: CGPoint(x: 0.92, y: -0.03), width: 2.5, opacity: 1, speed: 0.28, phase: 4.0),
        Wisp(start: CGPoint(x: -0.08, y: 0.42), control1: CGPoint(x: 0.30, y: 0.30), control2: CGPoint(x: 0.70, y: 0.90), end: CGPoint(x: 1.10, y: 0.82), width: 1.6, opacity: 0.55, speed: 0.18, phase: 1.3),
        Wisp(start: CGPoint(x: 0.30, y: -0.04), control1: CGPoint(x: 0.10, y: 0.40), control2: CGPoint(x: 0.95, y: 0.35), end: CGPoint(x: 0.70, y: 1.04), width: 1.4, opacity: 0.45, speed: 0.24, phase: 5.2),
    ]

    var body: some View {
        let paused = !animated || reduceMotion || scenePhase != .active || !isPageVisible
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused)) { timeline in
            let time = (animated && !reduceMotion) ? timeline.date.timeIntervalSinceReferenceDate : 0
            Canvas { context, size in
                let gradient = Gradient(colors: [.clear, SystemTheme.cyan.opacity(0.40), Color.indigo.opacity(0.54), .clear])
                let shading = GraphicsContext.Shading.linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0))
                for wisp in Self.wisps {
                    let path = Self.path(wisp, size: size, time: time)
                    // Brightness breathes slowly, out of step with the sway.
                    let breath = 0.65 + 0.35 * sin(time * wisp.speed * 1.7 + wisp.phase * 2)
                    context.drawLayer { haze in
                        haze.addFilter(.blur(radius: 10))
                        haze.opacity = 0.5 * wisp.opacity * breath
                        haze.stroke(path, with: shading, style: StrokeStyle(lineWidth: wisp.width * 4, lineCap: .round))
                    }
                    context.drawLayer { thread in
                        thread.addFilter(.blur(radius: 3))
                        thread.opacity = wisp.opacity * breath
                        thread.stroke(path, with: shading, style: StrokeStyle(lineWidth: wisp.width, lineCap: .round))
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The end points sway a little; the control points sway more, so the curve bends and unbends.
    private static func path(_ wisp: Wisp, size: CGSize, time: Double) -> Path {
        func point(_ unit: CGPoint, amount: Double, offset: Double) -> CGPoint {
            let angle = time * wisp.speed + wisp.phase + offset
            return CGPoint(x: (unit.x + amount * 0.6 * cos(angle * 0.7)) * size.width,
                           y: (unit.y + amount * sin(angle)) * size.height)
        }
        var path = Path()
        path.move(to: point(wisp.start, amount: 0.04, offset: 0))
        path.addCurve(to: point(wisp.end, amount: 0.04, offset: 1.9),
                      control1: point(wisp.control1, amount: 0.14, offset: 0.7),
                      control2: point(wisp.control2, amount: 0.15, offset: 3.1))
        return path
    }
}

private struct PageVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False for a paged screen that is off to the side. Animations pause there.
    var isPageVisible: Bool {
        get { self[PageVisibleKey.self] }
        set { self[PageVisibleKey.self] = newValue }
    }
}

#Preview {
    ContentView()
        .environmentObject(GameStore(persistence: .memory))
}
