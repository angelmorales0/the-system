import Foundation

/// One line of the monthly quest window.
nonisolated struct MonthlyQuestRow: Equatable, Identifiable {
    enum Status: Equatable {
        case active, cleared, failed, noData
    }

    var id: String
    var title: String
    /// `[$512/$1,000]`, `[+12/+50]`, or `[1/4]`.
    var progress: String
    var status: Status
    /// Share of the limit or goal used, 0...1. Nil hides the bar.
    var share: Double?
    /// Numbers under the row.
    var lines: [String] = []
}

nonisolated struct MonthlyBoard: Equatable {
    var monthName: String
    var rows: [MonthlyQuestRow]
    var lastMonthName: String
    var lastRows: [MonthlyQuestRow]
}

/// What the player must do in one Codeforces language in one month. Only contests from before the month decide it,
/// so it stays fixed for the whole month and a bad contest cannot make the goal easier.
enum CodeforcesGoal {
    enum Plan: Equatable {
        /// The account's first rated contests add bonus rating, and a language needs a first contest.
        case playContests(Int)
        case gain(start: Int, amount: Int)
        case hold(start: Int)
    }

    static let targetRating = Int(IntelligenceLevel.ratingBand.target)
    /// Rated contests of an account with a bonus. The rating is real after them.
    static let settledContests = 6
    /// Rated contests a month in each language. Codeforces runs about 6 to 8 a month.
    static let contestsPerMonth = 2
    /// Share of the gap to 2100 asked for each month.
    static let gapShare = 0.08
    /// The goal is above the recent monthly gain by this factor.
    static let paceStretch = 1.25
    static let paceWindowSeconds = 183 * 86_400
    static let secondsPerMonth = 2_629_800.0
    static let minGain = 25
    static let maxGain = 150

    /// `contests` holds this language only, oldest first. `accountContests` counts every language before the month.
    static func plan(contests: [CodeforcesContest], accountContests: Int, monthStart: Int) -> Plan {
        let before = contests.filter { $0.time < monthStart }
        guard accountContests >= settledContests, let last = before.last else { return .playContests(contestsPerMonth) }
        let start = last.newRating
        let gap = targetRating - start
        guard gap > 0 else { return .hold(start: start) }
        let wanted = max(Double(gap) * gapShare, pace(before, monthStart: monthStart) * paceStretch)
        let clamped = min(max(wanted, Double(minGain)), Double(maxGain))
        return .gain(start: start, amount: min(gap, Int((clamped / 5).rounded(.up)) * 5))
    }

    /// Rating points a month earned in the recent contests. 0 with fewer than 2 of them.
    static func pace(_ contests: [CodeforcesContest], monthStart: Int) -> Double {
        let recent = contests.filter { $0.time >= monthStart - paceWindowSeconds }
        guard recent.count >= 2, let first = recent.first, let last = recent.last else { return 0 }
        let months = max(1, Double(last.time - first.time) / secondsPerMonth)
        return Double(recent.reduce(0) { $0 + $1.newRating - $1.oldRating }) / months
    }
}

enum MonthlyQuests {
    static let budgetId = "monthly_budget"
    static let typingId = "monthly_typing"
    /// The first month with these quests. An older month has no result to show.
    static let firstMonth = "2026-11"
    static let names = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]

    static func board(codeforces: CodeforcesReading?, typing: MonkeytypeReading?, financeMonths: [FinanceMonth], excuses: PotionExcuses, now: Date) -> MonthlyBoard {
        let dayKey = QuestDay.key(for: now)
        let months = IntegrationClient.financeMonthKeys(dayKey: dayKey)
        return MonthlyBoard(
            monthName: name(of: months.this),
            rows: [budgetRow(month: months.this, finance: financeMonths, excuses: excuses, ended: false, daysLeft: daysLeft(dayKey: dayKey))]
                + CodeforcesLanguage.allCases.map { codeforcesRow(month: months.this, language: $0, reading: codeforces, ended: false) }
                + [typingRow(typing)],
            lastMonthName: name(of: months.last),
            lastRows: months.last < firstMonth ? [] : [budgetRow(month: months.last, finance: financeMonths, excuses: excuses, ended: true, daysLeft: 0)]
                + CodeforcesLanguage.allCases.map { codeforcesRow(month: months.last, language: $0, reading: codeforces, ended: true) }
        )
    }

    static func name(of month: String) -> String {
        guard let number = Int(month.suffix(2)), names.indices.contains(number - 1) else { return month }
        return names[number - 1]
    }

    /// Days left in the month, today included.
    static func daysLeft(dayKey: String) -> Int {
        guard let date = QuestDay.date(from: dayKey), let days = QuestDay.calendar.range(of: .day, in: .month, for: date)?.count,
              let today = Int(dayKey.suffix(2)) else { return 0 }
        return max(days - today + 1, 1)
    }

    // MARK: - Budget

    static func budgetRow(month: String, finance: [FinanceMonth], excuses: PotionExcuses, ended: Bool, daysLeft: Int) -> MonthlyQuestRow {
        let title = "Monthly budget"
        guard let raw = finance.first(where: { $0.month == month }) else {
            return MonthlyQuestRow(id: budgetId, title: title, progress: "[--]", status: .noData, share: nil)
        }
        let spent = excuses.excusing(raw).spendingUsd
        let budget = raw.budgetUsd ?? MercurySettings.defaultBudgetUsd
        let over = spent > budget + FinanceLevel.budgetTolerance
        var lines: [String] = []
        if over {
            lines.append("\(usd(spent - budget)) over budget")
        } else if !ended {
            lines.append("\(usd(budget - spent)) left, \(usd((budget - spent) / Double(max(daysLeft, 1)))) a day for \(daysLeft) days")
        }
        if let bills = raw.cardBillUsd, bills > 0 { lines.append("Card bills \(usd(bills))") }
        if let necessary = raw.necessaryUsd { lines.append("Necessary \(usd(max(necessary - (raw.cardBillUsd ?? 0), 0)))") }
        if let discretionary = raw.discretionaryUsd { lines.append("Discretionary \(usd(discretionary))") }
        if raw.spendingUsd > spent { lines.append("Potion excused \(usd(raw.spendingUsd - spent))") }
        return MonthlyQuestRow(
            id: budgetId,
            title: title,
            progress: "[\(usd(spent))/\(usd(budget))]",
            status: over ? .failed : ended ? .cleared : .active,
            share: min(spent / budget, 1),
            lines: lines
        )
    }

    static func usd(_ value: Double) -> String { "$\(Int(value.rounded()).formatted())" }

    // MARK: - Codeforces

    static func codeforcesId(_ language: CodeforcesLanguage) -> String { "monthly_codeforces_\(language.rawValue)" }

    static func codeforcesRow(month: String, language: CodeforcesLanguage, reading: CodeforcesReading?, ended: Bool) -> MonthlyQuestRow {
        let id = codeforcesId(language)
        let none = MonthlyQuestRow(id: id, title: "\(language.rawValue) rating", progress: "[--]", status: .noData, share: nil)
        guard let reading, reading.available, let history = reading.history,
              let start = QuestDay.start(of: "\(month)-01"), let end = QuestDay.start(of: "\(MercuryClient.nextMonth(month))-01") else { return none }
        let monthStart = Int(start.timeIntervalSince1970), monthEnd = Int(end.timeIntervalSince1970)
        let contests = history.filter { $0.language == language }
        let played = contests.filter { $0.time >= monthStart && $0.time < monthEnd }
        let quota = "Rated contests [\(played.count)/\(CodeforcesGoal.contestsPerMonth)]"
        func status(_ done: Bool) -> MonthlyQuestRow.Status { done ? .cleared : ended ? .failed : .active }

        switch CodeforcesGoal.plan(contests: contests, accountContests: history.filter { $0.time < monthStart }.count, monthStart: monthStart) {
        case .playContests(let count):
            return MonthlyQuestRow(id: id, title: "\(language.rawValue) rated contests", progress: "[\(min(played.count, count))/\(count)]",
                                   status: status(played.count >= count), share: min(Double(played.count) / Double(count), 1))
        case .gain(let from, let amount):
            let now = played.last?.newRating ?? from
            let gained = played.reduce(0) { $0 + $1.newRating - $1.oldRating }
            let sign = gained < 0 ? "" : "+"
            return MonthlyQuestRow(id: id, title: "\(language.rawValue) rating +\(amount)", progress: "[\(sign)\(gained)/+\(amount)]",
                                   status: status(gained >= amount), share: min(max(Double(gained) / Double(amount), 0), 1),
                                   lines: ["Rating \(now), \(max(CodeforcesGoal.targetRating - now, 0)) to \(CodeforcesGoal.targetRating)", quota])
        case .hold(let from):
            let now = played.last?.newRating ?? from
            let holds = now >= CodeforcesGoal.targetRating
            return MonthlyQuestRow(id: id, title: "\(language.rawValue) hold \(CodeforcesGoal.targetRating)", progress: "[\(now)/\(CodeforcesGoal.targetRating)]",
                                   status: holds ? (ended ? .cleared : .active) : status(false), share: 1, lines: [quota])
        }
    }

    // MARK: - Typing

    static func typingRow(_ reading: MonkeytypeReading?) -> MonthlyQuestRow {
        let goal = Int(IntelligenceLevel.typingBand.target)
        let title = "Monkeytype \(goal) WPM"
        guard let reading, reading.available, let best = reading.bestWpm else {
            return MonthlyQuestRow(id: typingId, title: title, progress: "[--]", status: .noData, share: nil)
        }
        let wpm = Int(best)
        return MonthlyQuestRow(id: typingId, title: title, progress: "[\(wpm)/\(goal)]", status: wpm >= goal ? .cleared : .active, share: min(best / Double(goal), 1))
    }

    // MARK: - Self-check (runs in DEBUG at launch)

    static func check() -> [String] {
        var errors: [String] = []
        let month = 1_800_000_000
        let day = 86_400
        func contests(_ ratings: [Int], end: Int, language: CodeforcesLanguage = .cpp) -> [CodeforcesContest] {
            ratings.enumerated().map { index, rating in
                CodeforcesContest(time: end - (ratings.count - index) * 7 * day, oldRating: index == 0 ? rating : ratings[index - 1], newRating: rating, language: language)
            }
        }
        func plan(_ list: [CodeforcesContest], account: Int = 20) -> CodeforcesGoal.Plan {
            CodeforcesGoal.plan(contests: list, accountContests: account, monthStart: month)
        }

        if plan([], account: 0) != .playContests(2) || plan(contests([1300, 1320], end: month), account: 4) != .playContests(2) {
            errors.append("an account with bonus contests left should play contests first")
        }
        if plan([], account: 12) != .playContests(2) {
            errors.append("a language with no contest should play contests first")
        }
        // Flat at 1500: the gap is 600, and 8% of it is 48, rounded up to 50.
        let flat = contests(Array(repeating: 1500, count: 8), end: month)
        if plan(flat) != .gain(start: 1500, amount: 50) {
            errors.append("flat 1500 should ask for +50, got \(plan(flat))")
        }
        // Rising about 87 a month: the goal stretches past the gap share.
        let rising = contests(Array(stride(from: 1200, through: 1500, by: 20)), end: month)
        if case .gain(_, let amount) = plan(rising) {
            if amount <= 50 || amount > CodeforcesGoal.maxGain { errors.append("a rising player should get a stretch goal, got +\(amount)") }
        } else {
            errors.append("a rising player should get a gain goal")
        }
        if plan(contests(Array(stride(from: 1800, through: 1500, by: -20)), end: month)) != .gain(start: 1500, amount: 50) {
            errors.append("a falling player should use the gap share, not a negative pace")
        }
        if plan(contests(Array(repeating: 2090, count: 8), end: month)) != .gain(start: 2090, amount: 10) {
            errors.append("the goal should stop at 2100")
        }
        if plan(contests(Array(repeating: 2150, count: 8), end: month)) != .hold(start: 2150) {
            errors.append("2100 or more should be a hold goal")
        }
        if plan(flat + [CodeforcesContest(time: month + 5 * day, oldRating: 1500, newRating: 900, language: .cpp)]) != .gain(start: 1500, amount: 50) {
            errors.append("a contest inside the month must not move that month's goal")
        }

        let spent = FinanceMonth(month: "2026-11", postTaxIncomeUsd: 0, spendingUsd: 700, budgetUsd: 1_000, complete: false,
                                 necessaryUsd: 500, discretionaryUsd: 200, cardBillUsd: 300)
        let open = budgetRow(month: "2026-11", finance: [spent], excuses: .none, ended: false, daysLeft: 20)
        if open.progress != "[$700/$1,000]" || open.status != .active || open.share != 0.7
            || open.lines != ["$300 left, $15 a day for 20 days", "Card bills $300", "Necessary $200", "Discretionary $200"] {
            errors.append("the budget row should show the month's spend and split, got \(open)")
        }
        if budgetRow(month: "2026-11", finance: [spent], excuses: .none, ended: true, daysLeft: 0).status != .cleared {
            errors.append("an ended month under budget should clear")
        }
        var high = spent
        high.spendingUsd = 1_200
        let over = budgetRow(month: "2026-11", finance: [high], excuses: .none, ended: false, daysLeft: 20)
        if over.status != .failed || over.lines.first != "$200 over budget" || over.share != 1 {
            errors.append("spend over budget should fail the quest at once, got \(over)")
        }
        let excused = budgetRow(month: "2026-11", finance: [high], excuses: PotionExcuses(spendUsdByMonth: ["2026-11": 300]), ended: false, daysLeft: 20)
        if excused.status != .active || excused.progress != "[$900/$1,000]" || excused.lines.last != "Potion excused $300" {
            errors.append("the FIN potion should excuse spend from the budget quest, got \(excused)")
        }
        if budgetRow(month: "2026-11", finance: [], excuses: .none, ended: false, daysLeft: 20).status != .noData {
            errors.append("the budget row without Mercury should show no data")
        }

        var reading = CodeforcesReading.disconnected(reason: "")
        if codeforcesRow(month: "2026-11", language: .cpp, reading: reading, ended: false).status != .noData
            || codeforcesRow(month: "2026-11", language: .cpp, reading: nil, ended: false).status != .noData {
            errors.append("the Codeforces row without data should show no data")
        }
        reading.available = true
        reading.configured = true
        reading.history = []
        let rookie = codeforcesRow(month: "2026-11", language: .python, reading: reading, ended: false)
        if rookie.title != "Python rated contests" || rookie.progress != "[0/2]" || rookie.status != .active {
            errors.append("an unrated player should see the contest quest, got \(rookie)")
        }
        if codeforcesRow(month: "2026-11", language: .python, reading: reading, ended: true).status != .failed {
            errors.append("an ended month short of the contests should fail")
        }
        if let start = QuestDay.start(of: "2026-11-01") {
            let first = Int(start.timeIntervalSince1970)
            reading.history = contests(Array(repeating: 1500, count: 8), end: first)
                + contests(Array(repeating: 1300, count: 2), end: first, language: .java)
                + [CodeforcesContest(time: first + 2 * day, oldRating: 1500, newRating: 1560, language: .cpp),
                   CodeforcesContest(time: first + 3 * day, oldRating: 1560, newRating: 1500, language: .java)]
            let gained = codeforcesRow(month: "2026-11", language: .cpp, reading: reading, ended: false)
            if gained.title != "C++ rating +50" || gained.progress != "[+60/+50]" || gained.status != .cleared
                || gained.lines != ["Rating 1560, 540 to 2100", "Rated contests [1/2]"] {
                errors.append("a gain over the goal should clear, got \(gained)")
            }
            let java = codeforcesRow(month: "2026-11", language: .java, reading: reading, ended: false)
            if java.progress != "[-60/+65]" || java.status != .active {
                errors.append("each language should count only its own contests, got \(java)")
            }
        } else {
            errors.append("the quest month should parse")
        }
        if typingRow(MonkeytypeReading(available: true, configured: true, reason: "", username: "t", bestWpm: 100.9)).progress != "[100/200]"
            || typingRow(.disconnected(reason: "")).status != .noData
            || typingRow(MonkeytypeReading(available: true, configured: true, reason: "", username: "t", bestWpm: 200)).status != .cleared {
            errors.append("the typing row should show the best against 200 WPM")
        }

        let november = QuestDay.start(of: "2026-11-15") ?? .now
        let december = QuestDay.start(of: "2026-12-15") ?? .now
        let boards = [november, december].map { board(codeforces: reading, typing: nil, financeMonths: [], excuses: .none, now: $0) }
        if !boards[0].lastRows.isEmpty || boards[1].lastRows.count != 4 || boards[0].rows.count != 5 {
            errors.append("a month from before these quests should show no result")
        }
        if name(of: "2026-11") != "November" || name(of: "2026-01") != "January" {
            errors.append("month names wrong")
        }
        if daysLeft(dayKey: "2026-11-03") != 28 || daysLeft(dayKey: "2026-11-30") != 1 {
            errors.append("days left should count today")
        }
        return errors
    }
}
