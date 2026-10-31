import Foundation

/// One AGI self-test. No app, sensor or API measures these, so the user records each result in the app.
/// Left and right sides are separate tests, because one tight side must not hide behind the other.
enum AgilityTest: String, Codable, Equatable, CaseIterable {
    /// Inches jumped (entered by hand, or copied from a jump app).
    case verticalJump
    /// Centimetres from the hips to the floor, left leg forward. 0 = full splits.
    case frontSplitsLeft
    /// Centimetres from the hips to the floor, right leg forward. 0 = full splits.
    case frontSplitsRight
    /// Centimetres from the hips to the floor. 0 = full splits.
    case sideSplits
    /// Finger gap behind the back in cm, left hand over the shoulder. Negative = the fingers overlap (clasp).
    case apleyLeft
    /// Finger gap behind the back in cm, right hand over the shoulder. Negative = the fingers overlap (clasp).
    case apleyRight
    /// Largest toe-to-wall distance in cm at which the left knee still touches the wall with the heel flat.
    case kneeToWallLeft
    /// Largest toe-to-wall distance in cm at which the right knee still touches the wall with the heel flat.
    case kneeToWallRight
    /// Controlled 90/90 hip switches without hands, in reps.
    case hipSwitches
}

/// One self-reported AGI test result. `value` uses the unit of its `test` (see `AgilityTest`).
struct AgilityMeasurement: Codable, Equatable {
    var test: AgilityTest
    var value: Double
    var date: Date
    var source: String
}

/// Deterministic AGI (agility) level 0...350.
/// Pure: the same inputs and `now` always give the same report. No network and no clock.
///
/// Every input is self-reported. No sensor can verify a splits depth, a finger gap or a knee touch,
/// so the level is only as honest as the user's tape measure.
enum AgilityLevel {
    /// Flexibility goes away without practice: only the newest result of each test within 90 days counts.
    static let windowDays = 90

    // Floors are the level 0 limits; targets are the max level rules. Lower-is-better metrics put the floor above the target.
    static let verticalJumpBand = StatLevel.Band(floor: 8, target: 30)   // inches
    static let splitsBand = StatLevel.Band(floor: 60, target: 0)         // cm from the hips to the floor
    static let apleyBand = StatLevel.Band(floor: 25, target: 0)          // cm finger gap; negative = clasp
    static let kneeToWallBand = StatLevel.Band(floor: 0, target: 10)     // cm toe to wall (one fist ≈ 10 cm)
    static let hipSwitchBand = StatLevel.Band(floor: 0, target: 10)      // controlled reps without hands

    /// Strict pass limits. Splits allow 0.5 cm, because a hand-held tape cannot read a true 0.
    static let splitsPassMax = 0.5
    static let apleyPassMax = 0.0

    enum Weight {
        static let verticalJump = 100.0 / 6
        static let frontSplits = 100.0 / 6
        static let sideSplits = 100.0 / 6
        static let apley = 100.0 / 6
        static let kneeToWall = 100.0 / 6
        static let hipSwitches = 100.0 / 6
    }

    static func evaluate(measurements: [AgilityMeasurement], now: Date) -> StatLevelReport {
        let start = now.addingTimeInterval(-Double(windowDays) * 86_400)
        var latest: [AgilityTest: AgilityMeasurement] = [:]
        for measurement in measurements where measurement.date >= start && measurement.value.isFinite {
            if let current = latest[measurement.test], current.date >= measurement.date { continue }
            latest[measurement.test] = measurement
        }
        return StatLevelReport(stat: .AGI, requirements: [
            single("Vertical jump", latest[.verticalJump], band: verticalJumpBand, unit: "in", weight: Weight.verticalJump) {
                $0 >= verticalJumpBand.target
            },
            paired("Front splits", latest[.frontSplitsLeft], latest[.frontSplitsRight], band: splitsBand, unit: "cm", weight: Weight.frontSplits) {
                $0 <= splitsPassMax
            },
            single("Side splits", latest[.sideSplits], band: splitsBand, unit: "cm", weight: Weight.sideSplits) {
                $0 <= splitsPassMax
            },
            paired("Apley scratch test", latest[.apleyLeft], latest[.apleyRight], band: apleyBand, unit: "cm", weight: Weight.apley) {
                $0 <= apleyPassMax
            },
            paired("Knee-to-wall test", latest[.kneeToWallLeft], latest[.kneeToWallRight], band: kneeToWallBand, unit: "cm", weight: Weight.kneeToWall) {
                $0 >= kneeToWallBand.target
            },
            single("90/90 hip switches", latest[.hipSwitches], band: hipSwitchBand, unit: "reps", weight: Weight.hipSwitches) {
                $0 >= hipSwitchBand.target
            },
        ])
    }

    // MARK: - Rules

    private static var missing: String { "not tested in \(windowDays) days" }

    /// One test. Strict rule: the newest result in 90 days meets `passes`.
    private static func single(
        _ category: String,
        _ measurement: AgilityMeasurement?,
        band: StatLevel.Band,
        unit: String,
        weight: Double,
        passes: (Double) -> Bool
    ) -> StatRequirement {
        guard let measurement else {
            return StatRequirement(category: category, passed: false, progress: 0, weight: weight, detail: missing, hasData: false)
        }
        return StatRequirement(
            category: category,
            passed: passes(measurement.value),
            progress: band.progress(measurement.value),
            weight: weight,
            detail: "\(format(measurement.value)) \(unit) (\(QuestDay.key(for: measurement.date)))"
        )
    }

    /// A left and a right test. Strict rule: both tested sides pass. Progress is the worse tested side.
    /// A side that was never tested is left out, so one tested side scores alone. Neither side tested is no data.
    private static func paired(
        _ category: String,
        _ left: AgilityMeasurement?,
        _ right: AgilityMeasurement?,
        band: StatLevel.Band,
        unit: String,
        weight: Double,
        passes: (Double) -> Bool
    ) -> StatRequirement {
        let tested = [left, right].compactMap { $0 }
        guard !tested.isEmpty else {
            return StatRequirement(category: category, passed: false, progress: 0, weight: weight, detail: missing, hasData: false)
        }
        func side(_ name: String, _ measurement: AgilityMeasurement?) -> String {
            measurement.map { "\(name) \(format($0.value)) \(unit)" } ?? "\(name) not tested"
        }
        let newest = [left, right].compactMap { $0?.date }.max() ?? Date(timeIntervalSince1970: 0)
        let passed = tested.allSatisfy { passes($0.value) }
        let progress = tested.map { band.progress($0.value) }.min() ?? 0
        return StatRequirement(
            category: category,
            passed: passed,
            progress: progress,
            weight: weight,
            detail: "\(side("left", left)), \(side("right", right)) (\(QuestDay.key(for: newest)))"
        )
    }

    // MARK: - Formatting

    /// Whole numbers without decimals: 4 → "4", 4.5 → "4.5", -2 → "-2".
    static func format(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10 + 0  // + 0 turns -0 into 0
        if rounded == rounded.rounded() { return String(format: "%.0f", rounded) }
        return String(format: "%.1f", rounded)
    }

    // MARK: - Self-check (runs in DEBUG at launch)

    /// Fixed clock for the fixtures.
    static let checkNow = QuestDay.date(from: "2026-10-17") ?? Date(timeIntervalSince1970: 0)

    static func daysAgo(_ days: Int, from now: Date = checkNow) -> Date {
        now.addingTimeInterval(-Double(days) * 86_400)
    }

    struct Fixture {
        var measurements: [AgilityMeasurement]

        func evaluate(now: Date = checkNow) -> StatLevelReport {
            AgilityLevel.evaluate(measurements: measurements, now: now)
        }

        /// Replaces the value of one test in place.
        mutating func set(_ test: AgilityTest, _ value: Double) {
            for index in measurements.indices where measurements[index].test == test {
                measurements[index].value = value
            }
        }
    }

    private static func fixture(_ values: [(AgilityTest, Double)]) -> Fixture {
        Fixture(measurements: values.enumerated().map { index, pair in
            AgilityMeasurement(test: pair.0, value: pair.1, date: daysAgo(5 + index), source: "Manual")
        })
    }

    /// Inputs that meet every the max level requirement. Tests edit a copy.
    static func perfectFixture() -> Fixture {
        fixture([
            (.verticalJump, 31),
            (.frontSplitsLeft, 0),
            (.frontSplitsRight, 0),
            (.sideSplits, 0),
            (.apleyLeft, -1),
            (.apleyRight, 0),
            (.kneeToWallLeft, 11),
            (.kneeToWallRight, 10),
            (.hipSwitches, 12),
        ])
    }

    /// Inputs at or below every level 0 floor.
    static func floorFixture() -> Fixture {
        fixture([
            (.verticalJump, 6),
            (.frontSplitsLeft, 60),
            (.frontSplitsRight, 70),
            (.sideSplits, 65),
            (.apleyLeft, 25),
            (.apleyRight, 30),
            (.kneeToWallLeft, 0),
            (.kneeToWallRight, 0),
            (.hipSwitches, 0),
        ])
    }

    static func check() -> [String] {
        var errors: [String] = []
        let perfect = perfectFixture()
        let report = perfect.evaluate()
        if !report.isMaxLevel {
            errors.append("perfect fixture should reach the max level, failing: " + report.failing.map { "\($0.category): \($0.detail)" }.joined(separator: " | "))
        }
        if report.requirements.count != 6 {
            errors.append("AGI should have 6 requirements, got \(report.requirements.count)")
        }
        let totalWeight = report.requirements.reduce(0) { $0 + $1.weight }
        if abs(totalWeight - 100) > 0.001 {
            errors.append("weights should add to 100, got \(totalWeight)")
        }
        if report.level != StatLevel.maxLevel || abs(report.score - 100) > 0.001 || report.stat != .AGI {
            errors.append("perfect fixture should score 100 and the max level, got \(report.score) level \(report.level)")
        }

        let empty = Fixture(measurements: []).evaluate()
        if empty.isMaxLevel || empty.level != 0 || empty.score != 0 {
            errors.append("no data must be level 0, got level \(empty.level) score \(empty.score)")
        }
        if empty.requirements.contains(where: { $0.detail != "not tested in 90 days" || $0.hasData }) {
            errors.append("missing tests should read \"not tested in 90 days\" with no data, got \(empty.requirements.map(\.detail))")
        }
        // One test done and the rest never tested: that test scores alone at weight 100.
        let jumpOnly = fixture([(.verticalJump, 19)]).evaluate()
        if jumpOnly.counted.map(\.category) != ["Vertical jump"] || jumpOnly.counted.first?.weight != 100 || jumpOnly.level != 175 || jumpOnly.withoutData.count != 5 {
            errors.append("a lone 19 in jump should score alone at weight 100 and level 175, got \(jumpOnly.counted.map { "\($0.category) \($0.weight)" }) level \(jumpOnly.level)")
        }

        let floorReport = floorFixture().evaluate()
        if floorReport.level != 0 || floorReport.score > 0.001 {
            errors.append("floor fixture should be level 0, got level \(floorReport.level) score \(floorReport.score): " + floorReport.requirements.map { "\($0.category) \($0.points)" }.joined(separator: ", "))
        }

        func failsOnly(_ category: String, _ edit: (inout Fixture) -> Void, line: Int = #line) {
            var fixture = perfect
            edit(&fixture)
            let edited = fixture.evaluate()
            let failing = edited.failing.map(\.category)
            if failing != [category] {
                errors.append("line \(line): expected only \(category) to fail, got \(failing)")
            }
            if edited.level >= StatLevel.maxLevel {
                errors.append("line \(line): a failing \(category) must stay under the max level, got \(edited.level)")
            }
            if edited.topGains(1).first?.category != category {
                errors.append("line \(line): \(category) should be the top gain, got \(edited.topGains(1).map(\.category))")
            }
        }

        failsOnly("Vertical jump") { $0.set(.verticalJump, 24) }
        failsOnly("Front splits") { $0.set(.frontSplitsLeft, 12) }
        failsOnly("Side splits") { $0.set(.sideSplits, 15) }
        failsOnly("Apley scratch test") { $0.set(.apleyRight, 6) }
        failsOnly("Knee-to-wall test") { $0.set(.kneeToWallLeft, 6) }
        failsOnly("90/90 hip switches") { $0.set(.hipSwitches, 5) }

        // Front splits: one side full and the other 10 cm away fails, and progress is the worse side.
        var oneSide = perfect
        oneSide.set(.frontSplitsLeft, 0)
        oneSide.set(.frontSplitsRight, 10)
        let frontRow = oneSide.evaluate().requirements.first { $0.category == "Front splits" }
        if frontRow?.passed != false || abs((frontRow?.progress ?? 0) - 50.0 / 60.0) > 0.0001 {
            errors.append("front splits 0/10 cm should fail with progress \(50.0 / 60.0), got \(String(describing: frontRow))")
        }
        if frontRow?.detail.hasPrefix("left 0 cm, right 10 cm (") != true {
            errors.append("front splits detail wrong: \(String(describing: frontRow?.detail))")
        }
        // One side never tested is left out: the tested side scores alone and the detail says so.
        var halfTested = perfect
        halfTested.measurements.removeAll { $0.test == .frontSplitsRight }
        let halfRow = halfTested.evaluate().requirements.first { $0.category == "Front splits" }
        if halfRow?.passed != true || halfRow?.progress != 1 || halfRow?.hasData != true || halfRow?.detail.contains("right not tested") != true {
            errors.append("an untested right side should leave the left side to score alone, got \(String(describing: halfRow))")
        }
        halfTested.set(.frontSplitsLeft, 30)
        let halfFail = halfTested.evaluate().requirements.first { $0.category == "Front splits" }
        if halfFail?.passed != false || abs((halfFail?.progress ?? 0) - 0.5) > 0.0001 {
            errors.append("a 30 cm left side alone should fail at progress 0.5, got \(String(describing: halfFail))")
        }

        // Splits pass within 0.5 cm; 0.6 cm fails.
        var nearSplits = perfect
        nearSplits.set(.sideSplits, 0.5)
        if !nearSplits.evaluate().isMaxLevel {
            errors.append("side splits at 0.5 cm should pass")
        }
        failsOnly("Side splits") { $0.set(.sideSplits, 0.6) }

        // Apley: a clasp (−2 cm overlap) passes on both sides; a 1 cm gap fails.
        var clasp = perfect
        clasp.set(.apleyLeft, -2)
        clasp.set(.apleyRight, -2)
        let claspRow = clasp.evaluate().requirements.first { $0.category == "Apley scratch test" }
        if claspRow?.passed != true || claspRow?.progress != 1 || claspRow?.detail.hasPrefix("left -2 cm, right -2 cm") != true {
            errors.append("an Apley clasp of -2 cm should pass at full progress, got \(String(describing: claspRow))")
        }
        failsOnly("Apley scratch test") { $0.set(.apleyLeft, 1) }

        // Exact targets pass: 30 in jump, 10 cm knee to wall, 10 hip switches.
        var exact = perfect
        exact.set(.verticalJump, 30)
        exact.set(.kneeToWallLeft, 10)
        exact.set(.hipSwitches, 10)
        if !exact.evaluate().isMaxLevel {
            errors.append("exact targets should pass, failing \(exact.evaluate().failing.map(\.category))")
        }

        // Progress is linear: a 19 in jump is (19 - 8) / (30 - 8) = 0.5.
        var midJump = perfect
        midJump.set(.verticalJump, 19)
        let jumpRow = midJump.evaluate().requirements.first { $0.category == "Vertical jump" }
        if abs((jumpRow?.progress ?? 0) - 0.5) > 0.0001 || jumpRow?.detail.hasPrefix("19 in (") != true {
            errors.append("a 19 in jump should give progress 0.5, got \(String(describing: jumpRow))")
        }

        // The newest result wins over an older, better one.
        failsOnly("Vertical jump") { fixture in
            fixture.measurements.removeAll { $0.test == .verticalJump }
            fixture.measurements.append(AgilityMeasurement(test: .verticalJump, value: 32, date: daysAgo(40), source: "Manual"))
            fixture.measurements.append(AgilityMeasurement(test: .verticalJump, value: 26, date: daysAgo(2), source: "Manual"))
        }
        failsOnly("Front splits") { fixture in
            fixture.measurements.append(AgilityMeasurement(test: .frontSplitsRight, value: 8, date: daysAgo(1), source: "Manual"))
        }

        // Results older than 90 days do not count. With no newer result the test has no data and drops out.
        var expired = perfect
        for index in expired.measurements.indices where expired.measurements[index].test == .hipSwitches {
            expired.measurements[index].date = daysAgo(91)
        }
        let expiredReport = expired.evaluate()
        if expiredReport.requirements.first(where: { $0.category == "90/90 hip switches" })?.hasData != false || !expiredReport.isMaxLevel || expiredReport.counted.count != 5 {
            errors.append("an expired hip switch result should drop out and leave the other five at the max, got level \(expiredReport.level) failing \(expiredReport.failing.map(\.category))")
        }
        var oldSplits = perfect
        for index in oldSplits.measurements.indices where oldSplits.measurements[index].test == .sideSplits {
            oldSplits.measurements[index].date = daysAgo(120)
        }
        let oldDetail = oldSplits.evaluate().requirements.first { $0.category == "Side splits" }?.detail
        if oldDetail != "not tested in 90 days" {
            errors.append("an old side splits result should read \"not tested in 90 days\", got \(String(describing: oldDetail))")
        }
        // An old result does not come back when the newer one expires the window: a 91-day-old 0 cm stays out.
        failsOnly("Side splits") { fixture in
            fixture.measurements.removeAll { $0.test == .sideSplits }
            fixture.measurements.append(AgilityMeasurement(test: .sideSplits, value: 0, date: daysAgo(91), source: "Manual"))
            fixture.measurements.append(AgilityMeasurement(test: .sideSplits, value: 20, date: daysAgo(30), source: "Manual"))
        }

        if format(4) != "4" || format(4.5) != "4.5" || format(-2) != "-2" || format(0) != "0" {
            errors.append("format wrong: \(format(4)) \(format(4.5)) \(format(-2)) \(format(0))")
        }
        return errors
    }
}
