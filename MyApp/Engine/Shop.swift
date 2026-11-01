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

/// One potion per stat that has a forced daily quest. INT has none: reading is never forced.
/// You buy a potion at the moment you drink it. A day that uses any potion pays no gold.
enum Potion: String, Codable, CaseIterable, Equatable {
    case gildedIndulgence, nightfall, idleHours, ironblood, secondWind, quicksilver

    var stat: Stat {
        switch self {
        case .gildedIndulgence: .FIN
        case .nightfall: .REC
        case .idleHours: .FOC
        case .ironblood: .STR
        case .secondWind: .END
        case .quicksilver: .AGI
        }
    }

    init?(stat: Stat) {
        guard let potion = Potion.allCases.first(where: { $0.stat == stat }) else { return nil }
        self = potion
    }

    var name: String {
        switch self {
        case .gildedIndulgence: "Gilded Indulgence Philter"
        case .nightfall: "Insomniac's Elixir"
        case .idleHours: "Veil of Hours"
        case .ironblood: "Ironblood Draught"
        case .secondWind: "Second Wind Tonic"
        case .quicksilver: "Quicksilver Vial"
        }
    }

    var rank: String {
        switch self {
        case .gildedIndulgence: "S-rank"
        case .nightfall: "A-rank"
        case .idleHours: "B-rank"
        case .ironblood, .secondWind: "C-rank"
        case .quicksilver: "E-rank"
        }
    }

    var details: String {
        switch self {
        case .gildedIndulgence:
            "\(rank). Gold dust in a sealed flask. Spend up to \(FinanceLevel.usd(Self.indulgenceUsd)) over budget today. The ledger does not count it."
        case .nightfall:
            "\(rank). Eyes stay open until dawn. No quest is skipped. The sleepless night and tomorrow's tired morning do not count against REC."
        case .idleHours:
            "\(rank). A grey veil over the clock. Lifts today's screen time cap. The lost hours do not count against FOC."
        case .ironblood:
            "\(rank). Hot iron poured into tired muscle. Skips today's lifting session. The body still remembers the debt."
        case .secondWind:
            "\(rank). Breath returns to burning lungs. Skips today's run. The road waits for tomorrow."
        case .quicksilver:
            "\(rank). Liquid motion in a glass vial. Skips today's stretch."
        }
    }

    /// Price before the repeat rule.
    var basePrice: Int {
        switch self {
        case .gildedIndulgence: 25_000
        case .nightfall: 8_000
        case .idleHours: 6_000
        case .ironblood, .secondWind: 3_600
        case .quicksilver: 1_200
        }
    }

    /// Days after a use before this potion can be used again. Nil means no limit.
    var cooldownDays: Int? {
        switch self {
        case .gildedIndulgence: 30
        case .nightfall, .idleHours: 14
        case .ironblood, .secondWind, .quicksilver: nil
        }
    }

    /// These potions clear the stat's open daily quests, so they need one. FIN has no daily quest.
    var needsQuest: Bool { self == .ironblood || self == .secondWind || self == .quicksilver }

    /// Dollars of spending the FIN potion excuses from the month.
    static let indulgenceUsd = 150.0
    /// Each use in this many days raises the next price by 50%.
    static let repeatWindowDays = 30
}

struct PotionUse: Codable, Equatable {
    var dayKey: String
    var potion: Potion
}

/// Days and dollars that potions remove from the FOC, REC, and FIN scores.
struct PotionExcuses: Equatable {
    var focusDayKeys: Set<String> = []
    var recoveryDayKeys: Set<String> = []
    /// "YYYY-MM" → excused dollars.
    var spendUsdByMonth: [String: Double] = [:]

    static let none = PotionExcuses()

    func excusing(_ month: FinanceMonth) -> FinanceMonth {
        var copy = month
        copy.spendingUsd = max(0, month.spendingUsd - (spendUsdByMonth[month.month] ?? 0))
        return copy
    }
}

extension GameSnapshot {
    var potionUsedToday: Bool {
        potionLog.contains { $0.dayKey == bundle.dayKey }
    }

    /// Every required quest of the day is done by real work. A potion, a Full Recovery, or a failed emergency breaks it.
    var isPerfectDay: Bool {
        guard bundle.mode != .fullRecovery, !signals.spendingFullRecovery, fullRecoveryDayKey != bundle.dayKey,
              emergencyFailedDayKey != bundle.dayKey, !potionUsedToday else { return false }
        let required = bundle.quests.filter { $0.kind != .optional }
        return !required.isEmpty && required.allSatisfy { $0.status == .completed && !$0.skippedWithPotion }
    }

    /// Pays the day that is ending. Runs once per day from `refreshIfNeeded`.
    mutating func awardDayGold() {
        lastGoldReward = nil
        guard isPerfectDay else { return }
        let amount = Gold.reward(for: bundle.dayKey)
        gold += amount
        lastGoldReward = GoldReward(dayKey: bundle.dayKey, amount: amount)
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
        let repeats = uses(of: potion, sinceDaysAgo: Potion.repeatWindowDays).count
        let price = base * pow(1.5, Double(repeats))
        return Int((price / 10).rounded()) * 10
    }

    /// Open daily quests the potion would clear today.
    func potionTargets(_ potion: Potion) -> [Quest] {
        guard bundle.mode != .fullRecovery else { return [] }
        return bundle.quests.filter { $0.kind == .daily && $0.stat == potion.stat && $0.status != .completed }
    }

    /// Why the potion cannot be used now, or nil when it can.
    func potionBlocker(_ potion: Potion) -> String? {
        if player.penaltyOpen { return "The shop is closed during a penalty." }
        if potionUsedToday { return "One potion per day. You already used one today." }
        if let cooldown = potion.cooldownDays, let last = uses(of: potion, sinceDaysAgo: cooldown).last {
            let ready = QuestDay.key(byAddingDays: cooldown, to: last.dayKey)
            return "\(potion.name) is on cooldown until \(ready)."
        }
        let targets = potionTargets(potion)
        if potion.needsQuest && targets.isEmpty { return "There is no open \(potion.stat.rawValue) quest today." }
        let price = potionPrice(potion)
        if gold < price { return "Not enough gold. \(potion.name) costs \(price) gold. You have \(gold)." }
        return nil
    }

    /// Buys and drinks one potion. Clears the stat's open quests and records the excuse.
    mutating func usePotion(_ potion: Potion) -> String {
        if let blocker = potionBlocker(potion) { return blocker }
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
        potionLog.append(PotionUse(dayKey: bundle.dayKey, potion: potion))
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
            case .gildedIndulgence:
                let month = String(use.dayKey.prefix(7))
                excuses.spendUsdByMonth[month, default: 0] += Potion.indulgenceUsd
            case .ironblood, .secondWind, .quicksilver:
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
        if Potion(stat: .INT) != nil || Potion.allCases.count != Stat.allCases.count - 1 {
            errors.append("every stat except INT needs exactly one potion")
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

        // A perfect day pays gold once. A missed day pays nothing.
        var perfect = GameSnapshot.fresh(catalog: catalog, now: dayOne)
        finishRequired(&perfect, now: dayOne)
        let dayKey = perfect.bundle.dayKey
        perfect.refreshIfNeeded(catalog: catalog, now: dayTwo)
        perfect.refreshIfNeeded(catalog: catalog, now: dayTwo.addingTimeInterval(600))
        if perfect.gold != Gold.reward(for: dayKey) || perfect.lastGoldReward?.dayKey != dayKey {
            errors.append("a perfect day should pay \(Gold.reward(for: dayKey)) gold once, got \(perfect.gold)")
        }
        var missed = GameSnapshot.fresh(catalog: catalog, now: dayOne)
        missed.refreshIfNeeded(catalog: catalog, now: dayTwo)
        if missed.gold != 0 || missed.lastGoldReward != nil {
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
        if shop.potionBlocker(.gildedIndulgence) == nil {
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
        _ = excuse.usePotion(.nightfall)
        let excuses = excuse.potionExcuses
        if !excuses.recoveryDayKeys.contains(dayKey) || !excuses.recoveryDayKeys.contains(QuestDay.key(byAddingDays: 1, to: dayKey)) {
            errors.append("Insomniac's Elixir should excuse the night and the next morning from REC")
        }
        finishRequired(&excuse, now: dayOne)
        excuse.refreshIfNeeded(catalog: catalog, now: dayTwo)
        if excuse.potionBlocker(.nightfall)?.contains("cooldown") != true {
            errors.append("Insomniac's Elixir should be on a 14-day cooldown, got \(String(describing: excuse.potionBlocker(.nightfall)))")
        }
        excuse.player.penaltyOpen = true
        if excuse.potionBlocker(.gildedIndulgence)?.contains("penalty") != true || !excuse.buyFullRecovery().contains("penalty") {
            errors.append("the shop should be closed during a penalty")
        }
        excuse.player.penaltyOpen = false
        _ = excuse.usePotion(.gildedIndulgence)
        let month = FinanceMonth(month: String(excuse.bundle.dayKey.prefix(7)), postTaxIncomeUsd: 5_000, spendingUsd: 1_100, budgetUsd: 1_000, complete: true)
        if excuse.potionExcuses.excusing(month).spendingUsd != 1_100 - Potion.indulgenceUsd {
            errors.append("Gilded Indulgence should excuse $\(Int(Potion.indulgenceUsd)), got \(excuse.potionExcuses.excusing(month).spendingUsd)")
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
