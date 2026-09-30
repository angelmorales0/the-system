import SwiftUI

struct SystemView: View {
    private let quests = [("Run Intervals", "[0/6]"), ("Bench Press", "[0/4]"), ("Mobility", "[0/10min]"), ("Protein", "[0/150g]")]
    var body: some View {
        ScreenContainer {
            GeometryReader { proxy in
                VStack {
                    Spacer(minLength: 32)
                    SystemPanel {
                        VStack(spacing: 0) {
                        Text("[Daily Quest: Performance Training\nhas arrived.]")
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
                            ForEach(quests, id: \.0) { quest in
                                HStack {
                                    Text(quest.0).foregroundStyle(.white)
                                    Spacer()
                                    Text(quest.1).font(.subheadline.monospacedDigit()).foregroundStyle(SystemTheme.muted)
                                    Image(systemName: "square").font(.body).foregroundStyle(SystemTheme.cyan)
                                }
                                .font(.subheadline)
                            }
                        }

                        Spacer()

                        SystemDivider()
                            .padding(.bottom, 18)
                        Text("WARNING:")
                            .font(.caption.weight(.bold))
                            .tracking(1.8)
                            .foregroundStyle(SystemTheme.cyan)
                        Text("Failure to complete\nthe daily quest will result\nin a penalty.")
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

#Preview { SystemView() }
