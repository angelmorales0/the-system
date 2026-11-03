import SwiftUI

#if os(iOS)
import FamilyControls
#endif

/// Additive sheet. The four swipe screens stay as they are.
/// Two lists: the apps a penalty or an emergency quest leaves open, and the apps a penalty hides.
struct PenaltyTargetsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: GameStore

    private enum List: String, CaseIterable, Identifiable {
        case allowed = "Allowed"
        case hidden = "Hidden"
        var id: String { rawValue }
    }

    @State private var list = List.allowed
    #if os(iOS)
    @State private var allowed = PenaltySelectionStore.load(key: PenaltyGroup.allowedSelectionKey)
    @State private var hidden = PenaltySelectionStore.load(key: PenaltyGroup.hiddenSelectionKey, entireCategory: true)
    #endif
    @State private var accessError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SystemPanel {
                    VStack(alignment: .leading, spacing: 14) {
                        QuestInfoHeader(title: "PENALTY ZONE")
                        Picker("List", selection: $list) {
                            ForEach(List.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        if let accessError {
                            Text(accessError)
                                .font(.footnote)
                                .foregroundStyle(SystemTheme.muted)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                // Apple's picker draws its own list. It cannot take the quest window style.
                #if os(iOS)
                switch list {
                case .allowed: FamilyActivityPicker(selection: $allowed)
                case .hidden: FamilyActivityPicker(selection: $hidden)
                }
                #else
                Text("Family Controls runs on iPhone. The steps are in docs/PHASE7_DEVICE.md.")
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
        PenaltySelectionStore.save(allowed, key: PenaltyGroup.allowedSelectionKey)
        PenaltySelectionStore.save(hidden, key: PenaltyGroup.hiddenSelectionKey)
        #endif
        // Also reapplies an open penalty, so new lists take effect at once.
        store.saveTargetSelections()
        dismiss()
    }

    private func requestAccess() async {
        #if os(iOS)
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
        } catch {
            accessError = "Family Controls was not granted. The penalty lock and the Penalty Zone stay off until it is."
        }
        #endif
    }
}
