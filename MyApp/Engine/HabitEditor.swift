import Foundation

/// The habit editor: the player adds, removes, renames, and orders the hand-marked Systems rows, and picks for each
/// one whether a fail can open the penalty.
///
/// The app holds the player to the rules, so a change cannot help on a bad day:
/// - A new row, a removal, and a penalty switch (on or off) start tomorrow. Today is judged by today's rules.
/// - While a penalty is open, no row can be removed and no penalty can be turned off.
/// - A row that an active contract checks cannot be removed.
/// A new row's type (Pass or Fail, or at most N days a week) is set when it is added.
enum HabitEditor {
    /// The most rows the Systems page shows by hand.
    static let maxRows = 12
    static let maxLimit = 6
    static let rules = "A new row, a removal, and a penalty change start tomorrow. "
        + "While a penalty is open, you cannot remove a row or turn a penalty off. "
        + "A row that an active contract checks stays until the contract ends."

    static func check() -> [String] {
        var errors: [String] = []
        let catalog = FallbackCatalog.bundled()
        guard let monday = QuestDay.date(from: "2026-11-23") else { return ["could not build editor dates"] }
        var game = GameSnapshot.fresh(catalog: catalog, now: monday)
        let today = game.bundle.dayKey
        let tomorrow = QuestDay.key(byAddingDays: 1, to: today)
        if game.habits.handHabits(on: today).map(\.id) != (HandHabit.systemRows + HandHabit.builtIns).map(\.id) {
            errors.append("an unedited save should show Screen Time, Stretching, and the built-in rows")
        }

        // Add: a Pass or Fail row with the penalty on. It starts tomorrow.
        if game.addHabit(name: "  Read 20 pages ", weeklyLimit: nil, opensPenalty: true) != nil { errors.append("a new habit should be added") }
        guard let read = game.habits.allHandHabits.last, read.name == "Read 20 pages", read.id.hasPrefix(HandHabit.rowPrefix) else {
            return errors + ["the new habit should be the last row, trimmed, with a row id"]
        }
        if read.firstDay != tomorrow || read.penaltyFrom != tomorrow || read.opensPenalty(on: today) || !read.opensPenalty(on: tomorrow) {
            errors.append("a new habit should start tomorrow, with its penalty from tomorrow")
        }
        if game.addHabit(name: "read 20 PAGES", weeklyLimit: nil, opensPenalty: false) == nil { errors.append("a second row with the same name should be refused") }
        if game.addHabit(name: " ", weeklyLimit: nil, opensPenalty: false) == nil { errors.append("an empty name should be refused") }
        if game.addHabit(name: "Dessert", weeklyLimit: 2, opensPenalty: false) != nil { errors.append("a limit habit should be added") }

        // Its marks are kept under its own id, and a fail opens no penalty while it is off.
        game.setHandMark(read, today, passed: false)
        if game.habits.marks(read)[today] != false { errors.append("a new row should keep its marks") }

        // Rename and order change at once.
        if game.renameHabit(id: read.id, name: "Read 30 pages") != nil || game.habits.allHandHabits.last(where: { $0.id == read.id })?.name != "Read 30 pages" {
            errors.append("a rename should change the name at once")
        }
        game.moveHabit(id: read.id, by: -1)
        if game.habits.handHabits(on: today).suffix(3).map(\.name) != ["Read 30 pages", HandHabit.study.name, "Dessert"] {
            errors.append("a move should change the order, got \(game.habits.handHabits(on: today).map(\.name))")
        }

        // Penalty off: it still counts today and stops tomorrow. Refused while a penalty is open.
        var penalized = game
        penalized.player.penaltyOpen = true
        if penalized.setHabitPenalty(id: HandHabit.noCaffeine.id, on: false) == nil || penalized.removeHabit(id: HandHabit.noCaffeine.id) == nil {
            errors.append("a penalty off or a removal should be refused while a penalty is open")
        }
        if game.setHabitPenalty(id: HandHabit.noCaffeine.id, on: false) != nil { errors.append("a penalty off should be taken") }
        let caffeine = game.habits.allHandHabits.first { $0.id == HandHabit.noCaffeine.id }
        if caffeine?.opensPenalty(on: today) != true || caffeine?.opensPenalty(on: tomorrow) != false || caffeine?.penaltyOnFromTomorrow != false {
            errors.append("a penalty turned off should count today and stop tomorrow")
        }
        _ = game.setHabitPenalty(id: HandHabit.noCaffeine.id, on: true)
        if game.habits.allHandHabits.first(where: { $0.id == HandHabit.noCaffeine.id })?.opensPenalty(on: tomorrow) != true {
            errors.append("a penalty turned on again before it stopped should stay on")
        }

        // Remove: today stays on the page and still counts; tomorrow the row is gone. A row not started yet goes at once.
        if game.removeHabit(id: HandHabit.wholeFoods.id) != nil { errors.append("a removal should be taken") }
        let foods = game.habits.allHandHabits.first { $0.id == HandHabit.wholeFoods.id }
        if !game.habits.handHabits(on: today).contains(where: { $0.id == HandHabit.wholeFoods.id })
            || game.habits.handHabits(on: tomorrow).contains(where: { $0.id == HandHabit.wholeFoods.id }) || foods?.opensPenalty(on: today) != true {
            errors.append("a removed row should stay and count today, and be gone tomorrow")
        }
        _ = game.removeHabit(id: read.id)
        if game.habits.allHandHabits.contains(where: { $0.id == read.id }) || game.habits.rowMarks[read.id] != nil {
            errors.append("a row removed before its first day should go at once, with its marks")
        }

        // A row an active contract checks stays.
        var signed = GameSnapshot.fresh(catalog: catalog, now: monday)
        let contract = Contract(id: "c1", kind: .habit, startDayKey: "", endDayKey: QuestDay.key(byAddingDays: 20, to: today), signedAt: monday,
                                habitKey: HandHabit.study.id, habitName: HandHabit.study.name, daysPerWeek: 5, punishment: Punishment(tokens: 1))
        if let refused = signed.signContract(contract, now: monday) { errors.append("the editor check's contract should sign: \(refused)") }
        if signed.removeHabit(id: HandHabit.study.id) == nil { errors.append("a row an active contract checks should not be removed") }

        // Screen Time and Stretching are marked by hand. Days before the switch keep the app's mark.
        var hand = GameSnapshot.fresh(catalog: catalog, now: monday)
        hand.setHandMark(.screenTime, today, passed: true)
        hand.setHandMark(.stretching, today, passed: false)
        let handTracks = SystemsView.tracks(hand)
        if handTracks.first(where: { $0.handHabit == .screenTime })?.marks.last != .done
            || handTracks.first(where: { $0.handHabit == .stretching })?.marks.last != .missed
            || handTracks.filter({ $0.name == "Screen Time" || $0.name == DailyStretch.title }).count != 2 {
            errors.append("Screen Time and Stretching should be one hand-marked row each, got \(handTracks.map(\.name))")
        }
        if HandHabit.screenTime.opensPenalty(on: tomorrow) || HandHabit.stretching.opensPenalty(on: tomorrow) {
            errors.append("Screen Time and Stretching rows should open no penalty")
        }

        // Home by: a new time starts tomorrow, renames the row, and starts a new streak. A pick of today's time takes it back.
        var homeBy = GameSnapshot.fresh(catalog: catalog, now: monday)
        if homeBy.setHomeByTime(22 * 60 + 30) != nil || homeBy.habits.homeByMinutes(on: today) != HomeBy.defaultMinutes
            || homeBy.habits.homeByMinutes(on: tomorrow) != 22 * 60 + 30 {
            errors.append("a new Home by time should start tomorrow")
        }
        if HomeBy.title(22 * 60 + 30) != "Home by 10:30 pm" || HomeBy.title(HomeBy.defaultMinutes) != "Home by 9 pm" {
            errors.append("the Home by title should read the time, got \(HomeBy.title(22 * 60 + 30))")
        }
        if HomeBy.quest(mode: .performanceTraining, minutes: 22 * 60 + 30, now: monday).title != "Home by 10:30 pm"
            || HomeBy.deadline(tomorrow, minutes: 22 * 60 + 30) != QuestDay.start(of: tomorrow)?.addingTimeInterval(22.5 * 3600) {
            errors.append("the Home by row should be judged at its own time")
        }
        if homeBy.habits.homeByStreakStart(on: tomorrow) != tomorrow || homeBy.habits.homeByStreakStart(on: today) != nil {
            errors.append("a new Home by time should start a new streak on its first day")
        }
        _ = homeBy.setHomeByTime(HomeBy.defaultMinutes)
        if !homeBy.habits.homeByTimes.isEmpty { errors.append("a pick of today's time should take back the change") }
        var lockedTime = homeBy
        lockedTime.player.penaltyOpen = true
        if lockedTime.setHomeByTime(23 * 60) == nil || homeBy.setHomeByTime(23 * 60 + 50) == nil {
            errors.append("a Home by change should be refused while a penalty is open, and off the 15-minute steps")
        }

        // The saved list loads back.
        if let data = try? JSONEncoder().encode(game.habits), let loaded = try? JSONDecoder().decode(HabitState.self, from: data) {
            if loaded.habitRows != game.habits.habitRows { errors.append("the edited rows should load back") }
        } else {
            errors.append("the habit state should save and load")
        }
        return errors
    }
}

extension GameSnapshot {
    private var tomorrowKey: String { QuestDay.key(byAddingDays: 1, to: bundle.dayKey) }

    /// Changes the saved list. The first edit saves the list the page shows now.
    private mutating func editRows(_ change: (inout [HandHabit]) -> Void) {
        var rows = habits.allHandHabits
        change(&rows)
        habits.habitRows = rows
    }

    private func cleanName(_ name: String, except id: String? = nil) -> (String?, String?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return (nil, "Type a name for the habit.") }
        if trimmed.count > CustomHabit.maxNameLength { return (nil, "Keep the name to \(CustomHabit.maxNameLength) characters.") }
        let taken = habits.handHabits(on: bundle.dayKey).contains { $0.id != id && $0.name.lowercased() == trimmed.lowercased() }
            || trimmed.lowercased().hasPrefix("home by")
        if taken { return (nil, "\(trimmed) is already a Systems row.") }
        return (trimmed, nil)
    }

    /// Adds a row from tomorrow. `weeklyLimit` nil is Pass or Fail; a number is "at most that many days a week".
    /// Returns why it was refused, or nil.
    mutating func addHabit(name: String, weeklyLimit: Int?, opensPenalty: Bool) -> String? {
        let (clean, problem) = cleanName(name)
        guard let clean else { return problem }
        if habits.handHabits(on: tomorrowKey).count >= HabitEditor.maxRows { return "The Systems page holds \(HabitEditor.maxRows) habit rows. Remove one first." }
        if let weeklyLimit, !(1...HabitEditor.maxLimit).contains(weeklyLimit) { return "Pick 1 to \(HabitEditor.maxLimit) days a week." }
        let row = HandHabit(id: HandHabit.rowPrefix + UUID().uuidString, name: clean, firstDay: tomorrowKey, weeklyLimit: weeklyLimit,
                            penaltyFrom: opensPenalty ? tomorrowKey : nil)
        editRows { $0.append(row) }
        return nil
    }

    mutating func renameHabit(id: String, name: String) -> String? {
        let (clean, problem) = cleanName(name, except: id)
        guard let clean else { return problem }
        editRows { rows in
            if let index = rows.firstIndex(where: { $0.id == id }) { rows[index].name = clean }
        }
        return nil
    }

    /// The row goes from tomorrow; today stays and counts. A row that has not started yet goes at once.
    mutating func removeHabit(id: String) -> String? {
        if player.penaltyOpen { return "A penalty is open. You cannot remove a habit until it is done." }
        let today = bundle.dayKey
        if let contract = habits.contracts.first(where: { $0.habitKey == id && $0.isActive(on: today) }) {
            return "A contract checks this habit until \(Contract.dateText(contract.endDayKey)). It stays until then."
        }
        guard let row = habits.allHandHabits.first(where: { $0.id == id }), row.isShown(on: tomorrowKey) else { return nil }
        if row.firstDay > today {
            editRows { $0.removeAll { $0.id == id } }
            habits.rowMarks[id] = nil
            return nil
        }
        let tomorrow = tomorrowKey
        editRows { rows in
            if let index = rows.firstIndex(where: { $0.id == id }) { rows[index].endDay = tomorrow }
        }
        return nil
    }

    /// On or off from tomorrow. Off is refused while a penalty is open.
    mutating func setHabitPenalty(id: String, on: Bool) -> String? {
        guard let row = habits.allHandHabits.first(where: { $0.id == id }), row.penaltyOnFromTomorrow != on else { return nil }
        if !on, player.penaltyOpen { return "A penalty is open. You cannot turn a habit's penalty off until it is done." }
        let tomorrow = tomorrowKey, today = bundle.dayKey
        editRows { rows in
            guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
            if on {
                // Turned off but still on today: it simply stays on.
                if let end = rows[index].penaltyEnd, end == tomorrow, rows[index].penaltyFrom != nil {
                    rows[index].penaltyEnd = nil
                } else {
                    rows[index].penaltyFrom = tomorrow
                    rows[index].penaltyEnd = nil
                }
            } else if let from = rows[index].penaltyFrom, from > today {
                // Not started yet: it never starts.
                rows[index].penaltyFrom = nil
            } else {
                rows[index].penaltyEnd = tomorrow
            }
        }
        return nil
    }

    /// Moves a shown row up (`by` -1) or down (+1) among the rows shown today.
    mutating func moveHabit(id: String, by offset: Int) {
        let shown = habits.handHabits(on: bundle.dayKey).map(\.id)
        guard let at = shown.firstIndex(of: id), shown.indices.contains(at + offset) else { return }
        let other = shown[at + offset]
        editRows { rows in
            guard let a = rows.firstIndex(where: { $0.id == id }), let b = rows.firstIndex(where: { $0.id == other }) else { return }
            rows.swapAt(a, b)
        }
    }
}
