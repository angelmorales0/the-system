import Foundation
import DeviceActivity
import FamilyControls
import ManagedSettings
import UserNotifications

/// Re-asserts the penalty lock while a penalty is active. It does not start a Live Activity.
/// At midnight it locks the phone if the quest day that just ended left its required set open, even when the app is closed.
/// Interval end does not lift shields; only the main app clears them after the penalty quests are done.
/// And it counts phone screen time: each threshold event of the daily count writes its minutes for the app to read.
/// This target is `nonisolated`. If the SDK marks these overrides isolated, drop the `nonisolated` keyword.
class PenaltyDeviceActivityMonitor: DeviceActivityMonitor {
    nonisolated override func intervalDidStart(for activity: DeviceActivityName) {
        if activity.rawValue == FocusMonitor.activity {
            FocusMonitor.startDay(now: Date())
            return
        }
        if PhoneScreenMonitor.activities.contains(activity.rawValue) { return }
        if activity.rawValue == PenaltyMonitorGroup.dawnActivity {
            PenaltyMonitorShields.lockIfDayMissed(now: Date())
            return
        }
        if activity.rawValue == MorningLockMonitor.activity {
            MorningLockMonitor.start(now: Date())
            return
        }
        PenaltyMonitorShields.reassert()
    }

    nonisolated override func intervalDidEnd(for activity: DeviceActivityName) {
        if activity.rawValue == FocusMonitor.activity {
            FocusMonitor.endDay(now: Date())
            return
        }
        if PhoneScreenMonitor.activities.contains(activity.rawValue) { return }
        if activity.rawValue == PenaltyMonitorGroup.dawnActivity || activity.rawValue == MorningLockMonitor.activity { return }
        PenaltyMonitorShields.reassert()
    }

    nonisolated override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        if activity.rawValue == FocusMonitor.activity {
            FocusMonitor.record(event: event.rawValue, now: Date())
            return
        }
        if PhoneScreenMonitor.activities.contains(activity.rawValue) {
            PhoneScreenMonitor.record(event.rawValue, now: Date())
        }
    }
}

/// Mirrors `PenaltyGroup` and `QuestDay.startHour` in the app. Keep the strings in step.
enum PenaltyMonitorGroup {
    static let suiteName = "group.com.angelmorales.thesystem"
    static let penaltyActiveKey = "penaltyActive"
    static let startedAtKey = "penaltyStartedAt"
    static let openDayKey = "penaltyOpenDayKey"
    static let owedDayKey = "penaltyOwedDayKey"
    static let allowedSelectionKey = "penaltyAllowedSelection"
    static let hiddenSelectionKey = "penaltyHiddenSelection"
    static let storeName = "penalty"
    static let dawnActivity = "penaltyDawn"
    static let dayStartHour = 0
}

enum PenaltyMonitorShields {
    nonisolated static func reassert() {
        let defaults = UserDefaults(suiteName: PenaltyMonitorGroup.suiteName) ?? .standard
        guard defaults.bool(forKey: PenaltyMonitorGroup.penaltyActiveKey) else {
            ManagedSettingsStore(named: .init(PenaltyMonitorGroup.storeName)).clearAllSettings()
            return
        }
        lockEverything()
    }

    /// The app writes the open quest day. If that day ended before this midnight, the penalty starts now.
    /// It also writes the day on which an open penalty waited (a token day or a rest day): that penalty comes back now.
    nonisolated static func lockIfDayMissed(now: Date) {
        let defaults = UserDefaults(suiteName: PenaltyMonitorGroup.suiteName) ?? .standard
        let today = questDayKey(for: now)
        let missedDay = defaults.string(forKey: PenaltyMonitorGroup.openDayKey).flatMap { $0 < today ? $0 : nil }
        let owedDay = defaults.string(forKey: PenaltyMonitorGroup.owedDayKey).flatMap { $0 < today ? $0 : nil }
        guard let openDay = missedDay ?? owedDay else {
            reassert()
            return
        }
        let alreadyActive = defaults.bool(forKey: PenaltyMonitorGroup.penaltyActiveKey)
        defaults.set(true, forKey: PenaltyMonitorGroup.penaltyActiveKey)
        if defaults.object(forKey: PenaltyMonitorGroup.startedAtKey) == nil {
            defaults.set(now.timeIntervalSince1970, forKey: PenaltyMonitorGroup.startedAtKey)
        }
        lockEverything()
        guard !alreadyActive else { return }
        let content = UNMutableNotificationContent()
        content.title = "PENALTY QUEST"
        content.body = missedDay != nil
            ? "Yesterday's daily quest was not completed. Every app except your allowed apps is locked until the penalty quest is cleared in The System."
            : "Your penalty waited through the rest day. Every app except your allowed apps is locked until the penalty quest is cleared in The System."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "penalty-\(openDay)", content: content, trigger: nil))
    }

    /// Same rule as `PenaltyEnforcement.applyShields` in the app: every app category except the allowed apps,
    /// every website, and the hidden apps off the Home Screen. iOS keeps calls and emergency SOS open.
    nonisolated private static func lockEverything() {
        let defaults = UserDefaults(suiteName: PenaltyMonitorGroup.suiteName) ?? .standard
        let allowed = apps(defaults, PenaltyMonitorGroup.allowedSelectionKey)
        let hidden = apps(defaults, PenaltyMonitorGroup.hiddenSelectionKey).subtracting(allowed)
        let store = ManagedSettingsStore(named: .init(PenaltyMonitorGroup.storeName))
        store.shield.applications = nil
        store.shield.webDomains = nil
        store.shield.applicationCategories = .all(except: allowed)
        store.shield.webDomainCategories = .all()
        store.application.blockedApplications = Set(hidden.map { Application(token: $0) })
        store.application.denyAppRemoval = true
    }

    /// The app tokens of a selection the app saved, or none.
    nonisolated private static func apps(_ defaults: UserDefaults, _ key: String) -> Set<ApplicationToken> {
        guard let data = defaults.data(forKey: key),
              let selection = try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: data) else { return [] }
        return selection.applicationTokens
    }

    /// Same rule as `QuestDay.key` in the app: the day starts at midnight.
    nonisolated static func questDayKey(for date: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        let local = calendar.component(.hour, from: date) < PenaltyMonitorGroup.dayStartHour
            ? calendar.date(byAdding: .day, value: -1, to: date) ?? date
            : date
        let parts = calendar.dateComponents([.year, .month, .day], from: local)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }
}

/// Mirrors `MorningLockEnforcement` in the app. Keep the strings in step.
/// At 7:00 it blocks every app except the allowed ones, unless the app wrote that today has no lock
/// (a rest day, or the morning workout is done). Only the app ends the lock.
enum MorningLockMonitor {
    static let activity = "morningLock"
    static let storeName = "morningLock"
    static let offDayKey = "morningLockOffDayKey"
    static let morningAllowedSelectionKey = "morningAllowedSelection"

    nonisolated static func start(now: Date) {
        let defaults = UserDefaults(suiteName: PenaltyMonitorGroup.suiteName) ?? .standard
        let today = PenaltyMonitorShields.questDayKey(for: now)
        guard defaults.string(forKey: offDayKey) != today else { return }
        // The morning list, or the penalty's list while the morning list is empty.
        func tokens(_ key: String) -> Set<ApplicationToken> {
            guard let data = defaults.data(forKey: key),
                  let selection = try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: data) else { return [] }
            return selection.applicationTokens
        }
        let morning = tokens(morningAllowedSelectionKey)
        let allowed = morning.isEmpty ? tokens(PenaltyMonitorGroup.allowedSelectionKey) : morning
        let store = ManagedSettingsStore(named: .init(storeName))
        store.shield.applications = nil
        store.shield.webDomains = nil
        store.shield.applicationCategories = .all(except: allowed)
        store.shield.webDomainCategories = .all()
        let content = UNMutableNotificationContent()
        content.title = "MORNING LOCK"
        content.body = "Your apps are locked until your morning workout. Log it in Hevy, Strava, or Apple Health, then open The System."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "morning-lock-\(today)", content: content, trigger: nil))
    }
}

/// Mirrors `PhoneScreenGroup` in the app. Keep the strings in step.
enum PhoneScreenMonitor {
    /// The daily count, and the one-day count the app starts after a false burst.
    static let activities = ["screenTimeDay", "screenTimeRearm"]
    static let eventPrefix = "phone_"
    static let daysKey = "screenTimePhoneDays"
    /// Older days are dropped. The app reads the current day and the day that just ended.
    static let keepDays = 3

    /// `phone_95` → 95 minutes of phone use today. Days run midnight to midnight, like Apple's Screen Time.
    /// Keeps when each threshold was reached, so the app can find phone time that overlaps Mac time.
    nonisolated static func record(_ event: String, now: Date) {
        guard event.hasPrefix(eventPrefix), let minutes = Int(event.dropFirst(eventPrefix.count)) else { return }
        let defaults = UserDefaults(suiteName: PenaltyMonitorGroup.suiteName) ?? .standard
        let parts = Calendar.autoupdatingCurrent.dateComponents([.year, .month, .day], from: now)
        let today = String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
        var days = defaults.dictionary(forKey: daysKey) as? [String: [String: Double]] ?? [:]
        var times = days[today] ?? [:]
        times[String(minutes)] = times[String(minutes)] ?? now.timeIntervalSince1970
        days[today] = times
        for old in days.keys.sorted().dropLast(keepDays) {
            days.removeValue(forKey: old)
        }
        defaults.set(days, forKey: daysKey)
        // A false burst writes many steps in a few seconds. Real use reaches the step before at least 30 seconds earlier.
        if let previous = times[String(minutes - 1)], now.timeIntervalSince1970 - previous >= 30,
           PenaltyMonitorShields.questDayKey(for: now) == today {
            ScreenAlertMonitor.check(phoneMinutes: minutes, dayKey: today, defaults: defaults)
        }
    }
}

/// Mirrors `ScreenTimeAlerts` in the app. Keep the strings, steps, and message text in step.
/// Adds the phone count to the Mac minutes the app saved last, and sends the step of the cap that is due.
enum ScreenAlertMonitor {
    static let percents = [50, 75, 90, 95, 100]
    static let sentKey = "screenTimeAlertsSent"
    static let baseKey = "screenTimeAlertBase"
    /// Mirrors `ScreenTimeAlerts.capsKey`: the player's limits by the quest day they start. Empty: 8 h 20 m.
    static let capsKey = "screenTimeCaps"
    static let defaultCapMinutes = 500
    static let graceMinutes = 30

    /// The same rule as `HabitState.screenTimeCap(on:)`: the newest limit that started on or before the day.
    nonisolated static func capMinutes(on dayKey: String, defaults: UserDefaults) -> Int {
        let caps = defaults.dictionary(forKey: capsKey) as? [String: Int] ?? [:]
        return caps.filter { $0.key <= dayKey }.max { $0.key < $1.key }?.value ?? defaultCapMinutes
    }

    nonisolated static func check(phoneMinutes: Int, dayKey: String, defaults: UserDefaults) {
        let base = (defaults.dictionary(forKey: baseKey) as? [String: [String: Int]])?[dayKey] ?? [:]
        let work = base["work"] ?? 0
        // Same rule as `ScreenTimeDay.sharedMinutes`: with no measured overlap, every phone minute may be a Mac minute.
        let shared = min(base["overlap"] ?? phoneMinutes, phoneMinutes, work)
        let total = phoneMinutes + work - shared
        let capMinutes = capMinutes(on: dayKey, defaults: defaults)
        var sentDays = defaults.dictionary(forKey: sentKey) as? [String: [Int]] ?? [:]
        let sent = Set(sentDays[dayKey] ?? [])
        guard let percent = percents.filter({ total >= capMinutes * $0 / 100 }).max(), !sent.contains(percent) else { return }
        sentDays[dayKey] = Array(sent.union(percents.filter { $0 <= percent })).sorted()
        for old in sentDays.keys.sorted().dropLast(3) { sentDays.removeValue(forKey: old) }
        defaults.set(sentDays, forKey: sentKey)
        let content = UNMutableNotificationContent()
        content.title = "Screen Time: \(percent)%"
        content.body = percent >= 100
            ? "You reached \(clock(capMinutes)) today. Screen Time fails past \(clock(capMinutes + graceMinutes))."
            : "\(clock(total)) of \(clock(capMinutes)) used today. \(clock(max(capMinutes - total, 0))) left."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "screen-time-\(dayKey)-\(percent)", content: content, trigger: nil))
    }

    /// Same format as `ScreenTime.clock` in the app.
    nonisolated static func clock(_ minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest)m" }
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }
}

/// Mirrors `FocusGroup` in the app. Keep the strings in step.
/// Stores the highest FOC threshold reached per quest day; the app turns these into `FocusDay` rows.
enum FocusMonitor {
    static let activity = "focusDay"
    static let daysKey = "focusDays"
    static let socialTrackedKey = "focusSocialTracked"
    static let screenPrefix = "screen-"
    static let socialPrefix = "social-"
    /// Older days are dropped. FOC scores the newest 30.
    static let keepDays = 60

    /// A monitored day starts at 0 minutes, so a day under every threshold reads 0, not "no data".
    nonisolated static func startDay(now: Date) {
        update(now: now) { row, socialTracked in
            if row["screen"] == nil { row["screen"] = 0 }
            if socialTracked, row["social"] == nil { row["social"] = 0 }
        }
    }

    nonisolated static func record(event: String, now: Date) {
        for (prefix, field) in [(screenPrefix, "screen"), (socialPrefix, "social")] where event.hasPrefix(prefix) {
            guard let minutes = Int(event.dropFirst(prefix.count)) else { return }
            update(now: now) { row, _ in row[field] = max(row[field] ?? 0, minutes) }
        }
    }

    /// Called at 4:59, which still belongs to the day that is ending.
    nonisolated static func endDay(now: Date) {
        update(now: now) { row, _ in row["complete"] = 1 }
    }

    nonisolated private static func update(now: Date, _ change: (inout [String: Int], Bool) -> Void) {
        let defaults = UserDefaults(suiteName: PenaltyMonitorGroup.suiteName) ?? .standard
        var days = defaults.dictionary(forKey: daysKey) as? [String: [String: Int]] ?? [:]
        let key = PenaltyMonitorShields.questDayKey(for: now)
        var row = days[key] ?? [:]
        change(&row, defaults.bool(forKey: socialTrackedKey))
        days[key] = row
        for old in days.keys.sorted().dropLast(keepDays) {
            days.removeValue(forKey: old)
        }
        defaults.set(days, forKey: daysKey)
    }
}
