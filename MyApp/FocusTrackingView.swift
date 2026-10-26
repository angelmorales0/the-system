import SwiftUI

#if os(iOS)
import FamilyControls
#endif

/// Opens from the FOC targets. Chooses what iOS counts as screen time and social media, and explains the Mac tracker.
struct FocusTrackingView: View {
    #if os(iOS)
    @State private var all = FocusTracking.loadSelection(social: false)
    @State private var social = FocusTracking.loadSelection(social: true)
    @State private var pickingAll = false
    @State private var pickingSocial = false
    #endif

    var body: some View {
        QuestSheet(title: "Focus tracking") {
            #if os(iOS)
            QuestSectionTitle(text: "iPhone")
            VStack(alignment: .leading, spacing: 12) {
                pickerButton("All apps", summary: summary(all)) { pickingAll = true }
                note("Select every category. iOS counts screen time only for the apps and categories chosen here.")
                pickerButton("Social apps", summary: summary(social)) { pickingSocial = true }
                note("Select the social apps and sites. Without them, the social media target has no data.")
                note("Counting starts at the next 5:00. iOS reports thresholds, not exact minutes, so each day reads as the highest threshold reached.")
            }
            .familyActivityPicker(isPresented: $pickingAll, selection: $all)
            .familyActivityPicker(isPresented: $pickingSocial, selection: $social)
            .onChange(of: all) { _, next in FocusTracking.save(next, social: false) }
            .onChange(of: social) { _, next in FocusTracking.save(next, social: true) }
            #else
            note("Screen Time tracking runs on iPhone.")
            #endif

            QuestSectionTitle(text: "Mac")
            VStack(alignment: .leading, spacing: 12) {
                note("Run FocusTracker on your Mac. It counts active Mac time and time on social sites, then saves each finished day to your private iCloud. The app adds those minutes to the iPhone's.")
                note("A day counts only when the iPhone logged it. A day with no Mac data counts the iPhone alone.")
            }
        }
        .font(.subheadline)
        .tint(SystemTheme.accent)
        .navigationBarTitleDisplayMode(.inline)
    }

    #if os(iOS)
    private func summary(_ selection: FamilyActivitySelection) -> String {
        let categories = selection.categoryTokens.count
        let apps = selection.applicationTokens.count
        let sites = selection.webDomainTokens.count
        if categories + apps + sites == 0 { return "Not set" }
        return "\(categories) categories, \(apps) apps, \(sites) sites"
    }
    #endif

    /// Boxed like the quest window's header boxes.
    private func pickerButton(_ title: String, summary: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(0.8)
                Spacer()
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(SystemTheme.muted)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 38)
            .overlay { Rectangle().stroke(QuestLight.ink.opacity(0.6), lineWidth: 0.8) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(SystemTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}
