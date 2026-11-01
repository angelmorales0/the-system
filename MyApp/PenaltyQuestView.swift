import Combine
import CoreMotion
import SwiftUI

/// Covers every page while a penalty is open. The window is the System's urgent quest window:
/// flat, leaning a little as the phone moves, with every line drawn twice (a dim copy sunk under the bright one), and it arrives with a flicker.
/// The longer the penalty stays open, the more the screen rots around it (see `PenaltyDecay`):
/// gray creeps in from the edges, the edge turns blood red and pulses, then everything outside blurs.
/// There is no close button. The screen leaves when the penalty run is verified from Apple Health.
struct PenaltyQuestView: View {
    @EnvironmentObject private var store: GameStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let quest: Quest
    let startedAt: Date
    @State private var arrived = false
    @State private var flicker = false
    @StateObject private var tilt = MotionTilt()

    /// In DEBUG, launch with `-penaltyPreviewHours 12` to draw the screen as if the penalty were that old.
    static var previewHours: Double? {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "penaltyPreviewHours").flatMap(Double.init)
        #else
        return nil
        #endif
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let hours = Self.previewHours ?? PenaltyDecay.hours(since: startedAt, now: timeline.date)
            let clear = PenaltyDecay.clear(hours: hours)
            let blood = PenaltyDecay.blood(hours: hours)
            let beat = PenaltyDecay.beat(hours: hours)
            let ghost = PenaltyDecay.ghost(hours: hours)
            let pulse = reduceMotion ? 0.0 : (1 - cos(timeline.date.timeIntervalSinceReferenceDate * 2 * .pi / beat)) / 2
            GeometryReader { proxy in
                let radius = hypot(proxy.size.width, proxy.size.height) / 2
                ZStack {
                    scene(ghost: ghost)
                    // The same scene, gray and blurred, shown only outside the clear circle.
                    scene(ghost: ghost)
                        .saturation(0)
                        .contrast(0.92)
                        .blur(radius: PenaltyDecay.blur(hours: hours))
                        .mask {
                            RadialGradient(stops: [.init(color: .clear, location: clear),
                                                   .init(color: .black, location: min(1, clear + 0.28))],
                                           center: .center, startRadius: 0, endRadius: radius)
                        }
                        .allowsHitTesting(false)
                    // Blood at the edge, pulsing. Deep, almost black red, never bright.
                    RadialGradient(stops: [.init(color: .clear, location: max(0, clear - 0.05)),
                                           .init(color: Color(red: 0.30, green: 0, blue: 0.05).opacity(0.35), location: min(1, clear + 0.15)),
                                           .init(color: Color(red: 0.12, green: 0, blue: 0.02).opacity(0.92), location: 1.2)],
                                   center: .center, startRadius: 0, endRadius: radius)
                        .opacity(blood * (1 - 0.22 * pulse))
                        .allowsHitTesting(false)
                }
            }
            .ignoresSafeArea()
        }
        .accessibilityAddTraits(.isModal)
        .onAppear(perform: arrive)
    }

    private func scene(ghost: Double) -> some View {
        ZStack {
            QuestBackdrop()
            window(ghost: ghost)
                .padding(.horizontal, 26)
                .padding(.vertical, 40)
        }
    }

    private func window(ghost: Double) -> some View {
        QuestHologram {
            content(ghost: ghost)
                .padding(.horizontal, 26)
                .padding(.top, 28)
                .padding(.bottom, 30)
        }
        .frame(maxWidth: 420)
        // Flat at rest, as the app draws its window. It leans a little with the phone (see `MotionTilt`).
        .rotation3DEffect(.degrees(tilt.pitch), axis: (x: 1, y: 0, z: 0))
        .rotation3DEffect(.degrees(tilt.roll), axis: (x: 0, y: 1, z: 0))
        .opacity(flicker ? 0.55 : (arrived ? 1 : 0))
        .scaleEffect(arrived ? 1 : 0.86)
        .blur(radius: arrived ? 0 : 6)
        .offset(y: arrived ? 0 : 30)
        .contentShape(Rectangle())
        // A tap asks Apple Health again, so a finished run clears the screen without waiting.
        .onTapGesture { store.refreshForToday() }
    }

    /// `ghost` is how strong the dim copy under each line draws: none when fresh, the scene's look after a few hours.
    private func content(ghost: Double) -> some View {
        VStack(spacing: 0) {
            QuestInfoHeader()
            Spacer().frame(height: 18)
            GhostText(Text("[Urgent Quest: \(Text("10K Run.").bold().italic())]"), font: .footnote, alignment: .center, ghost: ghost)
            Spacer().frame(height: 26)
            VStack(spacing: 3) {
                GhostText(Text("GOAL").tracking(3), font: .system(.title2).weight(.medium), alignment: .center, ghost: ghost)
                    .shadow(color: QuestLight.cyan, radius: 7)
                Rectangle().fill(QuestLight.ink.opacity(0.85)).frame(width: 64, height: 1)
            }
            .accessibilityAddTraits(.isHeader)
            Spacer().frame(height: 26)
            GhostText(Text(threat), font: .subheadline, alignment: .leading, lineSpacing: 10, ghost: ghost)
                .shadow(color: QuestLight.blue.opacity(0.7), radius: 5)
            Spacer().frame(height: 30)
            GhostText(Text(warning), font: .subheadline, alignment: .leading, lineSpacing: 9, ghost: ghost)
                .shadow(color: QuestLight.blue.opacity(0.7), radius: 6)
            Spacer().frame(height: 26)
            HStack(spacing: 11) {
                Text("10K RUN")
                    .tracking(1.6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(progress)
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
                QuestCheckbox(checked: quest.status == .completed)
                    .frame(width: 16, height: 17)
            }
            .font(.footnote)
            .foregroundStyle(QuestLight.cyan)
            .shadow(color: QuestLight.cyan.opacity(0.6), radius: 5)
            .accessibilityElement(children: .combine)
        }
        .foregroundStyle(QuestLight.ink)
    }

    /// The generator's two sentences for today, or the app's own: `Laziness is present and is damaging the Player.
    /// Run 10 km and ensure your safety.`
    private var threat: String {
        PenaltyDecay.threatLine(generated: store.snapshot.bundle.threat, dayKey: store.snapshot.bundle.dayKey)
    }

    private var progress: String {
        let current = quest.progress.current, target = quest.progress.target
        let shown = min(current, target)
        return "[\(String(format: "%.1f", shown))/\(target == target.rounded() ? String(Int(target)) : String(target))\(quest.progress.unit)]"
    }

    /// The System's wording, with the threat in red. The word "penalty" never appears: the run is the way out, not the threat.
    private var warning: AttributedString {
        var text = AttributedString("WARNING: If you do not complete this quest, the damage will not stop.")
        if let range = text.range(of: "damage") {
            text[range].foregroundColor = QuestLight.penalty
        }
        return text
    }

    /// Fades and sharpens the window in, then flickers it three times, as the scene does.
    private func arrive() {
        guard !arrived else { return }
        SystemSound.penaltyOpen.play()
        if reduceMotion {
            arrived = true
            return
        }
        withAnimation(.easeOut(duration: 0.9)) { arrived = true }
        Task { @MainActor in
            for _ in 0..<3 {
                try? await Task.sleep(for: .milliseconds(300))
                flicker = true
                try? await Task.sleep(for: .milliseconds(90))
                flicker = false
            }
        }
    }
}

/// The phone's lean since the screen opened, in degrees, clamped small. Flat on a Mac or in the Simulator.
@MainActor
final class MotionTilt: ObservableObject {
    static let maxDegrees = 4.0
    @Published private(set) var pitch = 0.0
    @Published private(set) var roll = 0.0
    private let manager = CMMotionManager()
    private var rest: (pitch: Double, roll: Double)?

    init() {
        guard manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1 / 30
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let attitude = motion?.attitude else { return }
            // The first reading is the resting position, so the window starts flat however the phone is held.
            let rest = self.rest ?? (attitude.pitch, attitude.roll)
            self.rest = rest
            self.pitch = Self.clamp((attitude.pitch - rest.pitch) * 180 / .pi * 0.5)
            self.roll = Self.clamp((attitude.roll - rest.roll) * 180 / .pi * 0.5)
        }
    }

    private static func clamp(_ degrees: Double) -> Double {
        min(max(degrees, -maxDegrees), maxDegrees)
    }

    deinit {
        manager.stopDeviceMotionUpdates()
    }
}

/// A line of the window drawn twice: the bright text, and a dim blurred copy sunk a little below it.
/// `ghost` is the copy's opacity: 0 keeps the line crisp.
private struct GhostText: View {
    let text: Text
    let font: Font
    let alignment: TextAlignment
    var lineSpacing: CGFloat = 0
    var ghost: Double

    init(_ text: Text, font: Font, alignment: TextAlignment, lineSpacing: CGFloat = 0, ghost: Double) {
        self.text = text
        self.font = font
        self.alignment = alignment
        self.lineSpacing = lineSpacing
        self.ghost = ghost
    }

    var body: some View {
        ZStack {
            if ghost > 0 {
                line.opacity(ghost).blur(radius: 0.6).offset(y: 6).accessibilityHidden(true)
            }
            line
        }
    }

    private var line: some View {
        text
            .font(font)
            .lineSpacing(lineSpacing)
            .multilineTextAlignment(alignment)
            .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview {
    let store = GameStore(persistence: .memory)
    return PenaltyQuestView(quest: store.snapshot.bundle.quests[0], startedAt: .now.addingTimeInterval(-12 * 3600))
        .environmentObject(store)
}
