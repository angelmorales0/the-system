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
                .tag(0)
            StatusView()
                .tag(1)
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

enum SystemTheme {
    static let background = Color(red: 0.008, green: 0.014, blue: 0.038)
    static let panel = Color(red: 0.015, green: 0.06, blue: 0.13)
    static let accent = Color(red: 0.12, green: 0.70, blue: 1.0)
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
