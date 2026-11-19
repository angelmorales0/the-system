import Foundation

/// One local day of recovery inputs. Every field is optional because each
/// source (WHOOP, MacroFactor via HealthKit, Strava) can be missing on a day.
/// A nil field means "not logged". A metric with no logged day in the window has no data and counts as 0 in
/// the score (see `StatLevelReport.counted`). A metric logged on some days counts, scaled down by how many.
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
    /// The day's expenditure: Apple Health active plus basal energy (an Apple Watch), on days that have both.
    /// MacroFactor keeps its own expenditure estimate and does not write it to Health.
    var maintenanceKcal: Double?
    /// Trend weight, not a single weigh-in.
    var bodyMassKg: Double?
}

/// One scored category. `passed` is the strict the max level rule.
/// `progress` is 0 at the level 0 floor and 1 at the max level target.
struct RecoveryRequirement: Equatable, Identifiable {
    var category: String
    var passed: Bool
    var progress: Double
    /// Share of the 100-point score. All weights add to 100.
    var weight: Double
    var detail: String
    /// False when the metric was never logged in the window. The category then counts as 0 in the score.
    var hasData: Bool = true

    var id: String { category }
    var points: Double { progress * weight }
    /// Levels still available in this category.
    var levelsAvailable: Double { (weight - points) * Double(RecoveryLevel.maxLevel) / 100 }
}

/// The REC report. Scoring is `StatLevelReport`'s: categories without data count as 0 at their full weight.
struct RecoveryLevelReport: Equatable {
    var requirements: [RecoveryRequirement]

    /// The max level needs every counted requirement at once.
    var isMaxLevel: Bool { statReport.isMaxLevel }
    /// Counted categories that miss their strict rule.
    var failing: [RecoveryRequirement] { rows(statReport.failing) }

    /// 0...100. Weighted sum of the counted categories' progress.
    var score: Double { statReport.score }

    /// 0...350. The max level needs every strict rule, not just a full score.
    var level: Int { statReport.level }

    var levelsToMax: Int { RecoveryLevel.maxLevel - level }

    /// Counted categories with the most levels left, best first.
    func topGains(_ count: Int = 3) -> [RecoveryRequirement] {
        rows(statReport.topGains(count))
    }

    /// The same categories as a REC stat report, so the target list treats REC like every other stat.
    var statReport: StatLevelReport {
        StatLevelReport(stat: .REC, requirements: requirements.map {
            StatRequirement(category: $0.category, passed: $0.passed, progress: $0.progress, weight: $0.weight, detail: $0.detail, hasData: $0.hasData)
        })
    }

    /// The REC rows behind stat rows, in the stat rows' order.
    private func rows(_ stats: [StatRequirement]) -> [RecoveryRequirement] {
        stats.compactMap { stat in requirements.first { $0.category == stat.category } }
    }
}

/// Deterministic recovery level 0...350.
/// Pure: the same days always give the same report. No network and no clock.
enum RecoveryLevel {
    static let maxLevel = 350
    static let windowDays = 30
    static let baselineDays = 90
    /// A daily metric needs 90% of the window logged (27 of 30 days), or it fails for missing data.
    static let minimumLoggedDays = 27
    static let minimumBaselineSamples = 60

    /// Level 0 floor and the max level target for one metric. Lower-is-better metrics put the floor above the target.
    struct Band: Equatable {
        var floor: Double
        var target: Double

        func progress(_ value: Double) -> Double {
            let raw = (value - floor) / (target - floor)
            return min(max(raw, 0), 1)
        }
    }

    // Floors are common "unhealthy" limits; targets are the max level rules.
    static let sleepNeedBand = Band(floor: 0, target: 0.90)          // share of nights at 100% sleep need
    static let sleepConsistencyBand = Band(floor: 50, target: 90)    // %
    static let sleepEfficiencyBand = Band(floor: 75, target: 92)     // %
    static let sleepDebtBand = Band(floor: 120, target: 15)          // minutes
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

    /// Caffeine, protein, fat, carbs, and calories were removed on 2026-11-18. The 8 targets left keep their old ratio
    /// (each × 1.25), so they add to 100. `RecoveryDay` still holds the nutrition fields; nothing scores them.
    enum Weight {
        static let sleepDuration = 18.75
        static let sleepConsistency = 10.0
        static let sleepEfficiency = 12.5
        static let sleepDebt = 10.0
        static let training = 12.5
        static let hrv = 18.75
        static let restingHr = 10.0
        static let circadian = 7.5
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

    // MARK: - Training

    /// Three equal sub-metrics per week: rest days, light days, very-high days. Averaged over complete weeks.
    private static func trainingRecovery(_ window: [RecoveryDay]) -> RecoveryRequirement {
        let strainCount = window.filter { $0.dayStrain != nil }.count
        // Fixed 7-day blocks counted back from the newest day. A leftover partial week is not scored.
        let weeks = stride(from: window.count, through: 7, by: -7).map { end in Array(window[(end - 7)..<end]) }
        guard !weeks.isEmpty, strainCount > 0 else {
            return RecoveryRequirement(category: "Training recovery", passed: false, progress: 0, weight: Weight.training,
                                       detail: "strain logged on \(strainCount)/\(window.count) days", hasData: strainCount > 0)
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
            return RecoveryRequirement(category: "HRV", passed: false, progress: 0, weight: Weight.hrv, detail: "HRV logged on \(recent.count)/\(window.count) days", hasData: false)
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
            detail: logged(values.count, of: window.count) + "30-day average \(format(average)) bpm",
            hasData: !values.isEmpty
        )
    }

    private static func circadianRhythm(_ window: [RecoveryDay]) -> RecoveryRequirement {
        let nights = window.compactMap { day -> (Double, Double)? in
            guard let bed = day.bedtimeMinutes, let wake = day.wakeMinutes else { return nil }
            return (bed, wake)
        }
        guard !nights.isEmpty else {
            return RecoveryRequirement(category: "Circadian rhythm", passed: false, progress: 0, weight: Weight.circadian, detail: "sleep times logged on 0/\(window.count) nights", hasData: false)
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
            detail: logged(values.count, of: window.count) + "\(percent(ratio)) of \(label)",
            hasData: !values.isEmpty
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
            detail: logged(values.count, of: window.count) + "30-day average \(format(average))\(unit)",
            hasData: !values.isEmpty
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

    /// Ninety days that meet every the max level requirement. Tests edit a copy.
    static func perfectDays(count: Int = 90, start: String = "2026-07-01") -> [RecoveryDay] {
        guard let first = QuestDay.date(from: start) else { return [] }
        return (0..<count).map { offset in
            let date = QuestDay.calendar.date(byAdding: .day, value: offset, to: first) ?? first
            // Weekly plan: rest, light, high, very high, high, very high, moderate.
            let plan: [(Double, Int)] = [(5, 0), (10, 1), (15, 1), (19, 1), (16, 1), (19, 1), (13, 1)]
            let (strain, workouts) = plan[offset % 7]
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
            return copy
        }
    }

    static func check() -> [String] {
        var errors: [String] = []
        let perfect = perfectDays()
        let report = evaluate(days: perfect)
        if !report.isMaxLevel {
            errors.append("perfect days should reach the max level, failing: " + report.failing.map { "\($0.category): \($0.detail)" }.joined(separator: " | "))
        }
        let categories = ["Sleep duration", "Sleep consistency", "Sleep efficiency", "Sleep debt", "Training recovery", "HRV", "Resting heart rate", "Circadian rhythm"]
        if report.requirements.map(\.category) != categories {
            errors.append("REC should have the 8 sleep, training, and heart targets, got \(report.requirements.map(\.category))")
        }
        let totalWeight = report.requirements.reduce(0) { $0 + $1.weight }
        if abs(totalWeight - 100) > 0.001 {
            errors.append("weights should add to 100, got \(totalWeight)")
        }
        if report.level != maxLevel || abs(report.score - 100) > 0.001 || report.levelsToMax != 0 {
            errors.append("perfect days should score 100 and the max level, got \(report.score) level \(report.level)")
        }

        let empty = evaluate(days: [])
        if empty.isMaxLevel || empty.level != 0 || empty.score != 0 || empty.requirements.contains(where: \.hasData) {
            errors.append("no data must be level 0 with no counted category, got level \(empty.level) score \(empty.score)")
        }

        // Only WHOOP sleep logged: everything else counts as 0, so sleep alone can never max REC.
        let sleepOnly = perfect.map { day in
            RecoveryDay(dayKey: day.dayKey, sleepNeedPct: day.sleepNeedPct, sleepConsistencyPct: day.sleepConsistencyPct,
                        sleepEfficiencyPct: day.sleepEfficiencyPct, sleepDebtMinutes: day.sleepDebtMinutes)
        }
        let sleepReport = evaluate(days: sleepOnly)
        let sleepRows: Set<String> = ["Sleep duration", "Sleep consistency", "Sleep efficiency", "Sleep debt"]
        errors += StatLevelReport.zeroCheck(sleepReport.statReport, noData: Set(sleepReport.statReport.requirements.map(\.category)).subtracting(sleepRows), "sleep alone")
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
                errors.append("line \(line): a failing \(category) must stay under the max level, got \(edited.level)")
            }
            if edited.topGains(1).first?.category != category {
                errors.append("line \(line): \(category) should be the top gain, got \(edited.topGains(1).map(\.category))")
            }
        }

        // One bad night in 30 is fine (29/30 = 97%); four bad nights drop under 90%.
        var threeBad = perfect
        for index in 85..<88 { threeBad[index].sleepNeedPct = 80 }
        if !evaluate(days: threeBad).isMaxLevel {
            errors.append("three short nights in 30 (90%) should still pass sleep duration")
        }
        failsOnly("Sleep duration") { days in for index in 84..<88 { days[index].sleepNeedPct = 80 } }
        failsOnly("Sleep consistency") { days in for index in 60..<90 { days[index].sleepConsistencyPct = 85 } }
        failsOnly("Sleep efficiency") { days in days[89].sleepEfficiencyPct = 30 }
        failsOnly("Sleep debt") { days in days[89].sleepDebtMinutes = 400 }
        // The newest week is days 83...89: 83 moderate, 84 rest, 85 light, 86 high, 87 very high, 88 high, 89 very high.
        failsOnly("Training recovery") { days in days[84].dayStrain = 12 } // no rest day
        failsOnly("Training recovery") { days in days[84].workoutCount = 1 } // a workout on the rest day
        failsOnly("Training recovery") { days in days[85].dayStrain = 15 } // no light day
        failsOnly("Training recovery") { days in
            for index in [83, 86, 88] { days[index].dayStrain = 19 } // 5 very-high days in one week
        }
        var fourVeryHigh = perfect
        for index in [86, 88] { fourVeryHigh[index].dayStrain = 19 }
        if !evaluate(days: fourVeryHigh).isMaxLevel {
            errors.append("four very-high days in a week should still pass")
        }
        failsOnly("HRV") { days in for index in 60..<90 { days[index].hrv = 70 } }
        failsOnly("Resting heart rate") { days in for index in 60..<90 { days[index].restingHr = 52 } }
        failsOnly("Circadian rhythm") { days in for index in 60..<90 where index % 2 == 0 { days[index].wakeMinutes = 540 } }

        // Missing data fails the category instead of passing it quietly.
        failsOnly("Sleep consistency") { days in for index in 60..<64 { days[index].sleepConsistencyPct = nil } }
        failsOnly("HRV") { days in for index in 0..<40 { days[index].hrv = nil } }

        // A resting heart rate under 45 fails the strict rule but keeps full progress, so the level caps one under the max.
        var lowHr = perfect
        for index in 60..<90 { lowHr[index].restingHr = 42 }
        let lowHrReport = evaluate(days: lowHr)
        if lowHrReport.isMaxLevel || lowHrReport.level != maxLevel - 1 {
            errors.append("a 42 bpm average should cap at one under the max level, got \(lowHrReport.level)")
        }

        // Progress is linear between floor and target. Sleep efficiency at 83.5% is half of the 75 → 92 band.
        var halfEfficiency = perfect
        for index in 60..<90 { halfEfficiency[index].sleepEfficiencyPct = 83.5 }
        let halfReport = evaluate(days: halfEfficiency)
        guard let efficiencyRow = halfReport.requirements.first(where: { $0.category == "Sleep efficiency" }) else {
            return errors + ["sleep efficiency row missing"]
        }
        if abs(efficiencyRow.progress - 0.5) > 0.001 || abs(halfReport.score - 93.75) > 0.001 {
            errors.append("83.5% efficiency should be 0.5 progress and score 93.75, got \(efficiencyRow.progress) \(halfReport.score)")
        }
        if halfReport.level != 328 || abs(efficiencyRow.levelsAvailable - 21.875) > 0.001 {
            errors.append("score 93.75 should be level 328 with 21.875 levels available, got \(halfReport.level) \(efficiencyRow.levelsAvailable)")
        }

        // Skipped logs scale progress down: consistency logged on 9 of 30 days keeps a third of its points.
        var sparse = perfect
        for index in 60..<81 { sparse[index].sleepConsistencyPct = nil }
        let sparseRow = evaluate(days: sparse).requirements.first { $0.category == "Sleep consistency" }
        if sparseRow?.passed != false || abs((sparseRow?.progress ?? 0) - 9.0 / 27.0) > 0.001 {
            errors.append("9 logged consistency days should give progress 9/27, got \(String(describing: sparseRow))")
        }

        // Food and caffeine no longer score: none logged, or bad values, still reach the max level.
        var noFood = perfect
        for index in noFood.indices {
            noFood[index].caffeineMg = 700
            noFood[index].proteinG = nil
            noFood[index].caloriesKcal = 5000
        }
        if !evaluate(days: noFood).isMaxLevel {
            errors.append("caffeine and nutrition should not affect REC")
        }

        // Only the newest 30 days are scored; older days feed the HRV baseline.
        var oldBad = perfect
        for index in 0..<60 { oldBad[index].sleepDebtMinutes = 500 }
        if !evaluate(days: oldBad).isMaxLevel {
            errors.append("days older than the 30-day window should not score")
        }
        return errors
    }
}
