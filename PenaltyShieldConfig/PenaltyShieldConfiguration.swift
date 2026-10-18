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
    /// Mirrors `EmergencyGroup` in the app. Keep the strings in step.
    static let suiteName = "group.devplaceholder.HDDJMVMX.thesystem"
    static let lockdownKindKey = "emergencyLockdownKind"
    static let lockdownEndsAtKey = "emergencyLockdownEndsAt"

    static func make() -> ShieldConfiguration {
        if let emergency = emergencyCopy() { return emergency }
        return ShieldConfiguration(
            backgroundBlurStyle: .systemThickMaterialDark,
            backgroundColor: UIColor(red: 0.012, green: 0.035, blue: 0.09, alpha: 1),
            icon: nil,
            title: ShieldConfiguration.Label(text: "Penalty Zone", color: .white),
            subtitle: ShieldConfiguration.Label(text: "Clear the penalty quest in The System.", color: .white),
            primaryButtonLabel: ShieldConfiguration.Label(text: "Open The System", color: .black),
            primaryButtonBackgroundColor: UIColor(red: 0.24, green: 0.72, blue: 1.0, alpha: 1)
        )
    }

    /// An active emergency lockdown replaces the penalty copy. The end time is fixed text: shields cannot count down.
    private static func emergencyCopy() -> ShieldConfiguration? {
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        guard let kind = defaults.string(forKey: lockdownKindKey) else { return nil }
        let ends = Date(timeIntervalSince1970: defaults.double(forKey: lockdownEndsAtKey))
        guard ends > Date() || kind == "low_steps" else { return nil }
        let time = ends.formatted(date: .omitted, time: .shortened)
        let title: String
        let subtitle: String
        if kind == "bedtime_lockdown" {
            title = "EMERGENCY QUEST: LIGHTS OUT"
            subtitle = "It is past bedtime. Put your phone down.\nThe lockdown ends at \(time)."
        } else {
            title = "EMERGENCY QUEST: MOVEMENT"
            subtitle = "Walk now. These apps unlock when the walk is done.\nTime limit: \(time)."
        }
        return ShieldConfiguration(
            backgroundBlurStyle: .systemThickMaterialDark,
            backgroundColor: UIColor(red: 0.012, green: 0.035, blue: 0.09, alpha: 1),
            icon: nil,
            title: ShieldConfiguration.Label(text: title, color: UIColor(red: 1, green: 0.32, blue: 0.36, alpha: 1)),
            subtitle: ShieldConfiguration.Label(text: subtitle, color: .white),
            primaryButtonLabel: ShieldConfiguration.Label(text: "Close", color: .black),
            primaryButtonBackgroundColor: UIColor(red: 0.24, green: 0.72, blue: 1.0, alpha: 1)
        )
    }
}
