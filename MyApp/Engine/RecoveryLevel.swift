import Foundation

/// One local day of recovery inputs. Every field is optional because each
/// source (WHOOP, MacroFactor via HealthKit, Strava) can be missing on a day.
/// A nil field means "not logged"; it is never scored as a fail.
struct RecoveryDay: Codable, Equatable {
    var dayKey: String

    // WHOOP sleep
    /// Sleep performance: hours slept ÷ WHOOP sleep need, in percent.
    var sleepNeedPct: Double?
    var sleepConsistencyPct: Double?
    var sleepEfficiencyPct: Double?
    var sleepDebtMinutes: Double?
    /// Minutes relative to local midnight. Bedtime before midnight is negative (23:00 → -60).
    var bedtimeMinutes: Double?
    var wakeMinutes: Double?

    // WHOOP physiology
    var hrv: Double?
    var restingHr: Double?
    var dayStrain: Double?
    var workoutCount: Int = 0

    // MacroFactor (through HealthKit)
    var caffeineMg: Double?
    var proteinG: Double?
    var fatG: Double?
    var carbsG: Double?
    var caloriesKcal: Double?
    /// MacroFactor's expenditure estimate for the day.
    var maintenanceKcal: Double?
    /// Trend weight, not a single weigh-in.
    var bodyMassKg: Double?
}

/// One scored category. `passed` is the strict level 146 rule.
/// `progress` is 0 at the level 0 floor and 1 at the level 146 target.
struct RecoveryRequirement: Equatable, Identifiable {
    var category: String
    var passed: Bool
    var progress: Double
    /// Share of the 100-point score. All weights add to 100.
    var weight: Double
    var detail: String

    var id: String { category }
    var points: Double { progress * weight }
    /// Levels still available in this category.
    var levelsAvailable: Double { (weight - points) * Double(RecoveryLevel.maxLevel) / 100 }
}

struct RecoveryLevelReport: Equatable {
    var requirements: [RecoveryRequirement]

    /// Level 146 needs every requirement at once.
    var isLevel146: Bool { requirements.allSatisfy(\.passed) }
    var failing: [RecoveryRequirement] { requirements.filter { !$0.passed } }

    /// 0...100. Weighted sum of category progress.
    var score: Double { requirements.reduce(0) { $0 + $1.points } }

    /// 0...146. The max level needs every strict rule, not just a full score.
    var level: Int {
        let scored = Int((Double(RecoveryLevel.maxLevel) * score / 100 + 1e-9).rounded(.down))
        return isLevel146 ? RecoveryLevel.maxLevel : min(scored, RecoveryLevel.maxLevel - 1)
    }

    var levelsToMax: Int { RecoveryLevel.maxLevel - level }

    /// Categories with the most levels left, best first.
    func topGains(_ count: Int = 3) -> [RecoveryRequirement] {
        Array(requirements.filter { $0.levelsAvailable > 0 }.sorted { $0.levelsAvailable > $1.levelsAvailable }.prefix(count))
    }
}

/// Deterministic recovery level 0...146.
/// Pure: the same days always give the same report. No network and no clock.
enum RecoveryLevel {
    static let maxLevel = 146
    static let windowDays = 30
    static let baselineDays = 90
    /// A daily metric needs 90% of the window logged (27 of 30 days), or it fails for missing data.
    static let minimumLoggedDays = 27
    static let minimumBaselineSamples = 60

    /// Level 0 floor and level 146 target for one metric. Lower-is-better metrics put the floor above the target.
    struct Band: Equatable {
        var floor: Double
        var target: Double

        func progress(_ value: Double) -> Double {
            let raw = (value - floor) / (target - floor)
            return min(max(raw, 0), 1)
        }
    }

    // Floors are common "unhealthy" limits; targets are the level 146 rules.
    static let sleepNeedBand = Band(floor: 0, target: 0.90)          // share of nights at 100% sleep need
    static let sleepConsistencyBand = Band(floor: 50, target: 90)    // %
    static let sleepEfficiencyBand = Band(floor: 75, target: 92)     // %
    static let sleepDebtBand = Band(floor: 120, target: 15)          // minutes
    static let caffeineBand = Band(floor: 600, target: 0)            // mg/day average
    static let proteinBand = Band(floor: 0.8, target: 1.6)           // g/kg
    static let fatBand = Band(floor: 0.3, target: 0.8)               // g/kg
    static let carbBand = Band(floor: 0, target: 0.90)               // share of days matched to load
    static let calorieBand = Band(floor: 0.25, target: 0.05)         // worst 7-day deviation from maintenance
    static let restDaysBand = Band(floor: 0, target: 1)              // per week
    static let lightDaysBand = Band(floor: 0, target: 1)             // per week
    static let veryHighDaysBand = Band(floor: 7, target: 4)          // per week
    static let hrvBand = Band(floor: 0.80, target: 1.00)             // 30-day median ÷ 90-day median
    static let restingHrBand = Band(floor: 75, target: 50)           // bpm
    static let restingHrMin = 45.0
    static let circadianBand = Band(floor: 120, target: 30)          // minutes of drift

    static let restStrainMax = 8.0
    static let lightStrainRange = 8.0..<12.0
    static let veryHighStrainMin = 18.0

    enum Weight {
        static let sleepDuration = 15.0
        static let sleepConsistency = 8.0
        static let sleepEfficiency = 10.0
        static let sleepDebt = 8.0
        static let caffeine = 5.0
        static let nutrition = 15.0
        static let training = 10.0
        static let hrv = 15.0
        static let restingHr = 8.0
        static let circadian = 6.0
    }

    /// Carbs per kg of trend weight, chosen by the same day's WHOOP strain.
    static func carbFactor(strain: Double) -> Double {
        if strain < 8 { return 2 }
        if strain < 14 { return 3 }
        if strain < 18 { return 4 }
        return 8
    }

    static func carbTargetGrams(strain: Double, bodyMassKg: Double) -> Double {
        bodyMassKg * carbFactor(strain: strain)
    }

    /// `days` may hold up to 90 days (for the HRV baseline). The last 30 by `dayKey` form the scoring window.
    static func evaluate(days input: [RecoveryDay]) -> RecoveryLevelReport {
        let all = Array(input.sorted { $0.dayKey < $1.dayKey }.suffix(baselineDays))
        let window = Array(all.suffix(windowDays))
        return RecoveryLevelReport(requirements: [
            sleepDuration(window),
            sleepConsistency(window),
            sleepEfficiency(window),
            sleepDebt(window),
            caffeine(window),
            nutrition(window),
            trainingRecovery(window),
            hrv(window: window, baseline: all),
            restingHeartRate(window),
            circadianRhythm(window),
        ])
    }

    // MARK: - Sleep

    private static func sleepDuration(_ window: [RecoveryDay]) -> RecoveryRequirement {
        ratioRule("Sleep duration", window, \.sleepNeedPct, band: sleepNeedBand, weight: Weight.sleepDuration, label: "nights at 100% sleep need") { $0 >= 100 }
    }

    private static func sleepConsistency(_ window: [RecoveryDay]) -> RecoveryRequirement {
        averageRule("Sleep consistency", window, \.sleepConsistencyPct, band: sleepConsistencyBand, weight: Weight.sleepConsistency, unit: "%")
    }

    private static func sleepEfficiency(_ window: [RecoveryDay]) -> RecoveryRequirement {
        averageRule("Sleep efficiency", window, \.sleepEfficiencyPct, band: sleepEfficiencyBand, weight: Weight.sleepEfficiency, unit: "%")
    }

    private static func sleepDebt(_ window: [RecoveryDay]) -> RecoveryRequirement {
        averageRule("Sleep debt", window, \.sleepDebtMinutes, band: sleepDebtBand, weight: Weight.sleepDebt, unit: " min")
    }

    // MARK: - Stimulants

    /// Strict rule: every logged day at 0 mg. Progress: 30-day average from 600 mg down to 0.
    private static func caffeine(_ window: [RecoveryDay]) -> RecoveryRequirement {
        let values = window.compactMap(\.caffeineMg)
        let average = values.isEmpty ? caffeineBand.floor : values.reduce(0, +) / Double(values.count)
        return RecoveryRequirement(
            category: "Caffeine",
            passed: values.count >= minimumLoggedDays && values.allSatisfy { $0 <= 0 },
            progress: caffeineBand.progress(average) * coverage(values.count),
            weight: Weight.caffeine,
            detail: logged(values.count, of: window.count) + "average \(format(average)) mg/day"
        )
    }

    // MARK: - Nutrition

    /// Four equal sub-metrics: protein, fat, carbs matched to load, calories near maintenance.
    private static func nutrition(_ window: [RecoveryDay]) -> RecoveryRequirement {
        var problems: [String] = []
        var notes: [String] = []
        var progressParts: [Double] = []

        let withMass = carryForwardBodyMass(window)

        // Protein and fat: 30-day average of g/kg trend weight.
        for (name, keyPath, band) in [
            ("protein", \RecoveryDay.proteinG, proteinBand),
            ("fat", \RecoveryDay.fatG, fatBand),
        ] {
            let perKg = withMass.compactMap { day -> Double? in
                guard let grams = day[keyPath: keyPath], let kg = day.bodyMassKg, kg > 0 else { return nil }
                return grams / kg
            }
            let average = perKg.isEmpty ? band.floor : perKg.reduce(0, +) / Double(perKg.count)
            progressParts.append(band.progress(average) * coverage(perKg.count))
            let text = "\(name) \(format(average)) g/kg"
            if perKg.count < minimumLoggedDays {
                problems.append("\(name) logged on \(perKg.count)/\(window.count) days")
            } else if average >= band.target {
                notes.append(text)
            } else {
                problems.append("\(text) < \(format(band.target))")
            }
        }

        // Carbs: 2-day rolling sum against the load-matched 2-day target.
        let scored = carbPassByDay(withMass).compactMap { $0 }
        let carbRatio = scored.isEmpty ? 0 : Double(scored.filter { $0 }.count) / Double(scored.count)
        progressParts.append(carbBand.progress(carbRatio) * coverage(scored.count + 1))
        let carbText = "carbs matched load on \(percent(carbRatio)) of days"
        if scored.count < minimumLoggedDays - 1 {
            problems.append("carbs scored on \(scored.count) days")
        } else if carbRatio >= carbBand.target {
            notes.append(carbText)
        } else {
            problems.append(carbText)
        }

        // Calories: every complete rolling 7-day window within 5% of maintenance.
        let caloriePairs = window.compactMap { day -> (Double, Double)? in
            guard let eaten = day.caloriesKcal, let need = day.maintenanceKcal, need > 0 else { return nil }
            return (eaten, need)
        }
        var worst = calorieBand.floor
        if caloriePairs.count >= 7 {
            worst = 0
            for end in 7...caloriePairs.count {
                let slice = caloriePairs[(end - 7)..<end]
                let eaten = slice.map(\.0).reduce(0, +)
                let need = slice.map(\.1).reduce(0, +)
                worst = max(worst, abs(eaten - need) / need)
            }
        }
        progressParts.append(calorieBand.progress(worst) * coverage(caloriePairs.count))
        let calorieText = "calories within \(percent(worst)) of maintenance (7-day)"
        if caloriePairs.count < minimumLoggedDays {
            problems.append("calories logged on \(caloriePairs.count)/\(window.count) days")
        } else if worst <= calorieBand.target {
            notes.append(calorieText)
        } else {
            problems.append(calorieText)
        }

        return RecoveryRequirement(
            category: "Nutrition",
            passed: problems.isEmpty,
            progress: progressParts.reduce(0, +) / Double(progressParts.count),
            weight: Weight.nutrition,
            detail: (problems + notes).joined(separator: "; ")
        )
    }

    /// Days without a weigh-in use the most recent earlier trend weight.
    private static func carryForwardBodyMass(_ window: [RecoveryDay]) -> [RecoveryDay] {
        var last: Double?
        return window.map { day in
            var copy = day
            if copy.bodyMassKg == nil { copy.bodyMassKg = last } else { last = copy.bodyMassKg }
            return copy
        }
    }

    /// One entry per day. `nil` when the day or the day before lacks carbs, strain, or weight.
    static func carbPassByDay(_ days: [RecoveryDay]) -> [Bool?] {
        var results: [Bool?] = [nil]
        for (previous, current) in zip(days, days.dropFirst()) {
            guard let carbsBefore = previous.carbsG, let carbsNow = current.carbsG,
                  let strainBefore = previous.dayStrain, let strainNow = current.dayStrain,
                  let massBefore = previous.bodyMassKg, let massNow = current.bodyMassKg else {
                results.append(nil)
                continue
            }
            let target = carbTargetGrams(strain: strainBefore, bodyMassKg: massBefore)
                + carbTargetGrams(strain: strainNow, bodyMassKg: massNow)
            results.append(carbsBefore + carbsNow >= target)
        }
        return results
    }

    // MARK: - Training

    /// Three equal sub-metrics per week: rest days, light days, very-high days. Averaged over complete weeks.
    private static func trainingRecovery(_ window: [RecoveryDay]) -> RecoveryRequirement {
        let strainCount = window.filter { $0.dayStrain != nil }.count
        // Fixed 7-day blocks counted back from the newest day. A leftover partial week is not scored.
        let weeks = stride(from: window.count, through: 7, by: -7).map { end in Array(window[(end - 7)..<end]) }
        guard !weeks.isEmpty else {
            return RecoveryRequirement(category: "Training recovery", passed: false, progress: 0, weight: Weight.training, detail: "strain logged on \(strainCount)/\(window.count) days")
        }

        var problems: [String] = []
        // Progress follows the worst week, so a single bad week shows up in the level.
        var fewestRest = Int.max, fewestLight = Int.max, mostVeryHigh = 0
        for (index, week) in weeks.enumerated() {
            let rest = week.filter { ($0.dayStrain ?? .infinity) < restStrainMax && $0.workoutCount == 0 }.count
            let light = week.filter { day in day.dayStrain.map { lightStrainRange.contains($0) } ?? false }.count
            let veryHigh = week.filter { ($0.dayStrain ?? 0) > veryHighStrainMin }.count
            fewestRest = min(fewestRest, rest)
            fewestLight = min(fewestLight, light)
            mostVeryHigh = max(mostVeryHigh, veryHigh)
            var missing: [String] = []
            if rest < 1 { missing.append("no rest day") }
            if light < 1 { missing.append("no light day") }
            if veryHigh > Int(veryHighDaysBand.target) { missing.append("\(veryHigh) very-high days") }
            if !missing.isEmpty {
                problems.append("week \(index + 1) back: " + missing.joined(separator: ", "))
            }
        }
        let progress = (restDaysBand.progress(Double(fewestRest))
            + lightDaysBand.progress(Double(fewestLight))
            + veryHighDaysBand.progress(Double(mostVeryHigh))) / 3 * coverage(strainCount)
        let summary = "\(weeks.count) weeks; worst week: \(fewestRest) rest, \(fewestLight) light, \(mostVeryHigh) very-high days"
        return RecoveryRequirement(
            category: "Training recovery",
            passed: strainCount >= minimumLoggedDays && problems.isEmpty,
            progress: progress,
            weight: Weight.training,
            detail: logged(strainCount, of: window.count) + (problems.isEmpty ? summary : problems.joined(separator: "; "))
        )
    }

    // MARK: - Physiology

    private static func hrv(window: [RecoveryDay], baseline: [RecoveryDay]) -> RecoveryRequirement {
        let recent = window.compactMap(\.hrv)
        let base = baseline.compactMap(\.hrv)
        guard !recent.isEmpty, !base.isEmpty else {
            return RecoveryRequirement(category: "HRV", passed: false, progress: 0, weight: Weight.hrv, detail: "HRV logged on \(recent.count)/\(window.count) days")
        }
        let recentMedian = median(recent)
        let baseMedian = median(base)
        let ratio = baseMedian > 0 ? recentMedian / baseMedian : 0
        let enough = recent.count >= minimumLoggedDays && base.count >= minimumBaselineSamples
        var detail = "30-day median \(format(recentMedian)) ms vs 90-day \(format(baseMedian)) ms"
        if base.count < minimumBaselineSamples { detail = "HRV baseline has \(base.count)/\(minimumBaselineSamples) days; " + detail }
        return RecoveryRequirement(
            category: "HRV",
            passed: enough && recentMedian >= baseMedian,
            progress: hrvBand.progress(ratio) * coverage(recent.count) * min(1, Double(base.count) / Double(minimumBaselineSamples)),
            weight: Weight.hrv,
            detail: logged(recent.count, of: window.count) + detail
        )
    }

    /// Strict rule: 45–50 bpm. Progress counts down from 75 and is full at 50 or lower.
    private static func restingHeartRate(_ window: [RecoveryDay]) -> RecoveryRequirement {
        let values = window.compactMap(\.restingHr)
        let average = values.isEmpty ? restingHrBand.floor : values.reduce(0, +) / Double(values.count)
        return RecoveryRequirement(
            category: "Resting heart rate",
            passed: values.count >= minimumLoggedDays && average >= restingHrMin && average <= restingHrBand.target,
            progress: restingHrBand.progress(average) * coverage(values.count),
            weight: Weight.restingHr,
            detail: logged(values.count, of: window.count) + "30-day average \(format(average)) bpm"
        )
    }

    private static func circadianRhythm(_ window: [RecoveryDay]) -> RecoveryRequirement {
        let nights = window.compactMap { day -> (Double, Double)? in
            guard let bed = day.bedtimeMinutes, let wake = day.wakeMinutes else { return nil }
            return (bed, wake)
        }
        guard !nights.isEmpty else {
            return RecoveryRequirement(category: "Circadian rhythm", passed: false, progress: 0, weight: Weight.circadian, detail: "sleep times logged on 0/\(window.count) nights")
        }
        let bedMedian = median(nights.map(\.0))
        let wakeMedian = median(nights.map(\.1))
        let bedDrift = nights.map { abs($0.0 - bedMedian) }.reduce(0, +) / Double(nights.count)
        let wakeDrift = nights.map { abs($0.1 - wakeMedian) }.reduce(0, +) / Double(nights.count)
        let drift = max(bedDrift, wakeDrift)
        return RecoveryRequirement(
            category: "Circadian rhythm",
            passed: nights.count >= minimumLoggedDays && drift <= circadianBand.target,
            progress: circadianBand.progress(drift) * coverage(nights.count),
            weight: Weight.circadian,
            detail: logged(nights.count, of: window.count) + "bedtime drifts \(format(bedDrift)) min, wake drifts \(format(wakeDrift)) min"
        )
    }

    // MARK: - Shared rules

    /// Strict rule: the share of logged days that satisfy `test` reaches the band target.
    private static func ratioRule(
        _ category: String,
        _ window: [RecoveryDay],
        _ keyPath: KeyPath<RecoveryDay, Double?>,
        band: Band,
        weight: Double,
        label: String,
        test: (Double) -> Bool
    ) -> RecoveryRequirement {
        let values = window.compactMap { $0[keyPath: keyPath] }
        let ratio = values.isEmpty ? band.floor : Double(values.filter(test).count) / Double(values.count)
        return RecoveryRequirement(
            category: category,
            passed: values.count >= minimumLoggedDays && ratio >= band.target,
            progress: band.progress(ratio) * coverage(values.count),
            weight: weight,
            detail: logged(values.count, of: window.count) + "\(percent(ratio)) of \(label)"
        )
    }

    /// Strict rule: the 30-day average reaches the band target.
    private static func averageRule(
        _ category: String,
        _ window: [RecoveryDay],
        _ keyPath: KeyPath<RecoveryDay, Double?>,
        band: Band,
        weight: Double,
        unit: String
    ) -> RecoveryRequirement {
        let values = window.compactMap { $0[keyPath: keyPath] }
        let average = values.isEmpty ? band.floor : values.reduce(0, +) / Double(values.count)
        return RecoveryRequirement(
            category: category,
            passed: values.count >= minimumLoggedDays && band.progress(average) >= 1,
            progress: band.progress(average) * coverage(values.count),
            weight: weight,
            detail: logged(values.count, of: window.count) + "30-day average \(format(average))\(unit)"
        )
    }

    /// Scales progress down when fewer than 27 days are logged, so skipped logs cannot raise the level.
    private static func coverage(_ loggedDays: Int) -> Double {
        min(1, Double(loggedDays) / Double(minimumLoggedDays))
    }

    private static func logged(_ count: Int, of total: Int) -> String {
        count < minimumLoggedDays ? "logged on \(count)/\(total) days; " : ""
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func percent(_ ratio: Double) -> String {
        "\(Int((ratio * 100).rounded()))%"
    }

    // MARK: - Self-check (runs in DEBUG at launch)

    /// Ninety days that meet every level 146 requirement. Tests edit a copy.
    static func perfectDays(count: Int = 90, start: String = "2026-07-01") -> [RecoveryDay] {
        guard let first = QuestDay.date(from: start) else { return [] }
        return (0..<count).map { offset in
            let date = QuestDay.calendar.date(byAdding: .day, value: offset, to: first) ?? first
            // Weekly plan: rest, light, high, very high, high, very high, moderate.
            let plan: [(Double, Int)] = [(5, 0), (10, 1), (15, 1), (19, 1), (16, 1), (19, 1), (13, 1)]
            let (strain, workouts) = plan[offset % 7]
            let carbs = carbTargetGrams(strain: strain, bodyMassKg: 80) + 10
            return RecoveryDay(
                dayKey: QuestDay.key(for: date),
                sleepNeedPct: 102,
                sleepConsistencyPct: 93,
                sleepEfficiencyPct: 94,
                sleepDebtMinutes: 5,
                bedtimeMinutes: -60,
                wakeMinutes: 420,
                hrv: 80,
                restingHr: 47,
                dayStrain: strain,
                workoutCount: workouts,
                caffeineMg: 0,
                proteinG: 140,
                fatG: 70,
                carbsG: carbs,
                caloriesKcal: 3000,
                maintenanceKcal: 3000,
                bodyMassKg: 80
            )
        }
    }

    /// Ninety days at or below every level 0 floor.
    static func floorDays(count: Int = 90, start: String = "2026-07-01") -> [RecoveryDay] {
        perfectDays(count: count, start: start).map { day in
            var copy = day
            copy.sleepNeedPct = 60
            copy.sleepConsistencyPct = 40
            copy.sleepEfficiencyPct = 70
            copy.sleepDebtMinutes = 150
            copy.bedtimeMinutes = Int(day.dayKey.suffix(2)).map { $0 % 2 == 0 ? -240 : 120 }
            copy.wakeMinutes = Int(day.dayKey.suffix(2)).map { $0 % 2 == 0 ? 300 : 660 }
            copy.restingHr = 80
            copy.dayStrain = 20
            copy.workoutCount = 2
            copy.caffeineMg = 700
            copy.proteinG = 40
            copy.fatG = 15
            copy.carbsG = 50
            copy.caloriesKcal = 4500
            return copy
        }
    }

    static func check() -> [String] {
        var errors: [String] = []
        let perfect = perfectDays()
        let report = evaluate(days: perfect)
        if !report.isLevel146 {
            errors.append("perfect days should reach level 146, failing: " + report.failing.map { "\($0.category): \($0.detail)" }.joined(separator: " | "))
        }
        if report.requirements.count != 10 {
            errors.append("level 146 should have 10 requirements, got \(report.requirements.count)")
        }
        let totalWeight = report.requirements.reduce(0) { $0 + $1.weight }
        if abs(totalWeight - 100) > 0.001 {
            errors.append("weights should add to 100, got \(totalWeight)")
        }
        if report.level != maxLevel || abs(report.score - 100) > 0.001 || report.levelsToMax != 0 {
            errors.append("perfect days should score 100 and level 146, got \(report.score) level \(report.level)")
        }

        let empty = evaluate(days: [])
        if empty.isLevel146 || empty.level != 0 || empty.score != 0 {
            errors.append("no data must be level 0, got level \(empty.level) score \(empty.score)")
        }

        // The floor set: at or below every level 0 floor, but with HRV at baseline so only the physiology ratio is tested elsewhere.
        var floored = floorDays()
        for index in 60..<90 { floored[index].hrv = 60 }
        let floorReport = evaluate(days: floored)
        if floorReport.level != 0 || floorReport.score > 0.001 {
            errors.append("floor days should be level 0, got level \(floorReport.level) score \(floorReport.score): " + floorReport.requirements.map { "\($0.category) \($0.points)" }.joined(separator: ", "))
        }

        func failsOnly(_ category: String, _ edit: (inout [RecoveryDay]) -> Void, line: Int = #line) {
            var days = perfect
            edit(&days)
            let edited = evaluate(days: days)
            let failing = edited.failing.map(\.category)
            if failing != [category] {
                errors.append("line \(line): expected only \(category) to fail, got \(failing)")
            }
            if edited.level >= maxLevel {
                errors.append("line \(line): a failing \(category) must stay under level 146, got \(edited.level)")
            }
            if edited.topGains(1).first?.category != category {
                errors.append("line \(line): \(category) should be the top gain, got \(edited.topGains(1).map(\.category))")
            }
        }

        // One bad night in 30 is fine (29/30 = 97%); four bad nights drop under 90%.
        var threeBad = perfect
        for index in 85..<88 { threeBad[index].sleepNeedPct = 80 }
        if !evaluate(days: threeBad).isLevel146 {
            errors.append("three short nights in 30 (90%) should still pass sleep duration")
        }
        failsOnly("Sleep duration") { days in for index in 84..<88 { days[index].sleepNeedPct = 80 } }
        failsOnly("Sleep consistency") { days in for index in 60..<90 { days[index].sleepConsistencyPct = 85 } }
        failsOnly("Sleep efficiency") { days in days[89].sleepEfficiencyPct = 30 }
        failsOnly("Sleep debt") { days in days[89].sleepDebtMinutes = 400 }
        failsOnly("Caffeine") { days in days[70].caffeineMg = 95 }
        failsOnly("Nutrition") { days in for index in 60..<90 { days[index].proteinG = 100 } }
        failsOnly("Nutrition") { days in for index in 60..<90 { days[index].fatG = 40 } }
        failsOnly("Nutrition") { days in for index in 60..<90 { days[index].caloriesKcal = 3400 } }
        // The newest week is days 83...89: 83 moderate, 84 rest, 85 light, 86 high, 87 very high, 88 high, 89 very high.
        failsOnly("Training recovery") { days in days[84].dayStrain = 12 } // no rest day
        failsOnly("Training recovery") { days in days[84].workoutCount = 1 } // a workout on the rest day
        failsOnly("Training recovery") { days in days[85].dayStrain = 15 } // no light day
        failsOnly("Training recovery") { days in
            for index in [83, 86, 88] { // 5 very-high days in one week
                days[index].dayStrain = 19
                days[index].carbsG = carbTargetGrams(strain: 19, bodyMassKg: 80) + 10
            }
        }
        var fourVeryHigh = perfect
        for index in [86, 88] {
            fourVeryHigh[index].dayStrain = 19
            fourVeryHigh[index].carbsG = carbTargetGrams(strain: 19, bodyMassKg: 80) + 10
        }
        if !evaluate(days: fourVeryHigh).isLevel146 {
            errors.append("four very-high days in a week should still pass")
        }
        failsOnly("HRV") { days in for index in 60..<90 { days[index].hrv = 70 } }
        failsOnly("Resting heart rate") { days in for index in 60..<90 { days[index].restingHr = 52 } }
        failsOnly("Circadian rhythm") { days in for index in 60..<90 where index % 2 == 0 { days[index].wakeMinutes = 540 } }

        // Missing data fails the category instead of passing it quietly.
        failsOnly("Caffeine") { days in for index in 60..<64 { days[index].caffeineMg = nil } }
        failsOnly("HRV") { days in for index in 0..<40 { days[index].hrv = nil } }

        // A resting heart rate under 45 fails the strict rule but keeps full progress, so the level caps at 145.
        var lowHr = perfect
        for index in 60..<90 { lowHr[index].restingHr = 42 }
        let lowHrReport = evaluate(days: lowHr)
        if lowHrReport.isLevel146 || lowHrReport.level != maxLevel - 1 {
            errors.append("a 42 bpm average should cap at level 145, got \(lowHrReport.level)")
        }

        // Progress is linear between floor and target. Caffeine at 300 mg is half of the 600 → 0 band.
        var halfCaffeine = perfect
        for index in 60..<90 { halfCaffeine[index].caffeineMg = 300 }
        let halfReport = evaluate(days: halfCaffeine)
        guard let caffeineRow = halfReport.requirements.first(where: { $0.category == "Caffeine" }) else {
            return errors + ["caffeine row missing"]
        }
        if abs(caffeineRow.progress - 0.5) > 0.001 || abs(halfReport.score - 97.5) > 0.001 {
            errors.append("300 mg caffeine should be 0.5 progress and score 97.5, got \(caffeineRow.progress) \(halfReport.score)")
        }
        if halfReport.level != 142 || abs(caffeineRow.levelsAvailable - 3.65) > 0.001 {
            errors.append("score 97.5 should be level 142 with 3.65 levels available in caffeine, got \(halfReport.level) \(caffeineRow.levelsAvailable)")
        }

        // Skipped logs scale progress down: caffeine logged on 9 of 30 days keeps a third of its points.
        var sparse = perfect
        for index in 60..<81 { sparse[index].caffeineMg = nil }
        let sparseRow = evaluate(days: sparse).requirements.first { $0.category == "Caffeine" }
        if sparseRow?.passed != false || abs((sparseRow?.progress ?? 0) - 9.0 / 27.0) > 0.001 {
            errors.append("9 logged caffeine days should give progress 9/27, got \(String(describing: sparseRow))")
        }

        // Carbs: the 2-day rolling sum lets the next day cover a shortfall, and one miss in 30 stays above 90%.
        var rolled = perfect
        rolled[88].carbsG = (rolled[88].carbsG ?? 0) - 100
        rolled[89].carbsG = (rolled[89].carbsG ?? 0) + 100
        let rolledPasses = carbPassByDay(Array(rolled.suffix(30)))
        if rolledPasses[28] != false || rolledPasses[29] != true {
            errors.append("day 88 should miss its 2-day carb target and day 89 should cover it, got \(rolledPasses.suffix(2))")
        }
        if !evaluate(days: rolled).isLevel146 {
            errors.append("a single carb shortfall in 30 days should still pass")
        }
        failsOnly("Nutrition") { days in for index in 60..<90 { days[index].carbsG = 100 } }
        var noWeight = perfect
        for index in 61..<90 { noWeight[index].bodyMassKg = nil }
        if !evaluate(days: noWeight).isLevel146 {
            errors.append("trend weight should carry forward across days without a weigh-in")
        }

        let factors = [(5.0, 2.0), (8.0, 3.0), (13.9, 3.0), (14.0, 4.0), (17.9, 4.0), (18.0, 8.0)]
        for (strain, expected) in factors where carbFactor(strain: strain) != expected {
            errors.append("carb factor for strain \(strain) should be \(expected), got \(carbFactor(strain: strain))")
        }
        if carbTargetGrams(strain: 19, bodyMassKg: 80) != 640 {
            errors.append("80 kg at strain 19 should need 640 g carbs")
        }

        // Only the newest 30 days are scored; older days feed the HRV baseline.
        var oldBad = perfect
        for index in 0..<60 { oldBad[index].caffeineMg = 500 }
        if !evaluate(days: oldBad).isLevel146 {
            errors.append("days older than the 30-day window should not score")
        }
        return errors
    }
}
