import Foundation

/// Targets for emergency quests. Saved in the App Group so the Screen Time monitor can read them.
/// Times are minutes after local midnight.
nonisolated struct EmergencySettings: Codable, Equatable {
    /// No emergency quest starts before this time.
    var earliestStart = 18 * 60

    var stepsEnabled = false
    var stepCheckTime = 18 * 60
    var minimumSteps = 1_000
    /// Steps to walk after the quest starts. About 15 minutes at a normal pace.
    var walkSteps = 1_500
    var walkLimitMinutes = 60

    var stretchEnabled = false
    var stretchCheckTime = 21 * 60
    /// Minutes to log the day's stretching before the quest fails.
    var stretchLimitMinutes = 60

    static let standard = EmergencySettings()

    init() {}

    /// Missing keys keep their defaults, so a later field does not reset saved targets.
    /// Keys of the removed bedtime lockdown in old saves are ignored.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EmergencySettings.standard
        earliestStart = try c.decodeIfPresent(Int.self, forKey: .earliestStart) ?? d.earliestStart
        stepsEnabled = try c.decodeIfPresent(Bool.self, forKey: .stepsEnabled) ?? d.stepsEnabled
        stepCheckTime = try c.decodeIfPresent(Int.self, forKey: .stepCheckTime) ?? d.stepCheckTime
        minimumSteps = try c.decodeIfPresent(Int.self, forKey: .minimumSteps) ?? d.minimumSteps
        walkSteps = try c.decodeIfPresent(Int.self, forKey: .walkSteps) ?? d.walkSteps
        walkLimitMinutes = try c.decodeIfPresent(Int.self, forKey: .walkLimitMinutes) ?? d.walkLimitMinutes
        stretchEnabled = try c.decodeIfPresent(Bool.self, forKey: .stretchEnabled) ?? d.stretchEnabled
        stretchCheckTime = try c.decodeIfPresent(Int.self, forKey: .stretchCheckTime) ?? d.stretchCheckTime
        stretchLimitMinutes = try c.decodeIfPresent(Int.self, forKey: .stretchLimitMinutes) ?? d.stretchLimitMinutes
    }
}

nonisolated enum EmergencyKind: String, Codable, Equatable {
    /// Too few steps by the check time. Distractors lock until the walk is done or the limit runs out.
    case lowSteps = "low_steps"
    /// The daily Stretching quest is still open at the check time. Distractors lock until its minutes are logged.
    case skippedStretch = "skipped_stretch"
}

nonisolated enum EmergencyStatus: String, Codable, Equatable {
    case active, completed, failed
}

nonisolated struct EmergencyQuest: Codable, Equatable, Identifiable {
    var kind: EmergencyKind
    var dayKey: String
    var startedAt: Date
    var deadline: Date
    var status: EmergencyStatus = .active
    /// Steps walked since `startedAt` (low steps only).
    var progressSteps: Int = 0
    var targetSteps: Int = 0
    /// Started from the settings sheet. A test can be ended early and never opens a penalty.
    var isTest = false

    var id: String { "\(kind.rawValue)-\(startedAt.timeIntervalSince1970)" }

    var title: String {
        switch kind {
        case .lowSteps: "Movement"
        case .skippedStretch: "Restore Flexibility"
        }
    }
}

enum EmergencyRules {
    static func minuteOfDay(_ date: Date) -> Int {
        let parts = QuestDay.calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// The step check never runs before the earliest start.
    static func stepCheckMinute(_ settings: EmergencySettings) -> Int {
        max(settings.stepCheckTime, settings.earliestStart)
    }

    /// One low-steps quest per day, after the check time, and never while another emergency runs.
    static func shouldTriggerLowSteps(now: Date, stepsToday: Int?, settings: EmergencySettings,
                                      lastTriggeredDayKey: String?, active: EmergencyQuest?) -> Bool {
        guard settings.stepsEnabled, active == nil, let stepsToday else { return false }
        guard lastTriggeredDayKey != QuestDay.key(for: now) else { return false }
        let minute = minuteOfDay(now)
        guard minute >= stepCheckMinute(settings) else { return false }
        return stepsToday < settings.minimumSteps
    }

    static func lowStepsQuest(now: Date, settings: EmergencySettings, isTest: Bool = false) -> EmergencyQuest {
        EmergencyQuest(
            kind: .lowSteps,
            dayKey: QuestDay.key(for: now),
            startedAt: now,
            deadline: now.addingTimeInterval(Double(max(1, settings.walkLimitMinutes)) * 60),
            targetSteps: max(1, settings.walkSteps),
            isTest: isTest
        )
    }

    static func stretchCheckMinute(_ settings: EmergencySettings) -> Int {
        max(settings.stretchCheckTime, settings.earliestStart)
    }

    /// One stretch quest per day, after the check time, while the daily Stretching quest is still open.
    static func shouldTriggerStretch(now: Date, stretchDone: Bool?, settings: EmergencySettings,
                                     lastTriggeredDayKey: String?, active: EmergencyQuest?) -> Bool {
        guard settings.stretchEnabled, active == nil, stretchDone == false else { return false }
        guard lastTriggeredDayKey != QuestDay.key(for: now) else { return false }
        let minute = minuteOfDay(now)
        guard minute >= stretchCheckMinute(settings) else { return false }
        return true
    }

    static func stretchQuest(now: Date, settings: EmergencySettings, isTest: Bool = false) -> EmergencyQuest {
        EmergencyQuest(
            kind: .skippedStretch,
            dayKey: QuestDay.key(for: now),
            startedAt: now,
            deadline: now.addingTimeInterval(Double(max(1, settings.stretchLimitMinutes)) * 60),
            isTest: isTest
        )
    }

    /// A walk completes at its step target and fails at its deadline.
    /// A stretch completes when the daily Stretching quest completes from tracked minutes, and fails at its deadline.
    static func resolve(_ quest: EmergencyQuest, now: Date, stepsSinceStart: Int?, stretchDone: Bool = false) -> EmergencyQuest {
        guard quest.status == .active else { return quest }
        var next = quest
        switch quest.kind {
        case .lowSteps:
            if let steps = stepsSinceStart { next.progressSteps = max(next.progressSteps, steps) }
            if next.progressSteps >= quest.targetSteps {
                next.status = .completed
            } else if now >= quest.deadline {
                next.status = .failed
            }
        case .skippedStretch:
            if stretchDone {
                next.status = .completed
            } else if now >= quest.deadline {
                next.status = .failed
            }
        }
        return next
    }

    /// Only a real, failed quest opens a penalty.
    static func opensPenalty(_ quest: EmergencyQuest) -> Bool {
        quest.status == .failed && !quest.isTest
    }

    // MARK: - Self-check (runs in DEBUG at launch)

    static func check() -> [String] {
        var errors: [String] = []
        guard let day = QuestDay.date(from: "2026-10-05") else { return ["emergency check date failed"] }
        func at(_ hour: Int, _ minute: Int) -> Date {
            QuestDay.calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        let morning = at(9, 0), afternoon = at(14, 30), late = at(18, 30)
        var settings = EmergencySettings()
        settings.stepsEnabled = true


        if shouldTriggerLowSteps(now: morning, stepsToday: 200, settings: settings, lastTriggeredDayKey: nil, active: nil) {
            errors.append("low steps must not trigger before the check time")
        }
        var twoPM = settings
        twoPM.stepCheckTime = 14 * 60
        if shouldTriggerLowSteps(now: afternoon, stepsToday: 200, settings: twoPM, lastTriggeredDayKey: nil, active: nil) {
            errors.append("a 2 PM step check must wait for the 6 PM earliest start")
        }
        if !shouldTriggerLowSteps(now: late, stepsToday: 999, settings: twoPM, lastTriggeredDayKey: nil, active: nil) {
            errors.append("999 steps at 18:30 should trigger a walk")
        }
        if shouldTriggerLowSteps(now: late, stepsToday: 1_000, settings: settings, lastTriggeredDayKey: nil, active: nil) {
            errors.append("exactly 1,000 steps meets the minimum")
        }
        if shouldTriggerLowSteps(now: late, stepsToday: 100, settings: settings, lastTriggeredDayKey: QuestDay.key(for: late), active: nil) {
            errors.append("low steps should trigger at most once per day")
        }
        if shouldTriggerLowSteps(now: late, stepsToday: nil, settings: settings, lastTriggeredDayKey: nil, active: nil) {
            errors.append("no Health data must not trigger a walk")
        }
        let running = stretchQuest(now: late, settings: settings)
        if shouldTriggerLowSteps(now: late, stepsToday: 100, settings: settings, lastTriggeredDayKey: nil, active: running) {
            errors.append("low steps must wait while another emergency is active")
        }
        var off = settings
        off.stepsEnabled = false
        if shouldTriggerLowSteps(now: late, stepsToday: 100, settings: off, lastTriggeredDayKey: nil, active: nil) {
            errors.append("a disabled step check must not trigger")
        }

        let walk = lowStepsQuest(now: late, settings: settings)
        if walk.deadline.timeIntervalSince(late) != 3600 || walk.targetSteps != 1_500 {
            errors.append("a walk should last 60 minutes with a 1,500-step target, got \(walk)")
        }
        let halfway = resolve(walk, now: late.addingTimeInterval(600), stepsSinceStart: 700)
        if halfway.status != .active || halfway.progressSteps != 700 {
            errors.append("700 of 1,500 steps should stay active, got \(halfway)")
        }
        if resolve(halfway, now: late.addingTimeInterval(700), stepsSinceStart: nil).progressSteps != 700 {
            errors.append("a missing step reading must keep the last progress")
        }
        if resolve(walk, now: late.addingTimeInterval(900), stepsSinceStart: 1_500).status != .completed {
            errors.append("1,500 steps should complete the walk")
        }
        let missed = resolve(walk, now: late.addingTimeInterval(3600), stepsSinceStart: 1_200)
        if missed.status != .failed || !opensPenalty(missed) {
            errors.append("a walk short at the deadline should fail and open a penalty, got \(missed)")
        }
        var test = lowStepsQuest(now: late, settings: settings, isTest: true)
        test = resolve(test, now: late.addingTimeInterval(3600), stepsSinceStart: 0)
        if opensPenalty(test) {
            errors.append("a test walk must never open a penalty")
        }

        // Restore Flexibility: 9 PM check, one hour to log the day's stretching.
        let ninePM = at(21, 5)
        var stretch = settings
        stretch.stretchEnabled = true
        if shouldTriggerStretch(now: late, stretchDone: false, settings: stretch, lastTriggeredDayKey: nil, active: nil) {
            errors.append("stretch must not trigger before 9 PM")
        }
        if !shouldTriggerStretch(now: ninePM, stretchDone: false, settings: stretch, lastTriggeredDayKey: nil, active: nil) {
            errors.append("an open Stretching quest at 21:05 should trigger")
        }
        if shouldTriggerStretch(now: ninePM, stretchDone: true, settings: stretch, lastTriggeredDayKey: nil, active: nil)
            || shouldTriggerStretch(now: ninePM, stretchDone: nil, settings: stretch, lastTriggeredDayKey: nil, active: nil) {
            errors.append("a done or missing Stretching quest must not trigger")
        }
        if shouldTriggerStretch(now: ninePM, stretchDone: false, settings: stretch, lastTriggeredDayKey: QuestDay.key(for: ninePM), active: nil) {
            errors.append("stretch should trigger at most once per day")
        }
        let stiff = stretchQuest(now: ninePM, settings: stretch)
        if stiff.deadline.timeIntervalSince(ninePM) != 3600 {
            errors.append("a stretch quest should allow one hour, got \(stiff)")
        }
        if resolve(stiff, now: ninePM.addingTimeInterval(3599), stepsSinceStart: nil).status != .active
            || !opensPenalty(resolve(stiff, now: ninePM.addingTimeInterval(3600), stepsSinceStart: nil)) {
            errors.append("a stretch not logged in one hour should fail with a penalty")
        }
        if resolve(stiff, now: ninePM.addingTimeInterval(600), stepsSinceStart: nil, stretchDone: true).status != .completed {
            errors.append("a completed Stretching quest should complete the emergency")
        }

        // An old save still holds the removed bedtime keys. They are ignored.
        let partial = Data(#"{"bedtimeEnabled":true,"lockdownMinutes":30,"minimumSteps":2000}"#.utf8)
        if let decoded = try? JSONDecoder().decode(EmergencySettings.self, from: partial) {
            if decoded.minimumSteps != 2_000 || decoded.walkSteps != 1_500 || decoded.stepsEnabled {
                errors.append("partial settings should keep defaults for missing keys, got \(decoded)")
            }
        } else {
            errors.append("partial settings JSON failed to decode")
        }
        return errors
    }
}
