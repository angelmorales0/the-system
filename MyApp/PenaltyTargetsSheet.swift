import SwiftUI

#if os(iOS)
import FamilyControls
#endif

/// Additive sheet. The four swipe screens stay as they are.
/// Three lists: the distractors for emergency quests, the apps a penalty leaves open, and the apps a penalty hides.
struct PenaltyTargetsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: GameStore

    private enum List: String, CaseIterable, Identifiable {
        case distractors = "Distractors"
        case allowed = "Allowed"
        case hidden = "Hidden"
        var id: String { rawValue }

        var note: String {
            switch self {
            case .distractors:
                return "Apps, categories, and sites to shield during a walk or stretch emergency quest."
            case .allowed:
                return "Apps that stay open during a penalty. Pick The System, Strava, and Spotify. Every other app and every website locks."
            case .hidden:
                return "Apps that leave the Home Screen during a penalty. Pick all apps; the allowed apps always stay. Settings and Phone cannot be hidden."
            }
        }
    }

    @State private var list = List.allowed
    #if os(iOS)
    @State private var distractors = PenaltySelectionStore.load()
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
                        Text(accessError ?? list.note)
                            .font(.footnote)
                            .foregroundStyle(SystemTheme.muted)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                // Apple's picker draws its own list. It cannot take the quest window style.
                #if os(iOS)
                switch list {
                case .distractors: FamilyActivityPicker(selection: $distractors)
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
        PenaltySelectionStore.save(distractors)
        PenaltySelectionStore.save(allowed, key: PenaltyGroup.allowedSelectionKey)
        PenaltySelectionStore.save(hidden, key: PenaltyGroup.hiddenSelectionKey)
        #endif
        // Also reapplies an open penalty, so new lists take effect at once.
        store.saveDistractorSelection()
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
