import Foundation

/// One connection that stopped working, for the warning on the quest screen and the notification.
struct ConnectionProblem: Equatable, Identifiable {
    var id: String
    var title: String
    var detail: String
}

/// Watches every connection and warns when one stops working:
/// - a service whose last read or test failed (a bad key, an expired sign-in, the service down);
/// - a service that worked once and is no longer set up (its key or sign-in is gone);
/// - the Mac tracker when its Worker does not answer;
/// - Screen Time access off, and location not set to Always once a home is set.
/// A service never set up is not a problem. Each problem sends one notification until it is fixed.
enum ConnectionAlerts {
    static let everConnectedKey = "com.angelmorales.thesystem.connections.everConnected"
    static let notifiedKey = "com.angelmorales.thesystem.connections.notified"

    /// The problems now. Also remembers each service seen working, so a later "not set" counts as a disconnect.
    static func problems(health: [Connection: ConnectionHealth], mac: MacTrackerStatus?, screenTimeApproved: Bool?,
                         locationAlways: Bool?, defaults: UserDefaults = .standard) -> [ConnectionProblem] {
        var ever = Set(defaults.stringArray(forKey: everConnectedKey) ?? [])
        var result: [ConnectionProblem] = []
        for connection in Connection.allCases {
            switch health[connection] ?? .notSet {
            case .connected:
                ever.insert(connection.rawValue)
            case .error(let message):
                ever.insert(connection.rawValue)
                result.append(ConnectionProblem(id: connection.rawValue, title: "\(connection.title) is not working",
                                                detail: message.isEmpty ? "The last read failed." : message))
            case .notSet:
                if ever.contains(connection.rawValue) {
                    result.append(ConnectionProblem(id: connection.rawValue, title: "\(connection.title) is disconnected",
                                                    detail: "Its key or sign-in is gone. Set it up again in Connections."))
                }
            }
        }
        defaults.set(ever.sorted(), forKey: everConnectedKey)
        if mac == .unreachable {
            result.append(ConnectionProblem(id: "macTracker", title: "Mac tracker is not answering",
                                            detail: "The Worker did not reply, so Mac work minutes are not counted. Check the address and token."))
        }
        if screenTimeApproved == false {
            result.append(ConnectionProblem(id: "screenTime", title: "Screen Time access is off",
                                            detail: "The penalty lock, the morning lock, and the Screen Time row cannot work. Allow it in Settings → Screen Time."))
        }
        if locationAlways == false {
            result.append(ConnectionProblem(id: "location", title: "Location is not set to Always",
                                            detail: "Home by 9 pm cannot check when you get home. Set The System to Always in Settings → Privacy → Location Services."))
        }
        return result
    }

    /// The problems not yet notified. Saves the current ones, so a fixed problem notifies again if it comes back.
    static func newProblems(_ problems: [ConnectionProblem], defaults: UserDefaults = .standard) -> [ConnectionProblem] {
        let notified = Set(defaults.stringArray(forKey: notifiedKey) ?? [])
        defaults.set(problems.map(\.id).sorted(), forKey: notifiedKey)
        return problems.filter { !notified.contains($0.id) }
    }

    /// "Strava and Hevy", "Strava, Hevy and WHOOP".
    static func names(_ problems: [ConnectionProblem]) -> String {
        let names = problems.map { $0.title.components(separatedBy: " is ").first ?? $0.title }
        guard let last = names.last else { return "" }
        return names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " and " + last
    }

    // MARK: - Self-check (runs in DEBUG at launch)

    static func check() -> [String] {
        var errors: [String] = []
        let suite = "com.angelmorales.thesystem.selfcheck.connectionAlerts"
        guard let defaults = UserDefaults(suiteName: suite) else { return errors }
        defaults.removePersistentDomain(forName: suite)
        // Never set up: no problem. Working: none, but remembered.
        let quiet = problems(health: [.strava: .notSet, .hevy: .connected], mac: .notSet, screenTimeApproved: true, locationAlways: nil, defaults: defaults)
        if !quiet.isEmpty { errors.append("a service never set up should not warn, got \(quiet.map(\.id))") }
        // Hevy's key removed, Strava failing, the Mac Worker down, Screen Time off.
        let broken = problems(health: [.strava: .error("Strava refused the sign-in."), .hevy: .notSet], mac: .unreachable,
                              screenTimeApproved: false, locationAlways: false, defaults: defaults)
        if broken.map(\.id) != ["hevy", "strava", "macTracker", "screenTime", "location"]
            || broken.first { $0.id == "strava" }?.detail != "Strava refused the sign-in." {
            errors.append("each broken connection should warn once, in order, got \(broken.map(\.id))")
        }
        // Each problem notifies once; a fixed one that comes back notifies again.
        let first = newProblems(broken, defaults: defaults)
        let again = newProblems(broken, defaults: defaults)
        _ = newProblems(Array(broken.dropFirst()), defaults: defaults)
        let back = newProblems(broken, defaults: defaults)
        if first.count != 5 || !again.isEmpty || back.map(\.id) != ["hevy"] {
            errors.append("a problem should notify once, and again after it was fixed and came back")
        }
        if names(Array(broken.prefix(3))) != "Hevy, Strava and Mac tracker" {
            errors.append("the names line is wrong: \(names(Array(broken.prefix(3))))")
        }
        defaults.removePersistentDomain(forName: suite)
        return errors
    }
}
