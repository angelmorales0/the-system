import SwiftUI

#if os(iOS)
import FamilyControls
#endif

/// Additive sheet. The four swipe screens stay as they are.
struct PenaltyTargetsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: GameStore
    #if os(iOS)
    @State private var selection = PenaltySelectionStore.load()
    #endif
    @State private var message = "Choose the distractor apps, categories, and sites to shield on a penalty day. This is not a full phone lock."

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(SystemTheme.muted)
                    .padding(.horizontal, 20)
                #if os(iOS)
                FamilyActivityPicker(selection: $selection)
                #else
                Text("Family Controls runs on iPhone. The steps are in docs/PHASE7_DEVICE.md.")
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                Spacer()
                #endif
            }
            .background(SystemTheme.background.ignoresSafeArea())
            .navigationTitle("Distractor shields")
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
        PenaltySelectionStore.save(selection)
        #endif
        store.saveDistractorSelection()
        dismiss()
    }

    private func requestAccess() async {
        #if os(iOS)
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
        } catch {
            message = "Family Controls was not granted. Shields stay off until it is."
        }
        #endif
    }
}
