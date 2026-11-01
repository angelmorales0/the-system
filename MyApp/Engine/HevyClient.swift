import Foundation

/// Hevy Pro API, called from the phone with the key from the Keychain. Port of the backend's Hevy reader.
/// Workouts come back as exercises and sets only: no notes and no description.
enum HevyClient {
    static let api = "https://api.hevyapp.com"
    /// Hevy pages are at most 10 workouts. Newest first, so a few pages reach any recent day.
    static let pageSize = 10
    static let maxPages = 5
    /// The 180-day history for the STR and AGI stats reads up to this many pages (300 workouts).
    static let historyPages = 30

    static func page(_ page: Int, size: Int = pageSize) -> URL? {
        OnDeviceHTTP.url("\(api)/v1/workouts", [("page", String(page)), ("pageSize", String(size))])
    }

    static func headers(_ key: String) -> [String: String] { ["api-key": key] }

    /// One local day of Hevy workouts. `key` nil returns the TODO before any request.
    static func snapshot(dayKey: String, key: String? = SecretStore.read(.hevyApiKey), zone: TimeZone? = nil) async -> HevyDayReading {
        var base = HevyDayReading.disconnected(dayKey: dayKey, reason: "")
        guard let key else {
            base.reason = "TODO: Type the Hevy API key in Status → Connections (Hevy Pro, hevy.com/settings)."
            return base
        }
        base.configured = true
        guard let (start, end) = OnDeviceTime.dayBounds(dayKey, zone: zone ?? QuestDay.timeZone) else { return base }
        var workouts: [HevyWorkout] = []
        for number in 1...maxPages {
            guard let url = page(number),
                  let payload = await OnDeviceHTTP.getJSON(url, headers: headers(key)),
                  let items = payload["workouts"]?.arrayValue else {
                if number == 1 {
                    base.reason = "TODO: Hevy request failed. Check the API key in Status → Connections."
                    return base
                }
                break
            }
            let parsed = items.compactMap(workout)
            workouts += parsed.filter { $0.start >= start && $0.start < end }
            // Newest first: once a page reaches before the day, later pages are older still.
            if items.isEmpty || parsed.contains(where: { $0.start < start }) { break }
            if number >= (payload["page_count"]?.intValue ?? number) { break }
        }
        base.available = true
        base.reason = ""
        base.workouts = workouts
        return base
    }

    /// Every workout since `start`, newest first, for the 30-day training history. The status says what happened.
    static func history(since start: Date, key: String? = SecretStore.read(.hevyApiKey)) async -> (workouts: [HevyWorkout], status: String) {
        guard let key else { return ([], "not configured") }
        var workouts: [HevyWorkout] = []
        for number in 1...historyPages {
            guard let url = page(number),
                  let payload = await OnDeviceHTTP.getJSON(url, headers: headers(key)),
                  let items = payload["workouts"]?.arrayValue else {
                return (workouts, number > 1 ? "ok" : "request failed")
            }
            let parsed = items.compactMap(workout)
            workouts += parsed.filter { $0.start >= start }
            if parsed.isEmpty || parsed.contains(where: { $0.start < start }) { break }
            if number >= (payload["page_count"]?.intValue ?? number) { break }
        }
        return (workouts, "ok")
    }

    /// For the Test button: one page of one workout.
    static func test() async -> (ok: Bool, message: String) {
        guard let key = SecretStore.read(.hevyApiKey), let url = page(1, size: 1) else { return (false, "Type the API key first.") }
        guard let reply = await OnDeviceHTTP.get(url, headers: headers(key)) else { return (false, "Cannot reach Hevy.") }
        switch reply.status {
        case 200..<300: return (true, "Connected to Hevy.")
        case 401, 403: return (false, "Hevy refused the key (HTTP \(reply.status)). Hevy Pro is required.")
        default: return (false, "Hevy answered with HTTP \(reply.status).")
        }
    }

    /// One Hevy workout reduced to exercises and sets. Nil without a start time.
    static func workout(_ item: JSONValue) -> HevyWorkout? {
        guard let startText = item["start_time"]?.stringValue, !startText.isEmpty,
              let start = OnDeviceTime.parse(startText) else { return nil }
        let endText = item["end_time"]?.stringValue ?? ""
        let end = OnDeviceTime.parse(endText) ?? start
        let exercises: [HevyExercise] = (item["exercises"]?.arrayValue ?? []).compactMap { exercise in
            guard exercise.objectValue != nil else { return nil }
            let sets: [HevySet] = (exercise["sets"]?.arrayValue ?? []).compactMap { entry in
                guard entry.objectValue != nil else { return nil }
                let type = entry["type"]?.stringValue ?? ""
                return HevySet(
                    type: type.isEmpty ? "normal" : type,
                    reps: entry["reps"]?.doubleValue.map { Int($0) },
                    weightKg: entry["weight_kg"]?.doubleValue,
                    rpe: entry["rpe"]?.doubleValue,
                    durationSec: entry["duration_seconds"]?.doubleValue,
                    distanceMeters: entry["distance_meters"]?.doubleValue
                )
            }
            let template: String? = {
                switch exercise["exercise_template_id"] {
                case .string(let value) where !value.isEmpty: return value
                case .number(let value) where value != 0: return String(format: "%g", value)
                default: return nil
                }
            }()
            return HevyExercise(title: exercise["title"]?.stringValue ?? "", templateId: template, sets: sets)
        }
        let title = item["title"]?.stringValue ?? ""
        let id = item["id"]?.stringValue ?? startText
        return HevyWorkout(id: id.isEmpty ? startText : id, title: title.isEmpty ? "Workout" : title, start: start, end: end, exercises: exercises)
    }

    // MARK: - Self-check (runs in DEBUG at launch). Fixtures from backend/integrations.py.

    static func check() -> [String] {
        var errors: [String] = []
        let sample: JSONValue = .object([
            "id": .string("w1"),
            "title": .string("Push"),
            "description": .string("private note"),
            "start_time": .string("2026-10-02T14:00:00+00:00"),
            "end_time": .string("2026-10-02T15:05:30Z"),
            "exercises": .array([
                .object([
                    "title": .string("Bench Press (Barbell)"),
                    "exercise_template_id": .string("79D0BB3A"),
                    "notes": .string("private"),
                    "sets": .array([
                        .object(["type": .string("warmup"), "weight_kg": .number(40), "reps": .number(10), "rpe": .null]),
                        .object(["type": .string("normal"), "weight_kg": .number(80.5), "reps": .number(5), "rpe": .number(8)]),
                        .object(["type": .string("normal"), "weight_kg": .null, "reps": .null]),
                    ]),
                ]),
                .object(["title": .string("Splits"), "exercise_template_id": .null, "sets": .array([.object(["type": .string("normal"), "duration_seconds": .number(90)])])]),
            ]),
        ])
        guard let parsed = workout(sample) else { return ["a Hevy workout with a start time should parse"] }
        if OnDeviceTime.utcString(parsed.start) != "2026-10-02T14:00:00Z" || OnDeviceTime.utcString(parsed.end) != "2026-10-02T15:05:30Z" {
            errors.append("Hevy times should normalize to UTC Z")
        }
        let bench = parsed.exercises[0]
        if bench.templateId != "79D0BB3A" || bench.sets.map(\.type) != ["warmup", "normal", "normal"] {
            errors.append("a Hevy exercise should keep its template id and set types")
        }
        if bench.sets[1] != HevySet(type: "normal", reps: 5, weightKg: 80.5, rpe: 8, durationSec: nil) || bench.sets[2].reps != nil {
            errors.append("Hevy sets should keep reps and kg")
        }
        if parsed.exercises[1].sets[0].durationSec != 90 || parsed.exercises[1].templateId != nil {
            errors.append("Hevy timed sets should keep their duration")
        }
        if JSONValue.from(parsed)?.sortedString().contains("private") != false {
            errors.append("a Hevy workout should drop notes and descriptions")
        }
        if workout(.object(["title": .string("no start")])) != nil {
            errors.append("a Hevy workout without a start time should be skipped")
        }
        if let (start, end) = OnDeviceTime.dayBounds("2026-10-02", zone: OnDeviceTime.losAngeles),
           let inside = OnDeviceTime.parse("2026-10-02T14:00:00Z"), let after = OnDeviceTime.parse("2026-10-03T07:30:00Z") {
            if !(inside >= start && inside < end) || (after >= start && after < end) {
                errors.append("the Hevy day filter should follow local midnight")
            }
        } else {
            errors.append("day bounds should parse")
        }
        if let (start, _) = OnDeviceTime.dayBounds("2026-10-02", zone: TimeZone(identifier: "America/New_York") ?? .current),
           OnDeviceTime.utcString(start) != "2026-10-02T04:00:00Z" {
            errors.append("day bounds should follow the phone's time zone")
        }
        if page(2)?.absoluteString != "https://api.hevyapp.com/v1/workouts?page=2&pageSize=10" {
            errors.append("Hevy page URL wrong")
        }
        return errors
    }
}
