import Foundation

/// The Test button on Status → Connections. Makes one small read call and saves a short result for the row.
enum ConnectionTester {
    static func test(_ connection: Connection) async -> (ok: Bool, message: String) {
        guard connection.isSet else {
            return (false, "Type the values first.")
        }
        let outcome: (ok: Bool, message: String)
        switch connection {
        case .hevy:
            outcome = await HevyClient.test()
        case .strava:
            outcome = await StravaClient.test()
        case .whoop:
            outcome = await WhoopClient.test()
        case .codeforces:
            outcome = await CodeforcesClient.test()
        case .mercury:
            outcome = await MercuryClient.test()
        case .claude:
            outcome = await QuestPlanner.test()
        }
        ConnectionStatusStore.record(connection, ok: outcome.ok, message: outcome.message)
        return outcome
    }
}
