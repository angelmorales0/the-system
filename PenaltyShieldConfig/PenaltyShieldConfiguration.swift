import ManagedSettings
import ManagedSettingsUI
import UIKit

/// Branding for a shielded distractor. This does not clear the shield.
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
    static func make() -> ShieldConfiguration {
        ShieldConfiguration(
            backgroundBlurStyle: .systemThickMaterialDark,
            backgroundColor: UIColor(red: 0.012, green: 0.035, blue: 0.09, alpha: 1),
            icon: nil,
            title: ShieldConfiguration.Label(text: "Penalty Zone", color: .white),
            subtitle: ShieldConfiguration.Label(text: "Clear the penalty quest in The System.", color: .white),
            primaryButtonLabel: ShieldConfiguration.Label(text: "Open The System", color: .black),
            primaryButtonBackgroundColor: UIColor(red: 0.24, green: 0.72, blue: 1.0, alpha: 1)
        )
    }
}
