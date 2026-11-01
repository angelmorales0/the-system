import Foundation

/// A race distance that the END stat scores.
enum RunDistance: String, Codable, Equatable, CaseIterable {
    case mile, fiveK, tenK
}

/// One timed effort at a race distance: a Strava or Apple Health run near that distance, at its average pace
/// over the distance (see `EnduranceEfforts`).
struct RunEffort: Codable, Equatable {
    var distance: RunDistance
    var seconds: Double
    var date: Date
    var source: String
}

/// One timed 1-mile swim (1,609 m, or 1,760 yd in a yard pool), from a Strava or Apple Health swim near that
/// distance at its average pace (see `EnduranceEfforts`).
struct SwimEffort: Codable, Equatable {
    var seconds: Double
    var date: Date
    var source: String
}

/// One VO₂ max estimate in mL/kg/min, from Apple Health (an Apple Watch writes one after outdoor runs and walks).
struct VO2MaxReading: Codable, Equatable {
    var value: Double
    var date: Date
    var source: String
}

/// The longest unbroken time in heart-rate zone 2 within one activity, from Apple Health heart rate samples (see `ZoneTwo`).
/// Separate sessions never add up: two 45-minute sessions are two 45-minute rows.
struct ZoneTwoSession: Codable, Equatable {
    var minutes: Double
    var date: Date
    var source: String
}

/// One body weight reading in kg, from Apple Health. MacroFactor's trend weight is used first when it is there.
struct BodyMassReading: Codable, Equatable {
    var kg: Double
    var date: Date
    var source: String

    var pounds: Double { kg * StatLevel.poundsPerKilogram }
}

/// Deterministic END (endurance) level 0...350.
/// Pure: the same inputs and `now` always give the same report. No network and no clock.
enum EnduranceLevel {
    /// Run and swim efforts and zone 2 sessions count from the last 180 days.
    static let effortWindowDays = 180
    /// VO₂ max is a current fitness estimate: the newest reading within 90 days, not the best.
    static let vo2WindowDays = 90
    /// Body weight uses the newest weigh-in within 30 days.
    static let bodyWeightWindowDays = 30

    /// Target body weight in lb. A lighter runner carries less over 10 km.
    static let bodyWeightTargetLb = 145.0
    /// Pounds either side of the target that still pass. Daily weigh-ins move about this much.
    static let bodyWeightToleranceLb = 2.0
    /// Pounds from the target, either side, at level 0.
    static let bodyWeightFloorLb = 30.0

    // Floors are the level 0 limits; targets are the max level rules. Times put the floor above the target.
    static let mileBand = StatLevel.Band(floor: 720, target: 330)      // seconds: 12:00 → 5:30
    static let fiveKBand = StatLevel.Band(floor: 2700, target: 1200)   // seconds: 45:00 → 20:00
    static let tenKBand = StatLevel.Band(floor: 5400, target: 3000)    // seconds: 90:00 → 50:00
    static let vo2Band = StatLevel.Band(floor: 25, target: 55)         // mL/kg/min
    static let zoneTwoBand = StatLevel.Band(floor: 0, target: 90)      // continuous minutes
    static let swimMileBand = StatLevel.Band(floor: 3600, target: 1500) // seconds: 60:00 → 25:00

    /// Seven equal requirements.
    enum Weight {
        static let mile = 100.0 / 7
        static let fiveK = 100.0 / 7
        static let tenK = 100.0 / 7
        static let vo2 = 100.0 / 7
        static let zoneTwo = 100.0 / 7
        static let swimMile = 100.0 / 7
        static let bodyWeight = 100.0 / 7
    }

    static func evaluate(
        efforts: [RunEffort],
        swims: [SwimEffort],
        vo2: [VO2MaxReading],
        zoneTwo: [ZoneTwoSession],
        bodyMass: [BodyMassReading] = [],
        now: Date
    ) -> StatLevelReport {
        let effortStart = now.addingTimeInterval(-Double(effortWindowDays) * 86_400)
        let recentEfforts = efforts.filter { $0.date >= effortStart && $0.seconds > 0 }
        let recentZoneTwo = zoneTwo.filter { $0.date >= effortStart && $0.minutes > 0 }
        let recentSwims = swims.filter { $0.date >= effortStart && $0.seconds > 0 }
        let vo2Start = now.addingTimeInterval(-Double(vo2WindowDays) * 86_400)
        let recentVO2 = vo2.filter { $0.date >= vo2Start && $0.value > 0 }
        let massStart = now.addingTimeInterval(-Double(bodyWeightWindowDays) * 86_400)
        let recentMass = bodyMass.filter { $0.date >= massStart && $0.date <= now && $0.kg > 0 }
        return StatLevelReport(stat: .END, requirements: [
            runRule("1-mile run", .mile, recentEfforts, band: mileBand, weight: Weight.mile),
            runRule("5K run", .fiveK, recentEfforts, band: fiveKBand, weight: Weight.fiveK),
            // "Easy" means a low heart rate, which a time alone cannot show. Any 10K effort counts.
            runRule("10K easy run", .tenK, recentEfforts, band: tenKBand, weight: Weight.tenK),
            vo2Max(recentVO2),
            zoneTwoEndurance(recentZoneTwo),
            swimMile(recentSwims),
            bodyWeight(recentMass),
        ])
    }

    // MARK: - Body weight

    /// Strict rule: the newest weigh-in in 30 days is within 2 lb of 145 lb, either side.
    /// Progress is 1 inside that range and falls to 0 at 30 lb away.
    private static func bodyWeight(_ readings: [BodyMassReading]) -> StatRequirement {
        guard let latest = readings.max(by: { $0.date < $1.date }) else {
            return StatRequirement(category: "Body weight", passed: false, progress: 0, weight: Weight.bodyWeight, detail: "no weigh-in in \(bodyWeightWindowDays) days", hasData: false)
        }
        let off = abs(latest.pounds - bodyWeightTargetLb)
        let progress = 1 - (off - bodyWeightToleranceLb) / (bodyWeightFloorLb - bodyWeightToleranceLb)
        return StatRequirement(
            category: "Body weight",
            passed: off <= bodyWeightToleranceLb,
            progress: min(max(progress, 0), 1),
            weight: Weight.bodyWeight,
            detail: "latest \(format(latest.pounds)) lb (\(QuestDay.key(for: latest.date)))"
        )
    }

    // MARK: - Runs

    /// Strict rule: the fastest effort in 180 days is at or under the target time.
    private static func runRule(
        _ category: String,
        _ distance: RunDistance,
        _ efforts: [RunEffort],
        band: StatLevel.Band,
        weight: Double
    ) -> StatRequirement {
        guard let best = efforts.filter({ $0.distance == distance }).min(by: { $0.seconds < $1.seconds }) else {
            return StatRequirement(category: category, passed: false, progress: 0, weight: weight, detail: "no \(label(distance)) in \(effortWindowDays) days", hasData: false)
        }
        return StatRequirement(
            category: category,
            passed: best.seconds <= band.target,
            progress: band.progress(best.seconds),
            weight: weight,
            detail: "best \(clock(best.seconds)) (\(QuestDay.key(for: best.date)))"
        )
    }

    // MARK: - Swim

    /// Strict rule: the fastest 1-mile swim in 180 days is at or under 25:00.
    private static func swimMile(_ swims: [SwimEffort]) -> StatRequirement {
        guard let best = swims.min(by: { $0.seconds < $1.seconds }) else {
            return StatRequirement(category: "1-mile swim", passed: false, progress: 0, weight: Weight.swimMile, detail: "no 1-mile swim in \(effortWindowDays) days", hasData: false)
        }
        return StatRequirement(
            category: "1-mile swim",
            passed: best.seconds <= swimMileBand.target,
            progress: swimMileBand.progress(best.seconds),
            weight: Weight.swimMile,
            detail: "best \(clock(best.seconds)) (\(QuestDay.key(for: best.date)))"
        )
    }

    // MARK: - Physiology

    /// Strict rule: the newest reading in 90 days is 55 or higher. An older, higher reading does not count.
    private static func vo2Max(_ readings: [VO2MaxReading]) -> StatRequirement {
        guard let latest = readings.max(by: { $0.date < $1.date }) else {
            return StatRequirement(category: "VO₂ max", passed: false, progress: 0, weight: Weight.vo2, detail: "no VO₂ max in \(vo2WindowDays) days", hasData: false)
        }
        return StatRequirement(
            category: "VO₂ max",
            passed: latest.value >= vo2Band.target,
            progress: vo2Band.progress(latest.value),
            weight: Weight.vo2,
            detail: "latest \(format(latest.value)) mL/kg/min (\(QuestDay.key(for: latest.date)))"
        )
    }

    /// Strict rule: one session with 90 continuous minutes in zone 2. Sessions never add up.
    private static func zoneTwoEndurance(_ sessions: [ZoneTwoSession]) -> StatRequirement {
        guard let longest = sessions.max(by: { $0.minutes < $1.minutes }) else {
            return StatRequirement(category: "Zone 2 endurance", passed: false, progress: 0, weight: Weight.zoneTwo, detail: "no zone 2 session in \(effortWindowDays) days", hasData: false)
        }
        return StatRequirement(
            category: "Zone 2 endurance",
            passed: longest.minutes >= zoneTwoBand.target,
            progress: zoneTwoBand.progress(longest.minutes),
            weight: Weight.zoneTwo,
            detail: "longest \(format(longest.minutes)) min continuous (\(QuestDay.key(for: longest.date)))"
        )
    }

    // MARK: - Formatting

    private static func label(_ distance: RunDistance) -> String {
        switch distance {
        case .mile: return "mile"
        case .fiveK: return "5K"
        case .tenK: return "10K"
        }
    }

    /// m:ss with unbounded minutes: 372 → "6:12", 5400 → "90:00".
    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    // MARK: - Self-check (runs in DEBUG at launch)

    /// Fixed clock for the fixtures.
    static let checkNow = QuestDay.date(from: "2026-10-17") ?? Date(timeIntervalSince1970: 0)

    static func daysAgo(_ days: Int, from now: Date = checkNow) -> Date {
        now.addingTimeInterval(-Double(days) * 86_400)
    }

    struct Fixture {
        var efforts: [RunEffort]
        var swims: [SwimEffort] = []
        var vo2: [VO2MaxReading]
        var zoneTwo: [ZoneTwoSession]
        var bodyMass: [BodyMassReading] = []

        func evaluate(now: Date = checkNow) -> StatLevelReport {
            EnduranceLevel.evaluate(efforts: efforts, swims: swims, vo2: vo2, zoneTwo: zoneTwo, bodyMass: bodyMass, now: now)
        }
    }

    /// Inputs that meet every the max level requirement. Tests edit a copy.
    static func perfectFixture() -> Fixture {
        Fixture(
            efforts: [
                RunEffort(distance: .mile, seconds: 325, date: daysAgo(10), source: "Strava"),
                RunEffort(distance: .fiveK, seconds: 1190, date: daysAgo(20), source: "Strava"),
                RunEffort(distance: .tenK, seconds: 2950, date: daysAgo(30), source: "Strava"),
            ],
            swims: [SwimEffort(seconds: 1470, date: daysAgo(12), source: "Strava")],
            vo2: [VO2MaxReading(value: 57, date: daysAgo(5), source: "Apple Health")],
            zoneTwo: [ZoneTwoSession(minutes: 95, date: daysAgo(15), source: "Strava")],
            bodyMass: [BodyMassReading(kg: 145 / StatLevel.poundsPerKilogram, date: daysAgo(1), source: "MacroFactor")]
        )
    }

    /// Inputs at or below every level 0 floor.
    static func floorFixture() -> Fixture {
        Fixture(
            efforts: [
                RunEffort(distance: .mile, seconds: 780, date: daysAgo(10), source: "Strava"),
                RunEffort(distance: .fiveK, seconds: 2700, date: daysAgo(20), source: "Strava"),
                RunEffort(distance: .tenK, seconds: 6000, date: daysAgo(30), source: "Strava"),
            ],
            swims: [SwimEffort(seconds: 4200, date: daysAgo(12), source: "Strava")],
            vo2: [VO2MaxReading(value: 22, date: daysAgo(5), source: "Apple Health")],
            zoneTwo: [],
            bodyMass: [BodyMassReading(kg: 180 / StatLevel.poundsPerKilogram, date: daysAgo(1), source: "MacroFactor")]
        )
    }

    static func check() -> [String] {
        var errors: [String] = []
        let perfect = perfectFixture()
        let report = perfect.evaluate()
        if !report.isMaxLevel {
            errors.append("perfect fixture should reach the max level, failing: " + report.failing.map { "\($0.category): \($0.detail)" }.joined(separator: " | "))
        }
        if report.requirements.count != 7 {
            errors.append("END should have 7 requirements, got \(report.requirements.count)")
        }
        let totalWeight = report.requirements.reduce(0) { $0 + $1.weight }
        if abs(totalWeight - 100) > 0.001 {
            errors.append("weights should add to 100, got \(totalWeight)")
        }
        if report.level != StatLevel.maxLevel || abs(report.score - 100) > 0.001 || report.stat != .END {
            errors.append("perfect fixture should score 100 and the max level, got \(report.score) level \(report.level)")
        }

        let empty = Fixture(efforts: [], swims: [], vo2: [], zoneTwo: []).evaluate()
        if empty.isMaxLevel || empty.level != 0 || empty.score != 0 {
            errors.append("no data must be level 0, got level \(empty.level) score \(empty.score)")
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

        failsOnly("1-mile run") { $0.efforts[0].seconds = 400 }
        failsOnly("5K run") { $0.efforts[1].seconds = 1500 }
        failsOnly("10K easy run") { $0.efforts[2].seconds = 3300 }
        failsOnly("VO₂ max") { $0.vo2[0].value = 48 }
        failsOnly("Zone 2 endurance") { $0.zoneTwo[0].minutes = 60 }
        failsOnly("1-mile swim") { $0.swims[0].seconds = 1800 }

        /// An input with nothing in its window has no data: it drops out and the other six targets still reach the max.
        func dropsOut(_ category: String, _ edit: (inout Fixture) -> Void, line: Int = #line) {
            var fixture = perfect
            edit(&fixture)
            let edited = fixture.evaluate()
            let row = edited.requirements.first { $0.category == category }
            if row?.hasData != false || row?.progress != 0 || edited.failing.contains(where: { $0.category == category }) {
                errors.append("line \(line): \(category) should have no data and not fail, got \(String(describing: row))")
            }
            if !edited.isMaxLevel || edited.counted.count != 6 || abs(edited.counted.reduce(0, { $0 + $1.weight }) - 100) > 0.001 {
                errors.append("line \(line): without \(category) the other six targets should share the weight and reach the max, got level \(edited.level)")
            }
        }
        dropsOut("1-mile swim") { $0.swims = [] }
        dropsOut("1-mile swim") { $0.swims[0].date = daysAgo(181) }

        // The swim passes at exactly 25:00 and fails at 25:01. A 42:30 swim is half of the 60:00 → 25:00 band.
        var exactSwim = perfect
        exactSwim.swims[0].seconds = 1500
        if !exactSwim.evaluate().isMaxLevel {
            errors.append("a 25:00 mile swim should pass")
        }
        var slowSwim = perfect
        slowSwim.swims[0].seconds = 1501
        if slowSwim.evaluate().failing.map(\.category) != ["1-mile swim"] {
            errors.append("a 25:01 mile swim should fail")
        }
        var halfSwim = perfect
        halfSwim.swims[0].seconds = 2550
        let swimRow = halfSwim.evaluate().requirements.first { $0.category == "1-mile swim" }
        if abs((swimRow?.progress ?? 0) - 0.5) > 0.0001 || swimRow?.detail.hasPrefix("best 42:30") != true {
            errors.append("a 42:30 swim should give progress 0.5, got \(String(describing: swimRow))")
        }

        // A 5:31 mile misses 5:30 by one second. Strict rule fails; progress stays near 1, so the level caps one under the max.
        var slowMile = perfect
        slowMile.efforts[0].seconds = 331
        let slowReport = slowMile.evaluate()
        if slowReport.failing.map(\.category) != ["1-mile run"] || slowReport.level != StatLevel.maxLevel - 1 {
            errors.append("a 5:31 mile should fail and cap at one under the max level, got \(slowReport.failing.map(\.category)) level \(slowReport.level)")
        }
        // Exactly 5:30 passes.
        var exactMile = perfect
        exactMile.efforts[0].seconds = 330
        if !exactMile.evaluate().isMaxLevel {
            errors.append("a 5:30 mile should pass")
        }

        // Progress is linear: an 8:00 mile is (720 - 480) / (720 - 330) = 240/390 of the band.
        var eightMile = perfect
        eightMile.efforts[0].seconds = 480
        let eightRow = eightMile.evaluate().requirements.first { $0.category == "1-mile run" }
        if abs((eightRow?.progress ?? 0) - 240.0 / 390.0) > 0.0001 || eightRow?.detail.hasPrefix("best 8:00") != true {
            errors.append("an 8:00 mile should give progress \(240.0 / 390.0), got \(String(describing: eightRow))")
        }

        // The fastest effort in the window counts, not the newest.
        var twoMiles = perfect
        twoMiles.efforts.append(RunEffort(distance: .mile, seconds: 500, date: daysAgo(1), source: "Strava"))
        if !twoMiles.evaluate().isMaxLevel {
            errors.append("a slower newer mile should not hide the faster one")
        }

        // Efforts and zone 2 sessions older than 180 days do not count. With nothing left in the window the target drops out.
        dropsOut("1-mile run") { $0.efforts[0].date = daysAgo(181) }
        dropsOut("Zone 2 endurance") { $0.zoneTwo[0].date = daysAgo(200) }
        var oldRow = perfect
        oldRow.efforts[1].date = daysAgo(181)
        let oldDetail = oldRow.evaluate().requirements.first { $0.category == "5K run" }?.detail
        if oldDetail != "no 5K in 180 days" {
            errors.append("an old 5K should read \"no 5K in 180 days\", got \(String(describing: oldDetail))")
        }

        // VO₂ max uses the newest reading, not the best: a newer 50 after an older 56 fails.
        failsOnly("VO₂ max") { fixture in
            fixture.vo2 = [
                VO2MaxReading(value: 56, date: daysAgo(40), source: "Apple Health"),
                VO2MaxReading(value: 50, date: daysAgo(3), source: "WHOOP"),
            ]
        }
        // A reading older than 90 days does not count; with no newer reading the target drops out.
        dropsOut("VO₂ max") { $0.vo2[0].date = daysAgo(91) }

        // Two 45-minute zone 2 sessions do not add up to 90.
        failsOnly("Zone 2 endurance") { fixture in
            fixture.zoneTwo = [
                ZoneTwoSession(minutes: 45, date: daysAgo(4), source: "Strava"),
                ZoneTwoSession(minutes: 45, date: daysAgo(2), source: "Strava"),
            ]
        }

        // Body weight: 147 lb and 143 lb pass, 147.5 lb fails. 160 lb is 15 lb off: 1 - (15 - 2) / (30 - 2) = 15/28 of the band.
        func pounds(_ lb: Double, daysAgo days: Int = 1) -> [BodyMassReading] {
            [BodyMassReading(kg: lb / StatLevel.poundsPerKilogram, date: daysAgo(days), source: "MacroFactor")]
        }
        for lb in [147.0, 143.0] {
            var near = perfect
            near.bodyMass = pounds(lb)
            if !near.evaluate().isMaxLevel {
                errors.append("\(lb) lb should pass the 145 lb target")
            }
        }
        failsOnly("Body weight") { $0.bodyMass = pounds(147.5) }
        failsOnly("Body weight") { $0.bodyMass = pounds(130) }
        dropsOut("Body weight") { $0.bodyMass = [] }
        dropsOut("Body weight") { $0.bodyMass = pounds(145, daysAgo: 31) }
        // Body weight alone, with nothing else logged, is the whole END score.
        let weightOnly = Fixture(efforts: [], swims: [], vo2: [], zoneTwo: [], bodyMass: pounds(160)).evaluate()
        if weightOnly.counted.map(\.category) != ["Body weight"] || weightOnly.counted.first?.weight != 100 || weightOnly.level != 187 {
            errors.append("a lone 160 lb weigh-in should score alone: 15/28 of 350 = level 187, got \(weightOnly.counted.map { "\($0.category) \($0.weight)" }) level \(weightOnly.level)")
        }
        var heavy = perfect
        heavy.bodyMass = pounds(160)
        let heavyRow = heavy.evaluate().requirements.first { $0.category == "Body weight" }
        if abs((heavyRow?.progress ?? 0) - 15.0 / 28.0) > 0.0001 || heavyRow?.detail.hasPrefix("latest 160.0 lb") != true {
            errors.append("160 lb should give progress 15/28, got \(String(describing: heavyRow))")
        }
        // The newest weigh-in counts, not the closest one.
        failsOnly("Body weight") { $0.bodyMass = pounds(145, daysAgo: 10) + pounds(150, daysAgo: 2) }

        if clock(372) != "6:12" || clock(5400) != "90:00" || clock(59.6) != "1:00" {
            errors.append("clock format wrong: \(clock(372)) \(clock(5400)) \(clock(59.6))")
        }
        return errors
    }
}
