import SwiftUI

/// Opens from the gear on the STATUS window: Full Recovery, the No Gym toggle, the shop, and the other settings screens.
struct StatusSettingsSheet: View {
    @EnvironmentObject private var store: GameStore
    @State private var confirmRecovery = false
    @State private var showShields = false
    @State private var showScreenTime = false
    @State private var showAppIcon = false
    @State private var showEmergency = false
    @State private var showConnections = false
    @State private var showShop = false

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
                    VStack(alignment: .leading, spacing: 3) {
                        Text("NO GYM AVAILABLE")
                            .font(.caption.weight(.semibold))
                            .tracking(1.1)
                            .foregroundStyle(SystemTheme.muted)
                        Text("Swap today's lifts for a second 10K")
                            .font(.caption2)
                            .foregroundStyle(SystemTheme.muted.opacity(0.8))
                    }
                }
                .tint(SystemTheme.cyan)
                .disabled(store.snapshot.bundle.mode != .performanceTraining)
                SystemDivider()
                link("SHOP") { showShop = true }
                link("PENALTY ZONE") { showShields = true }
                link("SCREEN TIME") { showScreenTime = true }
                link("EMERGENCY QUESTS") { showEmergency = true }
                link("CONNECTIONS") { showConnections = true }
                link("APP ICON") { showAppIcon = true }
            }
        }
        .confirmationDialog("Spend one Full Recovery token?", isPresented: $confirmRecovery, titleVisibility: .visible) {
            Button("Spend token") { store.spendFullRecovery() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A quiet morning switches today. A day already underway is queued for tomorrow. That day does not open a penalty if training is missed.")
        }
        .sheet(isPresented: $showShields) {
            PenaltyTargetsSheet()
        }
        .sheet(isPresented: $showScreenTime) {
            ScreenTimeSheet()
        }
        .sheet(isPresented: $showAppIcon) {
            AppIconSheet()
        }
        .sheet(isPresented: $showEmergency) {
            EmergencySettingsSheet()
        }
        .sheet(isPresented: $showConnections) {
            ConnectionsSheet()
        }
        .sheet(isPresented: $showShop) {
            ShopSheet()
        }
    }

    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
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
