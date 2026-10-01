import SwiftUI

struct SystemView: View {
    @EnvironmentObject private var store: GameStore

    var body: some View {
        ScreenContainer {
            GeometryReader { proxy in
                VStack {
                    Spacer(minLength: 32)
                    SystemPanel {
                        VStack(spacing: 0) {
                        Text("[Daily Quest: \(store.bundle.headerLine)\nhas arrived.]")
                            .font(.subheadline.weight(.medium))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.94))

                        if let banner = store.targetBanner {
                            Text(banner)
                                .font(.caption2.weight(.semibold))
                                .tracking(0.6)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(SystemTheme.cyan)
                                .padding(.top, 8)
                        }

                        Spacer()

                        Text("GOAL")
                            .font(.title2.weight(.bold))
                            .tracking(3)
                            .foregroundStyle(.white)
                        SystemDivider()
                            .padding(.top, 10)
                            .padding(.bottom, 30)

                        VStack(spacing: 19) {
                            ForEach(store.goalQuests) { quest in
                                Button {
                                    store.handleQuestTap(id: quest.id)
                                } label: {
                                    HStack {
                                        Text(quest.kind == .targetInjection ? "⟪TARGET⟫ \(quest.title)" : quest.title)
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(store.rowLabel(for: quest)).font(.subheadline.monospacedDigit()).foregroundStyle(SystemTheme.muted)
                                        Image(systemName: quest.status == .completed ? "checkmark.square.fill" : "square")
                                            .font(.body)
                                            .foregroundStyle(SystemTheme.cyan)
                                    }
                                    .font(.subheadline)
                                    .frame(maxWidth: .infinity)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(quest.title)
                                .accessibilityHint(questRowHint(quest))
                                .accessibilityValue(store.accessibilityValue(for: quest))
                            }
                        }

                        if let note = store.verificationNote, !note.isEmpty {
                            Text(note)
                                .font(.caption)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(SystemTheme.muted)
                                .padding(.top, 14)
                        }

                        Spacer()

                        SystemDivider()
                            .padding(.bottom, 18)
                        Text("WARNING:")
                            .font(.caption.weight(.bold))
                            .tracking(1.8)
                            .foregroundStyle(SystemTheme.cyan)
                        Text(store.bundle.warningCopy)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(SystemTheme.muted)
                            .padding(.top, 8)
                    }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .padding(.horizontal, 24)
                    .frame(height: min(proxy.size.height * 0.79, 650))
                    Spacer(minLength: 22)
                }
            }
        }
    }
}

private func questRowHint(_ quest: Quest) -> String {
    switch quest.verification.method {
    case .timerSession:
        return "Starts the in-app timer"
    case .manualConfirm:
        return "Confirms this quest"
    default:
        return "Checks this quest on this device"
    }
}

#Preview {
    SystemView()
        .environmentObject(GameStore(persistence: .memory))
}
