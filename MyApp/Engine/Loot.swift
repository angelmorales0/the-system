import Foundation

// MARK: - Items

/// Item ranks, from common (E) to legendary (S). The rank is the item's "acquisition difficulty".
enum ItemRank: String, Codable, CaseIterable, Comparable {
    case E, D, C, B, A, S

    static func < (lhs: ItemRank, rhs: ItemRank) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    var label: String { "\(rawValue)-rank" }
}

enum ItemCategory: String, Codable, CaseIterable {
    case material, crystal, consumable, equipment, box

    var label: String {
        switch self {
        case .material: "Miscellaneous"
        case .crystal: "Crystal"
        case .consumable: "Consumable"
        case .equipment: "Equipment"
        case .box: "Box"
        }
    }
}

/// How an item is drawn: an SF Symbol, or one of the app's own shapes where SF Symbols has none.
enum ItemIcon: Equatable {
    case symbol(String)
    case fang
    case dagger
    case sword
}

/// One kind of item. Items are sold in the inventory for `value` gold. The Sealed Chest is opened, not sold.
struct LootItem: Equatable, Identifiable {
    var id: String
    var name: String
    var category: ItemCategory
    var rank: ItemRank
    var value: Int
    var icon: ItemIcon
    var description: String
    /// Found only in a Sealed Chest, never from a quest.
    var chestOnly = false
}

/// The item list. Every item is original to the app; the style follows the System windows.
enum LootCatalog {
    static let chest = LootItem(id: "sealedChest", name: "Sealed Chest", category: .box, rank: .C, value: 0, icon: .symbol("shippingbox.fill"),
                                description: "A chest sealed with old mana. Keep it, and open it in the inventory when you want. It holds an item no quest drops.")

    static let items: [LootItem] = [
        // Materials
        LootItem(id: "lycanFang", name: "Lycan Fang", category: .material, rank: .E, value: 40, icon: .fang,
                 description: "A lycan's large, sharp fang. It can be sold in the shop."),
        LootItem(id: "goblinEar", name: "Goblin Ear", category: .material, rank: .E, value: 30, icon: .symbol("ear.fill"),
                 description: "A torn goblin ear. Hunters keep them as proof of a clear."),
        LootItem(id: "ironScale", name: "Iron Scale", category: .material, rank: .E, value: 50, icon: .symbol("hexagon.fill"),
                 description: "A dull scale from an iron lizard. Smiths melt it down."),
        LootItem(id: "shadowPelt", name: "Shadow Wolf Pelt", category: .material, rank: .D, value: 90, icon: .symbol("pawprint.fill"),
                 description: "A pelt that drinks the light. Warm, and hard to see at night."),
        LootItem(id: "venomGland", name: "Venom Gland", category: .material, rank: .D, value: 110, icon: .symbol("drop.fill"),
                 description: "A gland still full of venom. Handle it with gloves."),
        LootItem(id: "orcTusk", name: "Orc Tusk", category: .material, rank: .D, value: 100, icon: .symbol("moon.fill"),
                 description: "A heavy, yellowed tusk. Carvers pay well for whole ones."),
        LootItem(id: "frostShard", name: "Frost Shard", category: .material, rank: .C, value: 180, icon: .symbol("snowflake"),
                 description: "A shard of ice that never melts. It keeps the cold of the gate it came from."),
        LootItem(id: "spiderSilk", name: "Gate Spider Silk", category: .material, rank: .C, value: 160, icon: .symbol("circle.hexagongrid.fill"),
                 description: "Silk strong enough to stop a blade. Armorers weave it into vests."),
        LootItem(id: "gargoyleHeart", name: "Gargoyle Heart", category: .material, rank: .B, value: 350, icon: .symbol("heart.fill"),
                 description: "A stone heart that still beats once a minute."),
        LootItem(id: "wyvernScale", name: "Wyvern Scale", category: .material, rank: .B, value: 400, icon: .symbol("lizard.fill"),
                 description: "A scale from a wyvern's chest. Fire slides off it."),
        LootItem(id: "dragonClaw", name: "Dragon Claw", category: .material, rank: .A, value: 900, icon: .symbol("flame.fill"),
                 description: "A claw longer than a forearm, warm to the touch."),
        LootItem(id: "phoenixPlume", name: "Phoenix Plume", category: .material, rank: .S, value: 2_000, icon: .symbol("bird.fill"),
                 description: "A plume that glows like an ember. Few hunters have seen one."),
        // Crystals
        LootItem(id: "manaLow", name: "Low-Grade Mana Crystal", category: .crystal, rank: .E, value: 50, icon: .symbol("diamond.fill"),
                 description: "A small, cloudy crystal from a weak monster's core."),
        LootItem(id: "manaMid", name: "Mid-Grade Mana Crystal", category: .crystal, rank: .C, value: 200, icon: .symbol("rhombus.fill"),
                 description: "A clear crystal with a steady glow. Guilds buy these in bulk."),
        LootItem(id: "runeStone", name: "Rune Stone", category: .crystal, rank: .B, value: 450, icon: .symbol("seal.fill"),
                 description: "A stone carved with a rune that hums when held."),
        LootItem(id: "manaHigh", name: "High-Grade Mana Crystal", category: .crystal, rank: .A, value: 800, icon: .symbol("suit.diamond.fill"),
                 description: "A crystal so dense with mana that it lights a room."),
        // Consumables
        LootItem(id: "healingHerb", name: "Healing Herb", category: .consumable, rank: .E, value: 30, icon: .symbol("leaf.fill"),
                 description: "A bitter herb that closes small cuts."),
        LootItem(id: "minorPotion", name: "Minor Healing Potion", category: .consumable, rank: .D, value: 80, icon: .symbol("cross.vial.fill"),
                 description: "A red potion. It restores a little health."),
        LootItem(id: "manaPotion", name: "Mana Potion", category: .consumable, rank: .C, value: 150, icon: .symbol("flask.fill"),
                 description: "A blue potion. It restores a little mana."),
        LootItem(id: "vigorElixir", name: "Elixir of Vigor", category: .consumable, rank: .B, value: 400, icon: .symbol("testtube.2"),
                 description: "A golden elixir that removes all fatigue."),
        // Equipment
        LootItem(id: "rustyDagger", name: "Rusty Dagger", category: .equipment, rank: .E, value: 60, icon: .dagger,
                 description: "An old dagger with a chipped edge. Better than bare hands."),
        LootItem(id: "steelSword", name: "Steel Shortsword", category: .equipment, rank: .D, value: 120, icon: .sword,
                 description: "A plain, well-balanced sword. Standard issue for new hunters."),
        LootItem(id: "hunterGauntlets", name: "Hunter's Gauntlets", category: .equipment, rank: .C, value: 220, icon: .symbol("hand.raised.fill"),
                 description: "Leather gauntlets lined with iron. They add weight to a punch."),
        LootItem(id: "knightShield", name: "Knight's Shield", category: .equipment, rank: .B, value: 380, icon: .symbol("shield.fill"),
                 description: "A shield from a fallen knight. Its crest is worn away."),
        LootItem(id: "shadowBlade", name: "Shadow-Forged Blade", category: .equipment, rank: .A, value: 1_000, icon: .sword,
                 description: "A black blade that cuts without a sound."),
        LootItem(id: "fallenCrown", name: "Crown of the Fallen King", category: .equipment, rank: .S, value: 2_500, icon: .symbol("crown.fill"),
                 description: "A crown from the deepest floor of a gate. It is cold and very heavy."),
        // Found only in a Sealed Chest
        LootItem(id: "obsidianGreatsword", name: "Obsidian Greatsword", category: .equipment, rank: .A, value: 1_400, icon: .sword,
                 description: "A greatsword of black glass. It never dulls.", chestOnly: true),
        LootItem(id: "wraithCloak", name: "Cloak of the Wraith", category: .equipment, rank: .A, value: 1_200, icon: .symbol("eye.fill"),
                 description: "A cloak that hides its wearer from every monster below A-rank.", chestOnly: true),
        LootItem(id: "titanBracer", name: "Titan's Bracer", category: .equipment, rank: .A, value: 1_300, icon: .symbol("bolt.shield.fill"),
                 description: "A bracer forged for a giant's wrist. It doubles a hunter's grip.", chestOnly: true),
        LootItem(id: "stormSpear", name: "Stormcaller Spear", category: .equipment, rank: .S, value: 3_000, icon: .symbol("bolt.fill"),
                 description: "A spear that calls lightning down on whatever it points at.", chestOnly: true),
        LootItem(id: "abyssalCore", name: "Abyssal Core", category: .crystal, rank: .S, value: 3_500, icon: .symbol("atom"),
                 description: "The core of a gate boss from the abyss. Its mana could power a city.", chestOnly: true),
        LootItem(id: "starfallCrystal", name: "Starfall Crystal", category: .crystal, rank: .S, value: 4_000, icon: .symbol("sparkles"),
                 description: "A crystal that fell from a red gate in the sky. Only one hunter in a thousand holds one.", chestOnly: true),
    ]

    static func item(_ id: String) -> LootItem? {
        id == chest.id ? chest : items.first { $0.id == id }
    }

    /// Items a quest or a Pass can drop, by rank. Chest-only items are left out.
    static func items(of rank: ItemRank) -> [LootItem] { items.filter { $0.rank == rank && !$0.chestOnly } }

    /// Items only a Sealed Chest holds, by rank.
    static func chestItems(of rank: ItemRank) -> [LootItem] { items.filter { $0.rank == rank && $0.chestOnly } }
}

// MARK: - Drops

/// One item that dropped, waiting to be shown on its card. `key` names the thing that dropped it, so it drops once.
struct LootDrop: Codable, Equatable, Identifiable {
    var key: String
    var itemId: String
    /// What dropped it: a quest title, a Systems row, "Perfect day", or "Sealed Chest".
    var source: String
    var id: String { key + "#" + itemId }
}

/// The player's items: a count per item, the drops not yet shown, and the keys that already dropped.
struct InventoryState: Codable, Equatable {
    var counts: [String: Int] = [:]
    var pending: [LootDrop] = []
    var droppedKeys: [String] = []
    /// Chests opened so far. It seeds each opening, so a reload cannot reroll a chest.
    var chestsOpened = 0

    init() {}

    private enum CodingKeys: String, CodingKey { case counts, pending, droppedKeys, chestsOpened }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        counts = try container.decodeIfPresent([String: Int].self, forKey: .counts) ?? [:]
        pending = try container.decodeIfPresent(LossyArray<LootDrop>.self, forKey: .pending)?.elements ?? []
        droppedKeys = try container.decodeIfPresent([String].self, forKey: .droppedKeys) ?? []
        chestsOpened = try container.decodeIfPresent(Int.self, forKey: .chestsOpened) ?? 0
    }

    /// Items held, in catalog order, the chest first. Unknown ids (an item removed later) are left out.
    var held: [(item: LootItem, count: Int)] {
        ([LootCatalog.chest] + LootCatalog.items).compactMap { item in
            guard let count = counts[item.id], count > 0 else { return nil }
            return (item, count)
        }
    }

    /// Gold the held items sell for.
    var value: Int { held.reduce(0) { $0 + $1.item.value * $1.count } }
}

/// The drop tables. Every roll is seeded by the drop's key, so the same quest on the same day always drops the same item.
enum Loot {
    /// Chance in 100 that a quest also drops a Sealed Chest. Rare: a chest holds an item worth more than a whole day.
    static let chestChance = 4
    static let keepKeys = 600

    /// Weights per rank: a finished quest, a Pass mark, and a chest's contents.
    static let questWeights: [(ItemRank, Int)] = [(.E, 45), (.D, 30), (.C, 15), (.B, 8), (.A, 2)]
    static let passWeights: [(ItemRank, Int)] = [(.E, 80), (.D, 20)]
    /// A chest holds one chest-only item: A-rank or S-rank.
    static let chestWeights: [(ItemRank, Int)] = [(.A, 60), (.S, 40)]
    static let chestItems = 1
    /// A perfect day adds one better regular item.
    static let perfectWeights: [(ItemRank, Int)] = [(.C, 50), (.B, 40), (.A, 10)]

    /// FNV-1a: stable across launches, unlike `Hasher`.
    static func seed(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash
    }

    static func roll(_ weights: [(ItemRank, Int)], key: String, chest: Bool = false) -> LootItem {
        let total = weights.reduce(0) { $0 + $1.1 }
        var pick = Int(seed(key + "|rank") % UInt64(total))
        var rank = weights[0].0
        for (candidate, weight) in weights {
            if pick < weight { rank = candidate; break }
            pick -= weight
        }
        let pool = chest ? LootCatalog.chestItems(of: rank) : LootCatalog.items(of: rank)
        return pool[Int(seed(key + "|item") % UInt64(pool.count))]
    }

    static func dropsChest(key: String) -> Bool { seed(key + "|chest") % 100 < UInt64(chestChance) }

    /// Expected gold of one roll on a table.
    static func expectedValue(_ weights: [(ItemRank, Int)], chest: Bool = false) -> Double {
        let total = Double(weights.reduce(0) { $0 + $1.1 })
        return weights.reduce(0.0) { sum, entry in
            let pool = chest ? LootCatalog.chestItems(of: entry.0) : LootCatalog.items(of: entry.0)
            let average = Double(pool.reduce(0) { $0 + $1.value }) / Double(max(pool.count, 1))
            return sum + Double(entry.1) / total * average
        }
    }
}

extension GameSnapshot {
    /// Adds one item and queues its card. Returns false when `key` already dropped.
    @discardableResult
    mutating func grantDrop(_ item: LootItem, key: String, source: String) -> Bool {
        let dropKey = key + "#" + item.id
        guard !inventory.droppedKeys.contains(dropKey) else { return false }
        inventory.droppedKeys = Array((inventory.droppedKeys + [dropKey]).suffix(Loot.keepKeys))
        inventory.counts[item.id, default: 0] += 1
        inventory.pending.append(LootDrop(key: key, itemId: item.id, source: source))
        return true
    }

    /// Drops for everything finished since the last call: each completed quest of today and of the day that waits,
    /// and each Pass marked today on a hand-marked Systems row. Penalty rows and potion skips drop nothing.
    /// Returns the number of new drops.
    @discardableResult
    mutating func collectDrops() -> Int {
        var count = 0
        let bundles = [bundle] + (endedDay.map { [$0.bundle] } ?? [])
        for day in bundles {
            for quest in day.quests where quest.status == .completed && quest.kind != .penalty && !quest.skippedWithPotion {
                let key = "\(day.dayKey)|quest:\(quest.id)"
                if grantDrop(Loot.roll(Loot.questWeights, key: key), key: key, source: quest.title) { count += 1 }
                if Loot.dropsChest(key: key), grantDrop(LootCatalog.chest, key: key, source: quest.title) { count += 1 }
            }
        }
        for habit in habits.handHabits where habit.weeklyLimit == nil && habits.marks(habit)[bundle.dayKey] == true {
            let key = "\(bundle.dayKey)|hand:\(habit.id)"
            if grantDrop(Loot.roll(Loot.passWeights, key: key), key: key, source: habit.name) { count += 1 }
        }
        return count
    }

    /// The day's reward for a perfect day: one better regular item (C-rank or above). Once per day.
    @discardableResult
    mutating func grantPerfectDayItem(dayKey: String) -> Bool {
        let key = "\(dayKey)|perfect"
        return grantDrop(Loot.roll(Loot.perfectWeights, key: key), key: key, source: "Perfect day")
    }

    /// Sells `count` of an item (all of it when nil). Returns the gold earned, 0 when nothing was sold.
    @discardableResult
    mutating func sellItem(_ id: String, count: Int? = nil) -> Int {
        guard let item = LootCatalog.item(id), item.category != .box, let held = inventory.counts[id], held > 0 else { return 0 }
        let sold = min(count ?? held, held)
        guard sold > 0 else { return 0 }
        inventory.counts[id] = held - sold == 0 ? nil : held - sold
        let earned = sold * item.value
        gold += earned
        return earned
    }

    /// Opens one Sealed Chest: one chest-only item, shown on its card. Returns it.
    @discardableResult
    mutating func openChest() -> [LootItem] {
        guard let held = inventory.counts[LootCatalog.chest.id], held > 0 else { return [] }
        inventory.counts[LootCatalog.chest.id] = held == 1 ? nil : held - 1
        inventory.chestsOpened += 1
        let key = "chest:\(inventory.chestsOpened)"
        var items: [LootItem] = []
        for slot in 0..<Loot.chestItems {
            let item = Loot.roll(Loot.chestWeights, key: "\(key)|\(slot)", chest: true)
            if grantDrop(item, key: "\(key)|\(slot)", source: LootCatalog.chest.name) { items.append(item) }
        }
        return items
    }

    /// Removes the first card, after the player has seen it.
    mutating func acknowledgeDrop() {
        if !inventory.pending.isEmpty { inventory.pending.removeFirst() }
    }
}

// MARK: - Self-check (runs in DEBUG at launch)

enum LootRules {
    static func check() -> [String] {
        var errors: [String] = []
        if LootCatalog.items.count < 20 || Set(LootCatalog.items.map(\.id)).count != LootCatalog.items.count {
            errors.append("there should be at least 20 items with unique ids, got \(LootCatalog.items.count)")
        }
        for (rank, _) in Loot.questWeights + Loot.passWeights + Loot.perfectWeights where LootCatalog.items(of: rank).isEmpty {
            errors.append("rank \(rank.rawValue) has no item")
        }
        for (rank, _) in Loot.chestWeights where LootCatalog.chestItems(of: rank).isEmpty {
            errors.append("rank \(rank.rawValue) has no chest item")
        }
        // A chest item is worth far more than the best quest drop on average.
        let chestValue = Loot.expectedValue(Loot.chestWeights, chest: true) * Double(Loot.chestItems)
        if chestValue < 3 * Loot.expectedValue(Loot.perfectWeights) {
            errors.append("a chest should be worth far more than a perfect-day item, got \(Int(chestValue))")
        }
        // A perfect day's drops sell for about the old perfect-day gold (1,000 to 1,400): 4 quests, 3 Pass marks, the bonus.
        let perQuest = Loot.expectedValue(Loot.questWeights) + Double(Loot.chestChance) / 100 * chestValue
        let day = 4 * perQuest + 3 * Loot.expectedValue(Loot.passWeights) + Loot.expectedValue(Loot.perfectWeights)
        if !(1_000...1_600).contains(day) {
            errors.append("a perfect day should be worth about 1,000 to 1,400 gold in items, got \(Int(day))")
        }
        // Rolls are stable for a key and vary across keys.
        if Loot.roll(Loot.questWeights, key: "2026-11-18|quest:a") != Loot.roll(Loot.questWeights, key: "2026-11-18|quest:a")
            || Set((0..<60).map { Loot.roll(Loot.questWeights, key: "k\($0)").id }).count < 6 {
            errors.append("a roll should be stable for its key and vary across keys")
        }

        let catalog = FallbackCatalog.bundled()
        guard let now = QuestDay.date(from: "2026-11-18") else { return errors + ["could not build loot dates"] }
        var game = GameSnapshot.fresh(catalog: catalog, now: now)
        // Nothing done: no drop. A completed quest drops once; a second collect does nothing.
        if game.collectDrops() != 0 { errors.append("an untouched day should drop nothing") }
        guard let index = game.bundle.quests.firstIndex(where: { $0.kind != .penalty }) else { return errors + ["no quest to finish"] }
        game.bundle.quests[index].status = .completed
        let first = game.collectDrops()
        if first < 1 || game.collectDrops() != 0 || game.inventory.pending.first?.source != game.bundle.quests[index].title {
            errors.append("a finished quest should drop once and name its quest, got \(first) drops")
        }
        // A Pass mark drops once, and only for today.
        game.setHandMark(.noCaffeine, game.bundle.dayKey, passed: true)
        game.setHandMark(.noCaffeine, QuestDay.key(byAddingDays: -1, to: game.bundle.dayKey), passed: true)
        if game.collectDrops() != 1 || game.collectDrops() != 0 {
            errors.append("a Pass marked today should drop one item once")
        }
        // A potion skip drops nothing.
        if let other = game.bundle.quests.indices.first(where: { $0 != index && game.bundle.quests[$0].kind != .penalty }) {
            game.bundle.quests[other].status = .completed
            game.bundle.quests[other].skippedWithPotion = true
            if game.collectDrops() != 0 { errors.append("a quest skipped with a potion should drop nothing") }
        }
        // Selling pays the item's value; a chest cannot be sold but opens into two items.
        let goldBefore = game.gold
        let held = game.inventory.held.filter { $0.item.category != .box }
        let worth = held.reduce(0) { $0 + $1.item.value * $1.count }
        let earned = held.reduce(0) { $0 + game.sellItem($1.item.id) }
        if earned != worth || game.gold != goldBefore + worth || game.inventory.held.contains(where: { $0.item.category != .box }) {
            errors.append("selling should pay each item's value and empty its slot")
        }
        if !game.grantPerfectDayItem(dayKey: game.bundle.dayKey) || game.grantPerfectDayItem(dayKey: game.bundle.dayKey) {
            errors.append("a perfect day should give one item only")
        }
        // A chest is kept until opened, cannot be sold, and holds a chest-only item.
        game.grantDrop(LootCatalog.chest, key: "test|chest", source: "test")
        if game.sellItem(LootCatalog.chest.id) != 0 { errors.append("a chest should not be sold") }
        let chests = game.inventory.counts[LootCatalog.chest.id] ?? 0
        let opened = game.openChest()
        if opened.count != Loot.chestItems || (game.inventory.counts[LootCatalog.chest.id] ?? 0) != chests - 1
            || opened.contains(where: { !$0.chestOnly || $0.rank < .A }) {
            errors.append("a chest should open into \(Loot.chestItems) chest-only item of A-rank or better")
        }
        // No quest roll ever gives a chest-only item.
        if (0..<500).contains(where: { Loot.roll(Loot.questWeights, key: "q\($0)").chestOnly || Loot.roll(Loot.perfectWeights, key: "p\($0)").chestOnly }) {
            errors.append("chest-only items should never drop from a quest")
        }
        // Cards are shown in order and removed when seen.
        let pending = game.inventory.pending.count
        game.acknowledgeDrop()
        if game.inventory.pending.count != max(pending - 1, 0) { errors.append("a seen card should leave the queue") }
        // An old save without an inventory loads empty.
        if let empty = try? JSONDecoder().decode(InventoryState.self, from: Data("{}".utf8)), empty != InventoryState() {
            errors.append("an empty inventory should decode")
        }
        return errors
    }
}
