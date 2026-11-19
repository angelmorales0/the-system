import Foundation

#if os(iOS)
import UserNotifications
#endif

/// The always-on habit rules and their records, saved with the game (see docs/HABITS_PLAN.md).
/// Each field loads empty from a save made before it existed.
struct HabitState: Codable, Equatable {
    /// Quest weeks (their Monday) whose eat-out cap already opened a penalty. One penalty a week at most.
    var eatOutPenaltyWeeks: [String] = []
    /// The player's beliefs: who they decide to be. The quest screen shows one each day.
    var beliefs: [String] = Beliefs.defaults
    /// The quest day whose morning workout ended the morning lock.
    var morningUnlockedDayKey: String?
    /// The wake time WHOOP gave for a quest day, kept so the lock knows its start without a new read.
    var wokeAt: [String: Date] = [:]
    /// The contracts the player signed, oldest first. A contract stays until its end date and after, as a record.
    var contracts: [Contract] = []
    /// Body weight in lb by quest day (the newest weigh-in of the day), for the weight contract.
    var weights: [String: Double] = [:]
    /// Full Recovery tokens a broken contract took while the bank was empty: the next tokens earned go to it.
    var tokenDebt = 0
    /// Rest days a broken contract took, by quest week (its Monday).
    var restDaysForfeited: [String: Int] = [:]
    /// True once the player set a home. Home by 9 pm starts the next day.
    var homeSet = false
    /// When the phone entered and left home, newest last. Copied from `HomeEvents` before each judgment.
    var homeEvents: [HomeEvent] = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case eatOutPenaltyWeeks, beliefs, morningUnlockedDayKey, wokeAt, contracts, weights, tokenDebt, restDaysForfeited, homeSet, homeEvents
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eatOutPenaltyWeeks = try container.decodeIfPresent([String].self, forKey: .eatOutPenaltyWeeks) ?? []
        beliefs = try container.decodeIfPresent([String].self, forKey: .beliefs) ?? Beliefs.defaults
        morningUnlockedDayKey = try container.decodeIfPresent(String.self, forKey: .morningUnlockedDayKey)
        wokeAt = try container.decodeIfPresent([String: Date].self, forKey: .wokeAt) ?? [:]
        contracts = try container.decodeIfPresent([Contract].self, forKey: .contracts) ?? []
        weights = try container.decodeIfPresent([String: Double].self, forKey: .weights) ?? [:]
        tokenDebt = try container.decodeIfPresent(Int.self, forKey: .tokenDebt) ?? 0
        restDaysForfeited = try container.decodeIfPresent([String: Int].self, forKey: .restDaysForfeited) ?? [:]
        homeSet = try container.decodeIfPresent(Bool.self, forKey: .homeSet) ?? false
        homeEvents = try container.decodeIfPresent([HomeEvent].self, forKey: .homeEvents) ?? []
    }
}

// MARK: - Morning lock

/// Every app except the allowed ones (Spotify, Strava, The System) is blocked from wake time until the first workout
/// of the day. Wake time is the end of the WHOOP night sleep; without one, the lock starts at 7:00. A wake after 7:00
/// does not move the start: the lock is already on. A rest day (free rest day or Full Recovery) has no lock.
/// No shop item skips it. Any of these ends it: a Hevy workout with a set (stretches count), a Strava activity, or an
/// Apple Health workout of 10 minutes or more, started after waking (after 5:00 without a wake time).
enum MorningLock {
    static let fallbackHour = 7
    static let minHealthSeconds = 10.0 * 60

    /// 7:00 on the quest day, or the wake time when it is earlier and on that quest day.
    static func start(dayKey: String, wokeAt: Date?) -> Date? {
        guard let dayStart = QuestDay.start(of: dayKey) else { return nil }
        let seven = dayStart.addingTimeInterval(Double(fallbackHour - QuestDay.startHour) * 3600)
        guard let wokeAt, QuestDay.key(for: wokeAt) == dayKey else { return seven }
        return min(wokeAt, seven)
    }

    /// The first workout that ends the lock: started after `after`, from Hevy, Strava, or Apple Health.
    static func unlockingWorkout(_ data: DayIntegrationSnapshot, after: Date) -> Date? {
        let hevy = data.hevy.workouts.filter { $0.start >= after && $0.exercises.contains { !$0.sets.isEmpty } }.map(\.start)
        let strava = data.strava.activities.filter { $0.start >= after }.map(\.start)
        let health = data.health.workouts.filter { $0.start >= after && $0.end.timeIntervalSince($0.start) >= minHealthSeconds }.map(\.start)
        return (hevy + strava + health).min()
    }
}

extension GameSnapshot {
    /// No lock today: a rest day, a Full Recovery day, or the morning workout is done.
    var morningLockOff: Bool {
        let today = bundle.dayKey
        return restDue(on: today) || fullRecoveryDayKey == today || bundle.mode == .fullRecovery || habits.morningUnlockedDayKey == today
    }

    /// When today's lock starts, from the saved wake time.
    var morningLockStart: Date? { MorningLock.start(dayKey: bundle.dayKey, wokeAt: habits.wokeAt[bundle.dayKey]) }

    /// True while the lock holds now.
    func morningLockOn(now: Date) -> Bool {
        guard !morningLockOff, let start = morningLockStart, QuestDay.key(for: now) == bundle.dayKey else { return false }
        return now >= start
    }

    /// Saves today's wake time and ends the lock once a morning workout is found. Returns true when it ended it now.
    @discardableResult
    mutating func checkMorningLock(integrations: DayIntegrationSnapshot, wokeAt: Date?) -> Bool {
        let today = bundle.dayKey
        if let wokeAt, QuestDay.key(for: wokeAt) == today {
            habits.wokeAt[today] = wokeAt
            habits.wokeAt = habits.wokeAt.filter { $0.key >= QuestDay.key(byAddingDays: -7, to: today) }
        }
        // Only workouts that start after today's wake (or 5:00) count, so yesterday's data never ends today's lock.
        guard habits.morningUnlockedDayKey != today, let dayStart = QuestDay.start(of: today) else { return false }
        let after = habits.wokeAt[today] ?? dayStart
        guard MorningLock.unlockingWorkout(integrations, after: after) != nil else { return false }
        habits.morningUnlockedDayKey = today
        return true
    }
}

// MARK: - Contracts

/// A promise the player signs on purpose: an action rule, checked each quest week until an end date the player picks.
/// It cannot be changed or cancelled before the end date. Each broken week costs the same stake:
/// 1 Full Recovery token and 1 rest day. With no token in the bank, the next token earned is taken.
/// With no rest day left this week, next week has one fewer.
struct Contract: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        /// Body weight on or under a straight line from the start weight to the target on the end date.
        case bodyWeight
        var id: String { rawValue }
        var label: String { "Body weight" }
    }

    /// One judged week.
    struct Check: Codable, Equatable {
        /// The last quest day of the period: a Sunday, or the end date.
        var endDayKey: String
        /// The line on that day, in lb.
        var lineLb: Double
        /// The average of the period's weigh-ins. Nil when there was none.
        var averageLb: Double?
        var kept: Bool
    }

    var id: String
    var kind: Kind
    var startDayKey: String
    var endDayKey: String
    var startLb: Double
    var targetLb: Double
    var signedAt: Date
    var checks: [Check] = []

    var title: String {
        "Reach \(Contract.number(targetLb)) lb by \(Contract.dateText(endDayKey))"
    }

    /// The rule in words, for the sign screen and the record.
    var terms: String {
        let side = targetLb > startLb ? "on or over" : "on or under"
        let from = startLb > 0 ? "\(Contract.number(startLb)) lb" : "your start weight"
        return "Each week, from \(Contract.dateText(startDayKey)) to \(Contract.dateText(endDayKey)), your average weigh-in must be \(side) "
            + "a straight line from \(from) to \(Contract.number(targetLb)) lb. A week with no weigh-in is broken. "
            + "Weigh-ins come from Apple Health."
    }

    static let stake = "Each broken week costs 1 Full Recovery token and 1 rest day. With no token, the next one you earn is taken. "
        + "With no rest day left this week, next week has one fewer."

    func isActive(on dayKey: String) -> Bool { startDayKey <= dayKey && dayKey <= endDayKey }

    /// The line on a day: a straight line from the start weight on the start day to the target on the end day.
    func lineLb(on dayKey: String) -> Double {
        guard let start = QuestDay.date(from: startDayKey), let end = QuestDay.date(from: endDayKey), let day = QuestDay.date(from: dayKey),
              end > start else { return targetLb }
        let share = min(max(day.timeIntervalSince(start) / end.timeIntervalSince(start), 0), 1)
        return startLb + (targetLb - startLb) * share
    }

    /// The periods to judge: each quest week (Monday to Sunday) from the start day, the last one cut at the end date.
    var periods: [(start: String, end: String)] {
        var result: [(String, String)] = []
        var start = startDayKey
        while start <= endDayKey {
            let sunday = QuestDay.key(byAddingDays: 6, to: RestDays.weekKey(of: start))
            let end = min(sunday, endDayKey)
            result.append((start, end))
            start = QuestDay.key(byAddingDays: 1, to: end)
        }
        return result
    }

    /// Why the contract cannot be signed, or nil.
    var problem: String? {
        if !(50...500).contains(startLb) || !(50...500).contains(targetLb) { return "Type weights from 50 to 500 lb." }
        if abs(startLb - targetLb) < 0.5 { return "The target must differ from the start weight." }
        if endDayKey <= QuestDay.key(byAddingDays: 6, to: startDayKey) { return "Pick an end date at least a week away." }
        return nil
    }

    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    static func dateText(_ dayKey: String) -> String {
        QuestDay.date(from: dayKey)?.formatted(date: .abbreviated, time: .omitted) ?? dayKey
    }
}

extension GameSnapshot {
    /// Rest days the player can still spend in the week, after the ones a broken contract took.
    func restDaysForfeited(on dayKey: String) -> Int {
        habits.restDaysForfeited[RestDays.weekKey(of: dayKey)] ?? 0
    }

    /// Signs a contract. It starts today. Returns why it was refused, or nil when it was signed.
    mutating func signContract(_ draft: Contract, now: Date) -> String? {
        var contract = draft
        contract.startDayKey = bundle.dayKey
        contract.signedAt = now
        contract.checks = []
        if let problem = contract.problem { return problem }
        if habits.contracts.contains(where: { $0.kind == contract.kind && $0.isActive(on: bundle.dayKey) }) {
            return "A \(contract.kind.label.lowercased()) contract is already active. It ends on \(Contract.dateText(habits.contracts.last { $0.kind == contract.kind }?.endDayKey ?? ""))."
        }
        habits.contracts.append(contract)
        return nil
    }

    /// Saves the newest weigh-in of each quest day.
    mutating func recordWeights(_ readings: [BodyMassReading]) {
        for reading in readings.sorted(by: { $0.date < $1.date }) where reading.kg > 0 {
            habits.weights[QuestDay.key(for: reading.date)] = (reading.pounds * 10).rounded() / 10
        }
        let oldest = QuestDay.key(byAddingDays: -400, to: bundle.dayKey)
        habits.weights = habits.weights.filter { $0.key >= oldest }
    }

    /// Judges each period that has ended and takes the stake for each broken one. Returns the number broken now.
    @discardableResult
    mutating func judgeContracts(now: Date) -> Int {
        let today = QuestDay.key(for: now)
        var broken = 0
        for index in habits.contracts.indices {
            let contract = habits.contracts[index]
            for period in contract.periods where period.end < today && !contract.checks.contains(where: { $0.endDayKey == period.end }) {
                let weighIns = habits.weights.filter { $0.key >= period.start && $0.key <= period.end }.map(\.value)
                let average = weighIns.isEmpty ? nil : weighIns.reduce(0, +) / Double(weighIns.count)
                let line = contract.lineLb(on: period.end)
                let losing = contract.targetLb < contract.startLb
                let kept = average.map { losing ? $0 <= line + 0.05 : $0 >= line - 0.05 } ?? false
                habits.contracts[index].checks.append(Contract.Check(endDayKey: period.end, lineLb: (line * 10).rounded() / 10,
                                                                     averageLb: average.map { ($0 * 10).rounded() / 10 }, kept: kept))
                if !kept {
                    broken += 1
                    takeStake(today: today)
                }
            }
        }
        payTokenDebt()
        return broken
    }

    /// 1 Full Recovery token (or a debt on the next one) and 1 rest day (this week's, else next week's).
    private mutating func takeStake(today: String) {
        habits.tokenDebt += 1
        let week = RestDays.weekKey(of: today)
        let left = max(RestDays.allowance(on: today) - restDaysUsed(on: today) - restDaysForfeited(on: today), 0)
        let target = left > 0 ? week : QuestDay.key(byAddingDays: 7, to: week)
        habits.restDaysForfeited[target, default: 0] += 1
        habits.restDaysForfeited = habits.restDaysForfeited.filter { $0.key >= QuestDay.key(byAddingDays: -21, to: week) }
    }

    /// Takes owed tokens from the bank, as soon as there are any.
    mutating func payTokenDebt() {
        while habits.tokenDebt > 0, player.fullRecoveryBank > 0 {
            player.fullRecoveryBank -= 1
            habits.tokenDebt -= 1
        }
    }
}

// MARK: - Home by 9 pm

/// The phone entered (inside) or left home.
struct HomeEvent: Codable, Equatable {
    var at: Date
    var inside: Bool
}

/// The phone's home events, saved by `HomeTracker` when iOS wakes the app at the edge of home. Kept 14 days.
enum HomeEvents {
    static let key = "com.angelmorales.thesystem.homeEvents.v1"

    static func load(from defaults: UserDefaults = .standard) -> [HomeEvent] {
        guard let data = defaults.data(forKey: key), let events = try? JSONDecoder().decode([HomeEvent].self, from: data) else { return [] }
        return events
    }

    static func append(_ event: HomeEvent, to defaults: UserDefaults = .standard) {
        let cutoff = event.at.addingTimeInterval(-14 * 86_400)
        let events = (load(from: defaults) + [event]).filter { $0.at >= cutoff }.sorted { $0.at < $1.at }
        if let data = try? JSONEncoder().encode(events) { defaults.set(data, forKey: key) }
    }
}

/// Always on: the phone is at home at 9:00 pm, every day, a rest day too. Only the Moonlit Pass skips a night.
/// The row starts the day after the player sets a home. It is judged at 9:00 pm: home then completes it,
/// anywhere else fails it, and a failed row opens a penalty at the day's end like any required quest.
enum HomeBy {
    static let questId = "daily_home_by_9"
    static let title = "Home by 9 pm"
    static let hour = 21

    /// 9:00 pm of the quest day.
    static func deadline(_ dayKey: String) -> Date? {
        QuestDay.start(of: dayKey)?.addingTimeInterval(Double(hour - QuestDay.startHour) * 3600)
    }

    /// Home or not at a moment: the newest event at or before it. Nil with no event before it.
    static func home(at date: Date, events: [HomeEvent]) -> Bool? {
        events.filter { $0.at <= date }.max { $0.at < $1.at }?.inside
    }

    static func quest(mode: QuestMode, now: Date) -> Quest {
        Quest(
            id: questId,
            title: title,
            kind: .daily,
            stat: .REC,
            verification: VerificationSpec(method: .homeBy, params: ["hour": .number(Double(hour))]),
            deadline: QuestDay.endOfDay(now),
            difficulty: .normal,
            mode: mode,
            progress: QuestProgress(current: 0, target: 1, unit: ""),
            status: .pending,
            assignedAt: now
        )
    }

    /// Adds the row once, before Stretching and after the other required rows.
    static func ensure(in bundle: QuestBundle, homeSet: Bool, now: Date) -> QuestBundle {
        guard homeSet, !bundle.quests.contains(where: { $0.id == questId }) else { return bundle }
        var copy = bundle
        let insertAt = copy.quests.firstIndex { $0.id == DailyStretch.questId }
            ?? copy.quests.lastIndex(where: { $0.kind != .optional }).map { $0 + 1 } ?? copy.quests.count
        copy.quests.insert(quest(mode: bundle.mode, now: now), at: insertAt)
        return copy
    }
}

extension GameSnapshot {
    /// Moves the row: before 9:00 pm it shows home or not; at 9:00 pm it completes at home and fails elsewhere.
    mutating func applyHomeBy(now: Date) {
        guard let index = bundle.quests.firstIndex(where: { $0.id == HomeBy.questId }), bundle.quests[index].status == .pending,
              let deadline = HomeBy.deadline(bundle.dayKey) else { return }
        let events = habits.homeEvents
        if now >= deadline {
            let home = HomeBy.home(at: deadline, events: events) == true
            bundle.quests[index].status = home ? .completed : .failed
            bundle.quests[index].progress.current = home ? 1 : 0
        } else {
            bundle.quests[index].progress.current = HomeBy.home(at: now, events: events) == true ? 1 : 0
        }
    }

    /// The row of a day that is ending is judged at its 9:00 pm, so a closed app still gets an answer.
    mutating func settleHomeBy() {
        guard let deadline = HomeBy.deadline(bundle.dayKey) else { return }
        applyHomeBy(now: deadline)
    }

    /// True when today's Home by 9 pm row is not done. A rest day does not waive it.
    var homeByMissed: Bool {
        bundle.quests.contains { $0.id == HomeBy.questId && $0.status != .completed }
    }
}

// MARK: - Day off

/// One day a week with no knowledge work: every Sunday. The only rule: 0 Mac work minutes. The other rows stay.
/// A few minutes of grace cover a Mac that wakes for an update or a quick look. Past them, the Screen Time quest fails.
enum DayOff {
    /// Sunday in `Calendar.weekday` (Sunday is 1).
    static let weekday = 1
    static let graceMinutes = 5

    static func isDayOff(_ dayKey: String) -> Bool {
        guard let date = QuestDay.date(from: dayKey) else { return false }
        return QuestDay.calendar.component(.weekday, from: date) == weekday
    }
}

// MARK: - Beliefs

/// The identity first: decide who you are, then let the habits prove it. Up to 10 lines, like commandments.
enum Beliefs {
    static let defaults = [
        "I live below my means.",
        "I take care of where I live and the places I visit.",
    ]
    static let maxCount = 10
    static let maxLength = 120

    /// Trims each line, drops empty ones, cuts long ones, and keeps the first 10.
    static func cleaned(_ lines: [String]) -> [String] {
        Array(lines.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength)) }.filter { !$0.isEmpty }.prefix(maxCount))
    }

    /// The belief of the day. Days run through the list in order, so each one comes back.
    static func today(_ beliefs: [String], dayKey: String) -> String? {
        guard !beliefs.isEmpty, let date = QuestDay.date(from: dayKey) else { return nil }
        let day = Int((date.timeIntervalSince1970 / 86_400).rounded(.down))
        return beliefs[((day % beliefs.count) + beliefs.count) % beliefs.count]
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

        // Morning lock: from 7:00 or an earlier wake, until a workout started after waking. Off on rest days.
        let seven = (QuestDay.start(of: "2026-11-16") ?? monday).addingTimeInterval(2 * 3600)
        if MorningLock.start(dayKey: "2026-11-16", wokeAt: nil) != seven
            || MorningLock.start(dayKey: "2026-11-16", wokeAt: seven.addingTimeInterval(-3600)) != seven.addingTimeInterval(-3600)
            || MorningLock.start(dayKey: "2026-11-16", wokeAt: seven.addingTimeInterval(3600)) != seven {
            errors.append("the morning lock should start at 7:00, or at an earlier wake time")
        }
        var lock = GameSnapshot.fresh(catalog: catalog, now: monday)
        if lock.morningLockOn(now: seven.addingTimeInterval(-60)) || !lock.morningLockOn(now: seven) {
            errors.append("the morning lock should hold from 7:00")
        }
        func run(_ start: Date, minutes: Double, source: String = "strava") -> WorkoutEvent {
            WorkoutEvent(source: source, externalId: "\(start.timeIntervalSince1970)", sport: "Run", start: start,
                         end: start.addingTimeInterval(minutes * 60), movingTimeSec: minutes * 60)
        }
        var data = DayIntegrationSnapshot.empty(dayKey: lock.bundle.dayKey)
        data.health = HealthDaySummary(access: .requested, workouts: [run(seven.addingTimeInterval(600), minutes: 5, source: "health")])
        if lock.checkMorningLock(integrations: data, wokeAt: seven.addingTimeInterval(-1800)) || lock.habits.wokeAt[lock.bundle.dayKey] == nil {
            errors.append("a 5-minute Health workout should not end the lock, and the wake time should be kept")
        }
        data.strava = StravaDayReading(available: true, configured: true, reason: "", dayKey: lock.bundle.dayKey,
                                       activities: [run(seven.addingTimeInterval(-3600), minutes: 30)])
        if lock.checkMorningLock(integrations: data, wokeAt: nil) {
            errors.append("a run before the wake time should not end the lock")
        }
        data.strava.activities.append(run(seven.addingTimeInterval(900), minutes: 30))
        if !lock.checkMorningLock(integrations: data, wokeAt: nil) || lock.morningLockOn(now: seven.addingTimeInterval(3600)) {
            errors.append("a run after waking should end the lock for the day")
        }
        var rest = GameSnapshot.fresh(catalog: catalog, now: monday)
        rest.restDayKeys = [rest.bundle.dayKey]
        if rest.morningLockOn(now: seven) { errors.append("a rest day should have no morning lock") }

        // Contracts: weekly periods to the end date, a straight line, and the stake for a broken week.
        var signer = GameSnapshot.fresh(catalog: catalog, now: monday)
        let today = signer.bundle.dayKey
        var draft = Contract(id: "c1", kind: .bodyWeight, startDayKey: "", endDayKey: QuestDay.key(byAddingDays: 20, to: today),
                             startLb: 155, targetLb: 145, signedAt: monday)
        if signer.signContract(draft, now: monday) != nil || signer.signContract(draft, now: monday) == nil {
            errors.append("a contract should sign once, and a second weight contract should be refused while the first is active")
        }
        let signed = signer.habits.contracts[0]
        if signed.periods.count != 3 || signed.periods.first?.end != QuestDay.key(byAddingDays: 6, to: RestDays.weekKey(of: today))
            || abs(signed.lineLb(on: signed.endDayKey) - 145) > 0.001 || abs(signed.lineLb(on: today) - 155) > 0.001 {
            errors.append("a 21-day contract from a Monday should have 3 weekly periods and a line from 155 to 145, got \(signed.periods)")
        }
        draft.startDayKey = today
        draft.endDayKey = QuestDay.key(byAddingDays: 3, to: today)
        if draft.problem == nil { errors.append("a contract shorter than a week should be refused") }
        // Week 1: weigh-ins under the line keep it. Week 2: no weigh-in breaks it and takes the stake.
        signer.player.fullRecoveryBank = 0
        let line = signed.lineLb(on: signed.periods[0].end)
        signer.habits.weights = [today: line - 1]
        let weekTwo = (QuestDay.start(of: QuestDay.key(byAddingDays: 7, to: today)) ?? monday).addingTimeInterval(3600)
        let firstBroken = signer.judgeContracts(now: weekTwo)
        if firstBroken != 0 || signer.habits.contracts[0].checks.first?.kept != true {
            errors.append("a week under the line should be kept, got \(signer.habits.contracts[0].checks)")
        }
        let weekThree = (QuestDay.start(of: QuestDay.key(byAddingDays: 14, to: today)) ?? monday).addingTimeInterval(3600)
        signer.bundle.dayKey = QuestDay.key(for: weekThree)
        if signer.judgeContracts(now: weekThree) != 1 || signer.habits.tokenDebt != 1
            || signer.restDaysForfeited(on: QuestDay.key(for: weekThree)) != 1 || signer.judgeContracts(now: weekThree) != 0 {
            errors.append("a week with no weigh-in should be broken once: a token owed and a rest day taken")
        }
        signer.player.depositRecoveryToken()
        signer.payTokenDebt()
        if signer.player.fullRecoveryBank != 0 || signer.habits.tokenDebt != 0 {
            errors.append("the next token earned should pay the debt")
        }
        if signer.restDaysLeft(on: QuestDay.key(for: weekThree)) != RestDays.perWeek - 1 {
            errors.append("a taken rest day should leave one fewer this week")
        }

        // Home by 9 pm: judged at 21:00 from the events, added only once a home is set, and not waived on a rest day.
        var home = GameSnapshot.fresh(catalog: catalog, now: monday)
        if home.bundle.quests.contains(where: { $0.id == HomeBy.questId }) {
            errors.append("Home by 9 pm should wait until a home is set")
        }
        home.habits.homeSet = true
        home.rebuildBundle(catalog: catalog, now: monday)
        guard let nine = HomeBy.deadline(home.bundle.dayKey), home.bundle.quests.contains(where: { $0.id == HomeBy.questId }) else {
            return errors + ["Home by 9 pm should be on the day once a home is set"]
        }
        home.habits.homeEvents = [HomeEvent(at: nine.addingTimeInterval(-3600), inside: true)]
        home.applyHomeBy(now: nine.addingTimeInterval(-60))
        let before = home.bundle.quests.first { $0.id == HomeBy.questId }
        home.applyHomeBy(now: nine.addingTimeInterval(60))
        if before?.status != .pending || before?.progress.current != 1 || home.bundle.quests.first(where: { $0.id == HomeBy.questId })?.status != .completed {
            errors.append("home at 9:00 pm should complete the row, and not before 9:00 pm")
        }
        var out = GameSnapshot.fresh(catalog: catalog, now: monday)
        out.habits.homeSet = true
        out.rebuildBundle(catalog: catalog, now: monday)
        out.habits.homeEvents = [HomeEvent(at: nine.addingTimeInterval(-3600), inside: true), HomeEvent(at: nine.addingTimeInterval(-600), inside: false)]
        out.restDayKeys = [out.bundle.dayKey]
        out.settleHomeBy()
        if out.bundle.quests.first(where: { $0.id == HomeBy.questId })?.status != .failed || !out.homeByMissed {
            errors.append("away at 9:00 pm should fail the row, also on a rest day")
        }
        // The Moonlit Pass skips one night.
        var pass = GameSnapshot.fresh(catalog: catalog, now: monday)
        pass.habits.homeSet = true
        pass.rebuildBundle(catalog: catalog, now: monday)
        pass.gold = 10_000
        _ = pass.usePotion(.moonlitPass, now: monday)
        if pass.bundle.quests.first(where: { $0.id == HomeBy.questId })?.status != .completed || pass.homeByMissed || pass.gold != 5_800 {
            errors.append("a Moonlit Pass should skip tonight's Home by 9 pm for 4,200 gold")
        }

        // Day off: Sundays. Work past the grace fails the Screen Time quest; a weekday keeps the 7-hour work cap.
        let sunday = "2026-11-22"
        if !DayOff.isDayOff(sunday) || DayOff.isDayOff("2026-11-16") {
            errors.append("Sunday should be the day off and Monday not")
        }
        if let sundayDate = QuestDay.date(from: sunday) {
            var off = GameSnapshot.fresh(catalog: catalog, now: sundayDate)
            off.applyScreenTime(phoneMinutes: 30, workMinutes: DayOff.graceMinutes)
            let graceOK = off.bundle.quests.first { $0.id == ScreenTime.questId }?.status == .pending
            off.applyScreenTime(phoneMinutes: 30, workMinutes: 20)
            if !graceOK || off.bundle.quests.first(where: { $0.id == ScreenTime.questId })?.status != .failed || off.screenTimeToday.workCap != 0 {
                errors.append("work on the day off should fail the Screen Time quest past the grace")
            }
        }
        var weekday = GameSnapshot.fresh(catalog: catalog, now: monday)
        weekday.applyScreenTime(phoneMinutes: 30, workMinutes: 300)
        if weekday.bundle.quests.first(where: { $0.id == ScreenTime.questId })?.status != .pending || weekday.screenTimeToday.workCap != ScreenTime.workCapMinutes {
            errors.append("a weekday should keep the 7-hour work cap")
        }

        // Beliefs: cleaned to 10 lines, and the days run through them in order.
        let lines = Beliefs.cleaned(["  I live below my means. ", "", String(repeating: "x", count: 200)] + Array(repeating: "Line", count: 12))
        if lines.count != 10 || lines[0] != "I live below my means." || lines[1].count != Beliefs.maxLength {
            errors.append("beliefs should be trimmed, cut to \(Beliefs.maxLength) characters, and kept to 10, got \(lines.count)")
        }
        let shown = ["2026-11-16", "2026-11-17", "2026-11-18"].compactMap { Beliefs.today(["A", "B"], dayKey: $0) }
        if shown.count != 3 || shown[0] == shown[1] || shown[0] != shown[2] || Beliefs.today([], dayKey: "2026-11-16") != nil {
            errors.append("the daily belief should run through the list in order, got \(shown)")
        }

        // Old saves load with no habit records.
        if (try? JSONDecoder().decode(HabitState.self, from: Data("{}".utf8)))?.beliefs != Beliefs.defaults
            || (try? JSONDecoder().decode(HabitState.self, from: Data("{}".utf8))) != HabitState() {
            errors.append("an empty habit save should load")
        }
        return errors
    }
}
