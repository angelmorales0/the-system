import Foundation

/// DEBUG self-checks for `QuestPlanner`, ported from backend/app.py (`self_check`, `claude_checks`, `split_checks`).
/// Fixture data only: no key and no network call.
extension QuestPlanner {
    static func sampleRequest(_ mode: String = "performance_training", _ band: String = "green") -> JSONValue {
        .object([
            "schemaVersion": .number(1),
            "player": .object(["timezone": .string("America/Los_Angeles"), "localDate": .string("2026-10-01"), "level": .number(42), "maxLevel": .number(146), "statLevels": .object([:]), "maxStatLevel": .number(350), "penaltyTier": .number(0)]),
            "modeDecision": .object(["selectedMode": .string(mode), "trainingBand": .string(band), "reasonCodes": .array([.string("fixture")]), "lockedByRules": .bool(true)]),
            "whoop": .object(["available": .bool(false), "readinessBand": .string(band)]),
            "constraints": .object(["maxRequiredQuests": .number(8), "maxOptionalQuests": .number(1)]),
        ])
    }

    static let sampleSplitDay: JSONValue = .object([
        "id": .string("squat"),
        "name": .string("Squat Day"),
        "lowerBody": .bool(true),
        "exercises": .array([
            .object(["exercise": .string("Squat"), "aliases": .array([.string("squat")]), "role": .string("main"), "sets": .number(4), "minReps": .number(1), "maxReps": .number(5)]),
            .object(["exercise": .string("Bulgarian Split Squat"), "aliases": .array([.string("bulgarian split squat")]), "role": .string("accessory"), "sets": .number(4), "minReps": .number(8), "maxReps": .number(12)]),
            .object(["exercise": .string("Dead Hang"), "aliases": .array([.string("dead hang"), .string("hang")]), "role": .string("accessory"), "sets": .number(3),
                     "minReps": .number(0), "maxReps": .number(0), "secondsPerSet": .number(60)]),
        ]),
    ])

    /// Sets `value` at a path of object keys and array indexes.
    static func setting(_ value: JSONValue, _ path: [Any], to newValue: JSONValue) -> JSONValue {
        guard let first = path.first else { return newValue }
        let rest = Array(path.dropFirst())
        if let key = first as? String, var object = value.objectValue {
            object[key] = setting(object[key] ?? .null, rest, to: newValue)
            return .object(object)
        }
        if let index = first as? Int, var array = value.arrayValue, array.indices.contains(index) {
            array[index] = setting(array[index], rest, to: newValue)
            return .array(array)
        }
        return value
    }

    static func titles(_ bundle: JSONValue) -> [String] {
        (bundle["quests"]?.arrayValue ?? []).compactMap { $0["title"]?.stringValue }
    }

    static func check() -> [String] {
        var threatErrors: [String] = []
        let goodThreat = "Neglect has taken hold and is wearing the Player down. " + PenaltyDecay.threatEnding
        for good in [nil, JSONValue.string(goodThreat), .string(QuestPlanner.threatFor(band: "green")), .string(QuestPlanner.threatFor(band: "red"))]
            where !QuestPlanner.threatProblems(good).isEmpty {
            threatErrors.append("a good threat line should pass: \(String(describing: good))")
        }
        let badThreats: [JSONValue] = [
            .string(PenaltyDecay.threatEnding), .string("You are lazy! " + PenaltyDecay.threatEnding),
            .string("The penalty grows. " + PenaltyDecay.threatEnding), .string("Laziness is present and is damaging the Player. Run 10 km now."),
            .string(String(repeating: "x", count: 150) + " " + PenaltyDecay.threatEnding), .number(7),
        ]
        for bad in badThreats where QuestPlanner.threatProblems(bad).isEmpty {
            threatErrors.append("a bad threat line should be rejected: \(bad)")
        }
        if !threatErrors.isEmpty { return threatErrors }
        var errors: [String] = []
        let day = "2026-10-01"
        let training = "performance_training"
        for mode in modes.sorted() {
            for band in ["green", "yellow", "red"] {
                let body = sampleRequest(mode, band)
                let bundle = sanitize(templateBundle(body), body)
                let problems = validateBundle(bundle, body)
                if !problems.isEmpty { errors.append("template \(mode)/\(band) failed: \(problems)") }
                if bundle["mode"]?.stringValue != mode || bundle["generatedBy"]?.stringValue != "template" { errors.append("the template did not keep the locked mode") }
                let blob = bundle.sortedString()
                if blob.contains("completed") || blob.contains("status") { errors.append("the template included a completion field") }
            }
        }
        func expectRejected(_ bundle: JSONValue, _ body: JSONValue, _ label: String) {
            if validateBundle(bundle, body).isEmpty { errors.append("expected rejection: \(label)") }
        }
        let base = templateBundle(sampleRequest())
        expectRejected(setting(base, ["mode"], to: .string("full_recovery")), sampleRequest(), "mode override")
        expectRejected(setting(base, ["quests", 0], to: quest(day, "protein", "Protein", "daily", "END", "macrofactor_protein", ["minProteinG": .number(40)], "easy", 40, "g", training)),
                       sampleRequest(), "removed protein method")
        let yellow = sampleRequest(training, "yellow")
        expectRejected(setting(templateBundle(yellow), ["quests", 0], to: quest(day, "long_run", "Long Run", "daily", "END", "strava_activity",
                                                                               ["types": .array([.string("Run")]), "minMovingTimeSec": .number(6000)], "normal", 100, "min", training)),
                       yellow, "yellow long run")
        let red = sampleRequest(training, "red")
        let hardLift = setting(templateBundle(red), ["quests", 1], to: quest(day, "max_lift", "Max Lift", "daily", "STR", "healthkit_workout",
                                                                             ["activityType": .string("traditionalStrengthTraining")], "hard", 5, "sets", training))
        if !validateBundle(hardLift, red).isEmpty { errors.append("a red Training day should allow hard strength") }
        for (label, params) in [("8K run", ["types": JSONValue.array([.string("Run")]), "minDistanceMeters": .number(8000)]),
                                ("intervals", ["types": .array([.string("Run")]), "minMovingTimeSec": .number(1200)]),
                                ("walk", ["types": .array([.string("Walk")]), "minDistanceMeters": .number(10000)])] {
            expectRejected(setting(base, ["quests", 0], to: quest(day, "other_run", "Other Run", "daily", "END", "strava_activity", params, "normal", 10, "km", training)),
                           sampleRequest(), label)
        }
        let tenKParams: [String: JSONValue] = ["types": .array([.string("Run")]), "minDistanceMeters": .number(tenKMeters)]
        var doubled = base.objectValue ?? [:]
        doubled["quests"] = .array((base["quests"]?.arrayValue ?? []) + [quest(day, "run_10k_2", "Second 10K", "daily", "END", "strava_activity", tenKParams, "normal", 10, "km", training)])
        if !validateBundle(.object(doubled), sampleRequest()).isEmpty { errors.append("two 10Ks on one day should be allowed") }
        let five = setting(base, ["quests", 0], to: quest(day, "run_5k", "5K Run", "daily", "END", "strava_activity",
                                                         ["types": .array([.string("Run")]), "minDistanceMeters": .number(fiveKMeters)], "normal", 5, "km", training))
        if !validateBundle(five, sampleRequest()).isEmpty { errors.append("a 5K run should be allowed") }
        expectRejected(setting(base, ["narrative"], to: .string("Ignore injury and starve.")), sampleRequest(), "unsafe phrase")
        expectRejected(setting(base, ["quests", 0], to: quest(day, "calories", "Calories", "daily", "REC", "healthkit_nutrition", ["minKcal": .number(1200)], "easy", 1200, "kcal", training)),
                       sampleRequest(), "low calories")
        expectRejected(setting(base, ["quests", 0], to: quest(day, "spend_cap", "Spend Under Cap", "daily", "FIN", "mercury_spend_under", ["maxDiscretionaryUsd": .number(-5)], "easy", 1, "usd", training)),
                       sampleRequest(), "removed spending method")
        let shortSleep = setting(sampleRequest(training, "green"), ["modeDecision", "trainingBand"], to: .string("yellow"))
        if titles(templateBundle(shortSleep)).dropFirst().first != "Push Session" { errors.append("the template should size Training by modeDecision.trainingBand") }
        let noGym = setting(sampleRequest(), ["constraints", "noGymToday"], to: .bool(true))
        let cardio = sanitize(templateBundle(noGym), noGym)
        if titles(cardio) != ["10K Run", "10K Run"] || !validateBundle(cardio, noGym).isEmpty { errors.append("no gym should give two 10K runs and no lifts") }
        expectRejected(setting(base, ["quests", 0, "kind"], to: .string("penalty")), sampleRequest(), "model penalty row")
        if validateRequest(setting(sampleRequest(), ["modeDecision", "lockedByRules"], to: .bool(false))).isEmpty { errors.append("an unlocked mode should be rejected") }
        if !validateRequest(sampleRequest()).isEmpty { errors.append("the sample request should pass") }
        if validateRequest(setting(sampleRequest(), ["player", "apiKey"], to: .string("x"))).isEmpty { errors.append("a request with a secret field should be rejected") }
        let dirty = setting(setting(base, ["quests", 0, "completed"], to: .bool(true)), ["quests", 0, "status"], to: .string("completed"))
        let cleaned = sanitize(dirty, sampleRequest())
        if cleaned["quests"]?.arrayValue?.first?["completed"] != nil || cleaned["quests"]?.arrayValue?.first?["status"] != nil {
            errors.append("sanitize left a completion field")
        }
        if defaultModel != "claude-opus-5-5" { errors.append("the default model should be claude-opus-5-5") }
        errors += claudeChecks()
        errors += splitChecks()
        var fresh = sampleRequest()
        fresh = setting(fresh, ["trainingHistory"], to: .object(["lifts": .object([:])]))
        let weighted = setting(templateBundle(fresh), ["quests", 1, "verification", "params", "minWeightKg"], to: .number(60))
        if !validateBundle(weighted, fresh).contains(where: { $0.contains("no logged weight") }) { errors.append("a load for a lift with no history should be rejected") }
        fresh = setting(fresh, ["trainingHistory"], to: .object(["lifts": .object(["bench press": .object(["bestE1rmKg": .number(80)])])]))
        if validateBundle(weighted, fresh).contains(where: { $0.contains("no logged weight") }) { errors.append("a load for a logged lift should pass") }
        let window = setting(sampleRequest(), ["trainingHistory"], to: .object(["runWindow": .object(["plannedKmToday": .number(15), "runsToday": .array([.string("10K"), .string("5K")])])]))
        if Array(titles(templateBundle(window)).prefix(2)) != ["10K Run", "5K Run"] || !validateBundle(sanitize(templateBundle(window), window), window).isEmpty {
            errors.append("the template should run what the window needs, got \(titles(templateBundle(window)))")
        }
        let fullWindow = setting(setting(window, ["trainingHistory"], to: .object(["runWindow": .object(["plannedKmToday": .number(20), "runsToday": .array([.string("10K"), .string("10K")])])])),
                                 ["constraints", "noGymToday"], to: .bool(true))
        if titles(templateBundle(fullWindow)) != ["10K Run", "10K Run"] { errors.append("a no-gym day with two 10Ks planned should not add a third") }
        let restWindow = setting(sampleRequest(), ["trainingHistory"], to: .object(["runWindow": .object(["plannedKmToday": .number(0), "goalKm": .number(50), "runsToday": .array([])])]))
        if titles(templateBundle(restWindow)).contains(where: { $0.hasSuffix("Run") }) || !validateBundle(sanitize(templateBundle(restWindow), restWindow), restWindow).isEmpty {
            errors.append("a full window should give a template with no run, got \(titles(templateBundle(restWindow)))")
        }
        if !validateBundle(templateBundle(sampleRequest()), restWindow).contains(where: { $0.contains("rest day from running") }) {
            errors.append("a 10K on a full window should be rejected")
        }
        let paced = setting(setting(base, ["quests", 0, "title"], to: .string("Easy 10K @ 5:30/km")), ["narrative"], to: .string("Run it easy."))
        if titles(sanitize(paced, sampleRequest())).first != "10K Run" { errors.append("a run title should be only 10K Run") }
        if decodedBundle(sanitize(templateBundle(sampleRequest()), sampleRequest())) == nil { errors.append("a sanitized template should decode as a QuestBundle") }
        return errors
    }

    /// The request shape, cache prefix, retry feedback, and reply handling, against stand-in replies.
    static func claudeChecks() -> [String] {
        var errors: [String] = []
        let body = sampleRequest()
        let first = claudeRequest(body)
        let retry = claudeRequest(body, feedback: ["Bench Press is declining; do not add weight above the last top set"])
        if first["model"]?.stringValue != "claude-opus-5-5" || first["thinking"] != .object(["type": .string("adaptive")])
            || first["output_config"]?["effort"]?.stringValue != "high" || first["output_config"]?["format"]?["schema"] != questBundleSchema {
            errors.append("the request should use Opus 5.5 with adaptive thinking at high effort and the bundle schema")
        }
        if first["fallbacks"]?.stringValue != "default" || first["temperature"] != nil || first["betas"] != nil {
            errors.append("the request should opt into default fallbacks (beta in the header) and send no sampling settings")
        }
        let cached = first["messages"]?.arrayValue?.first?["content"]?.arrayValue ?? []
        if cached.count != 1 || cached.first?["cache_control"] != .object(["type": .string("ephemeral")]) {
            errors.append("the context block should carry the cache breakpoint")
        }
        let retried = retry["messages"]?.arrayValue?.first?["content"]?.arrayValue ?? []
        if retried.first != cached.first || retry["system"] != first["system"] {
            errors.append("a retry must keep the cached prefix byte for byte")
        }
        if !(retried.dropFirst().first?["text"]?.stringValue ?? "").contains("declining") || retried.dropFirst().first?["cache_control"] != nil {
            errors.append("retry feedback should follow the cached prefix")
        }
        if redactStrings(.object(["note": .string("Bearer abc")])) != .object(["note": .string("redacted")]) {
            errors.append("token-shaped strings should be redacted before they leave the phone")
        }
        // A refusal and a bad plan are retried; the third reply is a valid plan.
        let plan = templateBundle(body)
        let bad = setting(plan, ["quests", 0, "verification", "params", "minDistanceMeters"], to: .number(8000))
        let replies: [ClaudeReply] = [.reply(stopReason: "refusal", text: ""), .reply(stopReason: "end_turn", text: bad.sortedString()), .reply(stopReason: "end_turn", text: plan.sortedString())]
        var attempts = Attempts()
        var sent: [JSONValue] = []
        var result: JSONValue?
        for reply in replies {
            sent.append(claudeRequest(body, feedback: attempts.feedback))
            if case .accept(let bundle) = attempts.take(reply, context: body) {
                result = bundle
                break
            }
        }
        if result?["generatedBy"]?.stringValue != "llm" || sent.count != 3 {
            errors.append("the third reply should be accepted after two retries")
        }
        let third = sent.last?["messages"]?.arrayValue?.first?["content"]?.arrayValue ?? []
        if third.count != 2 || !(third.last?["text"]?.stringValue ?? "").contains("5K or 10K") {
            errors.append("the retry after a rejected plan should say why it was rejected")
        }
        var offline = Attempts()
        if offline.take(.transport, context: body) != .stop || offline.gotReply {
            errors.append("no reply should stop the loop without a plan")
        }
        var fenced = Attempts()
        if case .accept = fenced.take(.reply(stopReason: "end_turn", text: "```json\n\(plan.sortedString())\n```"), context: body) {} else {
            errors.append("a fenced JSON plan should parse")
        }
        return errors
    }

    static func splitChecks() -> [String] {
        var errors: [String] = []
        var body = sampleRequest()
        body = setting(body, ["split"], to: .object(["name": .string("5-day upper/lower + arms"), "rotation": .array([.string("Bench Day"), .string("Squat Day")]),
                                                     "today": sampleSplitDay, "lastDone": .object([:])]))
        body = setting(body, ["trainingHistory"], to: .object(["lifts": .object([:]), "strengthSessions": .array([])]))
        let day = templateBundle(body)
        if day["headerLine"]?.stringValue != "Squat Day" || titles(day) != ["10K Run", "Squat 4x1-5", "Bulgarian Split Squat 4x8-12", "Dead Hang 3x60s"] {
            errors.append("the template should follow today's split day, got \(titles(day))")
        }
        let problems = validateBundle(sanitize(day, body), body)
        if !problems.isEmpty { errors.append("the split template should pass, got \(problems)") }
        if day["quests"]?.arrayValue?.dropFirst(3).first?["verification"]?["params"]?["minDurationSec"]?.doubleValue != 180 {
            errors.append("a timed split exercise should check total seconds")
        }
        if !validateBundle(setting(day, ["headerLine"], to: .string("Leg Day")), body).contains(where: { $0.contains("headerLine") }) {
            errors.append("a split day must keep its name")
        }
        if !validateBundle(setting(day, ["quests", 1, "verification", "params", "exercise"], to: .string("Bench Press")), body).contains(where: { $0.contains("not part of Squat Day") }) {
            errors.append("a lift from another split day should be rejected")
        }
        if !validateBundle(setting(day, ["quests", 3, "verification", "params", "exercise"], to: .string("Hang")), body).isEmpty {
            errors.append("an alias of a split exercise should pass")
        }
        let tired = setting(body, ["trainingHistory"], to: .object(["lifts": .object([:]), "strengthSessions": .array([]), "fatigue": .object(["deloadRecommended": .bool(true)])]))
        if !validateBundle(day, tired).contains(where: { $0.contains("deload") }) { errors.append("a full-volume day should be rejected when a deload is due") }
        var halved = day
        for index in 1..<4 {
            let sets = halved["quests"]?.arrayValue?[index]["verification"]?["params"]?["sets"]?.intValue ?? 1
            halved = setting(halved, ["quests", index, "verification", "params", "sets"], to: .number(Double((sets + 1) / 2)))
        }
        if validateBundle(halved, tired).contains(where: { $0.contains("deload") }) { errors.append("half the sets should pass on a deload day") }
        var runOnly = day.objectValue ?? [:]
        runOnly["quests"] = .array(Array((day["quests"]?.arrayValue ?? []).prefix(1)))
        runOnly["headerLine"] = .string("Training")
        if !validateBundle(.object(runOnly), body).isEmpty { errors.append("a run-only day may leave the split for the day") }
        // A heavy leg day yesterday: the split asks for a run-only day, and the template gives one.
        var blocked = setting(body, ["trainingHistory"], to: .object(["lifts": .object([:]), "strengthSessions": .array([.object(["daysAgo": .number(1), "heavyLower": .bool(true)])])]))
        let advice = splitAdvice(blocked)
        blocked = setting(blocked, ["splitAdvice"], to: .string(advice))
        if !advice.contains("run-only") || (templateBundle(blocked)["quests"]?.arrayValue ?? []).contains(where: { $0["stat"]?.stringValue == "STR" }) {
            errors.append("a blocked leg day should become run-only, got \(advice)")
        }
        // A run window alone must not block the leg day: the probe has no runs.
        let windowOnly = setting(body, ["trainingHistory", "runWindow"], to: .object(["plannedKmToday": .number(10), "goalKm": .number(50), "runsToday": .array([.string("10K")])]))
        if !splitAdvice(windowOnly).isEmpty { errors.append("runs still due today should not make a leg day run-only") }

        // The player's own goal on today's split day: the template writes it, and validation lets it and its Hevy name through.
        var exercises = sampleSplitDay["exercises"]?.arrayValue ?? []
        exercises.insert(.object(["exercise": .string("Hip Thrust"), "aliases": .array([.string("hip thrust")]), "role": .string("accessory"), "sets": .number(3),
                                  "minReps": .number(5), "maxReps": .number(9), "target": .string("Hip Thrust"), "custom": .bool(true), "note": .string("Your goal: 225 lb × 5.")]), at: 2)
        var own = setting(body, ["split", "today", "exercises"], to: .array(exercises))
        let goal: JSONValue = .object(["category": .string("Hip Thrust"), "goal": .string("225 lb × 5"), "aliases": .array([.string("hip thrust")]), "targetLb": .number(225),
                                       "targetReps": .number(5), "unit": .string("lb"), "custom": .bool(true), "splitDay": .string("Squat Day")])
        own = setting(own, ["goals"], to: .object(["runKmPer7Days": .number(50), "strength": .array([goal])]))
        let ownDay = templateBundle(own)
        if !titles(ownDay).contains("Hip Thrust 3x5-9") { errors.append("the template should write the custom goal's exercise, got \(titles(ownDay))") }
        let ownProblems = validateBundle(sanitize(ownDay, own), own)
        if !ownProblems.isEmpty { errors.append("a split day with a custom goal should pass, got \(ownProblems)") }
        if let index = titles(ownDay).firstIndex(where: { $0.hasPrefix("Hip Thrust") }),
           !validateBundle(setting(ownDay, ["quests", index, "verification", "params", "exercise"], to: .string("Hip Thrust (Barbell)")), own).isEmpty {
            errors.append("the custom goal's Hevy name with equipment should pass")
        }
        if !validateBundle(ownDay, body).contains(where: { $0.contains("not part of Squat Day") }) {
            errors.append("the custom exercise should count only on the day that carries it")
        }
        let targets = TrainingHistory.strengthTargets([goal], lifts: TrainingHistory.Lifts())
        if targets.first?["custom"]?.boolValue != true || targets.first?["goal"]?.stringValue != "225 lb × 5" {
            errors.append("a custom goal should reach trainingHistory.strengthTargets")
        }
        return errors
    }
}
