import SwiftUI

/// Opens from the gear on the STATUS window: rest days, the No Gym and sound checkboxes, the other settings screens,
/// and every connection with its checkbox.
struct StatusSettingsSheet: View {
    @EnvironmentObject private var store: GameStore
    @State private var confirmRest = false
    @State private var showShields = false
    @State private var showScreenTime = false
    @State private var showAppIcon = false
    @State private var showHabits = false
    @State private var confirmHome = false
    @AppStorage(SoundPlayer.enabledKey) private var soundOn = true

    var body: some View {
        QuestSheet(title: "Settings") {
            VStack(spacing: 20) {
                restDayButton
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
                link("HABITS") { showHabits = true }
                link("PENALTY ZONE") { showShields = true }
                link("SCREEN TIME") { showScreenTime = true }
                link("APP ICON") { showAppIcon = true }
                homeRow
                SystemDivider()
                ConnectionRows()
            }
        }
        .confirmationDialog("Set this place as home?", isPresented: $confirmHome, titleVisibility: .visible) {
            Button("Set home here") { store.setHomeHere() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Home by starts tomorrow and holds every day, rest days too. The System needs Always location access; it saves only when you come home and leave.")
        }
        .confirmationDialog("Use one rest day?", isPresented: $confirmRest, titleVisibility: .visible) {
            Button("Use rest day") { store.useRestDay() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Today becomes a rest day. Finished quests stay done.")
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
        .sheet(isPresented: $showHabits, onDismiss: { SystemSound.systemClose.play() }) {
            HabitsEditorSheet()
        }
    }

    /// Home for Home by 9 pm: set it once, here, at home.
    private var homeRow: some View {
        Button {
            SystemSound.systemOpen.play()
            confirmHome = true
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("HOME")
                        .font(.caption.weight(.semibold))
                        .tracking(1.1)
                        .foregroundStyle(SystemTheme.muted)
                    Text(store.snapshot.habits.homeSet ? "Set. Tap to set it again here." : "Not set. Tap here at home.")
                        .font(.caption)
                        .foregroundStyle(QuestLight.ink.opacity(0.8))
                }
                Spacer()
                Image(systemName: "house.fill")
                    .font(.title3)
                    .foregroundStyle(SystemTheme.cyan)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("setHomeButton")
    }

    /// This week's free rest days: the ones left, out of the 2 each week gives.
    private var restDayButton: some View {
        let day = store.snapshot.bundle.dayKey
        let left = store.snapshot.restDaysLeft(on: day)
        return Button {
            confirmRest = true
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("REST DAYS")
                        .font(.caption.weight(.semibold))
                        .tracking(1.1)
                        .foregroundStyle(SystemTheme.muted)
                    Text("\(left)/\(RestDays.allowance(on: day))")
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
                Spacer()
                Image(systemName: "moon.fill")
                    .font(.title2)
                    .foregroundStyle(SystemTheme.cyan)
                    .shadow(color: SystemTheme.cyan.opacity(0.35), radius: 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(left == 0 || store.snapshot.bundle.mode == .fullRecovery || store.player.penaltyOpen)
        .opacity(left == 0 || store.snapshot.bundle.mode == .fullRecovery ? 0.45 : 1)
        .accessibilityIdentifier("restDayButton")
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
