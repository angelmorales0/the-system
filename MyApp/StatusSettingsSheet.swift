import SwiftUI

/// Opens from the gear on the STATUS window: Full Recovery, the No Gym and sound checkboxes, and the other settings screens. The shop opens from the STATUS window.
struct StatusSettingsSheet: View {
    @EnvironmentObject private var store: GameStore
    @State private var confirmRecovery = false
    @State private var showShields = false
    @State private var showScreenTime = false
    @State private var showAppIcon = false
    @State private var showConnections = false
    @AppStorage(SoundPlayer.enabledKey) private var soundOn = true

    var body: some View {
        QuestSheet(title: "Settings") {
            VStack(spacing: 20) {
                Button {
                    confirmRecovery = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("FULL RECOVERY")
                                .font(.caption.weight(.semibold))
                                .tracking(1.1)
                                .foregroundStyle(SystemTheme.muted)
                            Text("x\(store.player.fullRecoveryBank)")
                                .font(.title2.weight(.bold))
                                .foregroundStyle(.white)
                        }
                        Spacer()
                        Image(systemName: "bolt.fill")
                            .font(.title2)
                            .foregroundStyle(SystemTheme.cyan)
                            .shadow(color: SystemTheme.cyan.opacity(0.35), radius: 4)
                    }
                }
                .buttonStyle(.plain)
                Toggle(isOn: Binding(
                    get: { store.snapshot.noGymToday },
                    set: { store.setNoGym($0) }
                )) {
                    Text("NO GYM AVAILABLE")
                        .font(.caption.weight(.semibold))
                        .tracking(1.1)
                        .foregroundStyle(SystemTheme.muted)
                }
                .toggleStyle(QuestCheckToggleStyle())
                .disabled(store.snapshot.bundle.mode != .performanceTraining)
                Toggle(isOn: $soundOn) {
                    Text("SOUND")
                        .font(.caption.weight(.semibold))
                        .tracking(1.1)
                        .foregroundStyle(SystemTheme.muted)
                }
                .toggleStyle(QuestCheckToggleStyle())
                // A sample on switch-on, so the new setting is heard at once.
                .onChange(of: soundOn) { _, on in
                    if on { SystemSound.systemOpen.play() }
                }
                SystemDivider()
                link("PENALTY ZONE") { showShields = true }
                link("SCREEN TIME") { showScreenTime = true }
                link("CONNECTIONS") { showConnections = true }
                link("APP ICON") { showAppIcon = true }
            }
        }
        .confirmationDialog("Spend one Full Recovery token?", isPresented: $confirmRecovery, titleVisibility: .visible) {
            Button("Spend token") { store.spendFullRecovery() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Today becomes a rest day. Finished quests stay done. Missed training does not open a penalty today.")
        }
        .sheet(isPresented: $showShields, onDismiss: { SystemSound.systemClose.play() }) {
            PenaltyTargetsSheet()
        }
        .sheet(isPresented: $showScreenTime, onDismiss: { SystemSound.systemClose.play() }) {
            ScreenTimeSheet()
        }
        .sheet(isPresented: $showAppIcon, onDismiss: { SystemSound.systemClose.play() }) {
            AppIconSheet()
        }
        .sheet(isPresented: $showConnections, onDismiss: { SystemSound.systemClose.play() }) {
            ConnectionsSheet()
        }
    }

    /// Every link opens a System window, so each one plays the open cue.
    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: { SystemSound.systemOpen.play(); action() }) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .tracking(1.1)
                    .foregroundStyle(SystemTheme.muted)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(SystemTheme.muted.opacity(0.7))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    StatusSettingsSheet()
        .environmentObject(GameStore(persistence: .memory))
}

/// A settings switch drawn as the quest checkbox: checked when on. The whole row toggles it.
/// A disabled switch dims, like a row the player cannot act on today.
struct QuestCheckToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 11) {
                configuration.label
                    .frame(maxWidth: .infinity, alignment: .leading)
                QuestCheckbox(checked: configuration.isOn)
                    .frame(width: 16, height: 17)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}
