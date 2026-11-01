import Foundation

/// Plans today's quests on the phone with Claude. Port of backend/app.py: the request, the retries with feedback,
/// sanitize, validate, and the template the app falls back to when every plan is rejected.
/// The Anthropic API key comes from the Keychain and goes only into the `x-api-key` header.
enum QuestPlanner {
    static let modes: Set<String> = ["performance_training", "full_recovery"]
    static let methods: Set<String> = ["whoop_strain", "strava_activity", "hevy_sets", "healthkit_workout", "screen_time_limit", "manual_confirm", "timer_session"]
    static let stats: Set<String> = ["STR", "END", "INT", "AGI", "FOC", "REC", "FIN"]
    static let secretKeys: Set<String> = ["password", "apikey", "api_key", "authorization", "secret", "token", "xai_api_key", "anthropic_api_key", "openai_api_key"]
    static let unsafe = ["starve", "all-nighter", "all nighter", "ignore injury", "max debt"]
    static let defaultModel = "claude-opus-5-5"
    static let modelKey = "com.angelmorales.thesystem.claude.model"
    // Planning a day from 30 days of training is reasoning-heavy, so the model thinks at high effort.
    static let effort = "high"
    // The context holds 30 days of training and the model thinks first, so allow time for a retry.
    static let modelSeconds: TimeInterval = 100
    // A declined request is re-run server-side on the model Anthropic picks for that refusal category.
    static let fallbackBeta = "server-side-fallback-2026-07-01"
    static let apiVersion = "2026-10-21"
    static let endpoint = "https://api.anthropic.com/v1/messages"
    static let fiveKMeters = 5_000.0
    static let tenKMeters = 10_000.0
    static let defaultWarning = "Failure to complete\nthe daily quest will result\nin a penalty."

    /// The model from Status → Connections → Claude, or the default.
    static var model: String {
        let value = UserDefaults.standard.string(forKey: modelKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? defaultModel : value
    }

    // MARK: - Structured output schema

    static let questParamsSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "exercise": .object(["type": .string("string"), "description": .string("Hevy exercise name without equipment")]),
            "sets": .object(["type": .string("integer")]),
            "minReps": .object(["type": .string("integer")]),
            "minWeightKg": .object(["type": .string("number"), "description": .string("Only for a lift with logged history")]),
            "minDurationSec": .object(["type": .string("number")]),
            "types": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
            "minDistanceMeters": .object(["type": .string("number"), "enum": .array([.number(5000), .number(10000)])]),
            "activityType": .object(["type": .string("string")]),
            "minSec": .object(["type": .string("number")]),
            "label": .object(["type": .string("string")]),
            "prompt": .object(["type": .string("string")]),
        ]),
        "required": .array([]),
        "additionalProperties": .bool(false),
    ])

    /// The API returns JSON in exactly this shape, so field names, stats, and methods cannot drift.
    /// Ranges (id length, title length) are not schema features; `validateBundle` still checks them.
    static let questBundleSchema: JSONValue = {
        func strings(_ values: Set<String>) -> JSONValue { .array(values.sorted().map(JSONValue.string)) }
        return .object([
            "type": .string("object"),
            "properties": .object([
                "schemaVersion": .object(["type": .string("integer"), "enum": .array([.number(1)])]),
                "dayKey": .object(["type": .string("string"), "description": .string("player.localDate")]),
                "mode": .object(["type": .string("string"), "enum": strings(modes)]),
                "headerLine": .object(["type": .string("string")]),
                "narrative": .object(["type": .string("string")]),
                "threat": .object(["type": .string("string"), "description": .string("the penalty screen's two sentences, see the system prompt")]),
                "quests": .object([
                    "type": .string("array"),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "id": .object(["type": .string("string"), "description": .string("8-64 characters, unique, e.g. bench_press_main")]),
                            "title": .object(["type": .string("string"), "description": .string("3-48 characters")]),
                            "kind": .object(["type": .string("string"), "enum": .array([.string("daily"), .string("optional")])]),
                            "stat": .object(["type": .string("string"), "enum": strings(stats), "description": .string("STR for lifts, END for runs")]),
                            "verification": .object([
                                "type": .string("object"),
                                "properties": .object(["method": .object(["type": .string("string"), "enum": strings(methods)]), "params": questParamsSchema]),
                                "required": .array([.string("method"), .string("params")]),
                                "additionalProperties": .bool(false),
                            ]),
                            "difficulty": .object(["type": .string("string"), "enum": .array([.string("easy"), .string("normal"), .string("hard")])]),
                            "progress": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "target": .object(["type": .string("number")]),
                                    "unit": .object(["type": .string("string"), "enum": .array([.string("sets"), .string("km"), .string("min"), .string("session")])]),
                                ]),
                                "required": .array([.string("target"), .string("unit")]),
                                "additionalProperties": .bool(false),
                            ]),
                        ]),
                        "required": .array(["id", "title", "kind", "stat", "verification", "difficulty", "progress"].map(JSONValue.string)),
                        "additionalProperties": .bool(false),
                    ]),
                ]),
            ]),
            "required": .array(["schemaVersion", "dayKey", "mode", "headerLine", "narrative", "quests"].map(JSONValue.string)),
            "additionalProperties": .bool(false),
        ])
    }()

    static let systemPrompt = """
    You are The System, a strength and running coach. Write today's quests as JSON matching QuestBundle.

    Goals, in order:
    1. Reach the strength targets in trainingHistory.strengthTargets (goal, bestE1rmLb, gapLb; gapReps for rep goals, gapSeconds for holds). Spend the most work on the biggest gaps that were not trained recently.
       Targets with "custom": true are goals the player added. They are real strength targets: train them on their splitDay like the built-in ones.
    2. Keep at least goals.runKmPer7Days km of running in every 7-day window, today included. trainingHistory.runWindow says what today needs: runsToday lists the runs to write (5K and 10K quests).
       goals.focus lists the targets to put first right now (pull-ups first: 20 strict reps is the main goal; then lateral raises and biceps). The split trains them 3 times a rotation with the most sets: never drop them for time or readiness, and progress them first.
    3. Reach the body weight target in goals.bodyWeight. Do not write nutrition quests for it; it only informs how hard to push.

    Read the context before you plan:
    - trainingHistory.strengthSessions and trainingHistory.lifts hold 30 days of Hevy sets (weight, reps, RPE), newest first.
    - trainingHistory.runs holds 30 days of Strava activities with distance, pace, and heart rate.
    - trainingHistory.recovery holds 30 days of WHOOP recovery, HRV, resting heart rate, sleep, and strain. whoop holds today's values.
    - recentDays holds the quests the app assigned on each past day, and whether each was completed. Do not repeat a plan that was missed; adjust it.
    - trainingHistory.sources says which feeds were unavailable. With no data, start conservatively.

    Progression (pick loads from the logged sets, never guess):
    - Main lifts (squat, deadlift, bench press, overhead press, barbell row, pull-ups, dips): one top set at RPE 8, then 2-3 back-off sets at about 90% of the top set. If the last session's top set reached its reps at RPE 8 or lower, add 2.5 kg for upper-body lifts and 5 kg for squat and deadlift. At RPE 9, repeat the weight. At RPE 10 or a missed rep, drop 5%.
    - Accessories (lateral raise, curls, Bulgarian split squat, and other lifts): double progression in an 8-12 rep range. Add reps until every set reaches 12, then add the smallest weight step and go back to 8.
    - The split has 5 days: Bench Day, Squat Day, Press Day, Deadlift Day, Arms Day. It trains pull-ups 3 times a rotation with three jobs (volume on Bench Day, weighted strength on Press Day, a max-effort set first on Arms Day); lateral raises and curls 3 times (Bench, Press, and Arms Day); dead hangs 3 times (Squat, Press, and Arms Day); squats twice (heavy and light); and bench press, overhead press, rows, deadlift, and toes-to-bar once. Arms Day has no pressing. Pistol squats on Squat Day and handstand push-ups on Press Day are optional. Support exercises ("support": true: Romanian deadlift and calf raises on Squat Day; incline dumbbell press, skull crushers, and lying leg curl on Deadlift Day; face pulls on Arms Day) train what the running, shoulders, chest, and triceps need; their target is a muscle, not a strength target. Keep them unless readiness or recovery calls for cuts, and cut them before the strength targets.
    - No data yet: if trainingHistory.lifts has no entry for an exercise, write only sets and minReps, with no minWeightKg and no weight in the title (e.g. "Squat 4x3-5"). The player picks the weight and logs it in Hevy. In the narrative, say to pick a weight that leaves about 2 reps in reserve at the top of the range. From the first logged session on, set loads from the log.
    - Write exact loads once an exercise has history. Title: "Squat 3x5 @ 265 lb". Params: exercise (the Hevy name without equipment, e.g. "Squat"), sets, minReps, minWeightKg (the working weight in kg, rounded down to 2.5 kg). Unit "sets".

    Gym split (split in the context):
    - Follow split.today: write its exercises, in order, with headerLine exactly split.today.name. The split rotates in the order of split.rotation; the app picks today's day.
    - Roles: "main" is the day's heavy lift (top set at RPE 8, then back-offs). "light" is a main lift on its light day: keep every set under 80% of the lift's best e1RM and above 6 reps. "accessory" uses double progression in minReps-maxReps. secondsPerSet exercises are timed: params minDurationSec is the total seconds (sets × secondsPerSet), unit "min".
    - An exercise with "optional": true is written with kind "optional"; the player may skip it. An exercise's "note" says how to run it today and overrides its role's default progression. Follow it.
    - Use each exercise's Hevy name from trainingHistory.lifts when the player has logged it under one of its aliases; otherwise use split.today exercise.
    - An exercise with "custom": true is the player's own goal (its target is in goals.strength and trainingHistory.strengthTargets). The app put it on this day in place of a support exercise. Treat it as a strength target: cut support exercises before it, and follow its note.
    - You may drop other accessories or a set when readiness or recovery calls for it, but keep the goals.focus exercises. Do not add exercises from other days.
    - If splitAdvice says today's heavy lift would break the heavy-leg limits, make today a run-only day: write no lifts and headerLine "Training". The same split day comes back next time.

    Fatigue (adjust instead of pushing through):
    - Each entry in trainingHistory.lifts has a trend and advice from its newest sessions: improving, steady, stalled, declining, or dropping. Follow the advice for that lift.
    - declining: cut that lift's sets by a third and use 5-10% less weight than its last top set. dropping: half the sets at 60-70%. stalled: repeat the weight and add a rep, or drop 5% and build back. Never add weight to a declining or dropping lift; the backend rejects it.
    - If trainingHistory.fatigue.deloadRecommended is true, deload the whole day: every lift at half its split sets (rounded up) and 60-70% of its last top set. The backend rejects more sets than that.
    - Falling reps or loads on the focus lifts mean too much volume, not too little: cut sets before adding any.

    Running with lifting:
    - Heavy lower-body work interferes with running. Obey trainingHistory.limits: at most heavyLowerMaxPer7Days heavy squat or deadlift days in 7, at least heavyLowerMinDaysApart days apart, and no heavy squats or deadlifts on a two-10K day. The backend rejects any plan that breaks these.
    - Put upper-body and light lower-body work on days next to heavy leg days.
    - Write exactly trainingHistory.runWindow.runsToday as run quests: never more, never fewer, never over 20 km or maxTenKsPerDay 10Ks in a day. The app rejects a day whose run km differ from plannedKmToday. If runsToday is empty, the last 6 days already hold goals.runKmPer7Days km: write no run quest. Today is a rest day from running; the lifts stay.
    - A run quest's title is exactly "10K Run" or "5K Run". Give no pace, speed, heart rate, or effort for runs, in titles or the narrative: the player sets the pace.

    Readiness:
    - modeDecision.trainingBand is WHOOP readiness, one step lower after sleep performance under 60%. Green: full plan. Yellow and red: same exercises, one fewer back-off set and top sets at RPE 7. Every band still gets the run and strength work.
    - If constraints.noGymToday is true, the player has no gym today: write no strength quests and give two 10K runs instead.

    App rules:
    - Obey modeDecision.selectedMode. Do not change it. lockedByRules is authoritative.
    - performance_training is strength and 5K or 10K runs only. Lifts use hevy_sets, or healthkit_workout with activityType traditionalStrengthTraining. A run is always a 5K or a 10K: strava_activity with types ["Run"] and minDistanceMeters 5000 or 10000, progress target 5 or 10, unit "km". Prefer the 10K. Two 10Ks on one day are two separate quests. No walks, intervals, sprints, other run distances, protein, nutrition, spending, or stretch quests. The app adds its own Stretching quest.
    - Use kind daily or optional only. Never write penalty quests: the app adds them from player.penaltyTier.
    - Required quests (kind other than optional) <= constraints.maxRequiredQuests. Optional quests <= constraints.maxOptionalQuests. Total quests <= 9.
    - Titles are at most 48 characters. The narrative, at most 280 characters, says why today looks the way it does.
    - threat: two sentences for the penalty screen, at most 160 characters, in the voice of the System's urgent quest window. Sentence 1 names the fault behind a missed day as a presence that harms the Player: pick it from the data (missed quest days in trainingHistory.week, skipped stretching, high screen time, low readiness, few runs). Vary the noun: laziness, neglect, bad habits, complacency, weakness, avoidance. Sentence 2 is exactly "Run 10 km and ensure your safety." Cold, short, third person, no names, no advice, no exclamation marks, and never the word penalty. Examples: "Laziness is present and is damaging the Player. Run 10 km and ensure your safety." / "Neglect has taken hold and is wearing the Player down. Run 10 km and ensure your safety."
    - No run longer than 90 minutes when trainingBand is yellow.
    - Do not invent medical diagnoses or extreme deficits. Do not suggest calories under 1500.
    - Never use the phrases starve, all-nighter, ignore injury, or max debt.
    - Do not include completed, status, evidence, xp, reward, or assignedAt.
    - Output ONLY valid JSON with schemaVersion, dayKey, mode, headerLine, quests, narrative, and threat.

    """

    // MARK: - Request checks

    static func validateRequest(_ body: JSONValue) -> [String] {
        guard body.objectValue != nil else { return ["body must be an object"] }
        var problems: [String] = []
        if findSecretKeys(body) { problems.append("request contains a secret field") }
        if body["schemaVersion"]?.intValue != 1 { problems.append("schemaVersion must be 1") }
        let localDate = body["player"]?["localDate"]?.stringValue ?? ""
        if localDate.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) == nil { problems.append("player.localDate is required") }
        guard let decision = body["modeDecision"], decision.objectValue != nil else {
            return problems + ["modeDecision is required"]
        }
        if !modes.contains(decision["selectedMode"]?.stringValue ?? "") { problems.append("selectedMode is not a known mode") }
        if decision["lockedByRules"]?.boolValue != true { problems.append("mode must be locked by rules") }
        return problems
    }

    static func findSecretKeys(_ value: JSONValue) -> Bool {
        switch value {
        case .object(let object):
            return object.contains { key, item in
                secretKeys.contains(key.lowercased().replacingOccurrences(of: "-", with: "_")) || findSecretKeys(item)
            }
        case .array(let array):
            return array.contains { findSecretKeys($0) }
        default:
            return false
        }
    }

    /// The phone's context plus 30 days of Hevy, Strava, and WHOOP, and the split advice.
    static func withHistory(_ body: JSONValue, training: JSONValue) -> JSONValue {
        var context = body.objectValue ?? [:]
        context["trainingHistory"] = training
        let advice = splitAdvice(.object(context))
        if !advice.isEmpty { context["splitAdvice"] = .string(advice) }
        return .object(context)
    }

    // MARK: - Split rules

    static func splitToday(_ context: JSONValue) -> JSONValue? {
        guard let today = context["split"]?["today"], today["exercises"]?.arrayValue != nil else { return nil }
        return today
    }

    /// Says when today's split day is a leg day that the heavy-leg limits would block.
    /// The probe has no runs, so the run window is left out of its check: only the heavy-leg limits can block the lift.
    /// (The backend also counted the run window here, which made every lower-body day run-only while runs were due.)
    static func splitAdvice(_ context: JSONValue) -> String {
        guard let today = splitToday(context), today["lowerBody"].truthy,
              let main = today["exercises"]?.arrayValue?.first(where: { $0["role"]?.stringValue == "main" }) else { return "" }
        let probe: JSONValue = .object(["mode": .string("performance_training"), "quests": .array([.object([
            "verification": .object(["method": .string("hevy_sets"), "params": .object(["exercise": main["exercise"] ?? .null, "minReps": .number(1)])]),
        ])])])
        var history = context["trainingHistory"]?.objectValue ?? [:]
        history["runWindow"] = nil
        let problems = TrainingHistory.limitProblems(probe, .object(history))
        guard !problems.isEmpty else { return "" }
        return "Today's \(today["name"]?.stringValue ?? "None") heavy \(main["exercise"]?.stringValue ?? "None") would break the limits (\(problems.joined(separator: "; "))). Make today a run-only day."
    }

    static func splitNames(_ exercise: JSONValue) -> Set<String> {
        let names = [exercise["exercise"]?.stringValue ?? ""] + (exercise["aliases"]?.arrayValue ?? []).compactMap(\.stringValue)
        return Set(names.filter { !$0.isEmpty }.map { TrainingHistory.baseName($0).replacingOccurrences(of: "-", with: " ") })
    }

    /// On a split day, lifts must come from today's split day, under its name.
    static func splitProblems(_ bundle: JSONValue, _ context: JSONValue) -> [String] {
        guard let today = splitToday(context), bundle["mode"]?.stringValue == "performance_training" else { return [] }
        let lifts = (bundle["quests"]?.arrayValue ?? []).filter { $0.objectValue != nil && $0["stat"]?.stringValue == "STR" }
        guard !lifts.isEmpty else { return [] }
        var problems: [String] = []
        let name = today["name"]?.stringValue ?? "None"
        if bundle["headerLine"]?.stringValue != today["name"]?.stringValue { problems.append("headerLine must be \(name) on a split day") }
        let exercises = today["exercises"]?.arrayValue ?? []
        let allowed = exercises.reduce(into: Set<String>()) { $0.formUnion(splitNames($1)) }
        let deload = context["trainingHistory"]?["fatigue"]?["deloadRecommended"]?.boolValue == true
        for quest in lifts {
            let params = TrainingHistory.params(quest)
            let exercise = params.map { TrainingHistory.baseName($0["exercise"]?.stringValue ?? "").replacingOccurrences(of: "-", with: " ") } ?? ""
            let planned = exercises.first { splitNames($0).contains(exercise) }
            if deload, let planned, let sets = params?["sets"]?.doubleValue {
                let plannedSets = planned["sets"]?.intValue.flatMap { $0 == 0 ? nil : $0 } ?? 1
                if sets > Double((plannedSets + 1) / 2) { problems.append("\(quest["title"]?.stringValue ?? "None") has too many sets for a deload day") }
            }
            if TrainingHistory.method(quest) != "hevy_sets" || !allowed.contains(exercise) {
                problems.append("\(quest["title"]?.stringValue ?? "None") is not part of \(name)")
            }
        }
        return problems
    }

    /// A load needs a logged session to come from. Without one, the quest is sets and reps, and the player picks the weight.
    static func unloggedWeightProblems(_ bundle: JSONValue, _ context: JSONValue) -> [String] {
        guard let training = context["trainingHistory"], let trainingObject = training.objectValue, trainingObject["lifts"] != nil else { return [] }
        let lifts = training["lifts"]
        return (bundle["quests"]?.arrayValue ?? []).compactMap { quest in
            guard TrainingHistory.method(quest) == "hevy_sets", let params = TrainingHistory.params(quest),
                  let weight = params["minWeightKg"], !weight.isNull else { return nil }
            let exercise = params["exercise"]?.stringValue ?? ""
            if lifts?[TrainingHistory.baseName(exercise)]?["bestE1rmKg"].truthy == true { return nil }
            return "\(exercise.isEmpty ? "None" : exercise) has no logged weight yet; give sets and reps only"
        }
    }

    // MARK: - Claude

    /// The Messages request. The system prompt and the context form a cached prefix, so a retry rereads them at the
    /// cache price. Feedback comes after the breakpoint and never changes the prefix.
    static func claudeRequest(_ context: JSONValue, feedback: [String] = [], model: String = defaultModel) -> JSONValue {
        var content: [JSONValue] = [.object([
            "type": .string("text"),
            // Sorted keys keep the bytes the same on every retry, so the cache prefix matches.
            "text": .string(redactStrings(context).sortedString()),
            "cache_control": .object(["type": .string("ephemeral")]),
        ])]
        if !feedback.isEmpty {
            // The last plan broke a rule. Say which, so the retry fixes it instead of guessing again.
            content.append(.object(["type": .string("text"), "text": .string("Your last plan was rejected: " + Set(feedback).sorted().joined(separator: "; ") + ". Write a new plan that fixes this.")]))
        }
        return .object([
            "model": .string(model),
            "max_tokens": .number(16000),
            "system": .string(systemPrompt),
            "thinking": .object(["type": .string("adaptive")]),
            "output_config": .object(["effort": .string(effort), "format": .object(["type": .string("json_schema"), "schema": questBundleSchema])]),
            "fallbacks": .string("default"),
            "messages": .array([.object(["role": .string("user"), "content": .array(content)])]),
        ])
    }

    enum ClaudeReply: Equatable {
        /// No reply: network, timeout, or an HTTP error that another try will not fix in time.
        case transport
        case reply(stopReason: String, text: String)
    }

    /// The retry state across up to three calls: the feedback for the next call, and whether any plan came back.
    struct Attempts {
        var feedback: [String] = []
        var gotReply = false

        enum Step: Equatable {
            case accept(JSONValue)
            case retry
            case stop
        }

        /// What to do with one reply. A refusal, a cut-off reply, or bad JSON is retried with the same feedback.
        mutating func take(_ reply: ClaudeReply, context: JSONValue) -> Step {
            guard case .reply(let stop, let text) = reply else { return .stop }
            gotReply = true
            // A refusal that every fallback also declined, or a reply cut off at max_tokens, has no usable plan.
            guard stop != "refusal", stop != "max_tokens", var raw = parseJSONObject(text)?.objectValue else { return .retry }
            let locked = context["modeDecision"]?["selectedMode"]?.stringValue ?? "None"
            if raw["mode"]?.stringValue != locked {
                feedback = ["mode must be \(locked)"]
                return .retry
            }
            let localDate = context["player"]?["localDate"]?.stringValue
            if let day = raw["dayKey"], !day.isNull, day.stringValue != localDate {
                feedback = ["dayKey must be \(localDate ?? "None")"]
                return .retry
            }
            raw["generatedBy"] = .string("llm")
            let candidate = sanitize(.object(raw), context)
            feedback = validateBundle(candidate, context)
            return feedback.isEmpty ? .accept(candidate) : .retry
        }
    }

    enum PlanOutcome: Equatable {
        case accepted(JSONValue)
        /// Every reply was refused, cut off, or broke a rule: use the template.
        case rejected
        /// No reply came back at all (offline, app suspended, bad key): keep the catalog and try again later.
        case unreachable
    }

    /// Up to three calls inside `modelSeconds`. A rejected plan's problems go back to the model as feedback.
    static func claudeOrNone(_ context: JSONValue, send: (JSONValue, TimeInterval) async -> ClaudeReply) async -> PlanOutcome {
        let deadline = Date().addingTimeInterval(modelSeconds)
        var attempts = Attempts()
        for _ in 0..<3 {
            let remaining = deadline.timeIntervalSinceNow
            if remaining < 0.5 { break }
            let reply = await send(claudeRequest(context, feedback: attempts.feedback, model: model), remaining)
            switch attempts.take(reply, context: context) {
            case .accept(let bundle): return .accepted(bundle)
            case .retry: continue
            case .stop: return attempts.gotReply ? .rejected : .unreachable
            }
        }
        return attempts.gotReply ? .rejected : .unreachable
    }

    /// One POST to the Messages API. 429 and 5xx get one more try when time allows, like the SDK's single retry.
    static func callClaude(_ request: JSONValue, apiKey: String, timeout: TimeInterval) async -> ClaudeReply {
        guard let url = URL(string: endpoint), let body = request.sortedData() else { return .transport }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue(fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        let started = Date()
        for attempt in 0..<2 {
            let left = timeout - Date().timeIntervalSince(started)
            guard left > 1 else { return .transport }
            urlRequest.timeoutInterval = left
            guard let (data, response) = try? await OnDeviceHTTP.session(timeout: left).data(for: urlRequest),
                  let http = response as? HTTPURLResponse else { return .transport }
            if http.statusCode == 429 || http.statusCode >= 500, attempt == 0 { continue }
            // Auth, permission, and request errors will not fix themselves.
            guard (200..<300).contains(http.statusCode), let reply = JSONValue.parse(data) else { return .transport }
            let text = (reply["content"]?.arrayValue ?? []).filter { $0["type"]?.stringValue == "text" }.compactMap { $0["text"]?.stringValue }.joined()
            return .reply(stopReason: reply["stop_reason"]?.stringValue ?? "", text: text)
        }
        return .transport
    }

    /// For the Test button: reads the model's entry from the Models API. It checks the key and the model and costs no tokens.
    static func test() async -> (ok: Bool, message: String) {
        guard let key = SecretStore.read(.anthropicApiKey) else { return (false, "Type the API key first.") }
        let name = model
        guard let url = URL(string: "https://api.anthropic.com/v1/models/\(name)"),
              let reply = await OnDeviceHTTP.get(url, headers: ["x-api-key": key, "anthropic-version": apiVersion], timeout: 15) else {
            return (false, "Cannot reach the Anthropic API.")
        }
        switch reply.status {
        case 200..<300: return (true, "Connected. Quests are planned with \(name).")
        case 401: return (false, "Anthropic refused the API key.")
        case 404: return (false, "The model \(name) was not found. Check the model name.")
        default: return (false, "The Anthropic API answered with HTTP \(reply.status).")
        }
    }

    static func parseJSONObject(_ content: String) -> JSONValue? {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: #"^```(?:json)?"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            text = text.replacingOccurrences(of: #"```$"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let value = JSONValue.parse(Data(text.utf8)), value.objectValue != nil else { return nil }
        return value
    }

    static func redactStrings(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let text):
            let lower = text.lowercased()
            return ["sk-", "xai-", "bearer ", "api_key", "api-key"].contains(where: { lower.contains($0) }) ? .string("redacted") : value
        case .array(let array): return .array(array.map { redactStrings($0) })
        case .object(let object): return .object(object.mapValues { redactStrings($0) })
        default: return value
        }
    }

    // MARK: - Sanitize and validate

    static func sanitize(_ bundle: JSONValue, _ context: JSONValue) -> JSONValue {
        let mode = context["modeDecision"]?["selectedMode"]?.stringValue
        let day = context["player"]?["localDate"]?.stringValue
        var cleaned = bundle.objectValue ?? [:]
        cleaned["completed"] = nil
        cleaned["schemaVersion"] = .number(1)
        if let day { cleaned["dayKey"] = .string(day) }
        if let mode, modes.contains(mode) { cleaned["mode"] = .string(mode) }
        let author = cleaned["generatedBy"]?.stringValue ?? ""
        cleaned["generatedBy"] = .string(["llm", "template", "mock"].contains(author) ? author : "template")
        let quests: [JSONValue] = (cleaned["quests"]?.arrayValue ?? []).compactMap { quest in
            guard var row = quest.objectValue else { return nil }
            for field in ["completed", "status", "evidence", "xp", "reward", "grantedXP", "grantedStatPoints", "grantedRecoveryToken", "assignedAt", "skippedWithPotion"] { row[field] = nil }
            if let mode, modes.contains(mode) { row["mode"] = .string(mode) }
            if let day {
                // The app decodes a deadline and expects day-scoped ids, as the template writes them.
                row["deadline"] = .string("\(day)T23:59:59Z")
                let identifier = row["id"]?.stringValue ?? ""
                if !identifier.isEmpty, !identifier.hasPrefix("q_") { row["id"] = .string(String("q_\(day)_\(identifier)".prefix(64))) }
            }
            // A run reads only its distance; the player sets the pace.
            if isTrainingRow(.object(row)), let meters = TrainingHistory.params(.object(row))?["minDistanceMeters"]?.doubleValue,
               meters == fiveKMeters || meters == tenKMeters, row["kind"]?.stringValue != "penalty" {
                row["title"] = .string(meters == tenKMeters ? "10K Run" : "5K Run")
            }
            if var progress = row["progress"]?.objectValue {
                progress["current"] = .number(0)
                row["progress"] = .object(progress)
            }
            return .object(row)
        }
        cleaned["quests"] = .array(quests)
        if !cleaned["headerLine"].truthy, let mode {
            cleaned["headerLine"] = .string(mode.replacingOccurrences(of: "_", with: " ").capitalized)
        }
        if !cleaned["warnings"].truthy { cleaned["warnings"] = .array([.string(defaultWarning)]) }
        return .object(cleaned)
    }

    static func length(_ text: String) -> Int { text.unicodeScalars.count }

    static func validateBundle(_ bundle: JSONValue, _ context: JSONValue) -> [String] {
        var problems: [String] = []
        let constraints = context["constraints"]
        let band = trainingBand(context)
        if bundle["schemaVersion"]?.intValue != 1 { problems.append("schemaVersion must be 1") }
        if bundle["dayKey"] != context["player"]?["localDate"] { problems.append("dayKey does not match the local quest day") }
        if bundle["mode"] != context["modeDecision"]?["selectedMode"] { problems.append("locked mode overridden") }
        var narrative = ""
        switch bundle["narrative"] {
        case .string(let text): narrative = text
        case nil, .null: narrative = ""
        case .some(let other):
            if other.truthy { problems.append("narrative is missing or too long") }
        }
        if length(narrative) > 280 { problems.append("narrative is missing or too long") }
        problems += threatProblems(bundle["threat"])
        var quests = bundle["quests"]?.arrayValue ?? []
        if quests.isEmpty {
            problems.append("bundle has no quests")
            quests = []
        }
        let requiredCap = constraints?["maxRequiredQuests"]?.intValue.flatMap { $0 == 0 ? nil : $0 } ?? 8
        let optionalCap = constraints?["maxOptionalQuests"]?.intValue.flatMap { $0 == 0 ? nil : $0 } ?? 1
        let objects = quests.filter { $0.objectValue != nil }
        if quests.count > 9 { problems.append("too many quests") }
        if objects.filter({ $0["kind"]?.stringValue != "optional" }).count > requiredCap { problems.append("too many required quests") }
        if objects.filter({ $0["kind"]?.stringValue == "optional" }).count > optionalCap { problems.append("too many optional quests") }
        var texts = [narrative, bundle["headerLine"]?.stringValue ?? ""]
        var seen: Set<String> = []
        for quest in quests {
            guard quest.objectValue != nil else {
                problems.append("quest must be an object")
                continue
            }
            problems += validateQuest(quest, band: band, seen: &seen)
            if bundle["mode"]?.stringValue == "performance_training", !isTrainingRow(quest) {
                problems.append("Training allows only 5K or 10K runs and strength")
            }
            texts.append(quest["title"]?.stringValue ?? "")
            texts += (TrainingHistory.params(quest)?.objectValue ?? [:]).values.compactMap(\.stringValue)
        }
        problems += TrainingHistory.limitProblems(bundle, context["trainingHistory"])
        problems += splitProblems(bundle, context)
        problems += unloggedWeightProblems(bundle, context)
        let haystack = texts.joined(separator: "\n").lowercased()
        if unsafe.contains(where: { haystack.contains($0) }) { problems.append("unsafe phrasing") }
        if let regex = try? NSRegularExpression(pattern: #"(\d{3,4})\s*(kcal|calories)"#) {
            for match in regex.matches(in: haystack, range: NSRange(haystack.startIndex..., in: haystack)) {
                if let range = Range(match.range(at: 1), in: haystack), let value = Int(haystack[range]), value < 1500 {
                    problems.append("calorie suggestion below the floor")
                }
            }
        }
        return problems
    }

    static func validateQuest(_ quest: JSONValue, band: String, seen: inout Set<String>) -> [String] {
        var problems: [String] = []
        let identifier = quest["id"]?.stringValue ?? ""
        if !(8...64).contains(length(identifier)) { problems.append("quest id length") }
        if seen.contains(identifier) { problems.append("duplicate quest id") }
        seen.insert(identifier)
        let title = (quest["title"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !(3...48).contains(length(title)) { problems.append("quest title length") }
        if !["daily", "optional"].contains(quest["kind"]?.stringValue ?? "") || quest["difficulty"]?.stringValue == "penalty" { problems.append("quest kind") }
        if !stats.contains(quest["stat"]?.stringValue ?? "") { problems.append("quest stat") }
        let method = quest["verification"]?["method"]?.stringValue
        if !methods.contains(method ?? "") { problems.append("verification method") }
        var params = quest["verification"]?["params"] ?? .object([:])
        if params.objectValue == nil {
            params = .object([:])
            problems.append("verification params")
        }
        let target = quest["progress"]?["target"]?.doubleValue
        let unit = quest["progress"]?["unit"]?.stringValue ?? ""
        if (target ?? 0) <= 0 { problems.append("progress target must be positive") }
        if let object = quest.objectValue, object["completed"] != nil || object["status"] != nil || object["evidence"] != nil {
            problems.append("completion field present")
        }
        problems += boundProblems(title: title, params: params, band: band, target: target, unit: unit)
        return problems
    }

    static func boundProblems(title: String, params: JSONValue, band: String, target: Double?, unit: String) -> [String] {
        var problems: [String] = []
        if band == "yellow", isRun(title: title, params: params), let seconds = durationSec(params, target: target, unit: unit), seconds > 90 * 60 {
            problems.append("run longer than 90 minutes on yellow readiness")
        }
        for key in ["minKcal", "calorieTarget", "calories", "maxKcal", "calorieFloor"] {
            if let value = params[key]?.doubleValue, value < 1500 { problems.append("calorie suggestion below the floor") }
        }
        if unit == "kcal", let target, target < 1500 { problems.append("calorie suggestion below the floor") }
        return problems
    }

    /// A Training day is strength and 5K or 10K runs only. Two 10Ks on one day are two rows.
    static func isTrainingRow(_ quest: JSONValue) -> Bool {
        let method = TrainingHistory.method(quest)
        guard let params = TrainingHistory.params(quest) else { return false }
        let activity = (params["activityType"]?.stringValue ?? "").lowercased()
        if method == "hevy_sets" || (method == "healthkit_workout" && activity.contains("strength")) { return true }
        guard let meters = params["minDistanceMeters"]?.doubleValue, meters == fiveKMeters || meters == tenKMeters else { return false }
        if method == "strava_activity" {
            guard let types = params["types"]?.arrayValue, !types.isEmpty else { return false }
            return types.allSatisfy { ($0.stringValue ?? "").lowercased() == "run" }
        }
        return method == "healthkit_workout" && activity == "running"
    }

    static func isRun(title: String, params: JSONValue) -> Bool {
        let names = (params["types"]?.arrayValue ?? []).map { ($0.stringValue ?? "").lowercased() }
        if names.contains("run") { return true }
        if !names.isEmpty { return false }
        let lowered = title.lowercased()
        if lowered.contains("walk"), !lowered.contains("run") { return false }
        return lowered.contains("run")
    }

    static func durationSec(_ params: JSONValue, target: Double?, unit: String) -> Double? {
        for key in ["minMovingTimeSec", "minDurationSec", "minSec"] {
            if let value = params[key]?.doubleValue { return value }
        }
        if unit == "min", let target { return target * 60 }
        if unit == "sec", let target { return target }
        return nil
    }

    /// Band the app chose for the Training day: WHOOP readiness, lowered after a poor night.
    static func trainingBand(_ context: JSONValue) -> String {
        if let band = context["modeDecision"]?["trainingBand"]?.stringValue, !band.isEmpty { return band }
        if let band = context["whoop"]?["readinessBand"]?.stringValue, !band.isEmpty { return band }
        return "green"
    }

    // MARK: - Template

    static func templateBundle(_ context: JSONValue) -> JSONValue {
        let day = context["player"]?["localDate"]?.stringValue ?? ""
        let mode = context["modeDecision"]?["selectedMode"]?.stringValue ?? "performance_training"
        let band = trainingBand(context)
        var rows = modeQuests(mode: mode, band: band, day: day)
        if mode == "performance_training" { rows = windowRuns(rows, context: context, day: day, mode: mode) }
        var header = headerFor(mode)
        let today = splitToday(context)
        let noGym = context["constraints"]?["noGymToday"]?.boolValue == true
        let advised = context["splitAdvice"].truthy
        if mode == "performance_training", let today, !noGym, !advised {
            rows = rows.filter { $0["stat"]?.stringValue != "STR" } + splitQuests(today, band: band, day: day, mode: mode)
            header = today["name"]?.stringValue ?? header
        } else if mode == "performance_training", advised {
            rows = rows.filter { $0["stat"]?.stringValue != "STR" }
        }
        if mode == "performance_training", noGym { rows = noGymQuests(rows, day: day, mode: mode) }
        let required = Array(rows.filter { $0["kind"]?.stringValue != "optional" }.prefix(8))
        let optional = Array(rows.filter { $0["kind"]?.stringValue == "optional" }.prefix(1))
        return .object([
            "schemaVersion": .number(1),
            "dayKey": .string(day),
            "mode": .string(mode),
            "headerLine": .string(header),
            "narrative": .string(narrativeFor(band: band)),
            "threat": .string(threatFor(band: band)),
            "quests": .array(Array((required + optional).prefix(9))),
            "warnings": .array([.string(defaultWarning)]),
            "generatedBy": .string("template"),
        ])
    }

    static func modeQuests(mode: String, band: String, day: String) -> [JSONValue] {
        if mode == "full_recovery" {
            return [quest(day, "sleep", "Sleep Hygiene", "daily", "REC", "timer_session", ["minSec": .number(600), "label": .string("Sleep Hygiene")], "easy", 10, "min", mode)]
        }
        // Training is strength and 10K runs only; the app adds Stretching.
        let run = quest(day, "run_10k", "10K Run", "daily", "END", "strava_activity", ["types": .array([.string("Run")]), "minDistanceMeters": .number(tenKMeters)], "normal", 10, "km", mode)
        if band == "yellow" || band == "red" {
            let push = quest(day, "push", "Push Session", "daily", "STR", "healthkit_workout", ["activityType": .string("traditionalStrengthTraining"), "minDurationSec": .number(1800)], "normal", 30, "min", mode)
            return [run, push]
        }
        let bench = quest(day, "bench", "Bench Press", "daily", "STR", "hevy_sets", ["exercise": .string("Bench Press"), "sets": .number(4)], "normal", 4, "sets", mode)
        return [run, bench]
    }

    /// Today's runs from the 50 km window: two 10Ks, a 10K and a 5K, or none when the window is already full.
    /// Without a window (no history yet) the rows keep their default 10K.
    static func windowRuns(_ rows: [JSONValue], context: JSONValue, day: String, mode: String) -> [JSONValue] {
        guard let window = context["trainingHistory"]?["runWindow"], window.objectValue != nil else { return rows }
        let planned = (window["runsToday"]?.arrayValue ?? []).compactMap(\.stringValue)
        let lifts = rows.filter { $0["stat"]?.stringValue != "END" }
        let runs = planned.enumerated().map { index, label in
            let meters = label == "10K" ? tenKMeters : fiveKMeters
            return quest(day, "run_\(label.lowercased())_\(index + 1)", "\(label) Run", "daily", "END", "strava_activity",
                         ["types": .array([.string("Run")]), "minDistanceMeters": .number(meters)], "normal", meters / 1000, "km", mode)
        }
        return runs + lifts
    }

    /// Today's split exercises without loads, like the app's offline day. Yellow and red take a set off the main lift.
    static func splitQuests(_ today: JSONValue, band: String, day: String, mode: String) -> [JSONValue] {
        (today["exercises"]?.arrayValue ?? []).map { item in
            let main = item["role"]?.stringValue == "main"
            var sets = item["sets"]?.intValue.flatMap { $0 == 0 ? nil : $0 } ?? 3
            if main, band != "green" { sets = max(1, sets - 1) }
            let name = item["exercise"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "Lift"
            let slug = name.lowercased().replacingOccurrences(of: " ", with: "_") + (item["role"]?.stringValue == "light" ? "_light" : "")
            if let seconds = item["secondsPerSet"]?.doubleValue, seconds > 0 {
                let params: [String: JSONValue] = ["exercise": .string(name), "sets": .number(Double(sets)), "minDurationSec": .number(seconds * Double(sets))]
                return quest(day, slug, "\(name) \(sets)x\(Int(seconds))s", "daily", "STR", "hevy_sets", params, "normal", seconds * Double(sets) / 60, "min", mode)
            }
            let low = item["minReps"]?.intValue.flatMap { $0 == 0 ? nil : $0 } ?? 1
            let high = item["maxReps"]?.intValue.flatMap { $0 == 0 ? nil : $0 } ?? 1
            let reps = low == high ? "\(low)" : "\(low)-\(high)"
            let params: [String: JSONValue] = ["exercise": .string(name), "sets": .number(Double(sets)), "minReps": .number(Double(low))]
            let kind = item["optional"]?.boolValue == true ? "optional" : "daily"
            return quest(day, slug, "\(name) \(sets)x\(reps)", kind, "STR", "hevy_sets", params, main ? "hard" : "normal", Double(sets), "sets", mode)
        }
    }

    /// No gym today: the lifts give way to 10Ks, up to two runs, like the app.
    static func noGymQuests(_ rows: [JSONValue], day: String, mode: String) -> [JSONValue] {
        var runs = rows.filter { $0["stat"]?.stringValue != "STR" }
        let taken = Set(runs.compactMap { $0["id"]?.stringValue })
        var index = runs.count
        while index < 2 {
            let slug = ["run_10k_\(index + 1)", "run_10k_extra_\(index + 1)"].first { !taken.contains("q_\(day)_\($0)") } ?? "run_10k_extra_\(index + 1)"
            runs.append(quest(day, slug, "10K Run", "daily", "END", "strava_activity", ["types": .array([.string("Run")]), "minDistanceMeters": .number(tenKMeters)], "normal", 10, "km", mode))
            index += 1
        }
        return runs
    }

    static func quest(_ day: String, _ slug: String, _ title: String, _ kind: String, _ stat: String, _ method: String, _ params: [String: JSONValue],
                      _ difficulty: String, _ target: Double, _ unit: String, _ mode: String) -> JSONValue {
        .object([
            "id": .string(String("q_\(day)_\(slug)".prefix(64))),
            "title": .string(String(title.prefix(48))),
            "kind": .string(kind),
            "stat": .string(stat),
            "verification": .object(["method": .string(method), "params": .object(params)]),
            "deadline": .string("\(day)T23:59:59Z"),
            "difficulty": .string(difficulty),
            "mode": .string(mode),
            "progress": .object(["current": .number(0), "target": .number(target), "unit": .string(unit)]),
        ])
    }

    static func headerFor(_ mode: String) -> String {
        ["performance_training": "Training", "full_recovery": "Full Recovery Day"][mode] ?? "Daily Quest"
    }

    /// The penalty screen's line. Missing is fine (the app has its own); present, it must keep the System's voice.
    static func threatProblems(_ value: JSONValue?) -> [String] {
        guard let value, value != .null else { return [] }
        guard let threat = value.stringValue else { return ["threat must be text"] }
        let text = threat.trimmingCharacters(in: .whitespacesAndNewlines)
        let ending = PenaltyDecay.threatEnding
        if length(text) > PenaltyDecay.threatMaxCharacters { return ["threat is too long"] }
        if text.lowercased().contains("penalty") { return ["threat must not say penalty"] }
        if !text.hasSuffix(ending) || length(text) <= length(ending) {
            return ["threat must be a sentence about the Player, then \"\(ending)\""]
        }
        if !text.lowercased().contains("player") || text.contains("!") {
            return ["threat must speak of the Player, without exclamation marks"]
        }
        return []
    }

    /// The template's line. Claude writes a sharper one from the data when it plans the day.
    static func threatFor(band: String) -> String {
        let fault = band == "yellow" || band == "red" ? "Weakness" : "Laziness"
        return "\(fault) is present and is damaging the Player. \(PenaltyDecay.threatEnding)"
    }

    static func narrativeFor(band: String) -> String {
        band == "yellow" || band == "red" ? "Moderate day. Keep the lifting moderate." : "The daily quest is waiting."
    }
}
