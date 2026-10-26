import SwiftUI

#if os(iOS)
import FamilyControls
#endif

/// Picks what counts as phone screen time. Choose All Apps & Categories so every app on the phone counts.
struct ScreenTimeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: GameStore
    #if os(iOS)
    @State private var selection = PhoneScreenGroup.load()
    #endif
    @State private var message = "Choose All Apps & Categories so every app on this phone counts toward the daily cap. Phone 1.5 h and work 7 h turn red when over; only the 8.5 h total fails the quest and opens a penalty."

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SystemPanel {
                    VStack(alignment: .leading, spacing: 14) {
                        QuestInfoHeader(title: "SCREEN TIME")
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(SystemTheme.muted)
                        NavigationLink {
                            MacTrackerSettingsView()
                        } label: {
                            Text(MacScreenSettings.load().baseURL == nil ? "SET UP MAC TRACKER" : "MAC TRACKER")
                                .font(.caption2.weight(.semibold))
                                .tracking(0.8)
                                .frame(maxWidth: .infinity, minHeight: 34)
                                .overlay { Rectangle().stroke(QuestLight.ink.opacity(0.6), lineWidth: 0.8) }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                // Apple's picker draws its own list. It cannot take the quest window style.
                #if os(iOS)
                FamilyActivityPicker(selection: $selection)
                #else
                Text("Screen Time runs on iPhone.")
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                Spacer()
                #endif
            }
            .background { QuestBackdrop() }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .task { await requestAccess() }
        }
    }

    private func save() {
        #if os(iOS)
        PhoneScreenGroup.save(selection)
        #endif
        store.savePhoneScreenSelection()
        dismiss()
    }

    private func requestAccess() async {
        #if os(iOS)
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
        } catch {
            message = "Family Controls was not granted. Phone screen time cannot be counted until it is."
        }
        #endif
    }
}
