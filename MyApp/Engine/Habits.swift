import Foundation

#if os(iOS)
import UserNotifications
#endif

/// The always-on habit rules and their records, saved with the game (see docs/HABITS_PLAN.md).
/// Each field loads empty from a save made before it existed.
struct HabitState: Codable, Equatable {
    /// Quest weeks (their Monday) whose eat-out cap already opened a penalty. One penalty a week at most.
    var eatOutPenaltyWeeks: [String] = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case eatOutPenaltyWeeks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eatOutPenaltyWeeks = try container.decodeIfPresent([String].self, forKey: .eatOutPenaltyWeeks) ?? []
    }
}

// MARK: - Eat-out cap

/// Eating out (Restaurants and FoodDelivery) has its own weekly cap: $40, about one meal with friends.
/// The charge that takes the quest week over the cap opens a penalty 8 hours later. Mercury shows a card charge some
/// hours after it happens, so the 8 hours give it time to arrive. A Banquet Seal day does not count.
enum EatOut {
    static let capUsd = MercuryClient.eatOutWeeklyCapUsd
    static let penaltyDelay: TimeInterval = 8 * 60 * 60

    struct Week: Equatable {
        /// The Monday of the quest week.
        var weekKey: String
        var spentUsd: Double
        var capUsd: Double
        /// The time of the charge that took the week over the cap. Nil while the week is under it.
        var overAt: Date?
        /// Discretionary spend of the week, eat-out included. Nil before the first Mercury read with it.
        var discretionaryUsd: Double?

        var share: Double { capUsd > 0 ? spentUsd / capUsd : 0 }
        var penaltyAt: Date? { overAt.map { $0.addingTimeInterval(EatOut.penaltyDelay) } }
    }

    /// Adds the charges in time order; the first charge past the cap is the one that went over.
    static func week(_ charges: [EatOutCharge], weekKey: String, excusedDays: Set<String>, cap: Double = capUsd,
                     discretionaryUsd: Double? = nil) -> Week {
        var total = 0.0
        var overAt: Date?
        for charge in charges.sorted(by: { $0.at < $1.at }) where !excusedDays.contains(charge.dayKey) {
            total += charge.usd
            if overAt == nil, total > cap + 0.005 { overAt = charge.at }
        }
        return Week(weekKey: weekKey, spentUsd: MercuryClient.round2(total), capUsd: cap, overAt: overAt, discretionaryUsd: discretionaryUsd)
    }
}

/// Notices at 50, 75, 90, and 100% of the weekly eat-out cap, one of each a week, like the Screen Time notices.
enum EatOutAlerts {
    static let percents = [50, 75, 90, 100]
    /// Week key → percents already sent.
    static let sentKey = "eatOutAlertsSent"

    static func due(share: Double, sent: Set<Int>) -> Int? {
        percents.filter { share * 100 + 0.001 >= Double($0) }.max().flatMap { sent.contains($0) ? nil : $0 }
    }

    static func message(percent: Int, week: EatOut.Week) -> (title: String, body: String) {
        let spent = FinanceLevel.usd(week.spentUsd), cap = FinanceLevel.usd(week.capUsd)
        if percent >= 100 {
            return ("Eating out: over the cap", "\(spent) of \(cap) this week. A penalty opens 8 hours after the charge that went over.")
        }
        return ("Eating out: \(percent)%", "\(spent) of \(cap) this week. \(FinanceLevel.usd(max(week.capUsd - week.spentUsd, 0))) left.")
    }

    static func update(week: EatOut.Week, defaults: UserDefaults = .standard) {
        var sentWeeks = defaults.dictionary(forKey: sentKey) as? [String: [Int]] ?? [:]
        let sent = Set(sentWeeks[week.weekKey] ?? [])
        guard let percent = due(share: week.share, sent: sent) else { return }
        sentWeeks[week.weekKey] = Array(sent.union(percents.filter { $0 <= percent })).sorted()
        for old in sentWeeks.keys.sorted().dropLast(3) { sentWeeks.removeValue(forKey: old) }
        defaults.set(sentWeeks, forKey: sentKey)
        #if os(iOS)
        let text = message(percent: percent, week: week)
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "eat-out-\(week.weekKey)-\(percent)", content: content, trigger: nil))
        #endif
    }
}

extension GameSnapshot {
    /// Days a Banquet Seal excused from the eat-out cap.
    var eatOutExcusedDays: Set<String> {
        Set(potionLog.filter { $0.potion == .banquetSeal }.map(\.dayKey))
    }

    /// This quest week's eat-out spend, from the last Mercury read. Nil before a read of this week.
    var eatOutWeek: EatOut.Week? {
        let weekKey = RestDays.weekKey(of: bundle.dayKey)
        guard let finance, let charges = finance.eatOutWeek, RestDays.weekKey(of: finance.dayKey) == weekKey else { return nil }
        return EatOut.week(charges, weekKey: weekKey, excusedDays: eatOutExcusedDays, discretionaryUsd: finance.weekDiscretionaryUsd)
    }

    /// Opens the penalty 8 hours after the charge that took the week over the eat-out cap. Once a week.
    /// Returns true when it opened one now.
    @discardableResult
    mutating func applyEatOutCap(catalog: FallbackCatalog, now: Date) -> Bool {
        guard let week = eatOutWeek, let due = week.penaltyAt, now >= due,
              !habits.eatOutPenaltyWeeks.contains(week.weekKey) else { return false }
        habits.eatOutPenaltyWeeks = Array((habits.eatOutPenaltyWeeks + [week.weekKey]).suffix(20))
        player.penaltyOpen = true
        // This penalty is the week's, not the day's. Late work on the day that waits must not lift it.
        endedDay?.monthPenalty = true
        bundle = PenaltyQuests.ensure(in: bundle, open: true, band: trainingBand, catalog: catalog, now: now)
        return true
    }
}

enum HabitRules {
    static func check() -> [String] {
        var errors: [String] = []
        let catalog = FallbackCatalog.bundled()
        guard let monday = QuestDay.date(from: "2026-11-16") else { return ["could not build habit dates"] }
        func charge(_ day: String, hours: Double, _ usd: Double) -> EatOutCharge {
            EatOutCharge(dayKey: day, at: (QuestDay.start(of: day) ?? monday).addingTimeInterval(hours * 3600), usd: usd)
        }

        // $25 then $20: the second charge takes the week over $40. A Banquet Seal day does not count.
        let charges = [charge("2026-11-16", hours: 14, 25), charge("2026-11-18", hours: 15, 20)]
        let over = EatOut.week(charges, weekKey: "2026-11-16", excusedDays: [])
        if over.spentUsd != 45 || over.overAt != charges[1].at || over.penaltyAt != charges[1].at.addingTimeInterval(8 * 3600) {
            errors.append("$45 should be over the $40 cap at the second charge, got \(over)")
        }
        if EatOut.week(charges, weekKey: "2026-11-16", excusedDays: ["2026-11-18"]).overAt != nil {
            errors.append("a Banquet Seal day should not count toward the cap")
        }

        // The penalty opens 8 hours after the charge, once a week, and not before.
        var game = GameSnapshot.fresh(catalog: catalog, now: monday)
        game.finance = FinanceSnapshot(eatOutWeek: charges, weekDiscretionaryUsd: 120, dayKey: game.bundle.dayKey, discretionarySpendUsd: 0,
                                       necessarySpendUsd: 0, capUsd: 40, discretionary7dUsd: 0, paceState: "NORMAL", ytdIncomeUsd: 0,
                                       ytdGoalUsd: 0, settled: false)
        if game.eatOutWeek?.discretionaryUsd != 120 {
            errors.append("the week should carry its discretionary spend")
        }
        if game.applyEatOutCap(catalog: catalog, now: charges[1].at.addingTimeInterval(7 * 3600)) || game.player.penaltyOpen {
            errors.append("the eat-out penalty should wait 8 hours after the charge")
        }
        if !game.applyEatOutCap(catalog: catalog, now: charges[1].at.addingTimeInterval(8 * 3600)) || !game.player.penaltyOpen
            || PenaltyQuests.rows(in: game.bundle).isEmpty {
            errors.append("the eat-out penalty should open 8 hours after the charge that went over")
        }
        game.player.penaltyOpen = false
        if game.applyEatOutCap(catalog: catalog, now: charges[1].at.addingTimeInterval(9 * 3600)) {
            errors.append("the eat-out cap should open one penalty a week")
        }
        // A read from last week does not count for this week.
        var stale = GameSnapshot.fresh(catalog: catalog, now: monday)
        stale.finance = game.finance
        stale.finance?.dayKey = "2026-11-15"
        if stale.eatOutWeek != nil { errors.append("last week's read should not count for this week") }

        // Notices: the highest step reached and not sent, once.
        if EatOutAlerts.due(share: 0.8, sent: []) != 75 || EatOutAlerts.due(share: 0.8, sent: [50, 75]) != nil || EatOutAlerts.due(share: 1.2, sent: [50]) != 100 {
            errors.append("eat-out notices should send the highest step reached, once")
        }

        // Old saves load with no habit records.
        if (try? JSONDecoder().decode(HabitState.self, from: Data("{}".utf8))) != HabitState() {
            errors.append("an empty habit save should load")
        }
        return errors
    }
}
