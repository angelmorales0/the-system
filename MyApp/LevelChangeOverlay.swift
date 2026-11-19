import SwiftUI

/// The overall level went up (cyan) or down (red). Covers every page until OK.
struct LevelChangeOverlay: View {
    @EnvironmentObject private var store: GameStore
    @State private var glow = false

    private var change: LevelChange? {
        #if DEBUG
        // Launch with LEVEL_PREVIEW=up or LEVEL_PREVIEW=down to see the card (screenshots).
        if store.pendingLevelChange == nil, let preview = ProcessInfo.processInfo.environment["LEVEL_PREVIEW"],
           !UserDefaults.standard.bool(forKey: "levelPreviewSeen") {
            let up = preview != "down"
            return LevelChange(from: up ? 41 : 42, to: up ? 42 : 41,
                               stats: [.init(stat: .STR, from: up ? 120 : 128, to: up ? 128 : 120), .init(stat: .END, from: 98, to: up ? 101 : 96)])
        }
        #endif
        return store.pendingLevelChange
    }

    var body: some View {
        if let change {
            let color = change.rose ? QuestLight.cyan : QuestLight.penalty
            ZStack {
                Color.black.opacity(0.94).ignoresSafeArea()
                VStack(spacing: 18) {
                    Image(systemName: change.rose ? "arrow.up.circle" : "arrow.down.circle")
                        .font(.system(size: 54, weight: .light))
                        .foregroundStyle(color)
                        .shadow(color: color.opacity(glow ? 0.9 : 0.3), radius: glow ? 16 : 6)
                    Text(change.rose ? "LEVEL UP" : "LEVEL DOWN")
                        .font(.system(size: 34, weight: .heavy))
                        .tracking(4)
                        .foregroundStyle(color)
                        .shadow(color: color.opacity(glow ? 0.9 : 0.3), radius: glow ? 14 : 4)
                    HStack(spacing: 14) {
                        Text("LV. \(change.from)")
                            .foregroundStyle(QuestLight.ink.opacity(0.5))
                        Image(systemName: "arrow.right")
                            .foregroundStyle(color)
                        Text("LV. \(change.to)")
                            .foregroundStyle(QuestLight.ink)
                    }
                    .font(.title2.weight(.semibold).monospacedDigit())
                    if !change.stats.isEmpty {
                        VStack(spacing: 6) {
                            ForEach(change.stats, id: \.stat) { move in
                                HStack {
                                    Text(move.stat.fullName.uppercased())
                                        .tracking(1)
                                    Spacer()
                                    Text("\(move.from) → \(move.to)")
                                        .monospacedDigit()
                                        .foregroundStyle(move.to > move.from ? QuestLight.cyan : QuestLight.penalty)
                                }
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(QuestLight.ink)
                            }
                        }
                        .padding(14)
                        .overlay { Rectangle().stroke(color.opacity(0.5), lineWidth: 0.8) }
                    }
                    Button {
                        #if DEBUG
                        UserDefaults.standard.set(true, forKey: "levelPreviewSeen")
                        #endif
                        store.acknowledgeLevelChange()
                    } label: {
                        Text("OK")
                            .font(.caption.weight(.semibold))
                            .tracking(1)
                            .foregroundStyle(QuestLight.ink)
                            .frame(width: 140, height: 40)
                            .overlay { Rectangle().stroke(QuestLight.ink.opacity(0.7), lineWidth: 0.8) }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("levelChangeOK")
                }
                .padding(.horizontal, 36)
            }
            .transition(.opacity)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { glow = true }
            }
        }
    }
}
