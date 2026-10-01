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
                                    store.toggleQuest(id: quest.id)
                                } label: {
                                    HStack {
                                        Text(quest.title).foregroundStyle(.white)
                                        Spacer()
                                        Text(quest.progress.bracketLabel).font(.subheadline.monospacedDigit()).foregroundStyle(SystemTheme.muted)
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
                                .accessibilityValue(quest.status == .completed ? "Completed" : "Not completed")
                            }
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

#Preview {
    SystemView()
        .environmentObject(GameStore(persistence: .memory))
}
