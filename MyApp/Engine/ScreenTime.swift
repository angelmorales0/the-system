import Foundation

#if os(iOS)
import DeviceActivity
import FamilyControls
import UserNotifications
#endif

/// The daily screen time quest: phone minutes from Screen Time, work minutes (the Mac) from the backend.
/// Only the combined total can fail it. A sub-cap over its limit only turns its line red.
/// Phone minutes that overlap Mac minutes count once. Until the Macs report their minutes, the full
/// possible overlap is taken out, so the total is never inflated (see `ScreenTimeDay.sharedMinutes`).
/// At 500 minutes the row turns yellow. Past the 30-minute grace (over 530) the row fails and turns red.
/// A failed row opens no penalty (removed on 2026-11-18): it only shows the miss.
enum ScreenTime {
    static let questId = "daily_screen_time"
    static let title = "Screen Time"
    static let totalCapMinutes = 500
    /// Minutes over the total cap before the quest fails.
    static let graceMinutes = 30
    static var failAfterMinutes: Int { totalCapMinutes + graceMinutes }
    static let workCapMinutes = 420
    static let phoneCapMinutes = 90

    static func quest(mode: QuestMode, now: Date) -> Quest {
        Quest(
            id: questId,
            title: title,
            kind: .daily,
            stat: .FOC,
            verification: VerificationSpec(method: .screenTimeLimit, params: ["maxMinutes": .number(Double(totalCapMinutes))]),
            deadline: QuestDay.endOfDay(now),
            difficulty: .normal,
            mode: mode,
            progress: QuestProgress(current: 0, target: Double(totalCapMinutes), unit: "min"),
            status: .pending,
            assignedAt: now
        )
    }

    /// Adds the row once, after the last required quest, so Stretching still follows it.
    static func ensure(in bundle: QuestBundle, now: Date) -> QuestBundle {
        guard !bundle.quests.isEmpty || bundle.mode == .fullRecovery, !bundle.quests.contains(where: { $0.id == questId }) else { return bundle }
        var copy = bundle
        let insertAt = copy.quests.lastIndex(where: { $0.kind != .optional }).map { $0 + 1 } ?? copy.quests.count
        copy.quests.insert(quest(mode: bundle.mode, now: now), at: insertAt)
        return copy
    }

    /// `4h 40m`, `32m`, `7h`.
    static func clock(_ minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest)m" }
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }
}

/// One quest day of screen time. A source with no reading counts as 0 and says so.
struct ScreenTimeDay: Codable, Equatable {
    var dayKey: String
    var phoneMinutes = 0
    var workMinutes = 0
    var phoneMeasured = false
    /// True once the phone or a Mac reported minutes for the day.
    var hasReading: Bool { phoneMeasured || workMeasured }
    var workMeasured = false
    /// Phone minutes that surely happened while a Mac was also counting (see `ScreenOverlap`). Counted once.
    /// Nil until the Macs' minute bitmap arrives. Optional, so days saved before it existed still load.
    var overlapMinutes: Int?

    /// True once the Macs' minute bitmap gave a real overlap count.
    var overlapMeasured: Bool { overlapMinutes != nil }
    /// Minutes counted once. With no measurement, every phone minute may have been a Mac minute too,
    /// so the full possible overlap is taken out: the total is never inflated by double counting.
    var sharedMinutes: Int {
        guard let overlapMinutes else { return min(phoneMinutes, workMinutes) }
        return min(overlapMinutes, phoneMinutes, workMinutes)
    }
    var totalMinutes: Int { phoneMinutes + workMinutes - sharedMinutes }
    /// Red line, no failure.
    var phoneOver: Bool { phoneMinutes > ScreenTime.phoneCapMinutes }
    /// The work cap of the day: 7 h, or 0 on the weekly day off.
    var workCap: Int { DayOff.isDayOff(dayKey) ? 0 : ScreenTime.workCapMinutes }
    var workOver: Bool { workMinutes > workCap }
    /// The day off: Mac work past the small grace fails the quest.
    var workOnDayOff: Bool { DayOff.isDayOff(dayKey) && workMinutes > DayOff.graceMinutes }
    /// The quest fails: the total over the cap and its grace, or work on the day off.
    var fails: Bool { overTotal || workOnDayOff }
    /// Yellow row: the total reached 8 h 20 m but is still inside the grace.
    var atCap: Bool { totalMinutes >= ScreenTime.totalCapMinutes && !overTotal }
    /// The only failure: the combined total more than 30 minutes over 8 h 20 m.
    var overTotal: Bool { totalMinutes > ScreenTime.failAfterMinutes }
}

/// Notices at 50, 75, 90, 95, and 100 percent of the 500-minute total cap. One notice per step per quest day.
/// The app sends them when it reads new minutes. The Screen Time monitor sends them too, from the phone count and
/// the Mac minutes the app saved last, so a notice still comes while the app is closed. Both write the same sent list.
/// The monitor repeats these strings and the message text (`ScreenAlertMonitor`); change them together.
enum ScreenTimeAlerts {
    static let percents = [50, 75, 90, 95, 100]
    /// Quest day → percents already sent.
    static let sentKey = "screenTimeAlertsSent"
    /// Quest day → ["work": Mac minutes, "overlap": measured overlap]. The monitor adds its phone count to these.
    static let baseKey = "screenTimeAlertBase"

    static func minutes(for percent: Int) -> Int { ScreenTime.totalCapMinutes * percent / 100 }

    /// The highest step that `totalMinutes` reached and that was not sent. Lower steps it skipped are not sent.
    static func due(totalMinutes: Int, sent: Set<Int>) -> Int? {
        percents.filter { totalMinutes >= minutes(for: $0) }.max().flatMap { sent.contains($0) ? nil : $0 }
    }

    static func message(percent: Int, totalMinutes: Int) -> (title: String, body: String) {
        let cap = ScreenTime.totalCapMinutes
        if percent >= 100 {
            return ("Screen Time: 100%", "You reached \(ScreenTime.clock(cap)) today. The quest fails past \(ScreenTime.clock(ScreenTime.failAfterMinutes)).")
        }
        return ("Screen Time: \(percent)%", "\(ScreenTime.clock(totalMinutes)) of \(ScreenTime.clock(cap)) used today. \(ScreenTime.clock(max(cap - totalMinutes, 0))) left.")
    }

    /// Saves the Mac minutes for the monitor, then sends the step that is due, if one is.
    static func update(day: ScreenTimeDay, defaults: UserDefaults = PenaltyGroup.defaults) {
        var base = defaults.dictionary(forKey: baseKey) as? [String: [String: Int]] ?? [:]
        var row = ["work": day.workMinutes]
        if let overlap = day.overlapMinutes { row["overlap"] = overlap }
        base[day.dayKey] = row
        for old in base.keys.sorted().dropLast(3) { base.removeValue(forKey: old) }
        defaults.set(base, forKey: baseKey)

        var sentDays = defaults.dictionary(forKey: sentKey) as? [String: [Int]] ?? [:]
        let sent = Set(sentDays[day.dayKey] ?? [])
        guard let percent = due(totalMinutes: day.totalMinutes, sent: sent) else { return }
        sentDays[day.dayKey] = Array(sent.union(percents.filter { $0 <= percent })).sorted()
        for old in sentDays.keys.sorted().dropLast(3) { sentDays.removeValue(forKey: old) }
        defaults.set(sentDays, forKey: sentKey)
        #if os(iOS)
        let text = message(percent: percent, totalMinutes: day.totalMinutes)
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.sound = .default
        // The same id as the monitor's notice, so a step that both send shows once.
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "screen-time-\(day.dayKey)-\(percent)", content: content, trigger: nil))
        #endif
    }
}

/// App Group storage shared with the Screen Time monitor. The monitor repeats these strings; change them together.
enum PhoneScreenGroup {
    static let selectionKey = "screenTimeSelection"
    /// Calendar day → threshold minutes → when the monitor saw it, as seconds since 1970. Days run midnight to midnight, like Apple's Screen Time.
    /// The newest days stay, so the midnight check still finds the day that just ended.
    static let daysKey = "screenTimePhoneDays"
    static let activity = "screenTimeDay"
    /// Event names are this prefix plus the minutes they mark: `phone_95`.
    static let eventPrefix = "phone_"
    /// Why iOS refused to start the daily count. Nil after a good start.
    static let startErrorKey = "screenTimeStartError"
    /// The one-day count that takes over after a false burst used up the day's thresholds.
    static let rearmActivity = "screenTimeRearm"
    /// `["day": calendar day, "count": restarts that day]`.
    static let rearmKey = "screenTimeRearmDay"

    /// Thresholds the monitor reports: every minute, past the failure point.
    /// Phone minutes can be the whole day on a day with no Mac work.
    static let thresholds = Array(1...(ScreenTime.failAfterMinutes + 10))

    /// Phone minutes the monitor wrote for `dayKey`, without false bursts. Nil when it has none for that day.
    static func minutes(for dayKey: String, defaults: UserDefaults = PenaltyGroup.defaults) -> Int? {
        let raw = rawTimes(for: dayKey, defaults: defaults)
        return raw.isEmpty ? nil : PhoneBurst.trusted(raw).keys.max() ?? 0
    }

    /// When each trusted phone threshold was reached on `dayKey`. Empty when the monitor has none for that day.
    static func times(for dayKey: String, defaults: UserDefaults = PenaltyGroup.defaults) -> [Int: Date] {
        PhoneBurst.trusted(rawTimes(for: dayKey, defaults: defaults))
    }

    /// Every threshold the monitor wrote for `dayKey`, false bursts included.
    static func rawTimes(for dayKey: String, defaults: UserDefaults = PenaltyGroup.defaults) -> [Int: Date] {
        guard let days = defaults.dictionary(forKey: daysKey) as? [String: [String: Double]], let raw = days[dayKey] else { return [:] }
        var times: [Int: Date] = [:]
        for (minutes, seconds) in raw {
            if let minutes = Int(minutes) { times[minutes] = Date(timeIntervalSince1970: seconds) }
        }
        return times
    }

    /// Replaces the stored thresholds of `dayKey`. A re-armed step could not write over a false one otherwise.
    static func keep(_ times: [Int: Date], for dayKey: String, defaults: UserDefaults = PenaltyGroup.defaults) {
        var days = defaults.dictionary(forKey: daysKey) as? [String: [String: Double]] ?? [:]
        days[dayKey] = Dictionary(uniqueKeysWithValues: times.map { (String($0.key), $0.value.timeIntervalSince1970) })
        defaults.set(days, forKey: daysKey)
    }

    /// The monitor's day: midnight to midnight, the same span as the quest day.
    static func calendarDayKey(_ date: Date) -> String {
        let parts = Calendar.autoupdatingCurrent.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    #if os(iOS)
    static func load() -> FamilyActivitySelection {
        guard let data = PenaltyGroup.defaults.data(forKey: selectionKey),
              let selection = try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: data) else {
            return FamilyActivitySelection()
        }
        return selection
    }

    static func save(_ selection: FamilyActivitySelection) {
        let empty = selection.applicationTokens.isEmpty && selection.categoryTokens.isEmpty && selection.webDomainTokens.isEmpty
        guard !empty, let data = try? PropertyListEncoder().encode(selection) else {
            PenaltyGroup.defaults.removeObject(forKey: selectionKey)
            return
        }
        PenaltyGroup.defaults.set(data, forKey: selectionKey)
    }
    #endif
}

/// iOS can fire hundreds of phone thresholds at once with no real use behind them (iOS 26.2 onward; on 2026-11-05,
/// 484 steps came in 3.5 seconds and took the count from 56 to 540). Real steps arrive with the use.
/// Steps that arrive together form a group, and a group counts only if its growth fits the time since the last trusted step.
enum PhoneBurst {
    /// Steps closer than this are one group. False bursts are under 1 second apart, real steps 25 seconds or more.
    static let groupSeconds: TimeInterval = 10
    /// Extra growth a group may have, for a step that came late and the steps that catch up after it.
    static let slackMinutes = 5
    /// The most one group can add, however long the phone was quiet. Also covers the first group of a day.
    static let maxGrowth = 30

    static func trusted(_ times: [Int: Date]) -> [Int: Date] {
        var kept: [Int: Date] = [:]
        var top = 0
        var lastTrusted: Date?
        var group: [(minutes: Int, time: Date)] = []

        func closeGroup() {
            guard let highest = group.map(\.minutes).max(), let newest = group.last?.time, let oldest = group.first?.time else { return }
            let gap = lastTrusted.map { Int((oldest.timeIntervalSince($0) / 60).rounded(.up)) } ?? maxGrowth
            if highest - top <= min(gap + slackMinutes, maxGrowth) {
                for step in group { kept[step.minutes] = step.time }
                top = max(top, highest)
                lastTrusted = newest
            }
            group = []
        }

        for (minutes, time) in times.sorted(by: { ($0.value, $0.key) < ($1.value, $1.key) }) {
            if let previous = group.last, time.timeIntervalSince(previous.time) >= groupSeconds { closeGroup() }
            group.append((minutes, time))
        }
        closeGroup()
        return kept
    }
}

/// Finds phone minutes that happened while a Mac was counting, so the same minute is not counted twice.
/// iOS only says when phone use passed each threshold, not which minutes it used. Between two thresholds
/// the phone used `p` minutes somewhere in a window of `w` minutes, and the Macs were active `m` of them.
/// At least `p + m - w` of those minutes were shared, so only that much is removed: never more than is sure.
enum ScreenOverlap {
    /// Extra minute on each window for a late threshold report, so the estimate stays on the safe side.
    static let slackMinutes = 1
    /// Windows are this many phone minutes. In a 1-minute window the slack would remove the whole overlap.
    static let windowMinutes = 5

    static func minutes(phoneTimes: [Int: Date], macActive: Data, dayStart: Date) -> Int {
        let slots = macActive.count * 8
        func active(_ slot: Int) -> Bool { macActive[slot >> 3] & (1 << UInt8(slot & 7)) != 0 }
        var shared = 0
        var lastMinutes = 0
        // The phone counts from midnight, the quest day and the Macs' bitmap start. Phone minutes of a
        // step can be anywhere from midnight on, so the first window starts there.
        var windowStart = -QuestDay.startHour * 60
        let steps = phoneTimes.filter { $0.key % windowMinutes == 0 }.sorted { $0.key < $1.key }
        // iOS can report many steps at once. A batch is one window, or the same Mac minute counts once per step.
        let windows = steps.indices.filter { index in
            index == steps.count - 1 || Int(steps[index].value.timeIntervalSince(dayStart) / 60) != Int(steps[index + 1].value.timeIntervalSince(dayStart) / 60)
        }.map { steps[$0] }
        for (minutes, time) in windows {
            let offset = time.timeIntervalSince(dayStart) / 60
            let windowEnd = min(slots, max(windowStart, Int(offset.rounded(.up))))
            let phone = minutes - lastMinutes
            let mac = windowEnd > 0 ? (max(0, windowStart)..<windowEnd).filter(active).count : 0
            let window = windowEnd - windowStart + slackMinutes
            shared += max(0, min(phone, mac, phone + mac - window))
            lastMinutes = minutes
            windowStart = min(windowEnd, max(windowStart, Int(offset.rounded(.down))))
        }
        return shared
    }
}

/// Starts the daily phone count: one schedule from midnight to midnight, with a threshold event every minute.
/// A quest day takes the count of its calendar date, so phone use after midnight belongs to the next quest day, as in Apple's Screen Time.
/// Screen Time counts only the apps the player chose, so the picker should hold All Apps & Categories.
enum ScreenTimeEnforcement {
    /// A running count is left alone at launch. Only a new selection, step list, or schedule restarts it.
    static func syncMonitoring(restart: Bool = false) {
        #if os(iOS)
        let center = DeviceActivityCenter()
        let name = DeviceActivityName(PhoneScreenGroup.activity)
        if !restart, center.activities.contains(name), center.events(for: name).count == PhoneScreenGroup.thresholds.count,
           center.schedule(for: name)?.intervalStart.hour == 0 { return }
        center.stopMonitoring([name, DeviceActivityName(PhoneScreenGroup.rearmActivity)])
        let selection = PhoneScreenGroup.load()
        guard !(selection.applicationTokens.isEmpty && selection.categoryTokens.isEmpty && selection.webDomainTokens.isEmpty) else { return }
        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59),
            repeats: true
        )
        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        for minutes in PhoneScreenGroup.thresholds {
            events[DeviceActivityEvent.Name(PhoneScreenGroup.eventPrefix + String(minutes))] = DeviceActivityEvent(
                applications: selection.applicationTokens,
                categories: selection.categoryTokens,
                webDomains: selection.webDomainTokens,
                threshold: DateComponents(minute: minutes)
            )
        }
        do {
            try center.startMonitoring(name, during: schedule, events: events)
            PenaltyGroup.defaults.removeObject(forKey: PhoneScreenGroup.startErrorKey)
        } catch {
            PenaltyGroup.defaults.set(String(describing: error), forKey: PhoneScreenGroup.startErrorKey)
        }
        #endif
    }

    /// Restarts per calendar day. A burst can come back right after a restart, so the count then holds.
    static let maxRearms = 3
    /// The burst must be over first, so the monitor does not write its last steps back.
    static let rearmQuietSeconds: TimeInterval = 120
    /// iOS refuses a schedule shorter than 15 minutes.
    static let minRearmMinutes = 15

    /// A false burst uses up every threshold, so iOS sends nothing more that day. This drops the false steps and
    /// counts on from the trusted minutes. It runs as its own one-day schedule that starts now, so it holds no earlier use.
    static func rearmAfterBurst(now: Date) {
        #if os(iOS)
        let defaults = PenaltyGroup.defaults
        let dayKey = PhoneScreenGroup.calendarDayKey(now)
        let raw = PhoneScreenGroup.rawTimes(for: dayKey)
        let kept = PhoneBurst.trusted(raw)
        guard kept.count < raw.count, let newest = raw.values.max(), now.timeIntervalSince(newest) >= rearmQuietSeconds else { return }
        let record = defaults.dictionary(forKey: PhoneScreenGroup.rearmKey)
        let used = record?["day"] as? String == dayKey ? record?["count"] as? Int ?? 0 : 0
        let clock = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: now)
        let hour = clock.hour ?? 0, minute = clock.minute ?? 0
        guard used < maxRearms, hour * 60 + minute + minRearmMinutes <= 23 * 60 + 59 else { return }
        let attempt: [String: Any] = ["day": dayKey, "count": used + 1]
        defaults.set(attempt, forKey: PhoneScreenGroup.rearmKey)

        let selection = PhoneScreenGroup.load()
        guard !(selection.applicationTokens.isEmpty && selection.categoryTokens.isEmpty && selection.webDomainTokens.isEmpty) else { return }
        let base = kept.keys.max() ?? 0
        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        for step in PhoneScreenGroup.thresholds where step > base {
            events[DeviceActivityEvent.Name(PhoneScreenGroup.eventPrefix + String(step))] = DeviceActivityEvent(
                applications: selection.applicationTokens,
                categories: selection.categoryTokens,
                webDomains: selection.webDomainTokens,
                threshold: DateComponents(minute: step - base)
            )
        }
        let center = DeviceActivityCenter()
        let name = DeviceActivityName(PhoneScreenGroup.rearmActivity)
        center.stopMonitoring([name])
        do {
            try center.startMonitoring(
                name,
                during: DeviceActivitySchedule(
                    intervalStart: DateComponents(hour: hour, minute: minute),
                    intervalEnd: DateComponents(hour: 23, minute: 59),
                    repeats: false
                ),
                events: events
            )
            PhoneScreenGroup.keep(kept, for: dayKey)
            defaults.removeObject(forKey: PhoneScreenGroup.startErrorKey)
        } catch {
            defaults.set(String(describing: error), forKey: PhoneScreenGroup.startErrorKey)
        }
        #endif
    }
}

extension GameSnapshot {
    /// A false burst may already be saved. Lowers the phone count to the trusted one and lifts a failure it alone caused.
    /// Only this path may lower a count: `applyScreenTime` still keeps the larger reading.
    mutating func correctPhoneScreenTime(to minutes: Int?) {
        guard let minutes, var day = screenTime, day.dayKey == bundle.dayKey, day.phoneMinutes > minutes else { return }
        day.phoneMinutes = minutes
        screenTime = day
        guard let index = bundle.quests.firstIndex(where: { $0.id == ScreenTime.questId }) else { return }
        bundle.quests[index].progress.current = Double(day.totalMinutes)
        if bundle.quests[index].status == .failed && !day.fails {
            bundle.quests[index].status = .pending
        }
    }

    /// Takes the newest readings for today and moves the Screen Time row. Past the grace, the row fails and stays failed.
    mutating func applyScreenTime(phoneMinutes: Int?, workMinutes: Int?, overlapMinutes: Int? = nil) {
        var day = screenTime?.dayKey == bundle.dayKey ? screenTime ?? ScreenTimeDay(dayKey: bundle.dayKey) : ScreenTimeDay(dayKey: bundle.dayKey)
        // Readings only grow during a day; a stale or missing one never lowers the count.
        if let phoneMinutes {
            day.phoneMinutes = max(day.phoneMinutes, phoneMinutes)
            day.phoneMeasured = true
        }
        if let workMinutes {
            day.workMinutes = max(day.workMinutes, workMinutes)
            day.workMeasured = true
        }
        if let overlapMinutes {
            day.overlapMinutes = overlapMinutes
        }
        screenTime = day
        guard let index = bundle.quests.firstIndex(where: { $0.id == ScreenTime.questId }) else { return }
        var quest = bundle.quests[index]
        quest.progress.current = Double(day.totalMinutes)
        if day.fails && quest.status == .pending {
            quest.status = .failed
        }
        bundle.quests[index] = quest
    }

    /// Today's readings, or an empty day when nothing has come in yet.
    var screenTimeToday: ScreenTimeDay {
        screenTime?.dayKey == bundle.dayKey ? screenTime ?? ScreenTimeDay(dayKey: bundle.dayKey) : ScreenTimeDay(dayKey: bundle.dayKey)
    }
}

// MARK: - Self-check (runs in DEBUG at launch)

enum ScreenTimeRules {
    static func check() -> [String] {
        var errors: [String] = []
        let catalog = FallbackCatalog.bundled()
        guard let now = QuestDay.date(from: "2026-10-05") else { return ["quest day failed to parse"] }

        // Every day gets the row before Stretching, and a Training day keeps it.
        var snapshot = GameSnapshot.fresh(catalog: catalog, now: now)
        let ids = snapshot.bundle.quests.map(\.id)
        guard let row = ids.firstIndex(of: ScreenTime.questId), let stretch = ids.firstIndex(of: DailyStretch.questId), row < stretch else {
            return ["every day should have the Screen Time row before Stretching, got \(ids)"]
        }
        if TrainingDay.exerciseOnly(snapshot.bundle)?.quests.contains(where: { $0.id == ScreenTime.questId }) != true {
            errors.append("a Training day should keep the Screen Time row")
        }
        if VerificationMethod.screenTimeLimit.allowsLocalCheckbox {
            errors.append("Screen Time is measured, so it must not be a checkbox")
        }

        // 8 h of work and 30 min of phone is 510, past the 500 cap: work is red, the row is yellow, the quest still holds.
        snapshot.applyScreenTime(phoneMinutes: 30, workMinutes: 480, overlapMinutes: 0)
        let day = snapshot.screenTimeToday
        let quest = snapshot.bundle.quests.first { $0.id == ScreenTime.questId }
        if !day.workOver || day.phoneOver || day.overTotal || !day.atCap || quest?.status != .pending || quest?.progress.current != 510 {
            errors.append("8 h work + 30 min phone should be red for work and yellow, but not failed, got \(day) \(String(describing: quest?.status))")
        }
        // A pending Screen Time row alone does not count as an open required set.
        for index in snapshot.bundle.quests.indices where snapshot.bundle.quests[index].id != ScreenTime.questId {
            snapshot.bundle.quests[index].status = .completed
        }
        if snapshot.missesRequiredSet {
            errors.append("a day with everything done and Screen Time under the cap should not miss its required set")
        }
        // At the day's end it completes and no penalty opens.
        var held = snapshot
        held.refreshIfNeeded(catalog: catalog, now: now.addingTimeInterval(86_400))
        if held.player.penaltyOpen || held.questHistory.first?.quests.first(where: { $0.title == ScreenTime.title })?.status != .completed {
            errors.append("a held Screen Time day should complete and open no penalty")
        }

        // 530 is the last minute of the grace: still yellow and pending.
        snapshot.applyScreenTime(phoneMinutes: 50, workMinutes: nil)
        if !snapshot.screenTimeToday.atCap || snapshot.bundle.quests.first(where: { $0.id == ScreenTime.questId })?.status != .pending {
            errors.append("530 minutes should be yellow and still pending")
        }
        // One more minute of phone: 531 fails the row (red), but it does not miss the required set.
        snapshot.applyScreenTime(phoneMinutes: 51, workMinutes: nil)
        if snapshot.screenTimeToday.atCap || snapshot.bundle.quests.first(where: { $0.id == ScreenTime.questId })?.status != .failed || snapshot.missesRequiredSet {
            errors.append("531 minutes should fail the row without missing the required set")
        }
        // A lower reading later does not undo it.
        snapshot.applyScreenTime(phoneMinutes: 10, workMinutes: 10)
        if snapshot.screenTimeToday.totalMinutes != 531 || snapshot.bundle.quests.first(where: { $0.id == ScreenTime.questId })?.status != .failed {
            errors.append("a lower reading must not lower the count or clear the failure")
        }
        snapshot.refreshIfNeeded(catalog: catalog, now: now.addingTimeInterval(86_400))
        if snapshot.player.penaltyOpen || snapshot.screenTimeToday.totalMinutes != 0
            || snapshot.questHistory.first?.quests.first(where: { $0.title == ScreenTime.title })?.status != .failed {
            errors.append("a failed Screen Time day should stay red in the record, open no penalty, and start the next day at 0, got penalty \(snapshot.player.penaltyOpen)")
        }

        // 7 h + 1.5 h is 510, inside the grace: both lines stay normal and the row is yellow.
        var exact = ScreenTimeDay(dayKey: "x")
        exact.workMinutes = 420
        exact.phoneMinutes = 90
        exact.overlapMinutes = 0
        if exact.workOver || exact.phoneOver || exact.overTotal || !exact.atCap {
            errors.append("7 h work and 1.5 h phone should be inside both sub-caps and the grace")
        }
        if PhoneScreenGroup.thresholds.first != 1 || PhoneScreenGroup.thresholds.last ?? 0 <= ScreenTime.failAfterMinutes
            || PhoneScreenGroup.thresholds != Array(1...(PhoneScreenGroup.thresholds.last ?? 0)) {
            errors.append("phone thresholds should run every minute from 1 past the total cap")
        }
        // Each calendar day keeps its own count, so a count that ended at midnight is still there for the midnight check.
        let phoneSuite = "com.angelmorales.thesystem.selfcheck.phone"
        if let defaults = UserDefaults(suiteName: phoneSuite) {
            defaults.set(["2026-10-05": ["1": 10.0, "2": 70.0], "2026-10-06": ["1": 90.0]], forKey: PhoneScreenGroup.daysKey)
            if PhoneScreenGroup.minutes(for: "2026-10-05", defaults: defaults) != 2
                || PhoneScreenGroup.minutes(for: "2026-10-06", defaults: defaults) != 1
                || PhoneScreenGroup.minutes(for: "2026-10-07", defaults: defaults) != nil
                || PhoneScreenGroup.times(for: "2026-10-05", defaults: defaults)[2] != Date(timeIntervalSince1970: 70) {
                errors.append("each calendar day should keep its own phone count")
            }
            defaults.removePersistentDomain(forName: phoneSuite)
        }
        // The burst of 2026-11-05: steady steps, then every step left in a few seconds, out of order.
        if let start = QuestDay.start(of: "2026-10-05") {
            let at = { (minute: Double) in start.addingTimeInterval(minute * 60) }
            var steady = Dictionary(uniqueKeysWithValues: (1...56).map { ($0, at(Double($0) * 2)) })
            var burst = steady
            for (offset, step) in (57...540).reversed().enumerated() { burst[step] = at(114 + Double(offset) * 0.0001) }
            if PhoneBurst.trusted(steady) != steady {
                errors.append("steady phone steps should all be trusted")
            }
            if PhoneBurst.trusted(burst).keys.max() != 56 {
                errors.append("a burst should leave the count at 56, got \(String(describing: PhoneBurst.trusted(burst).keys.max()))")
            }
            // A step of the old count that comes after the burst does not jump past it, and a re-armed step does not need it.
            var stray = burst
            stray[541] = at(400)
            if PhoneBurst.trusted(stray).keys.max() != 56 {
                errors.append("a lone step far past the trusted count should not count")
            }
            steady[57] = at(180)
            if PhoneBurst.trusted(steady).keys.max() != 57 {
                errors.append("the next step after a quiet spell should count")
            }
            // A real batch: 3 steps at once after 4 quiet minutes, then a late step and its catch-up.
            let batch: [Int: Date] = [14: at(100), 15: at(104), 16: at(104.001), 17: at(104.002), 18: at(105), 19: at(105.5), 20: at(105.501), 21: at(105.502)]
            if PhoneBurst.trusted(batch).count != batch.count {
                errors.append("a small late batch should stay, got \(PhoneBurst.trusted(batch).keys.sorted())")
            }
            // The day's first group is a burst: nothing is trusted, and the count reads 0, not "no reading".
            let first = Dictionary(uniqueKeysWithValues: (1...321).map { ($0, at(1000 + Double($0) * 0.0001)) })
            if !PhoneBurst.trusted(first).isEmpty {
                errors.append("a burst as the day's first group should not count")
            }
            let burstSuite = "com.angelmorales.thesystem.selfcheck.phoneburst"
            if let defaults = UserDefaults(suiteName: burstSuite) {
                PhoneScreenGroup.keep(first, for: "2026-10-05", defaults: defaults)
                if PhoneScreenGroup.minutes(for: "2026-10-05", defaults: defaults) != 0 || PhoneScreenGroup.minutes(for: "2026-10-06", defaults: defaults) != nil {
                    errors.append("a day of only false steps should read 0, and a day with none should read nil")
                }
                PhoneScreenGroup.keep(PhoneBurst.trusted(burst), for: "2026-10-05", defaults: defaults)
                if PhoneScreenGroup.rawTimes(for: "2026-10-05", defaults: defaults).count != 56 {
                    errors.append("keep should replace the day's stored steps")
                }
                defaults.removePersistentDomain(forName: burstSuite)
            }
            // A false reading already saved: the count drops and the failure lifts.
            var saved = GameSnapshot.fresh(catalog: catalog, now: now)
            saved.applyScreenTime(phoneMinutes: 540, workMinutes: 9, overlapMinutes: 0)
            saved.correctPhoneScreenTime(to: 56)
            let row = saved.bundle.quests.first { $0.id == ScreenTime.questId }
            if saved.screenTimeToday.phoneMinutes != 56 || row?.status != .pending || row?.progress.current != 65 {
                errors.append("a corrected burst should read 56 + 9 and lift the failure, got \(saved.screenTimeToday) \(String(describing: row?.status))")
            }
            // A real failure stays: the work minutes alone are past the grace.
            var real = GameSnapshot.fresh(catalog: catalog, now: now)
            real.applyScreenTime(phoneMinutes: 540, workMinutes: 535, overlapMinutes: 0)
            real.correctPhoneScreenTime(to: 56)
            if real.bundle.quests.first(where: { $0.id == ScreenTime.questId })?.status != .failed {
                errors.append("a correction should not lift a failure the total still earns")
            }
        }
        // Phone 10:00–10:10 while a Mac was active 10:00–10:15: the second 5 minutes surely overlap.
        if let start = QuestDay.start(of: "2026-10-05") {
            var bits = [UInt8](repeating: 0, count: 188)
            for slot in 300..<315 { bits[slot >> 3] |= 1 << UInt8(slot & 7) }
            let at = { (minute: Int) in start.addingTimeInterval(Double(minute) * 60) }
            let shared = ScreenOverlap.minutes(phoneTimes: [5: at(305), 10: at(310)], macActive: Data(bits), dayStart: start)
            if shared != 4 {
                errors.append("5 phone minutes inside a 5-minute Mac window should share 4 minutes after the slack, got \(shared)")
            }
            // The same use reported every minute shares the same minutes.
            let everyMinute = Dictionary(uniqueKeysWithValues: (1...10).map { ($0, at(300 + $0)) })
            if ScreenOverlap.minutes(phoneTimes: everyMinute, macActive: Data(bits), dayStart: start) != 4 {
                errors.append("1-minute phone steps should share the same 4 minutes as 5-minute steps")
            }
            // A batch of steps reported in one minute is one window, so it cannot count one Mac minute many times.
            let batch = Dictionary(uniqueKeysWithValues: stride(from: 5, through: 50, by: 5).map { ($0, at(310)) })
            if ScreenOverlap.minutes(phoneTimes: batch, macActive: Data(bits), dayStart: start) != 0 {
                errors.append("a batch of phone steps should not repeat Mac minutes")
            }
            // Phone use while every Mac was idle shares nothing.
            if ScreenOverlap.minutes(phoneTimes: [5: at(605), 10: at(610)], macActive: Data(bits), dayStart: start) != 0 {
                errors.append("phone time away from the Mac should not overlap")
            }
            var both = ScreenTimeDay(dayKey: "x")
            both.phoneMinutes = 60
            both.workMinutes = 60
            both.overlapMinutes = 50
            if both.totalMinutes != 70 || both.sharedMinutes != 50 || !both.overlapMeasured {
                errors.append("an hour on each with 50 shared minutes should total 70, got \(both.totalMinutes)")
            }
        }
        // No overlap measurement yet: the phone minutes may all be Mac minutes too, so the total is the larger side.
        var unknown = ScreenTimeDay(dayKey: "x")
        unknown.phoneMinutes = 90
        unknown.workMinutes = 480
        if unknown.overlapMeasured || unknown.sharedMinutes != 90 || unknown.totalMinutes != 480 || unknown.overTotal {
            errors.append("without an overlap count 90 phone + 480 work should total 480, got \(unknown.totalMinutes)")
        }
        // One side alone past the grace still fails, with or without the measurement.
        unknown.phoneMinutes = 531
        if !unknown.overTotal || unknown.totalMinutes != 531 {
            errors.append("531 phone minutes should fail even before the overlap is measured, got \(unknown.totalMinutes)")
        }
        // The same day through the snapshot: no measurement holds the row, then a measured overlap of 10 makes it 560 and fails it.
        var pending = GameSnapshot.fresh(catalog: catalog, now: now)
        pending.applyScreenTime(phoneMinutes: 90, workMinutes: 480)
        if pending.screenTimeToday.totalMinutes != 480 || pending.bundle.quests.first(where: { $0.id == ScreenTime.questId })?.status != .pending {
            errors.append("90 phone + 480 work with no overlap count must not fail the day, got \(pending.screenTimeToday.totalMinutes)")
        }
        pending.applyScreenTime(phoneMinutes: nil, workMinutes: nil, overlapMinutes: 10)
        if pending.screenTimeToday.totalMinutes != 560 || pending.bundle.quests.first(where: { $0.id == ScreenTime.questId })?.status != .failed {
            errors.append("a measured overlap of 10 should make 90 + 480 total 560 and fail, got \(pending.screenTimeToday.totalMinutes)")
        }
        // Notices: the highest new step only, none twice, none under 50%.
        if ScreenTimeAlerts.due(totalMinutes: 249, sent: []) != nil || ScreenTimeAlerts.due(totalMinutes: 250, sent: []) != 50
            || ScreenTimeAlerts.due(totalMinutes: 460, sent: [50]) != 90 || ScreenTimeAlerts.due(totalMinutes: 460, sent: [50, 75, 90]) != nil
            || ScreenTimeAlerts.due(totalMinutes: 475, sent: [50, 75, 90]) != 95 || ScreenTimeAlerts.due(totalMinutes: 520, sent: [50, 75, 90, 95]) != 100 {
            errors.append("screen time notice steps wrong")
        }
        if ScreenTime.clock(280) != "4h 40m" || ScreenTime.clock(32) != "32m" || ScreenTime.clock(420) != "7h" {
            errors.append("screen time clock format wrong")
        }
        return errors
    }
}
