import Foundation

/// Strava API from the phone, with the owner's own Strava app and the tokens in the Keychain.
/// Port of the backend's Strava snapshot and 30-day activity reader. Activity names and GPS never leave this file.
enum StravaClient {
    static let api = "https://www.strava.com/api/v3"

    static var configured: Bool { SecretStore.has(.stravaTokens) }

    /// One local day of Strava activities as workout events.
    static func snapshot(dayKey: String, zone: TimeZone? = nil) async -> StravaDayReading {
        var base = StravaDayReading.disconnected(dayKey: dayKey, reason: "")
        guard configured else {
            base.reason = "TODO: Sign in to Strava in Status → Connections."
            return base
        }
        base.configured = true
        guard let token = await OAuthClient.accessToken(.strava) else {
            base.reason = "TODO: Strava token refresh failed. Sign in again in Status → Connections."
            return base
        }
        guard let (start, end) = OnDeviceTime.dayBounds(dayKey, zone: zone ?? QuestDay.timeZone),
              let url = activitiesURL(after: start, before: end, perPage: 50),
              let payload = await OnDeviceHTTP.getJSON(url, headers: bearer(token))?.arrayValue else {
            base.reason = "TODO: Strava request failed."
            return base
        }
        base.available = true
        base.reason = ""
        base.activities = payload.filter { $0["start_date"]?.stringValue?.isEmpty == false }.compactMap(activity)
        return base
    }

    /// Raw activities between `start` and `end` for the training history. Up to 3 pages of 100.
    static func history(start: Date, end: Date) async -> (activities: [JSONValue], status: String) {
        guard configured else { return ([], "not configured") }
        guard let token = await OAuthClient.accessToken(.strava) else { return ([], "token refresh failed") }
        var activities: [JSONValue] = []
        for page in 1...3 {
            guard let url = activitiesURL(after: start, before: end, perPage: 100, page: page),
                  let payload = await OnDeviceHTTP.getJSON(url, headers: bearer(token))?.arrayValue else {
                return (activities, page > 1 ? "ok" : "request failed")
            }
            activities += payload.filter { $0.objectValue != nil }
            if payload.count < 100 { break }
        }
        return (activities, "ok")
    }

    static func test() async -> (ok: Bool, message: String) {
        guard let token = await OAuthClient.accessToken(.strava) else { return (false, "Sign in to Strava again: the token could not be refreshed.") }
        guard let url = URL(string: "\(api)/athlete"), let reply = await OnDeviceHTTP.get(url, headers: bearer(token)) else {
            return (false, "Cannot reach Strava.")
        }
        if (200..<300).contains(reply.status) { return (true, "Connected to Strava.") }
        return (false, "Strava answered with HTTP \(reply.status).")
    }

    static func bearer(_ token: String) -> [String: String] { ["Authorization": "Bearer \(token)"] }

    static func activitiesURL(after: Date, before: Date, perPage: Int, page: Int? = nil) -> URL? {
        var query = [("after", String(Int(after.timeIntervalSince1970))), ("before", String(Int(before.timeIntervalSince1970))), ("per_page", String(perPage))]
        if let page { query.append(("page", String(page))) }
        return OnDeviceHTTP.url("\(api)/athlete/activities", query)
    }

    /// One Strava activity as a workout event. The end is the start plus the moving time.
    static func activity(_ item: JSONValue) -> WorkoutEvent? {
        guard let startText = item["start_date"]?.stringValue, let start = OnDeviceTime.parse(startText) else { return nil }
        let moving = item["moving_time"]?.doubleValue ?? 0
        let id: String = {
            switch item["id"] {
            case .number(let value): return String(format: "%.0f", value)
            case .string(let value) where !value.isEmpty: return value
            default: return OnDeviceTime.utcString(start)
            }
        }()
        return WorkoutEvent(
            source: "strava",
            externalId: id,
            sport: item["type"]?.stringValue ?? "other",
            start: start,
            end: start.addingTimeInterval(moving),
            movingTimeSec: moving,
            distanceMeters: item["distance"]?.doubleValue
        )
    }

    // MARK: - Self-check (runs in DEBUG at launch)

    static func check() -> [String] {
        var errors: [String] = []
        let run: JSONValue = .object([
            "id": .number(123456789), "name": .string("private"), "type": .string("Run"),
            "start_date": .string("2026-10-02T14:00:00Z"), "moving_time": .number(3000), "distance": .number(10020),
        ])
        if let event = activity(run) {
            if event.externalId != "123456789" || event.sport != "Run" || OnDeviceTime.utcString(event.end) != "2026-10-02T14:50:00Z"
                || event.distanceMeters != 10020 || event.movingTimeSec != 3000 {
                errors.append("a Strava activity should keep its id, type, distance, and end at start + moving time")
            }
        } else {
            errors.append("a Strava activity with a start should parse")
        }
        if activity(.object(["type": .string("Run")])) != nil {
            errors.append("a Strava activity without a start should be skipped")
        }
        let url = activitiesURL(after: Date(timeIntervalSince1970: 100), before: Date(timeIntervalSince1970: 200), perPage: 50)
        if url?.absoluteString != "https://www.strava.com/api/v3/athlete/activities?after=100&before=200&per_page=50" {
            errors.append("Strava activities URL wrong")
        }
        return errors
    }
}
