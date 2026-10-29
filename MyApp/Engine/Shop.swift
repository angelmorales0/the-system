import Foundation

/// Gold one perfect day paid. Kept so the app can show it after the day ends.
struct GoldReward: Codable, Equatable {
    var dayKey: String
    var amount: Int
}

/// A perfect day pays a varied amount of gold. Ten perfect days always buy one Full Recovery.
/// A potion clears one quest and costs 1/8 of a Full Recovery, about one quest of a full day.
enum Gold {
    static let fullRecoveryPrice = 10_000
    static let potionPrice = fullRecoveryPrice / 8
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

/// Each potion clears one daily quest of its stat. No XP, no stat points, and that day pays no gold.
enum Potion: String, Codable, CaseIterable, Equatable {
    case ironblood, secondWind, quicksilver, sageClarity, stillmind, moonwell, gildedLedger

    var stat: Stat {
        switch self {
        case .ironblood: .STR
        case .secondWind: .END
        case .quicksilver: .AGI
        case .sageClarity: .INT
        case .stillmind: .FOC
        case .moonwell: .REC
        case .gildedLedger: .FIN
        }
    }

    init?(stat: Stat) {
        guard let potion = Potion.allCases.first(where: { $0.stat == stat }) else { return nil }
        self = potion
    }

    var name: String {
        switch self {
        case .ironblood: "Ironblood Draught"
        case .secondWind: "Second Wind Tonic"
        case .quicksilver: "Quicksilver Vial"
        case .sageClarity: "Sage's Clarity Potion"
        case .stillmind: "Stillmind Essence"
        case .moonwell: "Moonwell Restoration Potion"
        case .gildedLedger: "Gilded Ledger Philter"
        }
    }

    var rank: String {
        self == .moonwell ? "B-rank" : "C-rank"
    }

    var details: String {
        switch self {
        case .ironblood:
            "\(rank). Hot iron poured into tired muscle. Clears one STR quest. The body still remembers the debt."
        case .secondWind:
            "\(rank). Breath returns to burning lungs. Clears one END quest. The road waits for tomorrow."
        case .quicksilver:
            "\(rank). Liquid motion in a glass vial. Clears one AGI quest. The legs stay still today."
        case .sageClarity:
            "\(rank). A cold, bright taste of ink. Clears one INT quest. The pages stay unread."
        case .stillmind:
            "\(rank). The noise stops for one breath. Clears one FOC quest. The screen keeps its hold."
        case .moonwell:
            "\(rank). Drawn from still water under a full moon. Clears one REC quest. The body heals without the work."
        case .gildedLedger:
            "\(rank). Gold dust in a sealed flask. Clears one FIN quest. The ledger closes without you."
        }
    }
}

enum ShopItem: Equatable {
    case fullRecovery
    case potion(Potion)

    static var all: [ShopItem] { [.fullRecovery] + Potion.allCases.map { .potion($0) } }

    var price: Int {
        switch self {
        case .fullRecovery: Gold.fullRecoveryPrice
        case .potion: Gold.potionPrice
        }
    }

    var name: String {
        switch self {
        case .fullRecovery: "Full Recovery"
        case .potion(let potion): potion.name
        }
    }

    var details: String {
        switch self {
        case .fullRecovery: "A-rank. One full day of rest. No required quest, no penalty. Banks one Full Recovery token."
        case .potion(let potion): potion.details
        }
    }
}

extension GameSnapshot {
    func potionCount(_ potion: Potion) -> Int {
        potions[potion.rawValue] ?? 0
    }

    /// Every required quest of the day is done by real work. A potion, a Full Recovery, or a failed emergency breaks it.
    var isPerfectDay: Bool {
        guard bundle.mode != .fullRecovery, !signals.spendingFullRecovery, fullRecoveryDayKey != bundle.dayKey,
              emergencyFailedDayKey != bundle.dayKey else { return false }
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

    mutating func buy(_ item: ShopItem) -> String {
        guard gold >= item.price else {
            return "Not enough gold. \(item.name) costs \(item.price) gold. You have \(gold)."
        }
        gold -= item.price
        switch item {
        case .fullRecovery:
            player.depositRecoveryToken()
        case .potion(let potion):
            potions[potion.rawValue, default: 0] += 1
        }
        return "Bought \(item.name). \(gold) gold left."
    }

    /// Clears one open daily quest of the potion's stat. Penalty and optional quests cannot be skipped.
    mutating func drinkPotion(_ potion: Potion, questId: String) -> String {
        guard potionCount(potion) > 0 else { return "No \(potion.name) in your inventory." }
        guard let index = bundle.quests.firstIndex(where: { $0.id == questId }) else { return "That quest is not in today's list." }
        var quest = bundle.quests[index]
        guard bundle.mode != .fullRecovery else { return "Today is a Full Recovery day. There is nothing to skip." }
        guard quest.kind == .daily else { return "A potion cannot clear a penalty or optional quest." }
        guard quest.status != .completed else { return "\(quest.title) is already complete." }
        guard quest.stat == potion.stat else {
            return "\(potion.name) clears only \(potion.stat.rawValue) quests. \(quest.title) is \(quest.stat.rawValue)."
        }
        potions[potion.rawValue] = potionCount(potion) - 1
        quest.status = .completed
        quest.skippedWithPotion = true
        quest.grantedXP = 0
        quest.grantedStatPoints = 0
        bundle.quests[index] = quest
        runningTimers.removeAll { $0.questId == questId }
        return "\(potion.name) used. \(quest.title) is cleared. No XP, and today pays no gold."
    }
}

enum ShopRules {
    static func check() -> [String] {
        var errors: [String] = []
        if Gold.perfectDayRange.lowerBound * 10 < Gold.fullRecoveryPrice {
            errors.append("10 perfect days must always afford one Full Recovery")
        }
        if Gold.potionPrice * 8 != Gold.fullRecoveryPrice {
            errors.append("a potion should cost 1/8 of a Full Recovery, got \(Gold.potionPrice)")
        }
        if Set(Potion.allCases.map(\.stat)).count != Stat.allCases.count {
            errors.append("every stat needs exactly one potion")
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

        // A perfect day pays gold once.
        var perfect = GameSnapshot.fresh(catalog: catalog, now: dayOne)
        finishRequired(&perfect, now: dayOne)
        let dayKey = perfect.bundle.dayKey
        perfect.refreshIfNeeded(catalog: catalog, now: dayTwo)
        if perfect.gold != Gold.reward(for: dayKey) || perfect.lastGoldReward?.dayKey != dayKey {
            errors.append("a perfect day should pay \(Gold.reward(for: dayKey)) gold, got \(perfect.gold)")
        }
        perfect.refreshIfNeeded(catalog: catalog, now: dayTwo.addingTimeInterval(600))
        if perfect.gold != Gold.reward(for: dayKey) {
            errors.append("a day must pay gold only once")
        }

        // A missed day pays nothing.
        var missed = GameSnapshot.fresh(catalog: catalog, now: dayOne)
        missed.refreshIfNeeded(catalog: catalog, now: dayTwo)
        if missed.gold != 0 || missed.lastGoldReward != nil {
            errors.append("a missed day should pay no gold, got \(missed.gold)")
        }

        // Buying needs enough gold. A Full Recovery banks one token.
        var shop = GameSnapshot.fresh(catalog: catalog, now: dayOne)
        let bank = shop.player.fullRecoveryBank
        if !shop.buy(.fullRecovery).contains("Not enough") || shop.player.fullRecoveryBank != bank {
            errors.append("a buy without gold should be refused")
        }
        shop.gold = Gold.fullRecoveryPrice
        _ = shop.buy(.fullRecovery)
        if shop.gold != 0 || shop.player.fullRecoveryBank != bank + 1 {
            errors.append("buying Full Recovery should cost \(Gold.fullRecoveryPrice) and bank a token")
        }

        // A potion clears one quest of its stat, gives no XP, keeps the penalty away, and blocks the day's gold.
        guard let target = shop.bundle.quests.first(where: { $0.kind == .daily && $0.status != .completed }),
              let potion = Potion(stat: target.stat),
              let wrong = Potion.allCases.first(where: { $0.stat != target.stat }) else {
            return errors + ["the shop test day needs an open daily quest"]
        }
        shop.gold = Gold.potionPrice * 2
        _ = shop.buy(.potion(potion))
        _ = shop.buy(.potion(wrong))
        if shop.gold != 0 || shop.potionCount(potion) != 1 || shop.potionCount(wrong) != 1 {
            errors.append("each potion should cost \(Gold.potionPrice) and go to the inventory")
        }
        _ = shop.drinkPotion(wrong, questId: target.id)
        if shop.bundle.quests.first(where: { $0.id == target.id })?.status == .completed || shop.potionCount(wrong) != 1 {
            errors.append("a potion must not clear a quest of another stat")
        }
        let xp = shop.player.xp
        let level = shop.player.level
        _ = shop.drinkPotion(potion, questId: target.id)
        let skipped = shop.bundle.quests.first { $0.id == target.id }
        if skipped?.status != .completed || skipped?.skippedWithPotion != true || shop.player.xp != xp
            || shop.player.level != level || shop.potionCount(potion) != 0 {
            errors.append("a potion should clear its quest with no XP and be used up")
        }
        if !shop.drinkPotion(potion, questId: target.id).contains("No ") {
            errors.append("an empty inventory should refuse a potion")
        }
        finishRequired(&shop, now: dayOne)
        shop.refreshIfNeeded(catalog: catalog, now: dayTwo)
        if shop.gold != 0 || shop.player.penaltyTier != 0 {
            errors.append("a potion day should pay no gold and open no penalty, got gold \(shop.gold) tier \(shop.player.penaltyTier)")
        }
        if shop.questHistory.first?.quests.first(where: { $0.title == target.title })?.status != .expired {
            errors.append("history should not count a potion skip as real work")
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
