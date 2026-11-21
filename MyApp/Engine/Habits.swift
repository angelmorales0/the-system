import Foundation

#if os(iOS)
import UserNotifications
#endif

/// The always-on habit rules and their records, saved with the game (see docs/HABITS_PLAN.md).
/// Each field loads empty from a save made before it existed.
struct HabitState: Codable, Equatable {
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
    /// Quest days whose morning workout ended the lock, for the systems view. Kept 60 days.
    var morningDoneDays: [String] = []
    /// The behavior log: one note a quest day, "what I did that could be better". Kept 365 days.
    var log: [String: String] = [:]
    /// No eating out, by quest day: true passed, false failed. A past day without a mark fails.
    var eatOutMarks: [String: Bool] = [:]
    /// No caffeine, by quest day, the same way.
    var caffeineMarks: [String: Bool] = [:]
    /// Only whole foods, by quest day, the same way.
    var wholeFoodsMarks: [String: Bool] = [:]
    /// Marks of the removed Traveling habit. Kept so older saves still load; nothing reads them.
    var travelMarks: [String: Bool] = [:]
    /// Two 1-hour study blocks, by quest day: true passed, false failed. A past day without a mark fails.
    var studyMarks: [String: Bool] = [:]
    /// Habits the player typed in for a contract. Each one is a Systems row, marked by hand like the others.
    var customHabits: [CustomHabit] = []
    /// The hand-marked Systems rows in their order, as the player edited them. Nil until the first edit:
    /// the built-in rows then show, followed by the contract habits.
    var habitRows: [HandHabit]? = nil
    /// Marks of the rows the player added in the habit editor, by row id, then by quest day.
    var rowMarks: [String: [String: Bool]] = [:]
    /// Home by: the time (minutes after midnight) from each quest day the player changed it. Empty: 9:00 pm.
    var homeByTimes: [String: Int] = [:]
    /// Screen Time: the total limit in minutes from each quest day the player changed it. Empty: 8 h 20 m.
    var screenTimeCaps: [String: Int] = [:]

    init() {}

    private enum CodingKeys: String, CodingKey {
        case beliefs, morningUnlockedDayKey, wokeAt, contracts, weights, tokenDebt, restDaysForfeited, homeSet, homeEvents
        case morningDoneDays, log, eatOutMarks, caffeineMarks, wholeFoodsMarks, travelMarks, studyMarks, customHabits
        case habitRows, rowMarks, homeByTimes, screenTimeCaps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        beliefs = try container.decodeIfPresent([String].self, forKey: .beliefs) ?? Beliefs.defaults
        morningUnlockedDayKey = try container.decodeIfPresent(String.self, forKey: .morningUnlockedDayKey)
        wokeAt = try container.decodeIfPresent([String: Date].self, forKey: .wokeAt) ?? [:]
        contracts = try container.decodeIfPresent([Contract].self, forKey: .contracts) ?? []
        weights = try container.decodeIfPresent([String: Double].self, forKey: .weights) ?? [:]
        tokenDebt = try container.decodeIfPresent(Int.self, forKey: .tokenDebt) ?? 0
        restDaysForfeited = try container.decodeIfPresent([String: Int].self, forKey: .restDaysForfeited) ?? [:]
        homeSet = try container.decodeIfPresent(Bool.self, forKey: .homeSet) ?? false
        homeEvents = try container.decodeIfPresent([HomeEvent].self, forKey: .homeEvents) ?? []
        morningDoneDays = try container.decodeIfPresent([String].self, forKey: .morningDoneDays) ?? []
        log = try container.decodeIfPresent([String: String].self, forKey: .log) ?? [:]
        eatOutMarks = try container.decodeIfPresent([String: Bool].self, forKey: .eatOutMarks) ?? [:]
        caffeineMarks = try container.decodeIfPresent([String: Bool].self, forKey: .caffeineMarks) ?? [:]
        wholeFoodsMarks = try container.decodeIfPresent([String: Bool].self, forKey: .wholeFoodsMarks) ?? [:]
        travelMarks = try container.decodeIfPresent([String: Bool].self, forKey: .travelMarks) ?? [:]
        studyMarks = try container.decodeIfPresent([String: Bool].self, forKey: .studyMarks) ?? [:]
        customHabits = try container.decodeIfPresent([CustomHabit].self, forKey: .customHabits) ?? []
        habitRows = try? container.decodeIfPresent([HandHabit].self, forKey: .habitRows)
        rowMarks = (try? container.decodeIfPresent([String: [String: Bool]].self, forKey: .rowMarks)) ?? [:]
        homeByTimes = (try? container.decodeIfPresent([String: Int].self, forKey: .homeByTimes)) ?? [:]
        screenTimeCaps = (try? container.decodeIfPresent([String: Int].self, forKey: .screenTimeCaps)) ?? [:]
    }
}

// MARK: - Morning lock

/// Every app except the allowed ones (Spotify, Strava, The System) is blocked from wake time until the first workout
/// of the day. Wake time is the end of the WHOOP night sleep; without one, the lock starts at 7:00. A wake after 7:00
/// does not move the start: the lock is already on. A rest day (free rest day or Full Recovery) has no lock.
/// No shop item skips it. Any of these ends it: a Hevy workout with a set (stretches count), a Strava activity, or an
/// Apple Health workout of 10 minutes or more, started after waking (after midnight without a wake time).
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
        // Only workouts that start after today's wake (or midnight) count, so yesterday's data never ends today's lock.
        guard habits.morningUnlockedDayKey != today, let dayStart = QuestDay.start(of: today) else { return false }
        let after = habits.wokeAt[today] ?? dayStart
        guard MorningLock.unlockingWorkout(integrations, after: after) != nil else { return false }
        habits.morningUnlockedDayKey = today
        habits.morningDoneDays = Array((habits.morningDoneDays + [today]).suffix(60))
        return true
    }
}

// MARK: - Contracts

/// A promise the player signs on purpose, checked each quest week until an end date the player picks.
/// It cannot be changed or cancelled before the end date. It is one of two kinds:
/// - a habit (a Systems row or one the player types in) that must pass on at least `daysPerWeek` days a week;
/// - body weight on the right side of a straight line from the start weight to the target.
/// The player picks the punishment at signing; the app takes it for each broken week. No partners: the app enforces it.
struct Contract: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case habit
        /// Body weight on or under a straight line from the start weight to the target on the end date.
        case bodyWeight
        var id: String { rawValue }
        var label: String {
            switch self {
            case .habit: "Habit"
            case .bodyWeight: "Body weight"
            }
        }
    }

    /// One judged week.
    struct Check: Codable, Equatable {
        /// The last quest day of the period: a Sunday, or the end date.
        var endDayKey: String
        /// The line on that day, in lb. 0 for a habit contract.
        var lineLb: Double
        /// The average of the period's weigh-ins. Nil when there was none.
        var averageLb: Double?
        var kept: Bool
        /// A habit contract's passed days and the days it needed in the period.
        var passedDays: Int? = nil
        var requiredDays: Int? = nil
    }

    var id: String
    var kind: Kind
    var startDayKey: String
    var endDayKey: String
    var startLb: Double
    var targetLb: Double
    var signedAt: Date
    var checks: [Check] = []
    /// The habit: a `ContractHabits` key. Nil for body weight.
    var habitKey: String? = nil
    /// The habit's name when signed.
    var habitName: String? = nil
    /// Passed days a full week needs, 1...7. A short first or last week needs its share, rounded up.
    var daysPerWeek = 7
    /// What each broken week costs.
    var punishment = Punishment.classic

    init(id: String, kind: Kind, startDayKey: String, endDayKey: String, startLb: Double = 0, targetLb: Double = 0, signedAt: Date,
         habitKey: String? = nil, habitName: String? = nil, daysPerWeek: Int = 7, punishment: Punishment = .classic) {
        self.id = id
        self.kind = kind
        self.startDayKey = startDayKey
        self.endDayKey = endDayKey
        self.startLb = startLb
        self.targetLb = targetLb
        self.signedAt = signedAt
        self.habitKey = habitKey
        self.habitName = habitName
        self.daysPerWeek = daysPerWeek
        self.punishment = punishment
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, startDayKey, endDayKey, startLb, targetLb, signedAt, checks, habitKey, habitName, daysPerWeek, punishment
    }

    /// A contract saved before habits and punishments existed is a body weight contract with the old stake.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        startDayKey = try container.decode(String.self, forKey: .startDayKey)
        endDayKey = try container.decode(String.self, forKey: .endDayKey)
        startLb = try container.decodeIfPresent(Double.self, forKey: .startLb) ?? 0
        targetLb = try container.decodeIfPresent(Double.self, forKey: .targetLb) ?? 0
        signedAt = try container.decode(Date.self, forKey: .signedAt)
        checks = try container.decodeIfPresent([Check].self, forKey: .checks) ?? []
        habitKey = try container.decodeIfPresent(String.self, forKey: .habitKey)
        habitName = try container.decodeIfPresent(String.self, forKey: .habitName)
        daysPerWeek = try container.decodeIfPresent(Int.self, forKey: .daysPerWeek) ?? 7
        punishment = try container.decodeIfPresent(Punishment.self, forKey: .punishment) ?? .classic
    }

    /// Passed days a period from `start` to `end` needs: the weekly number, scaled to a short period and rounded up.
    func requiredDays(start: String, end: String) -> Int {
        guard let from = QuestDay.date(from: start), let to = QuestDay.date(from: end) else { return daysPerWeek }
        let length = Int((to.timeIntervalSince(from) / 86_400).rounded()) + 1
        return min(length, Int((Double(daysPerWeek * length) / 7).rounded(.up)))
    }

    var title: String {
        switch kind {
        case .habit: "\(habitName ?? "Habit"): \(daysPerWeek)/7 days a week until \(Contract.dateText(endDayKey))"
        case .bodyWeight: "Reach \(Contract.number(targetLb)) lb by \(Contract.dateText(endDayKey))"
        }
    }

    /// The rule in words, for the sign screen and the record.
    var terms: String {
        if kind == .habit {
            let days = daysPerWeek == 7 ? "every day" : "on at least \(daysPerWeek) of 7 days"
            let name = habitName.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? "the habit"
            return "Each week, from \(Contract.dateText(startDayKey)) to \(Contract.dateText(endDayKey)), \(name) must pass \(days). "
                + "A short first or last week needs its share of days. " + ContractHabits.source(habitKey ?? "")
        }
        let side = startLb > 0 && targetLb > startLb ? "on or over" : "on or under"
        let from = startLb > 0 ? "\(Contract.number(startLb)) lb" : "your start weight"
        return "Each week, from \(Contract.dateText(startDayKey)) to \(Contract.dateText(endDayKey)), your average weigh-in must be \(side) "
            + "a straight line from \(from) to \(Contract.number(targetLb)) lb. A week with no weigh-in is broken. "
            + "Weigh-ins come from Apple Health or Log weigh-in on the contract."
    }

    /// The general rule, for the contracts screen.
    static let rules = "A promise you cannot cancel. Each broken week, the app takes the punishment you picked."

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
        if punishment.isEmpty { return "Pick at least one punishment." }
        if endDayKey <= QuestDay.key(byAddingDays: 6, to: startDayKey) { return "Pick an end date at least a week away." }
        if kind == .habit {
            guard let habitKey, !habitKey.isEmpty else { return "Pick a habit." }
            let name = (habitName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { return "Type a name for the habit." }
            if name.count > CustomHabit.maxNameLength { return "Keep the habit name to \(CustomHabit.maxNameLength) characters." }
            if !(1...7).contains(daysPerWeek) { return "Pick 1 to 7 days a week." }
            return nil
        }
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

/// The body weight contract the app offers until one is signed: 145 lb by May 1, 2027.
/// The player types the start weight and picks the punishment at signing.
enum WeightGoal {
    static let targetLb = 145.0
    static let endDayKey = "2027-05-01"
}

/// What a broken contract week costs. The player picks it at signing; the app takes it.
struct Punishment: Codable, Equatable {
    /// Full Recovery tokens taken. With none in the bank, the next ones earned are taken.
    var tokens = 0
    /// Rest days taken: this week's, else next week's.
    var restDays = 0
    /// Opens the penalty 10K run at once.
    var penaltyRun = false

    /// The stake contracts had before punishments could be picked.
    static let classic = Punishment(tokens: 1, restDays: 1)

    var isEmpty: Bool { tokens <= 0 && restDays <= 0 && !penaltyRun }

    /// "1 Full Recovery token, 1 rest day and the penalty 10K run".
    var text: String {
        var parts: [String] = []
        if tokens > 0 { parts.append("\(tokens) Full Recovery token\(tokens == 1 ? "" : "s")") }
        if restDays > 0 { parts.append("\(restDays) rest day\(restDays == 1 ? "" : "s")") }
        if penaltyRun { parts.append("the penalty 10K run") }
        guard let last = parts.popLast() else { return "nothing" }
        return parts.isEmpty ? last : parts.joined(separator: ", ") + " and " + last
    }

    var sentence: String { "Each broken week costs \(text)." }
}

/// The habits a contract can be about: the Systems rows the app checks, the hand-marked rows, and a new one the player types.
enum ContractHabits {
    static let homeBy = "homeBy"
    static let screenTime = "screenTime"
    static let log = "log"
    static let stretching = "stretching"
    /// A new habit, typed in at signing. Signing turns it into a custom habit and a Systems row.
    static let new = "new"

    /// Key and name of each habit the player can pick, in Systems order, then "New habit".
    static func options(_ habits: HabitState) -> [(key: String, name: String)] {
        [(homeBy, "Home by")] + habits.allHandHabits.filter { $0.endDay == nil }.map { ($0.id, $0.name) } + [(new, "New habit…")]
    }

    /// Where the day's pass comes from, in words.
    static func source(_ key: String) -> String {
        switch key {
        case homeBy: "The app checks it from your location at your Home by time. A day with no Home by row fails."
        case screenTime: "The app checks it from the Screen Time row."
        case log: "A day passes when you write the log."
        case stretching: "The app checks it from the Stretching row (Hevy)."
        default: "You mark each day Pass or Fail on the Systems page. A day you do not mark fails."
        }
    }
}

extension GameSnapshot {
    /// True when the contract habit passed on a quest day. A day with no record fails.
    func habitPassed(_ key: String, on dayKey: String) -> Bool {
        let rows = dayKey == bundle.dayKey ? GameSnapshot.questRecords(of: bundle) : questHistory.first { $0.dayKey == dayKey }?.quests ?? []
        switch key {
        case ContractHabits.homeBy: return rows.contains { $0.method == .homeBy && $0.status == .completed }
        case ContractHabits.screenTime: return rows.contains { $0.method == .screenTimeLimit && $0.status == .completed }
        case ContractHabits.log: return habits.log[dayKey] != nil
        case ContractHabits.stretching: return rows.contains { $0.params[DailyStretch.dayParam] != nil && $0.status == .completed }
        default:
            // A hand habit: a past day without a mark has its default (fail, or pass for a limit habit).
            guard let habit = habits.allHandHabits.first(where: { $0.id == key }) else { return false }
            return habit.passed(on: dayKey, marks: habits.marks(habit), today: QuestDay.key(byAddingDays: 1, to: dayKey)) == true
        }
    }

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
        contract.habitName = contract.habitName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if contract.kind == .bodyWeight { contract.habitKey = nil; contract.habitName = nil }
        if let problem = contract.problem { return problem }
        // A new habit must not share a name with a Systems row.
        let isNew = contract.kind == .habit && contract.habitKey == ContractHabits.new
        if isNew, let name = contract.habitName,
           ContractHabits.options(habits).contains(where: { $0.key != ContractHabits.new && $0.name.lowercased() == name.lowercased() }) {
            return "\(name) is already a Systems row. Pick it from the list."
        }
        if let active = habits.contracts.last(where: { $0.kind == contract.kind && $0.habitKey == contract.habitKey && $0.isActive(on: bundle.dayKey) }),
           !isNew {
            return "A contract on \(active.kind == .habit ? active.habitName ?? "this habit" : "body weight") is already active. "
                + "It ends on \(Contract.dateText(active.endDayKey))."
        }
        if isNew, let name = contract.habitName {
            let custom = CustomHabit(id: contract.id, name: name, createdDayKey: bundle.dayKey)
            habits.customHabits.append(custom)
            contract.habitKey = custom.handHabit.id
        }
        habits.contracts.append(contract)
        return nil
    }

    /// Saves a weigh-in the player typed, as today's. 50 to 500 lb. Returns false when refused.
    @discardableResult
    mutating func logWeighIn(_ lb: Double) -> Bool {
        guard (50...500).contains(lb) else { return false }
        habits.weights[bundle.dayKey] = (lb * 10).rounded() / 10
        return true
    }

    /// This week's weigh-ins for a weight contract: their average and the line at the week's end. Nil when the contract
    /// has no period this week.
    func weightWeek(_ contract: Contract) -> (average: Double?, lineLb: Double, onTrack: Bool?)? {
        let today = bundle.dayKey
        guard contract.kind == .bodyWeight, let period = contract.periods.first(where: { $0.start <= today && today <= $0.end }) else { return nil }
        let values = habits.weights.filter { $0.key >= period.start && $0.key <= today }.map(\.value)
        let average = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        let line = contract.lineLb(on: period.end)
        let losing = contract.targetLb < contract.startLb
        return (average, line, average.map { losing ? $0 <= line + 0.05 : $0 >= line - 0.05 })
    }

    /// Saves the newest weigh-in of each quest day.
    mutating func recordWeights(_ readings: [BodyMassReading]) {
        for reading in readings.sorted(by: { $0.date < $1.date }) where reading.kg > 0 {
            habits.weights[QuestDay.key(for: reading.date)] = (reading.pounds * 10).rounded() / 10
        }
        let oldest = QuestDay.key(byAddingDays: -400, to: bundle.dayKey)
        habits.weights = habits.weights.filter { $0.key >= oldest }
    }

    /// Judges each period that has ended and takes the punishment for each broken one. Returns the broken contract weeks.
    /// `catalog` is needed only for a punishment that opens the penalty run.
    @discardableResult
    mutating func judgeContracts(now: Date, catalog: FallbackCatalog? = nil) -> [Contract] {
        let today = QuestDay.key(for: now)
        var broken: [Contract] = []
        for index in habits.contracts.indices {
            let contract = habits.contracts[index]
            for period in contract.periods where period.end < today && !contract.checks.contains(where: { $0.endDayKey == period.end }) {
                if contract.kind == .habit {
                    var day = period.start
                    var passed = 0
                    while day <= period.end {
                        if habitPassed(contract.habitKey ?? "", on: day) { passed += 1 }
                        day = QuestDay.key(byAddingDays: 1, to: day)
                    }
                    let required = contract.requiredDays(start: period.start, end: period.end)
                    let kept = passed >= required
                    habits.contracts[index].checks.append(Contract.Check(endDayKey: period.end, lineLb: 0, averageLb: nil, kept: kept,
                                                                         passedDays: passed, requiredDays: required))
                    if !kept {
                        broken.append(contract)
                        takePunishment(contract.punishment, today: today, catalog: catalog, now: now)
                    }
                    continue
                }
                let weighIns = habits.weights.filter { $0.key >= period.start && $0.key <= period.end }.map(\.value)
                let average = weighIns.isEmpty ? nil : weighIns.reduce(0, +) / Double(weighIns.count)
                let line = contract.lineLb(on: period.end)
                let losing = contract.targetLb < contract.startLb
                let kept = average.map { losing ? $0 <= line + 0.05 : $0 >= line - 0.05 } ?? false
                habits.contracts[index].checks.append(Contract.Check(endDayKey: period.end, lineLb: (line * 10).rounded() / 10,
                                                                     averageLb: average.map { ($0 * 10).rounded() / 10 }, kept: kept))
                if !kept {
                    broken.append(contract)
                    takePunishment(contract.punishment, today: today, catalog: catalog, now: now)
                }
            }
        }
        payTokenDebt()
        return broken
    }

    /// Takes a broken week's punishment: tokens (or a debt on the next ones), rest days (this week's,
    /// else next week's), and the penalty run.
    private mutating func takePunishment(_ punishment: Punishment, today: String, catalog: FallbackCatalog?, now: Date) {
        habits.tokenDebt += max(punishment.tokens, 0)
        let week = RestDays.weekKey(of: today)
        for _ in 0..<max(punishment.restDays, 0) {
            let left = max(RestDays.allowance(on: today) - restDaysUsed(on: today) - restDaysForfeited(on: today), 0)
            let target = left > 0 ? week : QuestDay.key(byAddingDays: 7, to: week)
            habits.restDaysForfeited[target, default: 0] += 1
        }
        habits.restDaysForfeited = habits.restDaysForfeited.filter { $0.key >= QuestDay.key(byAddingDays: -21, to: week) }
        if punishment.penaltyRun, PenaltyHold.active(on: today), let catalog {
            player.penaltyOpen = true
            // The contract's penalty: late work on the day that waits must not lift it.
            endedDay?.monthPenalty = true
            bundle = PenaltyQuests.ensure(in: bundle, open: true, band: trainingBand, catalog: catalog, now: now)
        }
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

/// A Systems row, not a quest: the phone is at home at the player's time (9:00 pm until changed), every day.
/// Its row on the day is a background row: the quest list does not show it, and a miss opens no penalty.
/// The row starts the day after the player sets a home. It is judged at 9:00 pm: home then completes it,
/// anywhere else fails it, and a failed row opens a penalty at the day's end like any required quest.
enum HomeBy {
    static let questId = "daily_home_by_9"
    /// 9:00 pm, the time until the player picks another one.
    static let defaultMinutes = 21 * 60
    /// The times the player can pick: noon to 11:45 pm, in steps of 15 minutes.
    static let minutesRange = (12 * 60)...(23 * 60 + 45)
    static let step = 15
    static let title = title(defaultMinutes)

    /// "Home by 9 pm", "Home by 10:30 pm".
    static func title(_ minutes: Int) -> String { "Home by \(timeText(minutes))" }

    /// "9 pm", "10:30 pm", "12 pm".
    static func timeText(_ minutes: Int) -> String {
        let hour = minutes / 60, minute = minutes % 60
        let shown = hour % 12 == 0 ? 12 : hour % 12
        return minute == 0 ? "\(shown) \(hour < 12 ? "am" : "pm")" : String(format: "%d:%02d %@", shown, minute, hour < 12 ? "am" : "pm")
    }

    /// The row's time on the quest day.
    static func deadline(_ dayKey: String, minutes: Int = defaultMinutes) -> Date? {
        QuestDay.start(of: dayKey)?.addingTimeInterval(Double(minutes - QuestDay.startHour * 60) * 60)
    }

    /// The time a row was made with. Rows from before the setting existed are 9:00 pm.
    static func minutes(of quest: Quest) -> Int {
        quest.verification.params["minutes"]?.doubleValue.map { Int($0) } ?? defaultMinutes
    }

    /// Home or not at a moment: the newest event at or before it. Nil with no event before it.
    static func home(at date: Date, events: [HomeEvent]) -> Bool? {
        events.filter { $0.at <= date }.max { $0.at < $1.at }?.inside
    }

    static func quest(mode: QuestMode, minutes: Int = defaultMinutes, now: Date) -> Quest {
        Quest(
            id: questId,
            title: title(minutes),
            kind: .daily,
            stat: .REC,
            verification: VerificationSpec(method: .homeBy, params: ["hour": .number(Double(minutes / 60)), "minutes": .number(Double(minutes))]),
            deadline: QuestDay.endOfDay(now),
            difficulty: .normal,
            mode: mode,
            progress: QuestProgress(current: 0, target: 1, unit: ""),
            status: .pending,
            assignedAt: now
        )
    }

    /// Adds the row once, before Stretching and after the other required rows.
    static func ensure(in bundle: QuestBundle, homeSet: Bool, minutes: Int = defaultMinutes, now: Date) -> QuestBundle {
        guard homeSet, !bundle.quests.contains(where: { $0.id == questId }) else { return bundle }
        var copy = bundle
        let insertAt = copy.quests.firstIndex { $0.id == DailyStretch.questId }
            ?? copy.quests.lastIndex(where: { $0.kind != .optional }).map { $0 + 1 } ?? copy.quests.count
        copy.quests.insert(quest(mode: bundle.mode, minutes: minutes, now: now), at: insertAt)
        return copy
    }
}

extension GameSnapshot {
    /// Moves the row: before 9:00 pm it shows home or not; at 9:00 pm it completes at home and fails elsewhere.
    mutating func applyHomeBy(now: Date) {
        guard let index = bundle.quests.firstIndex(where: { $0.id == HomeBy.questId }), bundle.quests[index].status == .pending,
              let deadline = HomeBy.deadline(bundle.dayKey, minutes: HomeBy.minutes(of: bundle.quests[index])) else { return }
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
        guard let row = bundle.quests.first(where: { $0.id == HomeBy.questId }),
              let deadline = HomeBy.deadline(bundle.dayKey, minutes: HomeBy.minutes(of: row)) else { return }
        applyHomeBy(now: deadline)
    }

    /// True when today's Home by 9 pm row is not done. A rest day does not waive it.
    var homeByMissed: Bool {
        bundle.quests.contains { $0.id == HomeBy.questId && $0.status != .completed }
    }

    /// A new Home by time from tomorrow. Refused while a penalty is open. Returns why it was refused, or nil.
    /// The Systems row starts a new streak on the day the new time starts.
    mutating func setHomeByTime(_ minutes: Int) -> String? {
        guard HomeBy.minutesRange.contains(minutes), minutes % HomeBy.step == 0 else { return "Pick a time from 12 pm to 11:45 pm." }
        if player.penaltyOpen { return "A penalty is open. You cannot change the Home by time until it is done." }
        let tomorrow = QuestDay.key(byAddingDays: 1, to: bundle.dayKey)
        if habits.homeByMinutes(on: tomorrow) == minutes { return nil }
        // A pick equal to today's time takes back a change that has not started: no change, no new streak.
        if minutes == habits.homeByMinutes(on: bundle.dayKey) {
            habits.homeByTimes[tomorrow] = nil
        } else {
            habits.homeByTimes[tomorrow] = minutes
        }
        return nil
    }
}

extension HabitState {
    /// The Home by time on a quest day: the newest change on or before it.
    func homeByMinutes(on dayKey: String) -> Int {
        homeByTimes.filter { $0.key <= dayKey }.max { $0.key < $1.key }?.value ?? HomeBy.defaultMinutes
    }

    /// The Screen Time limit on a quest day: the newest change on or before it.
    func screenTimeCap(on dayKey: String) -> Int {
        screenTimeCaps.filter { $0.key <= dayKey }.max { $0.key < $1.key }?.value ?? ScreenTime.totalCapMinutes
    }

    /// The first day of the Home by streak: the newest change that has started. Nil: no change yet.
    func homeByStreakStart(on dayKey: String) -> String? {
        homeByTimes.keys.filter { $0 <= dayKey }.max()
    }
}

// MARK: - Behavior log

/// One short note a day: what I did that could be better. Optional, never a penalty.
enum BehaviorLog {
    static let maxLength = 1_000
    static let keepDays = 365
}

extension GameSnapshot {
    /// Saves today's note. An empty note removes it.
    mutating func setLogNote(_ text: String) {
        let note = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(BehaviorLog.maxLength))
        let today = bundle.dayKey
        habits.log[today] = note.isEmpty ? nil : note
        let oldest = QuestDay.key(byAddingDays: -BehaviorLog.keepDays, to: today)
        habits.log = habits.log.filter { $0.key >= oldest }
    }
}

// MARK: - Systems view

/// The habits as streaks, the 1% steps of each day, ahead of the levels. One row a habit, one dot a day for 28 days.
enum SystemsView {
    static let days = 28

    enum Mark: Equatable {
        case done, missed, none
    }

    struct Track: Equatable, Identifiable {
        var name: String
        /// Oldest first, today last.
        var marks: [Mark]
        /// The quest day of each mark, oldest first.
        var dayKeys: [String] = []
        /// Set when the player marks each day by hand: a tap picks Pass or Fail.
        var handHabit: HandHabit? = nil
        /// Shown in place of the streak when set: "1/2 travel days".
        var summary: String? = nil
        /// Today's quest day. Only today can be marked by hand.
        var today: String? = nil
        var id: String { handHabit?.id ?? name }

        /// Passes out of the days the habit was judged: done or missed, up to the 28 days in view.
        /// Nil before its first judged day. A day not judged yet, like today before its mark, does not count.
        var passRate: Double? {
            let judged = marks.filter { $0 != .none }
            guard !judged.isEmpty else { return nil }
            return Double(judged.filter { $0 == .done }.count) / Double(judged.count)
        }

        /// Active: a pass rate of 90% or more over the judged days in view.
        var isActive: Bool { (passRate ?? 0) >= SystemsView.activeRate }

        /// Done days in a row, ending today or yesterday (today may still be open).
        var streak: Int {
            var marks = self.marks
            if marks.last != .done { marks = Array(marks.dropLast()) }
            return marks.reversed().prefix { $0 == .done }.count
        }
    }

    /// The pass rate a habit needs to count as active.
    static let activeRate = 0.9

    static func tracks(_ game: GameSnapshot) -> [Track] {
        let today = game.bundle.dayKey
        let keys = (0..<days).map { QuestDay.key(byAddingDays: $0 - (days - 1), to: today) }
        let history = Dictionary(game.questHistory.map { ($0.dayKey, $0.quests) }, uniquingKeysWith: { first, _ in first })
        let todayRows = GameSnapshot.questRecords(of: game.bundle)
        func rows(_ key: String) -> [QuestRecord]? { key == today ? todayRows : history[key] }
        /// A day's mark from its rows of one kind: done when all are completed, missed when one failed or the day ended open.
        func mark(_ key: String, _ match: (QuestRecord) -> Bool) -> Mark {
            guard let list = rows(key)?.filter(match), !list.isEmpty else { return .none }
            if list.allSatisfy({ $0.status == .completed }) { return .done }
            return key == today && !list.contains(where: { $0.status == .failed }) ? .none : .missed
        }
        // A hand-marked day shows its mark. A past day without one fails; today stays open until marked.
        // Days before the rule started stay dim.
        func hand(_ habit: HandHabit) -> Track {
            let saved = game.habits.marks(habit)
            // A limit habit shows this quest week, Monday to Sunday, and the days used.
            let week = RestDays.weekKey(of: today)
            let days = habit.weeklyLimit == nil ? keys : (0..<7).map { QuestDay.key(byAddingDays: $0, to: week) }
            // Screen Time and Stretching were checked by the app before they were marked by hand: those days keep the app's mark.
            let checked = HandHabit.recordMatch(habit.id)
            let marks = days.map { key -> Mark in
                if key > today { return .none }
                if key < habit.firstDay, let checked { return mark(key, checked) }
                return habit.passed(on: key, marks: saved, today: today).map { $0 ? .done : .missed } ?? .none
            }
            let summary = habit.weeklyLimit.map { limit in
                "\(saved.filter { $0.value && $0.key >= week && $0.key <= today }.count)/\(limit) days"
            }
            return Track(name: habit.name, marks: marks, dayKeys: days, handHabit: habit, summary: summary, today: today)
        }
        // Home by: a new time starts a new streak, so the days before it stay dim.
        let homeStart = game.habits.homeByStreakStart(on: today)
        let home = Track(name: HomeBy.title(game.habits.homeByMinutes(on: today)), marks: keys.map { key in
            homeStart.map { key < $0 } == true ? .none : mark(key) { $0.method == .homeBy }
        })
        let screen = Track(name: ScreenTime.title, marks: keys.map { mark($0) { $0.method == .screenTimeLimit } })
        return [home, screen] + game.habits.handHabits(on: today).map(hand)
    }
}

/// A habit the player marks by hand on the systems view: tap a day, then Pass or Fail. A past day without a mark fails.
/// The built-in ones, the custom ones typed in for a contract (id "custom:<uuid>"), and the ones added in the habit
/// editor (id "row:<uuid>"). The editor saves the whole list in `HabitState.habitRows`.
struct HandHabit: Codable, Hashable {
    var id: String
    var name: String
    /// The first quest day the habit counts. Earlier days stay dim.
    var firstDay: String
    /// Set for a limit habit (Traveling): a mark means the day was used (traveled), up to this many days a quest week.
    /// A used day within the limit passes, one past it fails, and a day without a mark passes.
    var weeklyLimit: Int? = nil
    /// The first ending day whose fail opens the penalty. Nil: a fail never opens one.
    var penaltyFrom: String? = nil
    /// The first day a fail no longer opens the penalty, after the player turned it off.
    var penaltyEnd: String? = nil
    /// The first day the row is gone, after the player removed it. Earlier days still count.
    var endDay: String? = nil

    /// The two choices of the tap dialog: the label for true, then for false.
    var choices: (yes: String, no: String) { weeklyLimit == nil ? ("Pass", "Fail") : ("Did it", "Did not") }

    /// The row is on the Systems page on this day: it was not removed before it.
    func isShown(on dayKey: String) -> Bool { endDay.map { dayKey < $0 } ?? true }

    /// A fail on this day opens the penalty (with the rule of two misses in a row).
    func opensPenalty(on dayKey: String) -> Bool {
        guard let penaltyFrom, dayKey >= penaltyFrom, dayKey >= firstDay, isShown(on: dayKey) else { return false }
        return penaltyEnd.map { dayKey < $0 } ?? true
    }

    /// The penalty setting from tomorrow on: on, unless it is off or was turned off.
    var penaltyOnFromTomorrow: Bool { penaltyFrom != nil && penaltyEnd == nil }

    /// The day's pass from the marks. Nil for a day with no mark that is still open (today) or before the first day.
    func passed(on dayKey: String, marks: [String: Bool], today: String) -> Bool? {
        if dayKey < firstDay { return nil }
        if let limit = weeklyLimit {
            if marks[dayKey] != true { return dayKey < today || marks[dayKey] == false ? true : nil }
            let week = RestDays.weekKey(of: dayKey)
            let used = marks.filter { $0.value && $0.key >= week && $0.key <= dayKey }.count
            return used <= limit
        }
        if let mark = marks[dayKey] { return mark }
        return dayKey < today ? false : nil
    }

    static let builtInFirstDay = "2026-11-18"
    static let noEatingOut = HandHabit(id: "noEatingOut", name: "No eating out", firstDay: builtInFirstDay, penaltyFrom: penaltyFirstDay)
    static let noCaffeine = HandHabit(id: "noCaffeine", name: "No caffeine", firstDay: builtInFirstDay, penaltyFrom: penaltyFirstDay)
    static let wholeFoods = HandHabit(id: "wholeFoods", name: "Only whole foods", firstDay: builtInFirstDay, penaltyFrom: penaltyFirstDay)
    /// Two study blocks of 1 hour each. Added 2026-11-19: that day shows its mark, but only from 2026-11-20 a fail opens the penalty.
    static let study = HandHabit(id: "study", name: "Study (2× 1 h blocks)", firstDay: "2026-11-19", penaltyFrom: "2026-11-20")
    static let builtIns = [noEatingOut, noCaffeine, wholeFoods, study]
    /// The day Screen Time and Stretching became hand-marked rows. Earlier days keep the app's mark.
    static let handMarkedFrom = "2026-11-21"
    static let stretching = HandHabit(id: rowPrefix + "stretching", name: DailyStretch.title, firstDay: handMarkedFrom)
    /// Rows every list holds first, until the player removes them.
    static let systemRows = [stretching]
    /// Screen Time was a hand-marked row for a few hours on 2026-11-21. It is checked by the app again.
    static let retiredIds: Set<String> = [rowPrefix + "screenTime"]

    /// For the rows the app checked before they were marked by hand: the day's quest rows that held them.
    static func recordMatch(_ id: String) -> ((QuestRecord) -> Bool)? {
        switch id {
        case stretching.id: { $0.params[DailyStretch.dayParam] != nil }
        default: nil
        }
    }
    /// The first ending day whose failed habit opens the penalty (added 2026-11-19).
    static let penaltyFirstDay = "2026-11-19"
    static let customPrefix = "custom:"
    /// Rows added in the habit editor.
    static let rowPrefix = "row:"
}

/// A habit the player typed in when signing a contract. It stays a Systems row after the contract ends.
struct CustomHabit: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var createdDayKey: String
    /// By quest day: true passed, false failed.
    var marks: [String: Bool] = [:]

    static let maxNameLength = 40

    var handHabit: HandHabit { HandHabit(id: HandHabit.customPrefix + id, name: name, firstDay: createdDayKey) }
}

extension HabitState {
    /// Every hand-marked row, removed ones too, in the player's order. Contract habits the list does not hold yet
    /// come last. Removed rows still count for the days before they went.
    var allHandHabits: [HandHabit] {
        let saved = (habitRows ?? HandHabit.builtIns).filter { !HandHabit.retiredIds.contains($0.id) }
        let rows = HandHabit.systemRows.filter { row in !saved.contains { $0.id == row.id } } + saved
        return rows + customHabits.map(\.handHabit).filter { custom in !rows.contains { $0.id == custom.id } }
    }

    /// The rows on the Systems page on `dayKey`.
    func handHabits(on dayKey: String) -> [HandHabit] { allHandHabits.filter { $0.isShown(on: dayKey) } }

    func marks(_ habit: HandHabit) -> [String: Bool] { marks(id: habit.id) }

    func marks(id: String) -> [String: Bool] {
        switch id {
        case HandHabit.noEatingOut.id: return eatOutMarks
        case HandHabit.noCaffeine.id: return caffeineMarks
        case HandHabit.wholeFoods.id: return wholeFoodsMarks
        case HandHabit.study.id: return studyMarks
        case _ where id.hasPrefix(HandHabit.rowPrefix): return rowMarks[id] ?? [:]
        default:
            let custom = id.hasPrefix(HandHabit.customPrefix) ? String(id.dropFirst(HandHabit.customPrefix.count)) : id
            return customHabits.first { $0.id == custom }?.marks ?? [:]
        }
    }
}

extension GameSnapshot {
    /// Marks a day of a hand habit: true passed, false failed. Days after today cannot be marked.
    /// Built-in marks older than 60 days are dropped; a custom habit keeps 400 days for its contracts.
    mutating func setHandMark(_ habit: HandHabit, _ dayKey: String, passed: Bool) {
        guard dayKey <= bundle.dayKey else { return }
        var marks = habits.marks(habit)
        marks[dayKey] = passed
        switch habit.id {
        case HandHabit.noEatingOut.id: habits.eatOutMarks = marks.filter { $0.key >= QuestDay.key(byAddingDays: -60, to: bundle.dayKey) }
        case HandHabit.noCaffeine.id: habits.caffeineMarks = marks.filter { $0.key >= QuestDay.key(byAddingDays: -60, to: bundle.dayKey) }
        case HandHabit.wholeFoods.id: habits.wholeFoodsMarks = marks.filter { $0.key >= QuestDay.key(byAddingDays: -60, to: bundle.dayKey) }
        case HandHabit.study.id: habits.studyMarks = marks.filter { $0.key >= QuestDay.key(byAddingDays: -60, to: bundle.dayKey) }
        case _ where habit.id.hasPrefix(HandHabit.rowPrefix):
            habits.rowMarks[habit.id] = marks.filter { $0.key >= QuestDay.key(byAddingDays: -400, to: bundle.dayKey) }
        default:
            let custom = String(habit.id.dropFirst(HandHabit.customPrefix.count))
            guard let index = habits.customHabits.firstIndex(where: { $0.id == custom }) else { return }
            habits.customHabits[index].marks = marks.filter { $0.key >= QuestDay.key(byAddingDays: -400, to: bundle.dayKey) }
        }
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

enum HabitRules {
    static func check() -> [String] {
        var errors: [String] = []
        let catalog = FallbackCatalog.bundled()
        guard let monday = QuestDay.date(from: "2026-11-16") else { return ["could not build habit dates"] }
        // Morning lock: from 7:00 or an earlier wake, until a workout started after waking. Off on rest days.
        let seven = (QuestDay.start(of: "2026-11-16") ?? monday).addingTimeInterval(7 * 3600)
        if MorningLock.start(dayKey: "2026-11-16", wokeAt: nil) != seven
            || MorningLock.start(dayKey: "2026-11-16", wokeAt: seven.addingTimeInterval(-3600)) != seven.addingTimeInterval(-3600)
            || MorningLock.start(dayKey: "2026-11-16", wokeAt: seven.addingTimeInterval(3600)) != seven {
            errors.append("the morning lock should start at 7:00, or at an earlier wake time")
        }
        var lock = GameSnapshot.fresh(catalog: catalog, now: monday)
        if lock.morningLockOn(now: seven.addingTimeInterval(-60)) || !lock.morningLockOn(now: seven) {
            errors.append("the morning lock should hold from 7:00")
        }
        // A failed built-in habit opens the penalty as its day ends. Stretching never does.
        if let thursday = QuestDay.date(from: "2026-11-19"), let friday = QuestDay.date(from: "2026-11-20") {
            var day = GameSnapshot.fresh(catalog: catalog, now: thursday.addingTimeInterval(9 * 3600))
            for habit in HandHabit.builtIns where habit.weeklyLimit == nil { day.setHandMark(habit, day.bundle.dayKey, passed: true) }
            if !day.failedHabits(on: day.bundle.dayKey).isEmpty { errors.append("passed habits and no travel should not fail") }
            day.setHandMark(.noCaffeine, day.bundle.dayKey, passed: false)
            if day.failedHabits(on: day.bundle.dayKey).map(\.id) != [HandHabit.noCaffeine.id] { errors.append("a Fail mark should fail its habit") }
            var unmarked = day
            unmarked.habits.wholeFoodsMarks = [:]
            unmarked.setHandMark(.noCaffeine, unmarked.bundle.dayKey, passed: true)
            if unmarked.failedHabits(on: unmarked.bundle.dayKey).map(\.id) != [HandHabit.wholeFoods.id] { errors.append("a day left unmarked should fail") }
            // One miss is free. A second miss in a row opens the penalty, and the third starts a new pair.
            day.refreshIfNeeded(catalog: catalog, now: friday.addingTimeInterval(9 * 3600))
            if !day.penaltyHabits(on: "2026-11-19").isEmpty { errors.append("one failed habit day should not open the penalty") }
            for habit in HandHabit.builtIns where habit.weeklyLimit == nil { day.setHandMark(habit, day.bundle.dayKey, passed: true) }
            day.setHandMark(.noCaffeine, day.bundle.dayKey, passed: false)
            var passedBetween = day
            passedBetween.setHandMark(.noCaffeine, "2026-11-19", passed: true)
            if !passedBetween.penaltyHabits(on: day.bundle.dayKey).isEmpty { errors.append("a pass between two misses should reset the count") }
            day.refreshIfNeeded(catalog: catalog, now: friday.addingTimeInterval(33 * 3600))
            if !day.player.penaltyOpen || PenaltyQuests.rows(in: day.bundle).isEmpty || day.penaltyHabits(on: "2026-11-20").map(\.id) != [HandHabit.noCaffeine.id] {
                errors.append("a habit failed two days in a row should open the penalty")
            }
            for habit in HandHabit.builtIns where habit.weeklyLimit == nil { day.setHandMark(habit, day.bundle.dayKey, passed: habit != .noCaffeine) }
            if !day.penaltyHabits(on: day.bundle.dayKey).isEmpty { errors.append("a third miss in a row should start a new pair") }
            day.refreshIfNeeded(catalog: catalog, now: friday.addingTimeInterval(57 * 3600))
            for habit in HandHabit.builtIns where habit.weeklyLimit == nil { day.setHandMark(habit, day.bundle.dayKey, passed: habit != .noCaffeine) }
            if day.penaltyHabits(on: day.bundle.dayKey).map(\.id) != [HandHabit.noCaffeine.id] {
                errors.append("a fourth miss in a row should open the next penalty")
            }
            if !day.failedHabits(on: "2026-11-18").isEmpty { errors.append("days before the rule should not fail") }
            // Study shows a Fail on its first day, but the penalty starts the next day.
            var study = GameSnapshot.fresh(catalog: catalog, now: thursday.addingTimeInterval(9 * 3600))
            for habit in HandHabit.builtIns where habit.weeklyLimit == nil { study.setHandMark(habit, study.bundle.dayKey, passed: true) }
            study.setHandMark(.study, study.bundle.dayKey, passed: false)
            if SystemsView.tracks(study).first(where: { $0.handHabit == .study })?.marks.last != .missed || !study.failedHabits(on: study.bundle.dayKey).isEmpty {
                errors.append("a Study Fail on 2026-11-19 should show red and not open the penalty")
            }
            var stretch = QuestBundle.empty
            stretch.quests = [DailyStretch.quest(mode: .performanceTraining, now: thursday)]
            if !stretch.openRequired.isEmpty { errors.append("an open Stretching row should not open a penalty") }
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
        if !firstBroken.isEmpty || signer.habits.contracts[0].checks.first?.kept != true {
            errors.append("a week under the line should be kept, got \(signer.habits.contracts[0].checks)")
        }
        let weekThree = (QuestDay.start(of: QuestDay.key(byAddingDays: 14, to: today)) ?? monday).addingTimeInterval(3600)
        signer.bundle.dayKey = QuestDay.key(for: weekThree)
        if signer.judgeContracts(now: weekThree).count != 1 || signer.habits.tokenDebt != 1
            || signer.restDaysForfeited(on: QuestDay.key(for: weekThree)) != 1 || !signer.judgeContracts(now: weekThree).isEmpty {
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

        // A habit contract: a new typed habit becomes a Systems row; a week passes with enough marked days; the picked
        // punishment is taken: 2 tokens owed and the penalty run opened.
        var habitSigner = GameSnapshot.fresh(catalog: catalog, now: monday)
        habitSigner.player.fullRecoveryBank = 0
        let habitDraft = Contract(id: "h1", kind: .habit, startDayKey: "", endDayKey: QuestDay.key(byAddingDays: 20, to: today), signedAt: monday,
                                  habitKey: ContractHabits.new, habitName: "  Read 20 pages ", daysPerWeek: 5,
                                  punishment: Punishment(tokens: 2, penaltyRun: true))
        var noPunishment = habitDraft
        noPunishment.punishment = Punishment()
        var duplicate = habitDraft
        duplicate.habitName = "no caffeine"
        if habitSigner.signContract(noPunishment, now: monday) == nil || habitSigner.signContract(duplicate, now: monday) == nil
            || habitSigner.signContract(habitDraft, now: monday) != nil {
            errors.append("a habit contract needs a punishment and a new name, and should then sign")
        }
        let reading = habitSigner.habits.customHabits.first?.handHabit
        let habitContract = habitSigner.habits.contracts.last
        if reading?.name != "Read 20 pages" || habitContract?.habitKey != reading?.id
            || SystemsView.tracks(habitSigner).contains(where: { $0.handHabit?.id == reading?.id }) != true
            || habitContract?.requiredDays(start: today, end: QuestDay.key(byAddingDays: 6, to: today)) != 5
            || habitContract?.requiredDays(start: today, end: QuestDay.key(byAddingDays: 2, to: today)) != 3 {
            errors.append("a new habit should become a Systems row, and a short week should need its share of days")
        }
        if let reading {
            for offset in 0..<5 { habitSigner.bundle.dayKey = QuestDay.key(byAddingDays: offset, to: today); habitSigner.setHandMark(reading, habitSigner.bundle.dayKey, passed: true) }
            habitSigner.bundle.dayKey = QuestDay.key(byAddingDays: 7, to: today)
            let keptWeek = habitSigner.judgeContracts(now: weekTwo, catalog: catalog)
            habitSigner.bundle.dayKey = QuestDay.key(for: weekThree)
            let brokenWeek = habitSigner.judgeContracts(now: weekThree, catalog: catalog)
            let checks = habitSigner.habits.contracts.last?.checks ?? []
            if !keptWeek.isEmpty || brokenWeek.count != 1 || checks.map(\.kept) != [true, false] || checks.first?.passedDays != 5
                || habitSigner.habits.tokenDebt != 2 || !habitSigner.player.penaltyOpen {
                errors.append("a 5-of-7 habit week should pass with 5 marks, and a week with none should take the picked punishment, got \(checks)")
            }
        }
        if Punishment(tokens: 1, restDays: 2, penaltyRun: true).text != "1 Full Recovery token, 2 rest days and the penalty 10K run" {
            errors.append("the punishment text is wrong: \(Punishment(tokens: 1, restDays: 2, penaltyRun: true).text)")
        }
        // An old saved contract loads as body weight with the old stake.
        let oldJSON = #"{"id":"o","kind":"bodyWeight","startDayKey":"2026-11-16","endDayKey":"2026-12-16","startLb":150,"targetLb":145,"signedAt":0,"checks":[]}"#
        if (try? JSONDecoder().decode(Contract.self, from: Data(oldJSON.utf8)))?.punishment != .classic {
            errors.append("an old contract should load with the old stake")
        }

        // A typed weigh-in counts as today's and shows on or off track for the week.
        var weigher = GameSnapshot.fresh(catalog: catalog, now: monday)
        _ = weigher.signContract(Contract(id: "w", kind: .bodyWeight, startDayKey: "", endDayKey: WeightGoal.endDayKey, startLb: 160,
                                          targetLb: WeightGoal.targetLb, signedAt: monday), now: monday)
        let noneYet = weigher.weightWeek(weigher.habits.contracts[0])
        if weigher.logWeighIn(20) || !weigher.logWeighIn(159.96) || weigher.habits.weights[weigher.bundle.dayKey] != 160
            || noneYet?.average != nil || noneYet?.onTrack != nil
            || weigher.weightWeek(weigher.habits.contracts[0])?.onTrack != false {
            errors.append("a typed weigh-in should be saved as today's, and 160 lb should be off the line by the week's end")
        }
        weigher.logWeighIn(150)
        if weigher.weightWeek(weigher.habits.contracts[0])?.onTrack != true { errors.append("150 lb should be on track") }

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

        // The log keeps one trimmed note a day; an empty note removes it.
        var noted = GameSnapshot.fresh(catalog: catalog, now: monday)
        noted.setLogNote("  Ate out alone. ")
        let afterNote = noted.habits.log[noted.bundle.dayKey]
        noted.setLogNote("")
        if afterNote != "Ate out alone." || noted.habits.log[noted.bundle.dayKey] != nil {
            errors.append("the log should keep a trimmed note and remove an empty one")
        }
        // Systems view: 28 days a habit (7 for a weekly limit). The log has no row: it is not written from the app.
        let tracked = GameSnapshot.fresh(catalog: catalog, now: monday)
        let tracks = SystemsView.tracks(tracked)
        if tracks.map(\.name) != ["Home by 9 pm", "Screen Time", "Stretching", "No eating out", "No caffeine", "Only whole foods",
                                    "Study (2× 1 h blocks)"]
            || tracks.contains(where: { $0.marks.count != ($0.handHabit?.weeklyLimit == nil ? SystemsView.days : 7) }) {
            errors.append("the systems view should show 7 habits of 28 days, got \(tracks.map(\.name))")
        }
        // Active: 90% or more of the judged days passed. Days with no mark do not count.
        let ninety = SystemsView.Track(name: "a", marks: [.none, .none] + Array(repeating: .done, count: 9) + [.missed])
        let eighty = SystemsView.Track(name: "b", marks: Array(repeating: .done, count: 8) + [.missed, .missed, .none])
        let unjudged = SystemsView.Track(name: "c", marks: [.none, .none])
        if ninety.passRate != 0.9 || !ninety.isActive || eighty.isActive || unjudged.passRate != nil || unjudged.isActive {
            errors.append("a habit should be active at a 90% pass rate of its judged days only")
        }

        // Hand habits: dim before the first day, red for an unmarked past day, open today until marked, and each mark shows.
        if SystemsView.tracks(tracked).first(where: { $0.name == "No eating out" })?.marks.allSatisfy({ $0 == .none }) != true {
            errors.append("No eating out should stay dim before its first day")
        }
        if let later = QuestDay.date(from: "2026-11-20") {
            var ate = GameSnapshot.fresh(catalog: catalog, now: later)
            for habit in [HandHabit.noEatingOut, .noCaffeine, .wholeFoods] {
                let start = SystemsView.tracks(ate).first { $0.handHabit == habit }
                ate.setHandMark(habit, "2026-11-19", passed: true)
                ate.setHandMark(habit, "2026-11-20", passed: true)
                let passed = SystemsView.tracks(ate).first { $0.handHabit == habit }
                ate.setHandMark(habit, "2026-11-20", passed: false)
                ate.setHandMark(habit, "2026-11-21", passed: true)
                let failed = SystemsView.tracks(ate).first { $0.handHabit == habit }
                if start?.marks.suffix(4) != [.none, .missed, .missed, .none] || start?.dayKeys.last != "2026-11-20" || start?.name != habit.name
                    || passed?.marks.suffix(3) != [.missed, .done, .done] || passed?.streak != 2
                    || failed?.marks.suffix(2) != [.done, .missed] || failed?.streak != 1
                    || ate.habits.marks(habit) != ["2026-11-19": true, "2026-11-20": false] {
                    errors.append("\(habit.name) should fail unmarked past days and show each mark, got \(String(describing: failed?.marks.suffix(4)))")
                }
            }
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
