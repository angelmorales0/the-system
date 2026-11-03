import ManagedSettings
import ManagedSettingsUI
import UIKit

/// Branding for a shielded app. This does not clear the shield.
class PenaltyShieldConfiguration: ShieldConfigurationDataSource {
    override func configuration(shielding application: Application) -> ShieldConfiguration {
        PenaltyShieldCopy.make()
    }

    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        PenaltyShieldCopy.make()
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        PenaltyShieldCopy.make()
    }

    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
        PenaltyShieldCopy.make()
    }
}

enum PenaltyShieldCopy {
    /// Mirrors `PenaltyGroup.suiteName` in the app.
    static let suiteName = "group.com.angelmorales.thesystem"
    /// Mirrors `PenaltyGroup.shieldLineKey`.
    static let shieldLineKey = "penaltyShieldLine"

    static func make() -> ShieldConfiguration {
        // Only the penalty quest. The button sends a notification that opens The System.
        let line = (UserDefaults(suiteName: suiteName) ?? .standard).string(forKey: shieldLineKey) ?? "Penalty 10K"
        return ShieldConfiguration(
            backgroundBlurStyle: .systemThickMaterialDark,
            backgroundColor: UIColor(red: 0.012, green: 0.035, blue: 0.09, alpha: 1),
            icon: nil,
            title: ShieldConfiguration.Label(text: "PENALTY QUEST", color: UIColor(red: 1, green: 0.32, blue: 0.36, alpha: 1)),
            subtitle: ShieldConfiguration.Label(text: line, color: .white),
            primaryButtonLabel: ShieldConfiguration.Label(text: "Open The System", color: .black),
            primaryButtonBackgroundColor: UIColor(red: 0.24, green: 0.72, blue: 1.0, alpha: 1)
        )
    }
}
