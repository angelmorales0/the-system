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
    static let templatesKey = "hevyRoutineTemplateIds"
    /// Hevy lists 100 exercise templates in a page. The built-in list and a player's own exercises fit in these.
    static let templatePages = 12
    /// Routines come 10 in a page. The routine of an earlier install is looked for in these.
    static let routinePages = 5

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

    /// The lift rows of the day in list order, then the stretches of the day. Nil when the day has none of them.
    /// Finished rows stay in the plan: the routine is the day's workout, and it does not change while it is done.
    ///
    /// The Hevy exercise of a row is the one the player logged last under that name (the Hevy check's name rule), so
    /// "Bench Press" is the barbell or the dumbbell bench the player uses. A name with no log comes from `templates`
    /// (normalized Hevy title to id). The weight is the plan's weight, else the top weight of the last session.
    static func plan(for bundle: QuestBundle, history: [HevyWorkout], templates: [String: String]) -> Plan? {
        let newestFirst = history.sorted { $0.start > $1.start }
        func lastLogged(_ name: String, templateId: String?) -> HevyExercise? {
            for workout in newestFirst {
                if let entry = workout.exercises.first(where: { entry in
                    if let templateId { return entry.templateId == templateId }
                    return StrengthLevel.normalizedName(entry.title) == name && entry.templateId != nil
                }) { return entry }
            }
            return nil
        }
        var exercises: [ExercisePlan] = []
        for quest in bundle.quests where quest.verification.method == .hevySets && quest.id != DailyStretch.questId && quest.kind != .penalty {
            let params = quest.verification.params
            let shown = params["exercise"]?.stringValue ?? quest.title
            let name = StrengthLevel.normalizedName(shown)
            let count = max(1, Int(params["sets"]?.doubleValue ?? quest.progress.target))
            let logged = lastLogged(name, templateId: params["templateId"]?.stringValue)
            let templateId = params["templateId"]?.stringValue ?? logged?.templateId ?? templates[name]
            var set = SetPlan()
            if let total = params["minDurationSec"]?.doubleValue {
                set.seconds = max(1, Int((total / Double(count)).rounded()))
            } else {
                let range = repRange(quest)
                set.repsLow = range?.low ?? params["minReps"]?.doubleValue.map { Int($0) }
                set.repsHigh = range?.high ?? set.repsLow
                let top = logged?.sets.filter(\.isWorking).compactMap(\.weightKg).max()
                set.weightKg = params["minWeightKg"]?.doubleValue ?? top.flatMap { $0 > 0 ? $0 : nil }
            }
            exercises.append(ExercisePlan(name: shown, templateId: templateId, sets: Array(repeating: set, count: count), note: quest.title))
        }
        if let stretchRow = bundle.quests.first(where: { $0.id == DailyStretch.questId }), let day = StretchSplit.day(of: stretchRow) {
            for stretch in day.stretches {
                let name = StrengthLevel.normalizedName(stretch.name)
                let seconds = stretch.seconds * (stretch.perSide ? 2 : 1)
                exercises.append(ExercisePlan(
                    name: stretch.name,
                    templateId: lastLogged(name, templateId: nil)?.templateId ?? templates[name],
                    sets: Array(repeating: SetPlan(seconds: seconds), count: stretch.sets),
                    note: stretch.perSide ? "\(stretch.seconds) s each side in one set." : nil
                ))
            }
        }
        guard !exercises.isEmpty else { return nil }
        return Plan(title: "\(titlePrefix): \(bundle.headerLine)", exercises: exercises)
    }

    /// "Bench Press 3×3-5" gives 3 to 5. "Dead Hang 3×60s" gives nil: that is time.
    static func repRange(_ quest: Quest) -> (low: Int, high: Int)? {
        guard let match = quest.title.range(of: #"[×x]\s*\d+(-\d+)?(?![\ds])"#, options: .regularExpression) else { return nil }
        let numbers = quest.title[match].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard let low = numbers.first else { return nil }
        return (low, numbers.count > 1 ? numbers[1] : low)
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
                    return .object([
                        "type": .string("normal"),
                        "weight_kg": set.weightKg.map(JSONValue.number) ?? .null,
                        "reps": range ? .null : set.repsLow.map { .number(Double($0)) } ?? .null,
                        "distance_meters": .null,
                        "duration_seconds": set.seconds.map { .number(Double($0)) } ?? .null,
                        "custom_metric": .null,
                        "rep_range": range ? .object(["start": .number(Double(set.repsLow ?? 0)), "end": .number(Double(set.repsHigh ?? 0))]) : .null,
                    ])
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

    /// Every exercise Hevy knows on this account, by the name rule of the Hevy check. Of two exercises with one
    /// name ("Bench Press (Barbell)", "Bench Press (Dumbbell)") the first one Hevy lists stays, and a name the
    /// player logged never comes here: `plan` takes the logged one.
    static func loadTemplates(key: String) async -> [String: String]? {
        var found: [String: String] = [:]
        for number in 1...templatePages {
            guard let url = OnDeviceHTTP.url("\(HevyClient.api)/v1/exercise_templates", [("page", String(number)), ("pageSize", "100")]),
                  let payload = await OnDeviceHTTP.getJSON(url, headers: HevyClient.headers(key)),
                  let items = payload["exercise_templates"]?.arrayValue else {
                return number == 1 ? nil : found
            }
            for item in items {
                guard let id = item["id"]?.stringValue, !id.isEmpty, let title = item["title"]?.stringValue else { continue }
                let name = StrengthLevel.normalizedName(title)
                if found[name] == nil { found[name] = id }
            }
            if items.isEmpty || number >= (payload["page_count"]?.intValue ?? number) { break }
        }
        return found
    }

    /// The routine an earlier install made, by its title.
    static func existingRoutineId(key: String) async -> String? {
        for number in 1...routinePages {
            guard let url = OnDeviceHTTP.url("\(HevyClient.api)/v1/routines", [("page", String(number)), ("pageSize", "10")]),
                  let payload = await OnDeviceHTTP.getJSON(url, headers: HevyClient.headers(key)),
                  let items = payload["routines"]?.arrayValue else { return nil }
            if let mine = items.first(where: { $0["title"]?.stringValue?.hasPrefix(titlePrefix + ":") == true }) {
                return mine["id"]?.stringValue
            }
            if items.isEmpty || number >= (payload["page_count"]?.intValue ?? number) { break }
        }
        return nil
    }

    /// The id in Hevy's reply, which holds the routine as an object or as a list of one.
    static func routineId(in reply: JSONValue?) -> String? {
        let routine = reply?["routine"]
        return routine?["id"]?.stringValue ?? routine?.arrayValue?.first?["id"]?.stringValue
    }

    /// Writes the day's routine to Hevy when it changed. Returns a line for the player, or nil when nothing was sent.
    static func sync(bundle: QuestBundle, history: [HevyWorkout],
                     key: String? = SecretStore.read(.hevyApiKey), defaults: UserDefaults = .standard) async -> String? {
        guard let key else { return nil }
        var templates = defaults.dictionary(forKey: templatesKey) as? [String: String] ?? [:]
        guard var plan = plan(for: bundle, history: history, templates: templates) else { return nil }
        // A row with no Hevy exercise yet: read Hevy's list one time for each new set of names.
        let missing = plan.unknown.joined(separator: "|")
        if !missing.isEmpty, defaults.string(forKey: templatesKey + ".missing") != missing {
            if let loaded = await loadTemplates(key: key) {
                templates = loaded
                defaults.set(loaded, forKey: templatesKey)
                defaults.set(missing, forKey: templatesKey + ".missing")
                plan = self.plan(for: bundle, history: history, templates: templates) ?? plan
            }
        }
        guard !plan.known.isEmpty else { return "Hevy has none of today's exercises. No routine was written." }
        let signature = signature(plan)
        // The same routine is sent one time, also when Hevy refused it: a new day or a new plan sends again.
        guard defaults.string(forKey: signatureKey) != signature, defaults.string(forKey: signatureKey + ".refused") != signature else { return nil }

        var id = defaults.string(forKey: idKey)
        if id == nil { id = await existingRoutineId(key: key) }
        var reply: (status: Int, json: JSONValue?)?
        if let id, let url = URL(string: "\(HevyClient.api)/v1/routines/\(id)") {
            reply = await OnDeviceHTTP.sendJSON("PUT", url, headers: HevyClient.headers(key), body: body(plan, create: false))
        }
        // No routine yet, or the player deleted it in Hevy.
        if reply == nil || reply?.status == 404, let url = URL(string: "\(HevyClient.api)/v1/routines") {
            if id == nil || reply?.status == 404 {
                reply = await OnDeviceHTTP.sendJSON("POST", url, headers: HevyClient.headers(key), body: body(plan, create: true))
            }
        }
        guard let reply else { return "Hevy did not answer. The routine is written at the next refresh." }
        guard (200..<300).contains(reply.status) else {
            if reply.status == 403 { return "Hevy holds its limit of routines. Delete one in Hevy, and the day's routine is written." }
            if reply.status == 400 { defaults.set(signature, forKey: signatureKey + ".refused") }
            return "Hevy refused the routine (HTTP \(reply.status))."
        }
        if let written = routineId(in: reply.json) ?? id { defaults.set(written, forKey: idKey) }
        defaults.set(signature, forKey: signatureKey)
        return "In Hevy: \"\(plan.title)\"." + (plan.unknown.isEmpty ? "" : " Not in Hevy: \(plan.unknown.joined(separator: ", ")).")
    }

    // MARK: - Self-check (runs in DEBUG at launch)

    static func check() -> [String] {
        var errors: [String] = []
        let catalog = FallbackCatalog.bundled()
        guard let now = QuestDay.start(of: "2026-10-05")?.addingTimeInterval(4 * 3_600) else { return ["could not build routine dates"] }
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
        let history = [logged("Bench Press (Barbell)", "BARBELL", kg: 80, reps: 5, daysAgo: 9), logged("Bench Press (Dumbbell)", "DUMBBELL", kg: 36, reps: 5, daysAgo: 2),
                       logged("Pull Up", "PULLUP", kg: nil, reps: 8, daysAgo: 2)]
        guard let plan = plan(for: day.bundle, history: history, templates: ["lateral raise": "LATERAL"]) else { return ["a Bench Day should give a routine"] }
        if plan.title != "\(titlePrefix): \(day.bundle.headerLine)" { errors.append("the routine should carry the day's name, got \(plan.title)") }
        let benchPlan = plan.exercises.first { $0.name == bench.verification.params["exercise"]?.stringValue }
        let range = repRange(bench)
        if benchPlan?.templateId != "DUMBBELL" || benchPlan?.sets.count != Int(bench.verification.params["sets"]?.doubleValue ?? 0)
            || benchPlan?.sets.first?.weightKg != 36 || range == nil || benchPlan?.sets.first?.repsLow != range?.low || benchPlan?.sets.first?.repsHigh != range?.high {
            errors.append("Bench Press should be the exercise logged last, with the row's sets and reps and the last top weight, got \(String(describing: benchPlan))")
        }
        let pullPlan = plan.exercises.first { $0.name == pull.verification.params["exercise"]?.stringValue }
        if pullPlan?.templateId != "PULLUP" || pullPlan?.sets.count != GymSplit.maxPullUpSets || pullPlan?.sets.first?.weightKg != nil {
            errors.append("Pull Up should have its 4 sets and no weight, got \(String(describing: pullPlan))")
        }
        if plan.exercises.first(where: { StrengthLevel.normalizedName($0.name) == "lateral raise" })?.templateId != "LATERAL" {
            errors.append("an exercise with no log should take its Hevy exercise from Hevy's list")
        }
        if plan.unknown.isEmpty || plan.known.count + plan.unknown.count != plan.exercises.count {
            errors.append("exercises Hevy does not know should be named, not sent")
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
        // A hold is seconds for each set, and a stretch for two sides is one set of both.
        var holds = QuestBundle.empty
        holds.mode = .performanceTraining
        holds.headerLine = "Deadlift Day"
        holds.quests = [GymSplit.quest(for: GymSplit.Exercise(exercise: "Dead Hang", aliases: [], role: .accessory, sets: 3, minReps: 0, maxReps: 0, secondsPerSet: 60, target: "grip"),
                                       band: .green, dayKey: "2026-10-05", now: now)]
        let hang = HevyRoutine.plan(for: holds, history: [], templates: ["dead hang": "HANG"])
        if hang?.exercises.first?.sets.map(\.seconds) != [60, 60, 60] || repRange(holds.quests[0]) != nil
            || body(hang ?? Plan(title: "", exercises: []), create: false)["routine"]?["exercises"]?.arrayValue?.first?["sets"]?.arrayValue?.first?["duration_seconds"]?.doubleValue != 60 {
            errors.append("a hold should be 60 seconds for each of its 3 sets, got \(String(describing: hang))")
        }
        // The routine changes when the day changes, and only then.
        var other = plan
        other.exercises[0].sets.removeLast()
        if signature(plan) != signature(plan) || signature(plan) == signature(other) {
            errors.append("the signature should change with the routine and only with it")
        }
        // A day with no lifts and its stretching done has no routine.
        var rest = QuestBundle.empty
        rest.mode = .fullRecovery
        if HevyRoutine.plan(for: rest, history: history, templates: [:]) != nil { errors.append("a day with no lifts and no stretches should give no routine") }
        if routineId(in: .object(["routine": .array([.object(["id": .string("r1")])])])) != "r1" || routineId(in: .object(["routine": .object(["id": .string("r2")])])) != "r2" {
            errors.append("the routine id should be read from an object and from a list")
        }
        return errors
    }
}
