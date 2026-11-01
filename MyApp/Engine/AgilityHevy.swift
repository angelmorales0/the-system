import Foundation

/// AGI test results, read from Hevy. No sensor or API measures a splits depth or a finger gap, so each test is its own
/// Hevy exercise and the result is logged as a set: the number as reps (cm, inches, or switches), or a distance in
/// metres. Every workout gives one measurement per test, its best set. The newest in 90 days scores (`AgilityLevel`).
/// Names match like the STR targets: no equipment in brackets, any case (`StrengthLevel.normalizedName`).
enum AgilityHevy {
    static let metersPerInch = 0.0254

    /// The name to log in Hevy for each test.
    static let hevyName: [AgilityTest: String] = [
        .verticalJump: "Vertical Jump",
        .frontSplitsLeft: "Front Splits Left",
        .frontSplitsRight: "Front Splits Right",
        .sideSplits: "Side Splits",
        .apleyLeft: "Apley Scratch Test Left",
        .apleyRight: "Apley Scratch Test Right",
        .kneeToWallLeft: "Knee to Wall Left",
        .kneeToWallRight: "Knee to Wall Right",
        .hipSwitches: "90/90 Hip Switches",
    ]

    /// Every Hevy name that counts for each test, normalized.
    static let aliases: [AgilityTest: [String]] = [
        .verticalJump: ["vertical jump", "vertical jump test"],
        .frontSplitsLeft: ["front splits left", "front split left", "left front splits", "left front split"],
        .frontSplitsRight: ["front splits right", "front split right", "right front splits", "right front split"],
        .sideSplits: ["side splits", "side split", "middle splits", "middle split"],
        .apleyLeft: ["apley scratch test left", "apley scratch left", "apley test left", "apley left", "left apley scratch test"],
        .apleyRight: ["apley scratch test right", "apley scratch right", "apley test right", "apley right", "right apley scratch test"],
        .kneeToWallLeft: ["knee to wall left", "knee to wall test left", "left knee to wall"],
        .kneeToWallRight: ["knee to wall right", "knee to wall test right", "right knee to wall"],
        .hipSwitches: ["90/90 hip switches", "90/90 hip switch", "90 90 hip switches", "hip switches", "90/90 switches"],
    ]

    /// The AGI target category of each test, as `AgilityLevel.evaluate` names it.
    static let category: [AgilityTest: String] = [
        .verticalJump: "Vertical jump",
        .frontSplitsLeft: "Front splits",
        .frontSplitsRight: "Front splits",
        .sideSplits: "Side splits",
        .apleyLeft: "Apley scratch test",
        .apleyRight: "Apley scratch test",
        .kneeToWallLeft: "Knee-to-wall test",
        .kneeToWallRight: "Knee-to-wall test",
        .hipSwitches: "90/90 hip switches",
    ]

    /// The Hevy names for one AGI target, left side first.
    static func hevyNames(forCategory name: String) -> [String] {
        AgilityTest.allCases.filter { category[$0] == name }.compactMap { hevyName[$0] }
    }

    /// Splits and the Apley gap are better when smaller.
    static func lowerIsBetter(_ test: AgilityTest) -> Bool {
        switch test {
        case .frontSplitsLeft, .frontSplitsRight, .sideSplits, .apleyLeft, .apleyRight: return true
        case .verticalJump, .kneeToWallLeft, .kneeToWallRight, .hipSwitches: return false
        }
    }

    static func test(named title: String) -> AgilityTest? {
        let name = StrengthLevel.normalizedName(title)
        return AgilityTest.allCases.first { aliases[$0]?.contains(name) == true }
    }

    /// The result in one set: a distance in metres (to inches or cm), else the reps as the test's number.
    /// Hip switches are reps only. Nil when the set has neither.
    static func value(_ set: HevySet, for test: AgilityTest) -> Double? {
        if test == .hipSwitches { return set.reps.map(Double.init) }
        if let meters = set.distanceMeters, meters > 0 { return convert(meters, test) }
        if let reps = set.reps { return Double(reps) }
        if let meters = set.distanceMeters { return convert(meters, test) }
        return nil
    }

    private static func convert(_ meters: Double, _ test: AgilityTest) -> Double {
        test == .verticalJump ? meters / metersPerInch : meters * 100
    }

    /// One measurement per test per workout: the best working set, dated at the workout's start.
    static func measurements(_ workouts: [HevyWorkout]) -> [AgilityMeasurement] {
        workouts.flatMap { workout -> [AgilityMeasurement] in
            var best: [AgilityTest: Double] = [:]
            for exercise in workout.exercises {
                guard let test = test(named: exercise.title) else { continue }
                for set in exercise.sets where set.isWorking {
                    guard let value = value(set, for: test), value.isFinite else { continue }
                    if let current = best[test] {
                        best[test] = lowerIsBetter(test) ? min(current, value) : max(current, value)
                    } else {
                        best[test] = value
                    }
                }
            }
            return best.map { AgilityMeasurement(test: $0.key, value: $0.value, date: workout.start, source: "Hevy") }
        }
    }

    // MARK: - Self-check (runs in DEBUG at launch)

    static func check() -> [String] {
        var errors: [String] = []
        let now = AgilityLevel.checkNow
        func set(reps: Int? = nil, meters: Double? = nil, type: String = "normal") -> HevySet {
            HevySet(type: type, reps: reps, weightKg: nil, rpe: nil, durationSec: nil, distanceMeters: meters)
        }
        let workout = HevyWorkout(id: "a1", title: "Mobility", start: AgilityLevel.daysAgo(3), end: AgilityLevel.daysAgo(3), exercises: [
            HevyExercise(title: "Vertical Jump", templateId: nil, sets: [set(meters: 0.762), set(meters: 0.70)]),
            HevyExercise(title: "Front Splits Left", templateId: nil, sets: [set(reps: 4), set(reps: 2), set(reps: 9, type: "warmup")]),
            HevyExercise(title: "Front Splits (Right)", templateId: nil, sets: [set(reps: 3)]),
            HevyExercise(title: "side-splits", templateId: nil, sets: [set(meters: 0)]),
            HevyExercise(title: "Apley Scratch Test Left", templateId: nil, sets: [set(reps: 0)]),
            HevyExercise(title: "Apley Scratch Test Right", templateId: nil, sets: [set(meters: 0.02)]),
            HevyExercise(title: "Knee to Wall Left", templateId: nil, sets: [set(meters: 0.11)]),
            HevyExercise(title: "Knee to Wall Right", templateId: nil, sets: [set(reps: 10)]),
            HevyExercise(title: "90/90 Hip Switches", templateId: nil, sets: [set(reps: 12, meters: 5)]),
            HevyExercise(title: "Bench Press (Barbell)", templateId: nil, sets: [set(reps: 5)]),
        ])
        let found = Dictionary(uniqueKeysWithValues: measurements([workout]).map { ($0.test, $0.value) })
        let expected: [AgilityTest: Double] = [
            .verticalJump: 30, .frontSplitsLeft: 2, .sideSplits: 0, .apleyLeft: 0, .apleyRight: 2,
            .kneeToWallLeft: 11, .kneeToWallRight: 10, .hipSwitches: 12,
        ]
        for (test, value) in expected where abs((found[test] ?? -999) - value) > 0.01 {
            errors.append("\(test) should read \(value) from Hevy, got \(String(describing: found[test]))")
        }
        if found[.frontSplitsRight] != nil {
            errors.append("a name with the side in brackets loses the side and must not match, got \(String(describing: found[.frontSplitsRight]))")
        }
        if found.count != expected.count {
            errors.append("only AGI exercises should give measurements, got \(found.keys)")
        }
        // A newer workout replaces an older result; the level reads the mapped results like any other.
        var older = workout
        older.id = "a0"
        older.start = AgilityLevel.daysAgo(20)
        older.exercises = [HevyExercise(title: "Vertical Jump", templateId: nil, sets: [set(reps: 36)])]
        let report = AgilityLevel.evaluate(measurements: measurements([older, workout]), now: now)
        let jump = report.requirements.first { $0.category == "Vertical jump" }
        if jump?.passed != true || jump?.detail.hasPrefix("30 in") != true {
            errors.append("the newest Hevy jump (30 in) should score, got \(String(describing: jump?.detail))")
        }
        for test in AgilityTest.allCases {
            guard let name = hevyName[test] else {
                errors.append("\(test) has no Hevy name")
                continue
            }
            if self.test(named: name) != test { errors.append("the Hevy name \(name) should map back to \(test)") }
            if category[test].map({ hevyNames(forCategory: $0).contains(name) }) != true {
                errors.append("\(name) should be listed under its AGI target")
            }
        }
        if test(named: "Bulgarian Split Squat (Dumbbell)") != nil {
            errors.append("a split squat is not a splits test")
        }
        return errors
    }
}
