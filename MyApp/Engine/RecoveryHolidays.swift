import Foundation

/// Full Recovery tokens come only from these days, one token per day:
/// New Year's Day, March 3, October 21, Thanksgiving (US, 4th Thursday of November), and Christmas.
enum RecoveryHolidays {
    static func isHoliday(_ key: String) -> Bool {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return false }
        switch (parts[1], parts[2]) {
        case (1, 1), (3, 3), (10, 21), (12, 25):
            return true
        case (11, 22...28):
            guard let date = QuestDay.date(from: key) else { return false }
            return QuestDay.calendar.component(.weekday, from: date) == 5
        default:
            return false
        }
    }

    /// Holiday quest days after `previousKey`, up to and including `key`.
    /// Days the app was not opened still count. An empty `previousKey` checks only `key`.
    static func holidays(after previousKey: String, through key: String) -> [String] {
        guard !previousKey.isEmpty else { return isHoliday(key) ? [key] : [] }
        var days: [String] = []
        var day = QuestDay.key(byAddingDays: 1, to: previousKey)
        // Stop after about 3 years so a bad key cannot loop for a long time.
        var steps = 0
        while day <= key && steps < 1_100 {
            if isHoliday(day) { days.append(day) }
            let next = QuestDay.key(byAddingDays: 1, to: day)
            guard next > day else { break }
            day = next
            steps += 1
        }
        return days
    }
}

extension GameSnapshot {
    /// Banks one token for each holiday since the last quest day.
    mutating func grantHolidayRecovery(previousKey: String, key: String) {
        for _ in RecoveryHolidays.holidays(after: previousKey, through: key) {
            player.depositRecoveryToken()
        }
    }
}

enum RecoveryHolidayRules {
    static func check() -> [String] {
        var errors: [String] = []
        let holidays = ["2026-01-01", "2026-03-03", "2026-10-21", "2026-11-26", "2026-12-25", "2027-11-25"]
        for key in holidays where !RecoveryHolidays.isHoliday(key) {
            errors.append("\(key) should be a Full Recovery holiday")
        }
        for key in ["2026-11-19", "2026-11-27", "2026-12-24", "2026-03-04", "2026-07-04", "2027-11-26"] where RecoveryHolidays.isHoliday(key) {
            errors.append("\(key) should not be a Full Recovery holiday")
        }

        let range = RecoveryHolidays.holidays(after: "2026-12-20", through: "2027-01-02")
        if range != ["2026-12-25", "2027-01-01"] {
            errors.append("missed holidays should still count, got \(range)")
        }
        if RecoveryHolidays.holidays(after: "2026-12-25", through: "2026-12-25") != [] {
            errors.append("the same day must not grant twice")
        }

        // A day rollover onto Christmas banks exactly one token.
        let catalog = FallbackCatalog.bundled()
        guard let eve = QuestDay.start(of: "2026-12-24")?.addingTimeInterval(3_600),
              let christmas = QuestDay.start(of: "2026-12-25")?.addingTimeInterval(3_600) else {
            return errors + ["could not build holiday dates"]
        }
        var snapshot = GameSnapshot.fresh(catalog: catalog, now: eve)
        let before = snapshot.player.fullRecoveryBank
        snapshot.refreshIfNeeded(catalog: catalog, now: christmas)
        snapshot.refreshIfNeeded(catalog: catalog, now: christmas.addingTimeInterval(3_600))
        if snapshot.player.fullRecoveryBank != before + 1 {
            errors.append("Christmas should bank one token, got \(snapshot.player.fullRecoveryBank - before)")
        }
        return errors
    }
}
