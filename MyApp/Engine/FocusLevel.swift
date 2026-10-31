import Foundation

/// One day of DeviceActivity data for the FOC stat.
/// iOS never gives the app minute totals. `eventDidReachThreshold` only fires when usage passes a
/// scheduled threshold, so each value is the highest threshold reached that day: a lower bound.
struct FocusDay: Codable, Equatable {
    var dayKey: String
    /// Highest total screen time threshold reached (30, 60, 90, 120, 180, 240, 300, 360, 480).
    /// 0 means no threshold fired (under 30 min). `nil` means no monitor data that day.
    var screenMinutesReached: Int?
    /// Highest social media threshold reached (1, 5, 15, 30, 60, 120, 180) for the selected social apps.
    /// 0 means no threshold fired (under 1 min). `nil` means no monitor data that day.
    var socialMinutesReached: Int?
    /// True after `intervalDidEnd` for the day. Today in progress is not complete and does not count.
    var complete: Bool
}

/// Deterministic FOC (focus) level 0...350.
/// Pure: the same days always give the same report. No network and no clock.
enum FocusLevel {
    static let windowDays = 30
    /// A daily metric needs 90% of the window logged (27 of 30 days), or it fails for missing data.
    static let minimumLoggedDays = 27

    /// Thresholds the PenaltyMonitor extension schedules, in minutes.
    static let screenThresholds = [30, 60, 90, 120, 180, 240, 300, 360, 480]
    static let socialThresholds = [1, 5, 15, 30, 60, 120, 180]

    /// A day passes screen time when the 120-minute threshold never fired.
    static let screenLimitMinutes = 120
    /// Strict rule: 90% of logged days under 2 h.
    static let screenPassShare = 0.90

    // Floors are the level 0 limits; targets are the max level rules. Lower is better, so the floor is above the target.
    // The reached value is a lower bound: a day at 119 minutes reports 90, the last bucket under 2 h. So 90 is the target.
    static let screenBand = StatLevel.Band(floor: 480, target: 90)    // minutes reached per day
    static let socialBand = StatLevel.Band(floor: 180, target: 0)     // minutes reached per day

    enum Weight {
        static let screenTime = 75.0
        static let socialMedia = 25.0
    }

    /// Uses the newest 30 complete days by `dayKey`.
    static func evaluate(days: [FocusDay]) -> StatLevelReport {
        let window = Array(days.filter(\.complete).sorted { $0.dayKey < $1.dayKey }.suffix(windowDays))
        return StatLevelReport(stat: .FOC, requirements: [
            screenTime(window),
            socialMedia(window),
        ])
    }

    // MARK: - Rules

    /// Strict rule: 90% of logged days under 2 h, with at least 27 logged days.
    /// Progress: the per-day band from 480 to 90 minutes, averaged over logged days, × coverage.
    private static func screenTime(_ window: [FocusDay]) -> StatRequirement {
        let values = window.compactMap(\.screenMinutesReached)
        let passes = values.filter { $0 < screenLimitMinutes }.count
        let share = values.isEmpty ? 0 : Double(passes) / Double(values.count)
        return StatRequirement(
            category: "Daily screen time",
            passed: values.count >= minimumLoggedDays && share >= screenPassShare - 1e-9,
            progress: averageProgress(values, band: screenBand) * coverage(values.count),
            weight: Weight.screenTime,
            detail: logged(values.count, of: window.count) + "\(passes) of \(values.count) days under 2 h; avg reached \(average(values)) min",
            hasData: !values.isEmpty
        )
    }

    /// Strict rule: every logged day at 0 minutes (the 1-minute threshold never fired), with at least 27 logged days.
    /// Progress: the per-day band from 180 to 0 minutes, averaged over logged days, × coverage.
    private static func socialMedia(_ window: [FocusDay]) -> StatRequirement {
        let values = window.compactMap(\.socialMinutesReached)
        let passes = values.filter { $0 == 0 }.count
        return StatRequirement(
            category: "Social media",
            passed: values.count >= minimumLoggedDays && passes == values.count,
            progress: averageProgress(values, band: socialBand) * coverage(values.count),
            weight: Weight.socialMedia,
            detail: logged(values.count, of: window.count) + "\(passes) of \(values.count) days at 0 min; avg reached \(average(values)) min",
            hasData: !values.isEmpty
        )
    }

    // MARK: - Shared

    /// Average of the per-day band progress. No logged days gives 0.
    private static func averageProgress(_ values: [Int], band: StatLevel.Band) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0) { $0 + band.progress(Double($1)) } / Double(values.count)
    }

    /// Scales progress down when fewer than 27 days are logged, so missing days cannot raise the level.
    private static func coverage(_ loggedDays: Int) -> Double {
        min(1, Double(loggedDays) / Double(minimumLoggedDays))
    }

    private static func logged(_ count: Int, of total: Int) -> String {
        count < minimumLoggedDays ? "logged on \(count)/\(max(total, windowDays)) days; " : ""
    }

    private static func average(_ values: [Int]) -> Int {
        values.isEmpty ? 0 : Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
    }

    // MARK: - Self-check (runs in DEBUG at launch)

    /// Thirty complete days that meet every the max level requirement. Tests edit a copy.
    static func perfectDays(count: Int = 30, start: String = "2026-09-17") -> [FocusDay] {
        (0..<count).map { index in
            FocusDay(dayKey: QuestDay.key(byAddingDays: index, to: start), screenMinutesReached: 60, socialMinutesReached: 0, complete: true)
        }
    }

    /// Thirty complete days at every level 0 floor.
    static func floorDays(count: Int = 30, start: String = "2026-09-17") -> [FocusDay] {
        perfectDays(count: count, start: start).map { day in
            var day = day
            day.screenMinutesReached = 480
            day.socialMinutesReached = 180
            return day
        }
    }

    static func check() -> [String] {
        var errors: [String] = []
        let perfect = perfectDays()
        let report = evaluate(days: perfect)
        if !report.isMaxLevel || report.level != StatLevel.maxLevel || abs(report.score - 100) > 0.001 || report.stat != .FOC {
            errors.append("perfect days should score 100 and the max level, got \(report.score) level \(report.level): " + report.failing.map { "\($0.category): \($0.detail)" }.joined(separator: " | "))
        }
        if report.requirements.count != 2 {
            errors.append("FOC should have 2 requirements, got \(report.requirements.count)")
        }
        let totalWeight = report.requirements.reduce(0) { $0 + $1.weight }
        if abs(totalWeight - 100) > 0.001 {
            errors.append("weights should add to 100, got \(totalWeight)")
        }

        let empty = evaluate(days: [])
        if empty.isMaxLevel || empty.level != 0 || empty.score != 0 {
            errors.append("no data must be level 0, got level \(empty.level) score \(empty.score)")
        }

        let floorReport = evaluate(days: floorDays())
        if floorReport.level != 0 || floorReport.score > 0.001 {
            errors.append("floor days should be level 0, got level \(floorReport.level) score \(floorReport.score)")
        }

        func failsOnly(_ category: String, _ edit: (inout [FocusDay]) -> Void, line: Int = #line) {
            var days = perfect
            edit(&days)
            let edited = evaluate(days: days)
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

        // Three days at 120+ in 30 is 27/30 = 90%: still passes. Four days drop under 90%.
        var threeLong = perfect
        for index in 0..<3 { threeLong[index].screenMinutesReached = 120 }
        if !evaluate(days: threeLong).isMaxLevel {
            errors.append("three days at 120 min in 30 (90%) should still pass screen time")
        }
        failsOnly("Daily screen time") { days in for index in 0..<4 { days[index].screenMinutesReached = 180 } }
        // A day at 119 minutes reports 90 (the 120 threshold never fired), so it passes.
        var lowerBound = perfect
        for index in 0..<30 { lowerBound[index].screenMinutesReached = 90 }
        if !evaluate(days: lowerBound).isMaxLevel {
            errors.append("days that reached only 90 min should pass screen time")
        }

        // One day with 1 social minute fails social media.
        failsOnly("Social media") { $0[10].socialMinutesReached = 1 }

        // Weights: screen time failing alone costs far more levels than social failing alone.
        var badScreen = perfect
        for index in 0..<30 { badScreen[index].screenMinutesReached = 480 }
        var badSocial = perfect
        for index in 0..<30 { badSocial[index].socialMinutesReached = 180 }
        let screenLevel = evaluate(days: badScreen).level
        let socialLevel = evaluate(days: badSocial).level
        if screenLevel != 87 || socialLevel != 262 || screenLevel >= socialLevel {
            errors.append("screen time at floor should be level 87 and social at floor 262, got \(screenLevel) and \(socialLevel)")
        }

        // Today in progress is ignored: a bad incomplete day does not enter the window or push out an old day.
        var withToday = perfect
        withToday.append(FocusDay(dayKey: "2026-10-17", screenMinutesReached: 480, socialMinutesReached: 180, complete: false))
        if !evaluate(days: withToday).isMaxLevel {
            errors.append("an incomplete day should not count")
        }
        // Only the newest 30 complete days count: older bad days fall out of the window.
        let olderBad = floorDays(count: 10, start: "2026-09-01") + perfect
        if !evaluate(days: olderBad.shuffled()).isMaxLevel {
            errors.append("days older than the newest 30 should not count")
        }

        // Missing days never pass: 20 logged days cannot pass, and progress scales by 20/27.
        var twenty = perfect
        for index in 0..<10 {
            twenty[index].screenMinutesReached = nil
            twenty[index].socialMinutesReached = nil
        }
        let twentyReport = evaluate(days: twenty)
        if twentyReport.failing.map(\.category) != ["Daily screen time", "Social media"] {
            errors.append("20 logged days should fail both rules, got \(twentyReport.failing.map(\.category))")
        }
        let expected = 20.0 / 27.0
        for row in twentyReport.requirements where abs(row.progress - expected) > 0.0001 {
            errors.append("\(row.category) with 20 logged days should give progress \(expected), got \(row.progress)")
        }
        if twentyReport.requirements.first?.detail.hasPrefix("logged on 20/30 days; ") != true {
            errors.append("20 logged days detail wrong: \(String(describing: twentyReport.requirements.first?.detail))")
        }
        // Missing social data alone fails only social media.
        failsOnly("Social media") { days in for index in 0..<4 { days[index].socialMinutesReached = nil } }
        // Social never logged is no data: it drops out and screen time scores alone at weight 100.
        var noSocial = perfect
        for index in noSocial.indices { noSocial[index].socialMinutesReached = nil }
        let noSocialReport = evaluate(days: noSocial)
        if !noSocialReport.isMaxLevel || noSocialReport.counted.map(\.category) != ["Daily screen time"] || noSocialReport.counted.first?.weight != 100
            || noSocialReport.withoutData.map(\.category) != ["Social media"] {
            errors.append("social never logged should drop out and leave screen time at weight 100, got \(noSocialReport.counted.map { "\($0.category) \($0.weight)" }) level \(noSocialReport.level)")
        }

        // Progress is linear per day: 180 min reached is (480 - 180) / (480 - 90) = 300/390.
        var mid = perfect
        for index in 0..<30 { mid[index].screenMinutesReached = 180 }
        let midRow = evaluate(days: mid).requirements.first { $0.category == "Daily screen time" }
        if abs((midRow?.progress ?? 0) - 300.0 / 390.0) > 0.0001 || midRow?.detail != "0 of 30 days under 2 h; avg reached 180 min" {
            errors.append("180 min every day should give progress \(300.0 / 390.0), got \(String(describing: midRow))")
        }
        return errors
    }
}
