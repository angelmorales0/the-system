import Foundation

/// The day's lifts and stretches as one Hevy routine, so the workout is ready in the Hevy app: the player opens the
/// routine, starts it, and types only reps and weight.
///
/// Hevy's API can write routines, not a workout in progress, and it cannot start one. So the app keeps ONE routine,
/// "The System: Bench Day", and writes it again when the day's rows change. A free Hevy account holds 4 routines;
/// one routine that changes uses one place.
enum HevyRoutine {
    static let titlePrefix = "The System"
    static let idKey = "hevyRoutineId"
    static let signatureKey = "hevyRoutineSignature"
    static let refusedKey = "hevyRoutineSignature.refused"
    static let templatesKey = "hevyRoutineTemplateIds"
    static let typesKey = "hevyRoutineTemplateTypes"
    static let ranksKey = "hevyRoutineTemplateRanks"
    /// Set when Hevy's list was read with the equipment order.
    static let readKey = "hevyRoutineTemplateTypes.read.v2"
    /// Hevy's answer to the last routine it refused, for the developer. The player does not see it.
    static let errorKey = "hevyRoutineError"
    static let missingKey = "hevyRoutineTemplateIds.missing"
    /// Hevy lists 100 exercise templates in a page. The built-in list and a player's own exercises fit in these.
    static let templatePages = 12
    /// Routines come 10 in a page. The routine of an earlier install is looked for in these.
    static let routinePages = 10

    struct SetPlan: Equatable {
        var repsLow: Int?
        var repsHigh: Int?
        var seconds: Int?
        var weightKg: Double?
    }

    struct ExercisePlan: Equatable {
        /// The row's exercise, as the Hevy check names it.
        var name: String
        var templateId: String?
        var sets: [SetPlan]
        var note: String?
    }

    struct Plan: Equatable {
        var title: String
        var exercises: [ExercisePlan]

        /// The exercises Hevy can take: the ones whose Hevy exercise is known.
        var known: [ExercisePlan] { exercises.filter { $0.templateId != nil } }
        var unknown: [String] { exercises.filter { $0.templateId == nil }.map(\.name) }
    }

    /// What a row asks of the load, which decides the Hevy exercise and the weight it gets.
    enum Load: Equatable {
        /// The plan names a weight, or the split says the lift is weighted (weighted pull-ups).
        case weighted
        /// Bodyweight work: the split's volume and max-effort pull-ups.
        case bodyweight
        case any
    }

    /// The order of equipment for one exercise name: barbell, then other free weights and bodyweight, then a
    /// machine, then a cable, then a band or other help. Biceps and side delts take the dumbbell before the barbell.
    /// The words of the title come first: Hevy files a cable exercise under "machine".
    static func rank(title: String, equipment: String? = nil, dumbbellFirst: Bool = false) -> Int {
        let text = title.lowercased()
        let kind: String
        if let open = text.lastIndex(of: "("), text.hasSuffix(")") { kind = String(text[open...]) } else { kind = "" }
        func has(_ words: [String], in source: String) -> Bool { words.contains { source.contains($0) } }
        if has(["band", "assisted", "suspension"], in: kind) { return 4 }
        if text.contains("cable") { return 3 }
        if has(["machine", "smith", "lever"], in: kind) { return 2 }
        if has(["barbell", "ez bar", "trap bar"], in: kind) { return dumbbellFirst ? 1 : 0 }
        if kind.contains("dumbbell") { return dumbbellFirst ? 0 : 1 }
        if !kind.isEmpty { return 1 }
        switch equipment?.lowercased() {
        case "barbell": return dumbbellFirst ? 1 : 0
        case "dumbbell": return dumbbellFirst ? 0 : 1
        case "machine": return 2
        case "resistance_band", "suspension": return 4
        default: return 1
        }
    }

    /// Free weights are one group for a log: the player's newest free-weight exercise stays. Not for biceps and side delts.
    static func group(_ rank: Int, dumbbellFirst: Bool) -> Int { dumbbellFirst ? rank : [0, 0, 1, 2, 3][min(max(rank, 0), 4)] }

    /// Biceps and side delts: the dumbbell is first there. `muscle` is Hevy's primary muscle, when it is known.
    static func dumbbellFirst(name: String, muscle: String? = nil) -> Bool {
        if muscle?.lowercased() == "biceps" || name.contains("lateral raise") { return true }
        return name.contains("curl") && !["leg", "wrist", "hamstring", "nordic", "reverse"].contains { name.contains($0) }
    }

    /// The Hevy exercise and the weight for one row, from the player's own logs, newest first.
    ///
    /// The log must be of the row's job, not only of its name: Squat is heavy on one day and light on another, and
    /// pull-ups are weighted, bodyweight, or band-assisted. So a weight comes only from a session whose reps fit
    /// the row, a bodyweight row takes a log with no weight, and an assisted log is taken only when there is no
    /// other, and never for its weight (that number is help, not load).
    static func logged(name: String, templateId: String?, load: Load, low: Int?, high: Int?, plannedKg: Double?,
                       newestFirst: [HevyWorkout]) -> (templateId: String, weightKg: Double?, group: Int)? {
        var found: [(entry: HevyExercise, id: String)] = []
        for workout in newestFirst {
            for entry in workout.exercises {
                guard let id = entry.templateId else { continue }
                if templateId.map({ $0 == id }) ?? (StrengthLevel.normalizedName(entry.title) == name) { found.append((entry, id)) }
            }
        }
        let plain = found.filter { !StrengthLevel.isAssisted($0.entry.title) }
        let assistedOnly = plain.isEmpty
        // The best equipment the player logged for this name, then the newest log of it.
        let first = dumbbellFirst(name: name)
        func group(_ entry: HevyExercise) -> Int { HevyRoutine.group(rank(title: entry.title, dumbbellFirst: first), dumbbellFirst: first) }
        let best = (assistedOnly ? found : plain).map { group($0.entry) }.min()
        let pool = (assistedOnly ? found : plain).filter { group($0.entry) == best }
        guard let newest = pool.first, let best else { return nil }
        func working(_ entry: HevyExercise) -> [HevySet] { entry.sets.filter(\.isWorking) }
        func loaded(_ entry: HevyExercise) -> [HevySet] { working(entry).filter { ($0.weightKg ?? 0) > 0 } }
        func fits(_ set: HevySet) -> Bool {
            guard let reps = set.reps, let low, let high else { return true }
            return reps >= low && reps <= max(low, high)
        }
        switch load {
        case .bodyweight:
            let own = pool.first { loaded($0.entry).isEmpty } ?? newest
            return (own.id, nil, best)
        case .weighted, .any:
            if let plannedKg {
                // The plan's weight goes on the exercise that carried about that weight: a barbell weight does not
                // go on the dumbbell exercise the player used last.
                let own = pool.first { loaded($0.entry).contains { ($0.weightKg ?? 0) >= 0.8 * plannedKg } } ?? newest
                // On a band-assisted exercise Hevy reads the number as help: no weight there.
                return (own.id, assistedOnly ? nil : plannedKg, best)
            }
            if !assistedOnly, let own = pool.first(where: { loaded($0.entry).contains(where: fits) }) {
                return (own.id, loaded(own.entry).filter(fits).compactMap(\.weightKg).max(), best)
            }
            return (newest.id, nil, best)
        }
    }

    /// The lift rows of the day in list order, then the stretches of the day. Nil when the day has none of them.
    /// Finished rows stay in the plan: the routine is the day's workout, and it does not change while it is done.
    ///
    /// `templates` is Hevy's own list, by the name rule of the Hevy check, for a name the player never logged.
    /// `types` is the Hevy type of each exercise id, when it is known: a set holds only what its exercise takes.
    /// `ranks` is the equipment order of the exercise that `templates` holds for each name. A log stays only when
    /// its equipment is as good as that: a barbell exercise in Hevy's list comes before a machine log.
    static func plan(for bundle: QuestBundle, history: [HevyWorkout], templates: [String: String], types: [String: String] = [:],
                     ranks: [String: Int] = [:]) -> Plan? {
        /// The log, when Hevy's list holds no exercise of better equipment for the name.
        func kept(_ found: (templateId: String, weightKg: Double?, group: Int)?, _ name: String) -> (templateId: String, weightKg: Double?, group: Int)? {
            guard let found, templates[name] != nil, let listed = ranks[name] else { return found }
            return found.group <= group(listed, dumbbellFirst: dumbbellFirst(name: name)) ? found : nil
        }
        let newestFirst = history.sorted { $0.start > $1.start }
        let split = GymSplit.day(named: bundle.headerLine)
        var exercises: [ExercisePlan] = []
        for quest in bundle.quests where quest.verification.method == .hevySets && quest.id != DailyStretch.questId && quest.kind != .penalty {
            let params = quest.verification.params
            let shown = params["exercise"]?.stringValue ?? quest.title
            let name = StrengthLevel.normalizedName(shown)
            let range = repRange(quest)
            let count = setCount(quest)
            let plannedKg = params["minWeightKg"]?.doubleValue.flatMap { $0 > 0 ? $0 : nil }
            let light = quest.id.hasSuffix("_light")
            let own = split?.exercises.first { StrengthLevel.normalizedName($0.exercise) == name && ($0.role == .light) == light }
            let load: Load = plannedKg != nil || own?.note?.hasPrefix("Weighted") == true ? .weighted
                : (own?.note == GymSplit.pullUpVolume || own?.note == GymSplit.pullUpMax ? .bodyweight : .any)
            let low = range?.low ?? params["minReps"]?.doubleValue.map { Int($0) }
            let fixed = params["templateId"]?.stringValue
            let log = logged(name: name, templateId: fixed, load: load, low: low, high: range?.high ?? low,
                             plannedKg: plannedKg, newestFirst: newestFirst)
            let found = fixed != nil ? log : kept(log, name)
            let templateId = params["templateId"]?.stringValue ?? found?.templateId ?? templates[name]
            var set = SetPlan()
            if let total = params["minDurationSec"]?.doubleValue {
                set.seconds = max(1, Int((total / Double(count)).rounded()))
            } else {
                set.repsLow = low
                set.repsHigh = range?.high ?? low
                // The log's answer when there is a log: it holds the plan's weight, or none for a band-assisted exercise.
                set.weightKg = found != nil ? found?.weightKg : plannedKg
            }
            exercises.append(ExercisePlan(name: shown, templateId: templateId, sets: Array(repeating: fitted(set, to: templateId.flatMap { types[$0] }), count: count),
                                          note: [quest.title, own?.note].compactMap { $0 }.joined(separator: ". ")))
        }
        if let stretchRow = bundle.quests.first(where: { $0.id == DailyStretch.questId }), let day = StretchSplit.day(of: stretchRow) {
            for stretch in day.stretches {
                let name = StrengthLevel.normalizedName(stretch.name)
                let seconds = stretch.seconds * (stretch.perSide ? 2 : 1)
                let templateId = kept(logged(name: name, templateId: nil, load: .bodyweight, low: nil, high: nil, plannedKg: nil, newestFirst: newestFirst), name)?.templateId ?? templates[name]
                exercises.append(ExercisePlan(
                    name: stretch.name,
                    templateId: templateId,
                    sets: Array(repeating: fitted(SetPlan(seconds: seconds), to: templateId.flatMap { types[$0] }), count: stretch.sets),
                    note: stretch.perSide ? "\(stretch.seconds) s each side in one set." : nil
                ))
            }
        }
        guard !exercises.isEmpty else { return nil }
        return Plan(title: "\(titlePrefix): \(bundle.headerLine)", exercises: exercises)
    }

    /// A set holds only what its Hevy exercise takes: Hevy can refuse a whole routine for one set that does not fit.
    /// A hold on an exercise that counts reps, or a weight on a bodyweight exercise, is left empty for the player.
    /// An exercise of an unknown type gets the set as planned.
    static func fitted(_ set: SetPlan, to type: String?) -> SetPlan {
        guard let type = type?.lowercased(), !type.isEmpty else { return set }
        // Hevy's types are words joined by "_": weight_reps, bodyweight_reps, weighted_bodyweight, duration, ...
        let words = Set(type.split(separator: "_").map(String.init))
        var copy = set
        // weighted_bodyweight and assisted_bodyweight count reps too.
        if !words.contains("reps") && !words.contains("bodyweight") { copy.repsLow = nil; copy.repsHigh = nil }
        if !words.contains("duration") { copy.seconds = nil }
        if words.isDisjoint(with: ["weight", "weighted", "assisted"]) { copy.weightKg = nil }
        return copy
    }

    /// The sets of a row: its `sets`, else the number before the "×" of its title, else its target when that counts sets.
    static func setCount(_ quest: Quest) -> Int {
        if let sets = quest.verification.params["sets"]?.doubleValue, sets >= 1 { return Int(sets) }
        if let match = quest.title.range(of: #"\d+\s*[×xX]\s*\d"#, options: .regularExpression),
           let count = Int(quest.title[match].prefix(while: \.isNumber)), count >= 1 { return count }
        return quest.progress.unit == "sets" ? max(1, Int(quest.progress.target)) : 1
    }

    /// "Bench Press 3×3-5" gives 3 to 5. "Dead Hang 3×60s" and "Farmers Walk 3×40m" give nil: time and distance.
    /// The sets come before the mark, so a number in the exercise's name ("Max 10 Push Up 3×8") is not the reps.
    /// A row's own `reps` param wins over its title, like the 300 burpees: one set of 300 under the title "300 Burpees".
    static func repRange(_ quest: Quest) -> (low: Int, high: Int)? {
        if let reps = quest.verification.params["reps"]?.doubleValue, reps >= 1 { return (Int(reps), Int(reps)) }
        let pattern = #"\d+\s*[×xX]\s*(\d+)(?:\s*[-–]\s*(\d+))?(?!\d|\s*(?:s|sec|m|min|km)\b)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: quest.title, range: NSRange(quest.title.startIndex..., in: quest.title)),
              let lowRange = Range(match.range(at: 1), in: quest.title), let low = Int(quest.title[lowRange]) else { return nil }
        let high = Range(match.range(at: 2), in: quest.title).flatMap { Int(quest.title[$0]) }
        return (low, max(low, high ?? low))
    }

    /// The body of Hevy's "create routine" and "update routine" calls. `create` adds the folder: null is "My Routines".
    static func body(_ plan: Plan, create: Bool) -> JSONValue {
        let exercises: [JSONValue] = plan.known.map { exercise in
            .object([
                "exercise_template_id": .string(exercise.templateId ?? ""),
                "superset_id": .null,
                "rest_seconds": .null,
                "notes": exercise.note.map(JSONValue.string) ?? .null,
                "sets": .array(exercise.sets.map { set in
                    let range = set.repsLow != nil && set.repsLow != set.repsHigh
                    var fields: [String: JSONValue] = [
                        "type": .string("normal"),
                        "weight_kg": set.weightKg.map { .number(($0 * 100).rounded() / 100) } ?? .null,
                        "reps": range ? .null : set.repsLow.map { .number(Double($0)) } ?? .null,
                        "distance_meters": .null,
                        "duration_seconds": set.seconds.map { .number(Double($0)) } ?? .null,
                        "custom_metric": .null,
                    ]
                    // No "rep_range" key when there is no range. Hevy's update call refuses a null there
                    // ("Expected object, received null", HTTP 400), although its documentation permits it.
                    if range { fields["rep_range"] = .object(["start": .number(Double(set.repsLow ?? 0)), "end": .number(Double(set.repsHigh ?? 0))]) }
                    return .object(fields)
                }),
            ])
        }
        var routine: [String: JSONValue] = [
            "title": .string(plan.title),
            "notes": .string(notes(plan)),
            "exercises": .array(exercises),
        ]
        if create { routine["folder_id"] = .null }
        return .object(["routine": .object(routine)])
    }

    static func notes(_ plan: Plan) -> String {
        let base = "Written by The System. It changes with the day's quests."
        return plan.unknown.isEmpty ? base : base + " Not found in Hevy: " + plan.unknown.joined(separator: ", ") + "."
    }

    /// Changes when the routine Hevy should hold changes.
    static func signature(_ plan: Plan) -> String {
        EvidenceHash.sha256(body(plan, create: false).sortedString())
    }

    /// Changes when the rows the routine is made of change: the store writes the routine again then.
    static func rowsKey(_ bundle: QuestBundle) -> String {
        let lifts = bundle.quests.filter { $0.verification.method == .hevySets && $0.kind != .penalty }
        return ([bundle.dayKey, bundle.headerLine] + lifts.map { "\($0.id)|\($0.title)|\($0.verification.params.sortedText)" }).joined(separator: "\n")
    }

    // MARK: - Hevy calls

    /// The calls to Hevy, so the self-check can run the write with no network.
    struct Transport {
        var get: (URL, [String: String]) async -> (status: Int, json: JSONValue?)?
        var send: (String, URL, [String: String], JSONValue) async -> (status: Int, json: JSONValue?)?

        static let live = Transport(
            get: { url, headers in await OnDeviceHTTP.get(url, headers: headers) },
            send: { method, url, headers, body in await OnDeviceHTTP.sendJSON(method, url, headers: headers, body: body) }
        )
    }

    /// Every exercise Hevy knows on this account: its id by the name rule of the Hevy check, and its type by id.
    /// Of the exercises with one name ("Deadlift (Barbell)", "Deadlift (Band)") the one with the best equipment
    /// stays: see `rank`. Nil when Hevy's list could not be read to its end.
    static func loadTemplates(key: String, transport: Transport) async -> (ids: [String: String], types: [String: String], ranks: [String: Int])? {
        var ids: [String: String] = [:]
        var types: [String: String] = [:]
        var ranks: [String: Int] = [:]
        for number in 1...templatePages {
            guard let url = OnDeviceHTTP.url("\(HevyClient.api)/v1/exercise_templates", [("page", String(number)), ("pageSize", "100")]),
                  let reply = await transport.get(url, HevyClient.headers(key)), (200..<300).contains(reply.status),
                  let items = reply.json?["exercise_templates"]?.arrayValue else { return nil }
            for item in items {
                guard let id = item["id"]?.stringValue, !id.isEmpty, let title = item["title"]?.stringValue else { continue }
                let name = StrengthLevel.normalizedName(title)
                let order = rank(title: title, equipment: item["equipment"]?.stringValue,
                                 dumbbellFirst: dumbbellFirst(name: name, muscle: item["primary_muscle_group"]?.stringValue))
                // The best equipment for the name; of two that are equal, the first one Hevy lists.
                if order < ranks[name] ?? Int.max {
                    ids[name] = id
                    ranks[name] = order
                }
                if let type = item["type"]?.stringValue { types[id] = type }
            }
            if items.isEmpty || number >= (reply.json?["page_count"]?.intValue ?? number) { break }
        }
        return (ids, types, ranks)
    }

    enum Lookup: Equatable {
        case found(String)
        /// Hevy's list was read to its end and holds no routine of the app.
        case none
        /// The list could not be read. A new routine must not be made: one can be there.
        case failed
    }

    /// The routine an earlier install made, by its title.
    static func existingRoutine(key: String, transport: Transport) async -> Lookup {
        for number in 1...routinePages {
            guard let url = OnDeviceHTTP.url("\(HevyClient.api)/v1/routines", [("page", String(number)), ("pageSize", "10")]),
                  let reply = await transport.get(url, HevyClient.headers(key)), (200..<300).contains(reply.status),
                  let items = reply.json?["routines"]?.arrayValue else { return .failed }
            if let id = items.first(where: { $0["title"]?.stringValue?.hasPrefix(titlePrefix + ":") == true })?["id"]?.stringValue, !id.isEmpty {
                return .found(id)
            }
            if items.isEmpty || number >= (reply.json?["page_count"]?.intValue ?? number) { return .none }
        }
        // More routines than the pages read: one of the app's can be past them.
        return .failed
    }

    /// The id in Hevy's reply, which holds the routine as an object or as a list of one.
    static func routineId(in reply: JSONValue?) -> String? {
        let routine = reply?["routine"]
        let id = routine?["id"]?.stringValue ?? routine?.arrayValue?.first?["id"]?.stringValue
        return id.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Writes the day's routine to Hevy when it changed. Returns a line for the player, or nil when nothing was sent.
    ///
    /// A new routine is made only when Hevy's list was read to its end and holds none of the app's, or when Hevy
    /// says the stored one is gone (404). Any failure to read or write leaves Hevy as it is and tries again later.
    static func sync(bundle: QuestBundle, history: [HevyWorkout], key: String? = SecretStore.read(.hevyApiKey),
                     defaults: UserDefaults = .standard, transport: Transport = .live) async -> String? {
        guard let key else { return nil }
        var templates = defaults.dictionary(forKey: templatesKey) as? [String: String] ?? [:]
        var types = defaults.dictionary(forKey: typesKey) as? [String: String] ?? [:]
        var ranks = defaults.dictionary(forKey: ranksKey) as? [String: Int] ?? [:]
        // A list read before the equipment order is not used: its exercise for a name can be the band one.
        if !defaults.bool(forKey: readKey) { templates = [:] }
        guard var plan = plan(for: bundle, history: history, templates: templates, types: types, ranks: ranks) else { return nil }
        // Hevy's list is read one time, for the types, and again for each new set of names that are not known.
        let missing = plan.unknown.joined(separator: "|")
        if !defaults.bool(forKey: readKey) || (!missing.isEmpty && defaults.string(forKey: missingKey) != missing) {
            if let loaded = await loadTemplates(key: key, transport: transport) {
                templates = loaded.ids
                types = loaded.types
                ranks = loaded.ranks
                defaults.set(loaded.ids, forKey: templatesKey)
                defaults.set(loaded.types, forKey: typesKey)
                defaults.set(loaded.ranks, forKey: ranksKey)
                defaults.set(true, forKey: readKey)
                plan = self.plan(for: bundle, history: history, templates: templates, types: types, ranks: ranks) ?? plan
                // The names Hevy's list does not hold: the list is not read again for them.
                defaults.set(plan.unknown.joined(separator: "|"), forKey: missingKey)
            }
        }
        guard !plan.known.isEmpty else { return "Hevy has none of today's exercises. No routine was written." }
        let signature = signature(plan)
        // The same routine is sent one time, also when Hevy refused it: a new day or a new plan sends again.
        guard defaults.string(forKey: signatureKey) != signature, defaults.string(forKey: refusedKey) != signature else { return nil }

        var id = defaults.string(forKey: idKey)
        if id == nil {
            switch await existingRoutine(key: key, transport: transport) {
            case .found(let found): id = found
            case .none: break
            case .failed: return "Hevy did not answer. The routine is written at the next refresh."
            }
        }
        var reply: (status: Int, json: JSONValue?)?
        var created = false
        if let id, let url = URL(string: "\(HevyClient.api)/v1/routines/\(id)") {
            reply = await transport.send("PUT", url, HevyClient.headers(key), body(plan, create: false))
            guard reply != nil else { return "Hevy did not answer. The routine is written at the next refresh." }
        }
        // No routine yet, or the player deleted it in Hevy.
        if id == nil || reply?.status == 404, let url = URL(string: "\(HevyClient.api)/v1/routines") {
            // The stored id is gone. If the reply to the new routine is lost, the next write finds it by title.
            defaults.removeObject(forKey: idKey)
            reply = await transport.send("POST", url, HevyClient.headers(key), body(plan, create: true))
            created = true
        }
        guard let reply else { return "Hevy did not answer. The routine is written at the next refresh." }
        guard (200..<300).contains(reply.status) else {
            if created { defaults.removeObject(forKey: idKey) }
            if reply.status == 403 { return "Hevy holds its limit of routines. Delete one in Hevy, and the day's routine is written." }
            if reply.status == 400 { defaults.set(signature, forKey: refusedKey) }
            // Hevy's own words and the body it refused, kept for the developer. The player sees no line: an empty
            // note takes the line of an earlier write off the screen.
            defaults.set("HTTP \(reply.status) \(reply.json?.sortedString() ?? "") BODY \(body(plan, create: created).sortedString())", forKey: errorKey)
            return ""
        }
        if created {
            // Only the id Hevy gave. With none, the next write finds the routine by its title.
            if let made = routineId(in: reply.json) { defaults.set(made, forKey: idKey) } else { defaults.removeObject(forKey: idKey) }
        } else if let id {
            defaults.set(id, forKey: idKey)
        }
        defaults.set(signature, forKey: signatureKey)
        return "In Hevy: \"\(plan.title)\"." + (plan.unknown.isEmpty ? "" : " Not in Hevy: \(plan.unknown.joined(separator: ", ")).")
    }

    // MARK: - Self-check (runs in DEBUG at launch)

    static func check() -> [String] {
        var errors: [String] = []
        let catalog = FallbackCatalog.bundled()
        guard let now = QuestDay.time(on: "2026-10-05", minutes: 240) else { return ["could not build routine dates"] }
        let day = GameSnapshot.fresh(catalog: catalog, now: now)
        let lifts = day.bundle.quests.filter { $0.verification.method == .hevySets && $0.id != DailyStretch.questId }
        guard let bench = lifts.first(where: { $0.title.hasPrefix("Bench Press") }), let pull = lifts.first(where: { $0.title.hasPrefix("Pull Up") }) else {
            return ["a fresh day should be Bench Day with Bench Press and Pull Up, got \(lifts.map(\.title))"]
        }
        func logged(_ title: String, _ id: String, kg: Double?, reps: Int, daysAgo: Double) -> HevyWorkout {
            let start = now.addingTimeInterval(-daysAgo * 86_400)
            let sets = [HevySet(type: "warmup", reps: 10, weightKg: 200, rpe: nil, durationSec: nil), HevySet(type: "normal", reps: reps, weightKg: kg, rpe: nil, durationSec: nil)]
            return HevyWorkout(id: "\(id)-\(daysAgo)", title: "Gym", start: start, end: start.addingTimeInterval(3_600),
                               exercises: [HevyExercise(title: title, templateId: id, sets: sets)])
        }
        // The player benches with dumbbells now: the newest log names the Hevy exercise and its top working weight.
        let range = repRange(bench)
        let benchReps = range?.low ?? 5
        let history = [logged("Bench Press (Barbell)", "BARBELL", kg: 80, reps: benchReps, daysAgo: 9), logged("Bench Press (Dumbbell)", "DUMBBELL", kg: 36, reps: benchReps, daysAgo: 2),
                       logged("Pull Up", "PULLUP", kg: nil, reps: 8, daysAgo: 4), logged("Pull Up (Weighted)", "WEIGHTED", kg: 10, reps: 5, daysAgo: 2),
                       logged("Pull Up (Assisted)", "ASSISTED", kg: 30, reps: 8, daysAgo: 1)]
        guard let plan = plan(for: day.bundle, history: history, templates: ["lateral raise": "LATERAL"]) else { return ["a Bench Day should give a routine"] }
        if plan.title != "\(titlePrefix): \(day.bundle.headerLine)" { errors.append("the routine should carry the day's name, got \(plan.title)") }
        let benchPlan = plan.exercises.first { $0.name == bench.verification.params["exercise"]?.stringValue }
        if benchPlan?.templateId != "DUMBBELL" || benchPlan?.sets.count != Int(bench.verification.params["sets"]?.doubleValue ?? 0)
            || benchPlan?.sets.first?.weightKg != 36 || range == nil || benchPlan?.sets.first?.repsLow != range?.low || benchPlan?.sets.first?.repsHigh != range?.high {
            errors.append("Bench Press should be the exercise logged last, with the row's sets and reps and the last top weight, got \(String(describing: benchPlan))")
        }
        // Bench Day's pull-ups are bodyweight volume: not the weighted log, and not the band-assisted one or its 30 kg of help.
        let pullPlan = plan.exercises.first { $0.name == pull.verification.params["exercise"]?.stringValue }
        if pullPlan?.templateId != "PULLUP" || pullPlan?.sets.count != GymSplit.maxPullUpSets || pullPlan?.sets.first?.weightKg != nil {
            errors.append("Bench Day's Pull Up should be the bodyweight exercise with 4 sets and no weight, got \(String(describing: pullPlan))")
        }
        if plan.exercises.first(where: { StrengthLevel.normalizedName($0.name) == "lateral raise" })?.templateId != "LATERAL" {
            errors.append("an exercise with no log should take its Hevy exercise from Hevy's list")
        }
        if plan.unknown.isEmpty || plan.known.count + plan.unknown.count != plan.exercises.count {
            errors.append("exercises Hevy does not know should be named, not sent")
        }
        // The log is of the row's job. A light squat row (8 reps) takes no weight from the heavy day, and the heavy
        // row takes the heavy day's. The plan's 82.5 kg goes on the barbell bench, which carried it, not on the dumbbells.
        let squats = [logged("Squat (Barbell)", "SQUAT", kg: 140, reps: 5, daysAgo: 2), logged("Squat (Barbell)", "SQUAT", kg: 90, reps: 8, daysAgo: 4)]
        let newestFirst = squats.sorted { $0.start > $1.start }
        let lightSquat = HevyRoutine.logged(name: "squat", templateId: nil, load: .any, low: 8, high: 8, plannedKg: nil, newestFirst: newestFirst)
        let heavySquat = HevyRoutine.logged(name: "squat", templateId: nil, load: .any, low: 1, high: 5, plannedKg: nil, newestFirst: newestFirst)
        let planned = HevyRoutine.logged(name: "bench press", templateId: nil, load: .weighted, low: 5, high: 5, plannedKg: 82.5, newestFirst: history.sorted { $0.start > $1.start })
        let weighted = HevyRoutine.logged(name: "pull up", templateId: nil, load: .weighted, low: 3, high: 5, plannedKg: nil, newestFirst: history.sorted { $0.start > $1.start })
        if lightSquat?.weightKg != 90 || heavySquat?.weightKg != 140 || planned?.templateId != "BARBELL" || planned?.weightKg != 82.5
            || weighted?.templateId != "WEIGHTED" || weighted?.weightKg != 10 {
            errors.append("the exercise and the weight should come from a log of the row's job, got \(String(describing: lightSquat)) \(String(describing: heavySquat)) \(String(describing: planned)) \(String(describing: weighted))")
        }
        // The plan names 10 kg for the pull-ups, and the only log is band-assisted: the routine holds no weight there.
        var weightedRow = day.bundle
        if let at = weightedRow.quests.firstIndex(where: { $0.id == pull.id }) {
            weightedRow.quests[at].verification.params["minWeightKg"] = .number(10)
            let assistedOnly = HevyRoutine.plan(for: weightedRow, history: [logged("Pull Up (Assisted)", "ASSISTED", kg: 30, reps: 8, daysAgo: 1)], templates: [:])
            let set = assistedOnly?.exercises.first { $0.templateId == "ASSISTED" }?.sets.first
            if set == nil || set?.weightKg != nil {
                errors.append("the plan's weight should not go on a band-assisted exercise, got \(String(describing: set))")
            }
        }
        // The equipment order: barbell, other free weights, machine, cable, band. Biceps and side delts: dumbbell first.
        let order = ["Deadlift (Barbell)", "Deadlift (Dumbbell)", "Deadlift (Smith Machine)", "Cable Pull Through", "Deadlift (Band)"].map { rank(title: $0) }
        if order != [0, 1, 2, 3, 4] || rank(title: "Face Pull", equipment: "machine") != 2 || rank(title: "Seated Row (Cable)", equipment: "machine") != 3
            || rank(title: "Pull Up", equipment: "none") != 1 || rank(title: "Squat", equipment: "resistance_band") != 4
            || rank(title: "Bicep Curl (Dumbbell)", dumbbellFirst: true) != 0 || rank(title: "Bicep Curl (Barbell)", dumbbellFirst: true) != 1
            || !dumbbellFirst(name: "bicep curl") || !dumbbellFirst(name: "hammer curl") || !dumbbellFirst(name: "lateral raise")
            || dumbbellFirst(name: "lying leg curl") || dumbbellFirst(name: "deadlift") || !dumbbellFirst(name: "preacher", muscle: "biceps") {
            errors.append("the equipment order should be barbell, free weight, machine, cable, band, with the dumbbell first for biceps and side delts, got \(order)")
        }
        // A machine log does not stay when Hevy's list has the barbell exercise. A dumbbell log stays: free weights are one group.
        let machineBench = [logged("Bench Press (Machine)", "MACHINE", kg: 60, reps: benchReps, daysAgo: 1)]
        let listed = HevyRoutine.plan(for: day.bundle, history: machineBench, templates: ["bench press": "BARBELL"], ranks: ["bench press": 0])
        let keptLog = HevyRoutine.plan(for: day.bundle, history: history, templates: ["bench press": "BARBELL"], ranks: ["bench press": 0])
        func benchId(_ plan: Plan?) -> String? { plan?.exercises.first { $0.name == bench.verification.params["exercise"]?.stringValue }?.templateId }
        if benchId(listed) != "BARBELL" || benchId(keptLog) != "DUMBBELL" {
            errors.append("a barbell exercise in Hevy's list should come before a machine log, and a dumbbell log should stay, got \(String(describing: benchId(listed))) \(String(describing: benchId(keptLog)))")
        }
        // Two logs of one name: the cable one is newer, and the dumbbell one is taken.
        let raises = [logged("Lateral Raise (Cable)", "CABLE", kg: 10, reps: 12, daysAgo: 1), logged("Lateral Raise (Dumbbell)", "DB", kg: 8, reps: 12, daysAgo: 5),
                      logged("Lateral Raise (Barbell)", "BB", kg: 20, reps: 12, daysAgo: 3)].sorted { $0.start > $1.start }
        if HevyRoutine.logged(name: "lateral raise", templateId: nil, load: .any, low: 10, high: 15, plannedKg: nil, newestFirst: raises)?.templateId != "DB" {
            errors.append("a side delt exercise should take the dumbbell log before the cable and the barbell ones")
        }
        // The body Hevy takes: a rep range or reps, never both; seconds for a hold; no exercise without an id.
        let sent = body(plan, create: true)
        let rows = sent["routine"]?["exercises"]?.arrayValue ?? []
        if rows.count != plan.known.count || rows.contains(where: { ($0["exercise_template_id"]?.stringValue ?? "").isEmpty })
            || sent["routine"]?["folder_id"] != .some(.null) || body(plan, create: false)["routine"]?["folder_id"] != nil {
            errors.append("the routine body should hold the known exercises, and the folder only when it is created")
        }
        if let first = rows.first(where: { $0["exercise_template_id"]?.stringValue == "DUMBBELL" })?["sets"]?.arrayValue?.first, let range {
            let ranged = range.low != range.high
            if (first["rep_range"]?["start"]?.doubleValue != nil) != ranged || (first["reps"]?.doubleValue != nil) == ranged || first["weight_kg"]?.doubleValue != 36 {
                errors.append("a set should hold a rep range or reps, and its weight, got \(first.sortedString())")
            }
        } else {
            errors.append("the bench press should be in the routine body")
        }
        // Hevy's update call refuses "rep_range": null. A set with no range has no such key, in the two calls.
        let allSets = [true, false].flatMap { body(plan, create: $0)["routine"]?["exercises"]?.arrayValue ?? [] }.flatMap { $0["sets"]?.arrayValue ?? [] }
        if allSets.isEmpty || allSets.contains(where: { $0["rep_range"] == .some(.null) })
            || body(Plan(title: "t", exercises: [ExercisePlan(name: "n", templateId: "X", sets: [SetPlan(repsLow: 8, repsHigh: 8)])]), create: false)
                .sortedString().contains("rep_range") {
            errors.append("a set with no rep range should have no rep_range key")
        }
        // A hold is seconds for each set. A set holds only what its Hevy exercise takes.
        var holds = QuestBundle.empty
        holds.mode = .performanceTraining
        holds.headerLine = "Deadlift Day"
        holds.quests = [GymSplit.quest(for: GymSplit.Exercise(exercise: "Dead Hang", aliases: [], role: .accessory, sets: 3, minReps: 0, maxReps: 0, secondsPerSet: 60, target: "grip"),
                                       dayKey: "2026-10-05", now: now)]
        let hang = HevyRoutine.plan(for: holds, history: [], templates: ["dead hang": "HANG"], types: ["HANG": "duration"])
        let hangOnReps = HevyRoutine.plan(for: holds, history: [], templates: ["dead hang": "HANG"], types: ["HANG": "reps_only"])
        if hang?.exercises.first?.sets.map(\.seconds) != [60, 60, 60] || repRange(holds.quests[0]) != nil || hangOnReps?.exercises.first?.sets.first != SetPlan()
            || fitted(SetPlan(repsLow: 3, repsHigh: 5, weightKg: 40), to: "bodyweight_reps") != SetPlan(repsLow: 3, repsHigh: 5)
            || fitted(SetPlan(repsLow: 3, repsHigh: 5, weightKg: 40), to: "weight_reps").weightKg != 40
            || fitted(SetPlan(repsLow: 3, repsHigh: 5, weightKg: 10), to: "weighted_bodyweight") != SetPlan(repsLow: 3, repsHigh: 5, weightKg: 10)
            || fitted(SetPlan(repsLow: 3, repsHigh: 5, weightKg: 10), to: "assisted_bodyweight").repsLow != 3
            || HevyRoutine.logged(name: "pull up", templateId: nil, load: .weighted, low: 3, high: 5, plannedKg: 10,
                                  newestFirst: [logged("Pull Up (Assisted)", "ASSISTED", kg: 30, reps: 8, daysAgo: 1)])?.weightKg != nil {
            errors.append("a hold should be 60 seconds for each of its 3 sets, and a set should hold only what its exercise takes, got \(String(describing: hang))")
        }
        // Reps from a title: the number after the mark, a range with a hyphen or a dash, never seconds or meters.
        func titled(_ title: String, sets: Double? = nil, unit: String = "sets", target: Double = 3) -> Quest {
            var quest = holds.quests[0]
            quest.title = title
            quest.verification.params["sets"] = sets.map(JSONValue.number)
            quest.progress = QuestProgress(current: 0, target: target, unit: unit)
            return quest
        }
        let titles: [(String, Int?, Int?)] = [("Bench Press 3×3-5", 3, 5), ("Bench Press 3×3–5", 3, 5), ("Bench Press 3 x 3 - 5", 3, 5), ("Squat 3x5 @ 100 kg", 5, 5),
                                               ("Max 10 Push Up 3×8", 8, 8), ("Dead Hang 3×60s", nil, nil), ("Dead Hang 3×60 s", nil, nil), ("Farmers Walk 3×40m", nil, nil),
                                               ("Pull Up 4×3-10", 3, 10), ("Plank", nil, nil)]
        for (title, low, high) in titles where repRange(titled(title))?.low != low || repRange(titled(title))?.high != high {
            errors.append("the reps of \"\(title)\" should be \(String(describing: low)) to \(String(describing: high)), got \(String(describing: repRange(titled(title))))")
        }
        if setCount(titled("Plank", unit: "min", target: 10)) != 1 || setCount(titled("Dead Hang 3×60s", unit: "min", target: 3)) != 3 || setCount(titled("Squat", sets: 4)) != 4 {
            errors.append("a row with no sets should take them from its title, and never from its minutes")
        }
        // The routine changes when the day changes, and only then.
        var other = plan
        other.exercises[0].sets.removeLast()
        var rowsChanged = day.bundle
        rowsChanged.headerLine = "Squat Day"
        if signature(plan) != signature(plan) || signature(plan) == signature(other) || rowsKey(day.bundle) != rowsKey(day.bundle) || rowsKey(day.bundle) == rowsKey(rowsChanged) {
            errors.append("the signature and the rows key should change with the day's rows and only with them")
        }
        // A bundle with no lifts and no stretch row has no routine. Penalty rows are never in it.
        var rest = QuestBundle.empty
        rest.mode = .fullRecovery
        var owed = GameSnapshot.fresh(catalog: catalog, now: now)
        owed.player.penaltyOpen = true
        owed.rebuildBundle(catalog: catalog, now: now)
        if HevyRoutine.plan(for: rest, history: history, templates: [:]) != nil
            || HevyRoutine.plan(for: owed.bundle, history: history, templates: [:])?.exercises.contains(where: { $0.name.contains("Penalty") }) != false {
            errors.append("a day with no lifts and no stretches should give no routine, and a penalty row is no exercise")
        }
        // A stretch for two sides is one set of both sides.
        if let stretchDay = day.bundle.quests.first(where: { $0.id == DailyStretch.questId }).flatMap({ StretchSplit.day(of: $0) }),
           let sided = stretchDay.stretches.first(where: \.perSide) {
            let name = StrengthLevel.normalizedName(sided.name)
            let stretched = HevyRoutine.plan(for: day.bundle, history: [], templates: [name: "STRETCH"])
            if stretched?.exercises.first(where: { $0.templateId == "STRETCH" })?.sets.first?.seconds != sided.seconds * 2 {
                errors.append("a stretch for two sides should be one set of both sides")
            }
        }
        if routineId(in: .object(["routine": .array([.object(["id": .string("r1")])])])) != "r1" || routineId(in: .object(["routine": .object(["id": .string("r2")])])) != "r2"
            || routineId(in: .object(["id": .string("r3")])) != nil {
            errors.append("the routine id should be read from an object and from a list, and from nothing else")
        }
        return errors
    }
}

extension HevyRoutine {
    /// The write to Hevy, with replies made here and no network: when a routine is made, updated, or left alone.
    static func checkWrites() async -> [String] {
        var errors: [String] = []
        let catalog = FallbackCatalog.bundled()
        guard let now = QuestDay.time(on: "2026-10-05", minutes: 240) else { return ["could not build routine dates"] }
        let bundle = GameSnapshot.fresh(catalog: catalog, now: now).bundle
        var other = bundle
        other.headerLine = "Squat Day"

        /// Hevy, as far as this check needs it.
        final class Hevy {
            var routines: [(id: String, title: String)] = []
            var listFails = false, sendFails = false, missing: Set<String> = [], refuse: Int? = nil, replyHasId = true, postReplyLost = false
            var calls: [String] = []
            var made = 0
        }
        func transport(_ hevy: Hevy) -> Transport {
            Transport(
                get: { url, _ in
                    if url.path.hasSuffix("/exercise_templates") {
                        hevy.calls.append("GET templates")
                        let items: [JSONValue] = ["Bench Press (Band)", "Bench Press (Barbell)", "Pull Up", "Lateral Raise"].enumerated().map { index, title in
                            .object(["id": .string("T\(index)"), "title": .string(title), "type": .string(title == "Pull Up" ? "bodyweight_reps" : "weight_reps")])
                        }
                        return (200, .object(["page": .number(1), "page_count": .number(1), "exercise_templates": .array(items)]))
                    }
                    hevy.calls.append("GET routines")
                    if hevy.listFails { return nil }
                    let items: [JSONValue] = hevy.routines.map { .object(["id": .string($0.id), "title": .string($0.title)]) }
                    return (200, .object(["page": .number(1), "page_count": .number(1), "routines": .array(items)]))
                },
                send: { method, url, _, body in
                    hevy.calls.append("\(method) \(url.lastPathComponent)")
                    if hevy.sendFails { return nil }
                    if let status = hevy.refuse { return (status, .object(["error": .string("refused")])) }
                    let title = body["routine"]?["title"]?.stringValue ?? ""
                    if method == "PUT" {
                        guard let at = hevy.routines.firstIndex(where: { $0.id == url.lastPathComponent }), !hevy.missing.contains(url.lastPathComponent) else {
                            return (404, .object(["error": .string("not found")]))
                        }
                        hevy.routines[at].title = title
                        return (200, .object(["routine": .object(["id": .string(hevy.routines[at].id)])]))
                    }
                    hevy.made += 1
                    let id = "made-\(hevy.made)"
                    hevy.routines.append((id, title))
                    if hevy.postReplyLost { return nil }
                    return (201, hevy.replyHasId ? .object(["routine": .array([.object(["id": .string(id)])])]) : .object([:]))
                }
            )
        }
        func fresh(_ label: String) -> (UserDefaults, String) {
            let name = "hevy-routine-check-\(label)"
            UserDefaults().removePersistentDomain(forName: name)
            return (UserDefaults(suiteName: name) ?? .standard, name)
        }
        func write(_ hevy: Hevy, _ defaults: UserDefaults, _ day: QuestBundle) async -> String? {
            hevy.calls = []
            return await sync(bundle: day, history: [], key: "check", defaults: defaults, transport: transport(hevy))
        }

        // No routine yet and the list cannot be read: nothing is made. One can be there.
        var (defaults, suite) = fresh("list")
        var hevy = Hevy()
        hevy.listFails = true
        _ = await write(hevy, defaults, bundle)
        if hevy.made != 0 || defaults.string(forKey: idKey) != nil || defaults.string(forKey: signatureKey) != nil {
            errors.append("no routine should be made when Hevy's list cannot be read, got \(hevy.calls)")
        }
        // The list is read and holds none: one routine is made, and its id is kept.
        hevy.listFails = false
        let first = await write(hevy, defaults, bundle)
        if hevy.made != 1 || defaults.string(forKey: idKey) != "made-1" || first?.contains(bundle.headerLine) != true {
            errors.append("one routine should be made when Hevy has none, got \(hevy.calls) \(String(describing: first))")
        }
        // The same day again: no call. Another day: the same routine is updated, none is made.
        let same = await write(hevy, defaults, bundle)
        let sameCalls = hevy.calls
        _ = await write(hevy, defaults, other)
        if same != nil || !sameCalls.isEmpty || hevy.made != 1 || hevy.calls != ["PUT made-1"] || hevy.routines.first?.title != "\(titlePrefix): Squat Day" {
            errors.append("an unchanged day should send nothing, and a new day should update the one routine, got \(sameCalls) then \(hevy.calls)")
        }
        // Hevy does not answer the update: nothing is made, and the next write tries again.
        hevy.sendFails = true
        _ = await write(hevy, defaults, bundle)
        if hevy.made != 1 || hevy.calls != ["PUT made-1"] || defaults.string(forKey: idKey) != "made-1" {
            errors.append("an update with no answer should make no routine, got \(hevy.calls)")
        }
        hevy.sendFails = false
        // The player deleted the routine in Hevy: a new one is made, and its id replaces the old one.
        hevy.missing = ["made-1"]
        _ = await write(hevy, defaults, bundle)
        if hevy.made != 2 || hevy.calls != ["PUT made-1", "POST routines"] || defaults.string(forKey: idKey) != "made-2" {
            errors.append("a deleted routine should be made again one time, got \(hevy.calls) id \(defaults.string(forKey: idKey) ?? "none")")
        }
        UserDefaults().removePersistentDomain(forName: suite)

        // A new install: the routine of the app is found by its title and updated. No second one is made.
        (defaults, suite) = fresh("found")
        hevy = Hevy()
        hevy.routines = [("mine", "Push Day"), ("app", "\(titlePrefix): Deadlift Day")]
        _ = await write(hevy, defaults, bundle)
        if hevy.made != 0 || hevy.calls.last != "PUT app" || hevy.routines.first?.title != "Push Day" || defaults.string(forKey: idKey) != "app" {
            errors.append("the app's routine should be found by its title, and the player's own routine left alone, got \(hevy.calls)")
        }
        UserDefaults().removePersistentDomain(forName: suite)

        // Hevy makes the routine but its reply has no id: no id is kept, so the next write finds the routine by title.
        (defaults, suite) = fresh("no-id")
        hevy = Hevy()
        hevy.replyHasId = false
        _ = await write(hevy, defaults, bundle)
        let keptId = defaults.string(forKey: idKey)
        _ = await write(hevy, defaults, other)
        if keptId != nil || hevy.made != 1 || hevy.calls.last != "PUT made-1" {
            errors.append("a reply with no id should not lead to a second routine, got \(hevy.calls) made \(hevy.made)")
        }
        UserDefaults().removePersistentDomain(forName: suite)

        // The stored routine is gone, and the reply to the new one is lost: the old id is not kept, so the next
        // write finds the new routine by its title and makes no second one.
        (defaults, suite) = fresh("lost")
        hevy = Hevy()
        defaults.set("gone", forKey: idKey)
        hevy.postReplyLost = true
        _ = await write(hevy, defaults, bundle)
        let lostId = defaults.string(forKey: idKey)
        hevy.postReplyLost = false
        _ = await write(hevy, defaults, bundle)
        if lostId != nil || hevy.made != 1 || hevy.calls.last != "PUT made-1" || defaults.string(forKey: idKey) != "made-1" {
            errors.append("a new routine whose reply is lost should not be made a second time, got \(hevy.calls) made \(hevy.made)")
        }
        UserDefaults().removePersistentDomain(forName: suite)

        // Hevy refuses the routine: the same routine is not sent again, and a new plan is.
        (defaults, suite) = fresh("refused")
        hevy = Hevy()
        hevy.routines = [("app", "\(titlePrefix): Deadlift Day")]
        hevy.refuse = 400
        let refusal = await write(hevy, defaults, bundle)
        if refusal != "" || defaults.string(forKey: errorKey)?.contains("refused") != true || defaults.string(forKey: templatesKey + ".none") != nil
            || (defaults.dictionary(forKey: templatesKey) as? [String: String])?["bench press"] != "T1" {
            errors.append("a refusal should give the player no line and keep Hevy's words, and the barbell bench should come before the band one")
        }
        _ = await write(hevy, defaults, bundle)
        let afterRefusal = hevy.calls
        hevy.refuse = nil
        _ = await write(hevy, defaults, other)
        if !afterRefusal.isEmpty || hevy.calls.last != "PUT app" || hevy.made != 0 || defaults.string(forKey: idKey) != "app" {
            errors.append("a refused routine should not be sent again, and a new plan should be, got \(afterRefusal) then \(hevy.calls)")
        }
        UserDefaults().removePersistentDomain(forName: suite)
        return errors
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    /// The params in one fixed order.
    var sortedText: String { keys.sorted().map { "\($0)=\(self[$0]?.sortedString() ?? "")" }.joined(separator: ",") }
}
