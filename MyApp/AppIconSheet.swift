import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The home-screen icons the player can choose. `AppIcon` is the primary set;
/// `AppIconFull` is listed in ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES.
enum AppIconChoice: String, CaseIterable, Identifiable {
    case window = "AppIcon"
    case full = "AppIconFull"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .window: return "SYSTEM WINDOW"
        case .full: return "SYSTEM NOTICE"
        }
    }

    var subtitle: String {
        switch self {
        case .window: return "Will you accept?"
        case .full: return "Your heart will stop in 0.02 seconds."
        }
    }

    /// Small copies of the icons, kept as ordinary image sets so previews work on every platform.
    var previewName: String {
        switch self {
        case .window: return "AppIconPreviewWindow"
        case .full: return "AppIconPreviewFull"
        }
    }

    /// The name iOS expects: nil restores the primary icon.
    var alternateIconName: String? { self == .window ? nil : rawValue }

    static var current: AppIconChoice {
        #if os(iOS)
        if let name = UIApplication.shared.alternateIconName, let choice = AppIconChoice(rawValue: name) {
            return choice
        }
        #endif
        return .window
    }
}

/// Additive sheet. Picks the home-screen icon; iOS shows its own confirmation alert.
struct AppIconSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selected = AppIconChoice.current
    @State private var message: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Choose the icon shown on the Home Screen. iOS confirms each change with its own alert.")
                    .font(.footnote)
                    .foregroundStyle(SystemTheme.muted)
                    .padding(.horizontal, 20)
                ForEach(AppIconChoice.allCases) { choice in
                    Button { select(choice) } label: {
                        AppIconRow(choice: choice, isSelected: choice == selected)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                }
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                }
                Spacer()
            }
            .padding(.top, 12)
            .background(SystemTheme.background.ignoresSafeArea())
            .navigationTitle("App icon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func select(_ choice: AppIconChoice) {
        guard choice != selected else { return }
        #if os(iOS)
        guard UIApplication.shared.supportsAlternateIcons else {
            message = "This device does not support alternate icons."
            return
        }
        UIApplication.shared.setAlternateIconName(choice.alternateIconName) { error in
            DispatchQueue.main.async {
                if let error {
                    message = error.localizedDescription
                } else {
                    selected = choice
                    message = nil
                }
            }
        }
        #else
        message = "Alternate icons change only on iPhone and iPad."
        #endif
    }
}

private struct AppIconRow: View {
    let choice: AppIconChoice
    let isSelected: Bool

    var body: some View {
        SystemPanel(padding: 14) {
            HStack(spacing: 16) {
                Image(choice.previewName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(SystemTheme.cyan.opacity(isSelected ? 0.9 : 0.25), lineWidth: isSelected ? 2 : 1)
                    }
                VStack(alignment: .leading, spacing: 4) {
                    Text(choice.title)
                        .font(.caption.weight(.semibold))
                        .tracking(1.1)
                        .foregroundStyle(SystemTheme.muted)
                    Text(choice.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? SystemTheme.cyan : SystemTheme.muted.opacity(0.5))
            }
        }
    }
}

#Preview {
    AppIconSheet()
}
