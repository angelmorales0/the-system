import SwiftUI

#if os(iOS)
import FamilyControls
#endif

/// Additive sheet. The four swipe screens stay as they are.
/// Three lists: the apps a penalty leaves open, the apps a penalty hides, and the apps the morning lock leaves open.
struct PenaltyTargetsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: GameStore

    private enum List: String, CaseIterable, Identifiable {
        case allowed = "Allowed"
        case hidden = "Hidden"
        case morning = "Morning"
        var id: String { rawValue }
    }

    @State private var list = List.allowed
    #if os(iOS)
    @State private var allowed = PenaltySelectionStore.load(key: PenaltyGroup.allowedSelectionKey)
    @State private var hidden = PenaltySelectionStore.load(key: PenaltyGroup.hiddenSelectionKey, entireCategory: true)
    @State private var morning = PenaltySelectionStore.load(key: PenaltyGroup.morningAllowedSelectionKey)
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
                        if list == .morning {
                            Text("Pick the apps that stay open during the morning lock: Hevy, Strava, Spotify, and The System. "
                                 + "While this list is empty, the morning lock uses the Allowed list.")
                                .font(.footnote)
                                .foregroundStyle(SystemTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
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
                case .morning: FamilyActivityPicker(selection: $morning)
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
        PenaltySelectionStore.save(morning, key: PenaltyGroup.morningAllowedSelectionKey)
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
        PenaltyEnforcement.requestNoticePermission()
        #endif
    }
}
