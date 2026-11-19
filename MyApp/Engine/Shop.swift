import Foundation

/// Gold one perfect day paid. Kept so the app can show it after the day ends.
struct GoldReward: Codable, Equatable {
    var dayKey: String
    var amount: Int
}

/// A perfect day pays a varied amount of gold. Ten perfect days always buy one Full Recovery.
enum Gold {
    static let fullRecoveryPrice = 10_000
    /// The low end times 10 equals the Full Recovery price, so any 10 perfect days are enough.
    static let perfectDayRange = 1_000...1_400

    /// The same day always pays the same amount, so a reload cannot reroll it.
    static func reward(for dayKey: String) -> Int {
        // FNV-1a: stable across launches, unlike `Hasher`.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in dayKey.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        let span = UInt64(perfectDayRange.count)
        return perfectDayRange.lowerBound + Int(hash % span)
    }
}

/// One potion per stat that has a forced daily quest. INT and FIN have none. The FIN potion, the Gilded Indulgence,
/// was removed on 2026-11-18: FIN no longer reads spending. A saved use of it is dropped on load (`LossyArray`).
/// Rule skips are extra items: each one skips one always-on rule for one day (see `isRuleSkip`).
/// You buy a potion at the moment you drink it. A day that uses any potion pays no gold.
/// Every item has a 36-hour cooldown.
enum Potion: String, Codable, CaseIterable, Equatable {
    case nightfall, idleHours, ironblood, secondWind, quicksilver
    /// Skips tonight's Home by 9 pm, for a night out.
    case moonlitPass

    /// A rule skip, not the stat's potion: the Moonlit Pass clears Home by 9 pm only.
    /// The Banquet Seal left with the eat-out cap on 2026-11-18; a saved use of it is dropped on load.
    var isRuleSkip: Bool { self == .moonlitPass }

    var stat: Stat {
        switch self {
        case .moonlitPass: .REC
        case .nightfall: .REC
        case .idleHours: .FOC
        case .ironblood: .STR
        case .secondWind: .END
        case .quicksilver: .AGI
        }
    }

    init?(stat: Stat) {
        guard let potion = Potion.allCases.first(where: { $0.stat == stat && !$0.isRuleSkip }) else { return nil }
        self = potion
    }

    var name: String {
        switch self {
        case .nightfall: "Insomniac's Elixir"
        case .idleHours: "Veil of Hours"
        case .ironblood: "Ironblood Draught"
        case .secondWind: "Second Wind Tonic"
        case .quicksilver: "Quicksilver Vial"
        case .moonlitPass: "Moonlit Pass"
        }
    }

    /// One line: what the potion does.
    var details: String {
        switch self {
        case .nightfall: "A sleepless night does not count against REC."
        case .idleHours: "No screen time cap today. FOC ignores it."
        case .ironblood: "Skips today's lifts."
        case .secondWind: "Skips today's run."
        case .quicksilver: "Skips today's stretch."
        case .moonlitPass: "Skips tonight's Home by 9 pm, for a night out."
        }
    }

    /// Price before the repeat rule.
    var basePrice: Int {
        switch self {
        case .nightfall: 8_000
        case .idleHours: 6_000
        case .ironblood, .secondWind: 3_600
        case .quicksilver: 1_200
        // About half of a perfect week's gold (7 × 1,200).
        case .moonlitPass: 4_200
        }
    }

    /// Time after a use before the same item can be used again. The same for every item.
    static let cooldown: TimeInterval = 36 * 60 * 60

    /// These potions clear the stat's open daily quests, so they need one.
    var needsQuest: Bool { self == .ironblood || self == .secondWind || self == .quicksilver }

    /// Each use in this many days raises the next price by 50%.
    static let repeatWindowDays = 30
}

struct PotionUse: Codable, Equatable {
    var dayKey: String
    var potion: Potion
    /// When it was used. Nil on a save from before the 36-hour cooldown: the start of its quest day counts.
    var usedAt: Date? = nil

    var time: Date? { usedAt ?? QuestDay.start(of: dayKey) }
}

/// Days that potions remove from the FOC and REC scores.
struct PotionExcuses: Equatable {
    var focusDayKeys: Set<String> = []
    var recoveryDayKeys: Set<String> = []

    static let none = PotionExcuses()
}

extension GameSnapshot {
    var potionUsedToday: Bool {
        potionLog.contains { $0.dayKey == bundle.dayKey }
    }

    /// Every required quest of the day is done by real work. A potion or a Full Recovery breaks it.
    /// The Screen Time row does not count: over the limit it only turns red, and the day keeps its gold.
    var isPerfectDay: Bool {
        guard bundle.mode != .fullRecovery, !signals.spendingFullRecovery, fullRecoveryDayKey != bundle.dayKey,
              !potionUsedToday else { return false }
        let required = bundle.quests.filter { $0.kind != .optional && $0.id != ScreenTime.questId }
        return !required.isEmpty && required.allSatisfy { $0.status == .completed && !$0.skippedWithPotion }
    }

    /// Rewards the day that is ending. Runs once per day from `refreshIfNeeded`. Since 2026-11-18 a day pays in items:
    /// each finished quest drops one (see `Loot`), and a perfect day adds one better item. Gold comes from selling them.
    mutating func awardDayGold() {
        lastGoldReward = nil
        guard isPerfectDay else { return }
        grantPerfectDayItem(dayKey: bundle.dayKey)
    }

    mutating func buyFullRecovery() -> String {
        guard !player.penaltyOpen else { return "The shop is closed during a penalty." }
        guard gold >= Gold.fullRecoveryPrice else {
            return "Not enough gold. Full Recovery costs \(Gold.fullRecoveryPrice) gold. You have \(gold)."
        }
        gold -= Gold.fullRecoveryPrice
        player.depositRecoveryToken()
        return "Bought Full Recovery. \(gold) gold left."
    }

    private func uses(of potion: Potion, sinceDaysAgo days: Int) -> [PotionUse] {
        let cutoff = QuestDay.key(byAddingDays: -days, to: bundle.dayKey)
        return potionLog.filter { $0.potion == potion && $0.dayKey > cutoff && $0.dayKey <= bundle.dayKey }
    }

    /// Base price, then +50% for each use of the same potion in the last 30 days.
    func potionPrice(_ potion: Potion) -> Int {
        let base = Double(potion.basePrice)
        // One day more than the window: a use exactly 30 days ago still counts. The longest cooldown is 30 days too,
        // so without it the first day a potion is free again would never be a repeat.
        let repeats = uses(of: potion, sinceDaysAgo: Potion.repeatWindowDays + 1).count
        let price = base * pow(1.5, Double(repeats))
        return Int((price / 10).rounded()) * 10
    }

    /// Open daily quests the potion would clear today. A rule skip clears none.
    func potionTargets(_ potion: Potion) -> [Quest] {
        // Home by 9 pm holds on every day, a rest day too, so its skip works on any day.
        if potion == .moonlitPass {
            return bundle.quests.filter { $0.id == HomeBy.questId && $0.status == .pending }
        }
        guard bundle.mode != .fullRecovery, !potion.isRuleSkip else { return [] }
        // The 10K that "No gym today" added stands for the lifts. The run potion skips the day's run, not that one.
        return bundle.quests.filter { $0.kind == .daily && $0.stat == potion.stat && $0.status != .completed && !$0.isNoGymRun }
    }

    /// Why the potion cannot be used now, or nil when it can.
    func potionBlocker(_ potion: Potion, now: Date = .now) -> String? {
        if player.penaltyOpen { return "The shop is closed during a penalty." }
        if potionUsedToday { return "One potion per day. You already used one today." }
        if let ready = potionReady(potion), ready > now {
            return "\(potion.name) is on cooldown until \(ready.formatted(date: .abbreviated, time: .shortened))."
        }
        let targets = potionTargets(potion)
        if potion == .moonlitPass && targets.isEmpty {
            return "There is no open Home by 9 pm quest today."
        }
        if potion.needsQuest && targets.isEmpty {
            // The only open run is the 10K that "No gym today" added: it stands for the lifts.
            if bundle.quests.contains(where: { $0.isNoGymRun && $0.stat == potion.stat && $0.status != .completed }) {
                return "The added 10K of a no-gym day takes no potion. It stands for the lifts."
            }
            return "There is no open \(potion.stat.rawValue) quest today."
        }
        let price = potionPrice(potion)
        if gold < price { return "Not enough gold. \(potion.name) costs \(price) gold. You have \(gold)." }
        return nil
    }

    /// When the item's 36-hour cooldown ends, or nil when it was never used.
    func potionReady(_ potion: Potion) -> Date? {
        potionLog.filter { $0.potion == potion }.compactMap(\.time).max().map { $0.addingTimeInterval(Potion.cooldown) }
    }

    /// Buys and drinks one potion. Clears the stat's open quests and records the excuse.
    mutating func usePotion(_ potion: Potion, now: Date = .now) -> String {
        if let blocker = potionBlocker(potion, now: now) { return blocker }
        let price = potionPrice(potion)
        gold -= price
        for quest in potionTargets(potion) {
            guard let index = bundle.quests.firstIndex(where: { $0.id == quest.id }) else { continue }
            var row = bundle.quests[index]
            row.status = .completed
            row.skippedWithPotion = true
            bundle.quests[index] = row
            runningTimers.removeAll { $0.questId == quest.id }
        }
        potionLog.append(PotionUse(dayKey: bundle.dayKey, potion: potion, usedAt: now))
        // One use per day at most, so 400 entries cover more than a year of excuses.
        potionLog = Array(potionLog.suffix(400))
        return "\(potion.name) used for \(price) gold. Today pays no gold. \(gold) gold left."
    }

    var potionExcuses: PotionExcuses {
        var excuses = PotionExcuses()
        for use in potionLog {
            switch use.potion {
            case .idleHours:
                excuses.focusDayKeys.insert(use.dayKey)
            case .nightfall:
                // The night out and the tired morning after it.
                excuses.recoveryDayKeys.insert(use.dayKey)
                excuses.recoveryDayKeys.insert(QuestDay.key(byAddingDays: 1, to: use.dayKey))
            case .ironblood, .secondWind, .quicksilver, .moonlitPass:
                break
            }
        }
        return excuses
    }
}

enum ShopRules {
    static func check() -> [String] {
        var errors: [String] = []
        if Gold.perfectDayRange.lowerBound * 10 < Gold.fullRecoveryPrice {
            errors.append("10 perfect days must always afford one Full Recovery")
        }
        if Potion(stat: .INT) != nil || Potion(stat: .FIN) != nil || Potion.allCases.filter({ !$0.isRuleSkip }).count != Stat.allCases.count - 2 {
            errors.append("every stat except INT and FIN needs exactly one potion")
        }

        // Rewards stay in range, repeat for the same day, and vary across days.
        var amounts: [Int] = []
        var key = "2026-01-01"
        for _ in 0..<365 {
            let amount = Gold.reward(for: key)
            if !Gold.perfectDayRange.contains(amount) || Gold.reward(for: key) != amount {
                errors.append("gold for \(key) should be stable and in range, got \(amount)")
            }
            amounts.append(amount)
            key = QuestDay.key(byAddingDays: 1, to: key)
        }
        if Set(amounts).count < 10 {
            errors.append("daily gold should vary, got \(Set(amounts).count) distinct amounts")
        }
        for start in 0...(amounts.count - 10) where amounts[start..<start + 10].reduce(0, +) < Gold.fullRecoveryPrice {
            errors.append("10 perfect days from day \(start) do not buy a Full Recovery")
            break
        }

        let catalog = FallbackCatalog.bundled()
        guard let dayOne = QuestDay.date(from: "2026-10-01"), let dayTwo = QuestDay.date(from: "2026-10-02") else {
            return errors + ["could not build shop dates"]
        }

        // A perfect day gives its bonus item once, and no gold. A missed day gives no bonus.
        var perfect = GameSnapshot.fresh(catalog: catalog, now: dayOne)
        finishRequired(&perfect, now: dayOne)
        let dayKey = perfect.bundle.dayKey
        perfect.refreshIfNeeded(catalog: catalog, now: dayTwo)
        perfect.refreshIfNeeded(catalog: catalog, now: dayTwo.addingTimeInterval(600))
        if perfect.gold != 0 || perfect.inventory.droppedKeys.filter({ $0.hasPrefix("\(dayKey)|perfect") }).count != 1 {
            errors.append("a perfect day should give one bonus item and no gold, got gold \(perfect.gold)")
        }
        var missed = GameSnapshot.fresh(catalog: catalog, now: dayOne)
        missed.refreshIfNeeded(catalog: catalog, now: dayTwo)
        if missed.gold != 0 || missed.inventory.droppedKeys.contains(where: { $0.contains("|perfect") }) {
            errors.append("a missed day should pay no gold, got \(missed.gold)")
        }

        // Full Recovery needs enough gold and banks one token.
        var shop = GameSnapshot.fresh(catalog: catalog, now: dayOne)
        let bank = shop.player.fullRecoveryBank
        if !shop.buyFullRecovery().contains("Not enough") || shop.player.fullRecoveryBank != bank {
            errors.append("a buy without gold should be refused")
        }
        shop.gold = Gold.fullRecoveryPrice
        _ = shop.buyFullRecovery()
        if shop.gold != 0 || shop.player.fullRecoveryBank != bank + 1 {
            errors.append("buying Full Recovery should cost \(Gold.fullRecoveryPrice) and bank a token")
        }

        // A potion clears every open quest of its stat. One potion per day. The day pays no gold.
        guard let potion = Potion.allCases.first(where: { $0.needsQuest && !shop.potionTargets($0).isEmpty }) else {
            return errors + ["the shop test day needs an open STR, END, or AGI quest"]
        }
        if shop.potionBlocker(potion) == nil {
            errors.append("a potion without gold should be refused")
        }
        shop.gold = 100_000
        let targets = shop.potionTargets(potion).map(\.id)
        _ = shop.usePotion(potion)
        let cleared = shop.bundle.quests.filter { targets.contains($0.id) }
        if cleared.isEmpty || !cleared.allSatisfy({ $0.status == .completed && $0.skippedWithPotion })
            || shop.gold != 100_000 - potion.basePrice {
            errors.append("\(potion.name) should clear its quests for \(potion.basePrice) gold")
        }
        if shop.potionBlocker(.nightfall) == nil {
            errors.append("a second potion on the same day should be refused")
        }
        finishRequired(&shop, now: dayOne)
        let goldBefore = shop.gold
        shop.refreshIfNeeded(catalog: catalog, now: dayTwo)
        if shop.gold != goldBefore || shop.player.penaltyOpen {
            errors.append("a potion day should pay no gold and open no penalty, got gold \(shop.gold - goldBefore) penalty \(shop.player.penaltyOpen)")
        }
        if let title = cleared.first?.title,
           shop.questHistory.first?.quests.first(where: { $0.title == title })?.status != .expired {
            errors.append("history should not count a potion skip as real work")
        }

        // The next use of the same potion within 30 days costs 50% more.
        if shop.potionPrice(potion) != potion.basePrice * 3 / 2 {
            errors.append("a repeat use should cost 150%, got \(shop.potionPrice(potion))")
        }

        // Cooldowns, the penalty lock, and stat excuses.
        var excuse = GameSnapshot.fresh(catalog: catalog, now: dayOne)
        excuse.gold = 100_000
        _ = excuse.usePotion(.nightfall, now: dayOne)
        let excuses = excuse.potionExcuses
        if !excuses.recoveryDayKeys.contains(dayKey) || !excuses.recoveryDayKeys.contains(QuestDay.key(byAddingDays: 1, to: dayKey)) {
            errors.append("Insomniac's Elixir should excuse the night and the next morning from REC")
        }
        finishRequired(&excuse, now: dayOne)
        excuse.refreshIfNeeded(catalog: catalog, now: dayTwo)
        // Every item has a 36-hour cooldown: blocked a day later, free again after 36 hours.
        if excuse.potionBlocker(.nightfall, now: dayTwo)?.contains("cooldown") != true
            || excuse.potionBlocker(.nightfall, now: dayOne.addingTimeInterval(Potion.cooldown + 60)) != nil {
            errors.append("Insomniac's Elixir should be on a 36-hour cooldown, got \(String(describing: excuse.potionBlocker(.nightfall, now: dayTwo)))")
        }
        // A use saved before the cooldown time was kept counts from the start of its quest day.
        var old = excuse
        old.potionLog = [PotionUse(dayKey: dayKey, potion: .ironblood)]
        if old.potionReady(.ironblood) != QuestDay.start(of: dayKey)?.addingTimeInterval(Potion.cooldown) {
            errors.append("an old potion use should count from the start of its day")
        }
        // FIN has no item since the eat-out cap left; the Moonlit Pass is the only rule skip.
        if Potion(stat: .FIN) != nil || Potion.allCases.filter(\.isRuleSkip) != [.moonlitPass] {
            errors.append("the Moonlit Pass should be the only rule skip, and FIN should have no item")
        }
        excuse.player.penaltyOpen = true
        if excuse.potionBlocker(.moonlitPass)?.contains("penalty") != true || !excuse.buyFullRecovery().contains("penalty") {
            errors.append("the shop should be closed during a penalty")
        }
        return errors
    }

    /// Completes every open required quest with its own evidence, as a verifier would.
    private static func finishRequired(_ snapshot: inout GameSnapshot, now: Date) {
        for quest in snapshot.bundle.quests where quest.kind != .optional && quest.status != .completed {
            let evidence = Evidence.make(
                source: "shop_check",
                externalId: "shop:\(quest.id)",
                payload: "shop|\(quest.id)",
                timestamp: now
            )
            snapshot.apply(.completed(evidence: evidence), questId: quest.id, now: now)
        }
    }
}
