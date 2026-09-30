import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            SystemView()
            GoalsView()
            HistoryView()
            StatusView()
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .tint(SystemTheme.cyan)
    }
}

enum SystemTheme {
    static let background = Color(red: 0.012, green: 0.035, blue: 0.09)
    static let panel = Color(red: 0.025, green: 0.09, blue: 0.19)
    static let cyan = Color(red: 0.24, green: 0.72, blue: 1.0)
    static let muted = Color(red: 0.55, green: 0.72, blue: 0.94)
}

struct SystemBackground: View {
    var body: some View {
        ZStack {
            SystemTheme.background.ignoresSafeArea()
            LinearGradient(colors: [.black.opacity(0.38), SystemTheme.background, SystemTheme.cyan.opacity(0.035)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
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
            .background(SystemTheme.panel.opacity(0.55))
            .overlay { SystemBorder() }
            .clipShape(CutCornerRectangle(cut: 13))
    }
}

struct SystemBorder: View {
    var body: some View {
        CutCornerRectangle(cut: 13)
            .stroke(SystemTheme.cyan.opacity(0.74), lineWidth: 1)
            .shadow(color: SystemTheme.cyan.opacity(0.26), radius: 4)
            .overlay {
                CutCornerRectangle(cut: 11)
                    .stroke(.white.opacity(0.16), lineWidth: 0.5)
                    .padding(3)
            }
    }
}

struct SystemTitle: View {
    let text: String
    var body: some View {
        HStack(spacing: 9) {
            Rectangle().fill(SystemTheme.cyan.opacity(0.55)).frame(height: 1)
            Text(text.uppercased()).font(.caption.weight(.bold)).tracking(2.4).foregroundStyle(.white.opacity(0.94))
            Rectangle().fill(SystemTheme.cyan.opacity(0.55)).frame(height: 1)
        }
    }
}

struct SystemDivider: View {
    var body: some View {
        HStack(spacing: 6) {
            Rectangle().fill(SystemTheme.cyan.opacity(0.38)).frame(height: 1)
            Diamond().fill(SystemTheme.cyan.opacity(0.8)).frame(width: 5, height: 5)
            Rectangle().fill(SystemTheme.cyan.opacity(0.38)).frame(height: 1)
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
                    Capsule().fill(Color.black.opacity(0.42))
                    Capsule().fill(LinearGradient(colors: [SystemTheme.cyan.opacity(0.72), .blue.opacity(0.9)], startPoint: .leading, endPoint: .trailing)).frame(width: proxy.size.width * min(max(progress, 0), 1)).shadow(color: SystemTheme.cyan.opacity(0.36), radius: 3)
                }.overlay(Capsule().stroke(SystemTheme.cyan.opacity(0.7), lineWidth: 1))
            }.frame(height: 10)
        }
    }
}

struct StatLine: View {
    let label: String; let value: String
    var body: some View {
        HStack { Text(label.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(SystemTheme.muted); Spacer(); Text(value).font(.subheadline.monospacedDigit().weight(.medium)).foregroundStyle(.white) }
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

#Preview { ContentView() }
