import Foundation

#if os(iOS)
import DeviceActivity
import FamilyControls
#endif

/// App Group keys shared with the PenaltyMonitor extension for the FOC screen time days.
/// The extension repeats these strings in `FocusMonitor`; change them in both targets together.
enum FocusGroup {
    /// Every category, for total phone use. iOS counts only the apps and categories the player selects.
    static let allSelectionKey = "focusAllSelection"
    static let socialSelectionKey = "focusSocialSelection"
    /// True when social apps are selected, so the monitor records 0 social minutes instead of nil.
    static let socialTrackedKey = "focusSocialTracked"
    /// dayKey → ["screen": minutes, "social": minutes, "complete": 0 or 1]. Written by the monitor.
    static let daysKey = "focusDays"
    static let activity = "focusDay"
    static let screenPrefix = "screen-"
    static let socialPrefix = "social-"

    static var defaults: UserDefaults { PenaltyGroup.defaults }
}

enum FocusTracking {
    /// "screen-90" → (screen, 90). Unknown names give nil.
    static func parse(event: String) -> (isSocial: Bool, minutes: Int)? {
        for (prefix, isSocial) in [(FocusGroup.screenPrefix, false), (FocusGroup.socialPrefix, true)] where event.hasPrefix(prefix) {
            guard let minutes = Int(event.dropFirst(prefix.count)) else { return nil }
            return (isSocial, minutes)
        }
        return nil
    }

    /// The monitor's stored days as FOC days, oldest first.
    static func days(from stored: [String: [String: Int]]) -> [FocusDay] {
        stored.keys.sorted().compactMap { key in
            guard let row = stored[key] else { return nil }
            return FocusDay(dayKey: key, screenMinutesReached: row["screen"], socialMinutesReached: row["social"], complete: row["complete"] == 1)
        }
    }

    static func loadDays() -> [FocusDay] {
        days(from: FocusGroup.defaults.dictionary(forKey: FocusGroup.daysKey) as? [String: [String: Int]] ?? [:])
    }

    static var isTracking: Bool { FocusGroup.defaults.data(forKey: FocusGroup.allSelectionKey) != nil }

    #if os(iOS)
    static func loadSelection(social: Bool) -> FamilyActivitySelection {
        guard let data = FocusGroup.defaults.data(forKey: social ? FocusGroup.socialSelectionKey : FocusGroup.allSelectionKey),
              let selection = try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: data) else {
            return FamilyActivitySelection()
        }
        return selection
    }

    static func save(_ selection: FamilyActivitySelection, social: Bool) {
        let key = social ? FocusGroup.socialSelectionKey : FocusGroup.allSelectionKey
        if isEmpty(selection) {
            FocusGroup.defaults.removeObject(forKey: key)
        } else if let data = try? PropertyListEncoder().encode(selection) {
            FocusGroup.defaults.set(data, forKey: key)
        }
        syncMonitoring()
    }

    /// One schedule per quest day (5:00 to 4:59) with an event at every FOC threshold. Without an "all apps"
    /// selection nothing is counted, so monitoring stops.
    static func syncMonitoring() {
        let center = DeviceActivityCenter()
        let name = DeviceActivityName(FocusGroup.activity)
        center.stopMonitoring([name])
        let all = loadSelection(social: false)
        let social = loadSelection(social: true)
        FocusGroup.defaults.set(!isEmpty(social), forKey: FocusGroup.socialTrackedKey)
        guard !isEmpty(all) else { return }

        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        for minutes in FocusLevel.screenThresholds {
            events[.init(FocusGroup.screenPrefix + String(minutes))] = event(all, minutes: minutes)
        }
        if !isEmpty(social) {
            for minutes in FocusLevel.socialThresholds {
                events[.init(FocusGroup.socialPrefix + String(minutes))] = event(social, minutes: minutes)
            }
        }
        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: QuestDay.startHour, minute: 0),
            intervalEnd: DateComponents(hour: QuestDay.startHour - 1, minute: 59),
            repeats: true
        )
        try? center.startMonitoring(name, during: schedule, events: events)
    }

    private static func event(_ selection: FamilyActivitySelection, minutes: Int) -> DeviceActivityEvent {
        DeviceActivityEvent(
            applications: selection.applicationTokens,
            categories: selection.categoryTokens,
            webDomains: selection.webDomainTokens,
            threshold: DateComponents(minute: minutes)
        )
    }

    private static func isEmpty(_ selection: FamilyActivitySelection) -> Bool {
        selection.applicationTokens.isEmpty && selection.categoryTokens.isEmpty && selection.webDomainTokens.isEmpty
    }
    #endif

    /// The phone's days with each Mac's complete days added. Without iCloud the Mac adds nothing.
    static func loadDaysWithMac(todayKey: String) async -> [FocusDay] {
        let phone = loadDays()
        #if CLOUDKIT_SYNC
        let mac = (try? await MacScreenTimeCloud.fetchDays(before: todayKey)) ?? []
        return FocusDay.merging(phone, mac: mac)
        #else
        _ = todayKey
        return phone
        #endif
    }

    // MARK: - Self-check (runs in DEBUG at launch)

    static func check() -> [String] {
        var errors: [String] = []
        guard let screen = parse(event: "screen-90"), !screen.isSocial, screen.minutes == 90,
              let social = parse(event: "social-5"), social.isSocial, social.minutes == 5,
              parse(event: "bedtimeUse") == nil, parse(event: "screen-x") == nil else {
            errors.append("event names should parse to kind and minutes")
            return errors
        }
        let stored: [String: [String: Int]] = [
            "2026-10-24": ["screen": 90, "social": 0, "complete": 1],
            "2026-10-25": ["screen": 30],
        ]
        let parsed = days(from: stored)
        if parsed != [
            FocusDay(dayKey: "2026-10-24", screenMinutesReached: 90, socialMinutesReached: 0, complete: true),
            FocusDay(dayKey: "2026-10-25", screenMinutesReached: 30, socialMinutesReached: nil, complete: false),
        ] {
            errors.append("stored days should become FOC days oldest first, got \(parsed)")
        }
        let names = FocusLevel.screenThresholds.map { FocusGroup.screenPrefix + String($0) } + FocusLevel.socialThresholds.map { FocusGroup.socialPrefix + String($0) }
        if names.compactMap({ parse(event: $0)?.minutes }) != FocusLevel.screenThresholds + FocusLevel.socialThresholds {
            errors.append("every scheduled event name should parse back to its threshold")
        }
        return errors + MacScreenTime.check()
    }
}
