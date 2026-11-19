import SwiftUI

// MARK: - Icons

/// An item's icon: glowing white, like the System's windows.
struct ItemIconView: View {
    let icon: ItemIcon
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            // A soft halo behind the item, like light from the System's glass.
            RadialGradient(colors: [QuestLight.cyan.opacity(0.35), .clear], center: .center, startRadius: 0, endRadius: size * 0.75)
                .frame(width: size * 1.6, height: size * 1.6)
            shape
                .overlay { detail }
        }
        .frame(width: size, height: size)
    }

    /// Fine lines drawn on top of the shapes the app draws itself: a ridge, rings, barbs.
    @ViewBuilder
    private var detail: some View {
        let line = StrokeStyle(lineWidth: max(0.8, size * 0.035), lineCap: .round)
        switch icon {
        case .fang: FangDetail().stroke(QuestLight.blue.opacity(0.75), style: line)
        case .tusk: TuskDetail().stroke(QuestLight.blue.opacity(0.75), style: line)
        case .feather: FeatherDetail().stroke(QuestLight.blue.opacity(0.7), style: line)
        case .dagger: BladeDetail(length: 0.55).stroke(QuestLight.blue.opacity(0.8), style: line).rotationEffect(.degrees(45)).scaleEffect(1.05)
        case .sword: BladeDetail(length: 0.78).stroke(QuestLight.blue.opacity(0.8), style: line).rotationEffect(.degrees(45)).scaleEffect(1.25)
        case .longsword: BladeDetail(length: 0.92).stroke(QuestLight.blue.opacity(0.8), style: line).rotationEffect(.degrees(45)).scaleEffect(1.38)
        case .greatsword: BladeDetail(length: 0.95).stroke(QuestLight.blue.opacity(0.8), style: line).rotationEffect(.degrees(45)).scaleEffect(1.38)
        case .symbol: EmptyView()
        }
    }

    private var shape: some View {
        Group {
            switch icon {
            case .symbol(let name):
                Image(systemName: name)
                    .resizable()
                    .scaledToFit()
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, QuestLight.cyan.opacity(0.85))
            case .fang:
                FangShape().fill(Color.white)
            case .tusk:
                TuskShape().fill(Color.white)
            case .feather:
                FeatherShape().fill(Color.white, style: FillStyle(eoFill: true))
            case .dagger:
                BladeShape(length: 0.55, width: 0.16).fill(Color.white).rotationEffect(.degrees(45)).scaleEffect(1.05)
            case .sword:
                BladeShape(length: 0.78, width: 0.15).fill(Color.white).rotationEffect(.degrees(45)).scaleEffect(1.25)
            case .longsword:
                BladeShape(length: 0.92, width: 0.12).fill(Color.white).rotationEffect(.degrees(45)).scaleEffect(1.38)
            case .greatsword:
                BladeShape(length: 0.95, width: 0.24).fill(Color.white).rotationEffect(.degrees(45)).scaleEffect(1.38)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: QuestLight.cyan.opacity(0.9), radius: 4)
        .shadow(color: .white.opacity(0.6), radius: 1.5)
    }
}

/// The fang's gum line at the root and a crack along its curve.
struct FangDetail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        path.move(to: CGPoint(x: rect.minX + w * 0.31, y: rect.minY + h * 0.86))
        path.addQuadCurve(to: CGPoint(x: rect.minX + w * 0.58, y: rect.minY + h * 0.86), control: CGPoint(x: rect.minX + w * 0.45, y: rect.minY + h * 0.80))
        path.move(to: CGPoint(x: rect.minX + w * 0.44, y: rect.minY + h * 0.70))
        path.addQuadCurve(to: CGPoint(x: rect.minX + w * 0.70, y: rect.minY + h * 0.14), control: CGPoint(x: rect.minX + w * 0.46, y: rect.minY + h * 0.35))
        return path
    }
}

/// Growth rings across the tusk.
struct TuskDetail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        for (y, left, right) in [(0.84, 0.21, 0.59), (0.66, 0.30, 0.66), (0.48, 0.40, 0.70)] {
            path.move(to: CGPoint(x: rect.minX + w * left, y: rect.minY + h * y))
            path.addQuadCurve(to: CGPoint(x: rect.minX + w * right, y: rect.minY + h * (y - 0.04)),
                              control: CGPoint(x: rect.minX + w * (left + right) / 2, y: rect.minY + h * (y + 0.04)))
        }
        return path
    }
}

/// Barbs off the feather's spine.
struct FeatherDetail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        for step in 0..<5 {
            let t = 0.2 + Double(step) * 0.14
            let x = rect.minX + w * (0.36 + 0.5 * t), y = rect.minY + h * (0.78 - 0.66 * t)
            path.move(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x - w * 0.13, y: y - h * 0.02))
            path.move(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x + w * 0.06, y: y + h * 0.10))
        }
        return path
    }
}

/// A blade's ridge down its center and a ring on the pommel.
struct BladeDetail: Shape {
    var length: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let h = rect.height, mid = rect.midX
        let tip = rect.minY + h * (1 - length) * 0.5
        let guardY = rect.minY + h * 0.72
        path.move(to: CGPoint(x: mid, y: tip + h * 0.08))
        path.addLine(to: CGPoint(x: mid, y: guardY - h * 0.03))
        path.addEllipse(in: CGRect(x: mid - rect.width * 0.06, y: guardY + h * 0.215, width: rect.width * 0.12, height: rect.width * 0.12))
        return path
    }
}

/// A curved fang, wide at the root and sharp at the tip.
struct FangShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        path.move(to: CGPoint(x: rect.minX + w * 0.30, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + w * 0.78, y: rect.minY), control: CGPoint(x: rect.minX + w * 0.22, y: rect.minY + h * 0.35))
        path.addQuadCurve(to: CGPoint(x: rect.minX + w * 0.58, y: rect.maxY), control: CGPoint(x: rect.minX + w * 0.62, y: rect.minY + h * 0.55))
        path.closeSubpath()
        return path
    }
}

/// Short L-shaped marks at the four corners of a rect.
struct CornerBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let arm = min(rect.width, rect.height) * 0.18
        for (x, y, dx, dy) in [(rect.minX, rect.minY, 1.0, 1.0), (rect.maxX, rect.minY, -1.0, 1.0),
                               (rect.minX, rect.maxY, 1.0, -1.0), (rect.maxX, rect.maxY, -1.0, -1.0)] {
            path.move(to: CGPoint(x: x + dx * arm, y: y))
            path.addLine(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x, y: y + dy * arm))
        }
        return path
    }
}

/// A thick tusk, curved the other way from a fang, with a flat root.
struct TuskShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        path.move(to: CGPoint(x: rect.minX + w * 0.20, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + w * 0.22, y: rect.minY + h * 0.02), control: CGPoint(x: rect.minX + w * 0.95, y: rect.minY + h * 0.45))
        path.addQuadCurve(to: CGPoint(x: rect.minX + w * 0.58, y: rect.maxY), control: CGPoint(x: rect.minX + w * 0.70, y: rect.minY + h * 0.62))
        path.closeSubpath()
        return path
    }
}

/// A feather: a curved vane with a quill, and a cut line down the spine (even-odd fill).
struct FeatherShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        let base = CGPoint(x: rect.minX + w * 0.18, y: rect.maxY)
        let tip = CGPoint(x: rect.maxX - w * 0.08, y: rect.minY)
        // The vane: slim, with two notches on the outer edge.
        path.move(to: CGPoint(x: rect.minX + w * 0.32, y: rect.minY + h * 0.80))
        path.addQuadCurve(to: CGPoint(x: rect.minX + w * 0.40, y: rect.minY + h * 0.46), control: CGPoint(x: rect.minX + w * 0.22, y: rect.minY + h * 0.62))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.47, y: rect.minY + h * 0.47))
        path.addQuadCurve(to: CGPoint(x: rect.minX + w * 0.58, y: rect.minY + h * 0.22), control: CGPoint(x: rect.minX + w * 0.45, y: rect.minY + h * 0.32))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.64, y: rect.minY + h * 0.24))
        path.addQuadCurve(to: tip, control: CGPoint(x: rect.minX + w * 0.70, y: rect.minY + h * 0.08))
        path.addQuadCurve(to: CGPoint(x: rect.minX + w * 0.40, y: rect.minY + h * 0.84), control: CGPoint(x: rect.maxX - w * 0.05, y: rect.minY + h * 0.55))
        path.closeSubpath()
        // The quill below the vane.
        path.move(to: base)
        path.addLine(to: CGPoint(x: rect.minX + w * 0.33, y: rect.minY + h * 0.76))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.38, y: rect.minY + h * 0.80))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.22, y: rect.maxY))
        path.closeSubpath()
        // The spine, cut out of the vane.
        path.move(to: CGPoint(x: rect.minX + w * 0.34, y: rect.minY + h * 0.80))
        path.addQuadCurve(to: CGPoint(x: tip.x - w * 0.03, y: tip.y + h * 0.05), control: CGPoint(x: rect.minX + w * 0.55, y: rect.minY + h * 0.38))
        path.addQuadCurve(to: CGPoint(x: rect.minX + w * 0.37, y: rect.minY + h * 0.81), control: CGPoint(x: rect.minX + w * 0.58, y: rect.minY + h * 0.40))
        path.closeSubpath()
        return path
    }
}

/// A straight blade with a cross guard and a grip, drawn upright. `length` is the blade's share of the height,
/// `width` its share of the width.
struct BladeShape: Shape {
    var length: CGFloat
    var width: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height, mid = rect.midX
        let bladeWidth = w * width
        let tip = rect.minY + h * (1 - length) * 0.5
        let guardY = rect.minY + h * 0.72
        path.move(to: CGPoint(x: mid, y: tip))
        path.addLine(to: CGPoint(x: mid + bladeWidth / 2, y: tip + bladeWidth))
        path.addLine(to: CGPoint(x: mid + bladeWidth / 2, y: guardY))
        path.addLine(to: CGPoint(x: mid - bladeWidth / 2, y: guardY))
        path.addLine(to: CGPoint(x: mid - bladeWidth / 2, y: tip + bladeWidth))
        path.closeSubpath()
        // A cross guard with flared ends, the grip, and a round pommel.
        path.move(to: CGPoint(x: mid - w * 0.26, y: guardY - h * 0.02))
        path.addLine(to: CGPoint(x: mid + w * 0.26, y: guardY - h * 0.02))
        path.addLine(to: CGPoint(x: mid + w * 0.20, y: guardY + h * 0.05))
        path.addLine(to: CGPoint(x: mid - w * 0.20, y: guardY + h * 0.05))
        path.closeSubpath()
        path.addRect(CGRect(x: mid - w * 0.045, y: guardY + h * 0.05, width: w * 0.09, height: h * 0.15))
        path.addEllipse(in: CGRect(x: mid - w * 0.08, y: guardY + h * 0.195, width: w * 0.16, height: w * 0.16))
        return path
    }
}

// MARK: - Item card

/// One item's window: its icon, name, rank, category, and description. The drop card and the inventory use it.
struct ItemCard: View {
    let item: LootItem
    var source: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                ItemIconView(icon: item.icon, size: 54)
                    .frame(width: 92, height: 92)
                    .overlay { Rectangle().stroke(QuestLight.ink.opacity(0.7), lineWidth: 1) }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("ITEM:")
                            .font(.caption2.weight(.semibold))
                            .tracking(1)
                            .foregroundStyle(QuestLight.ink.opacity(0.75))
                        Text(item.name)
                            .font(.headline)
                            .foregroundStyle(QuestLight.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay { Rectangle().stroke(QuestLight.ink.opacity(0.5), lineWidth: 0.8) }
                    HStack(alignment: .top, spacing: 12) {
                        field("ACQUISITION DIFFICULTY:", item.rank.label)
                        field("CATEGORY:", item.category.label)
                    }
                }
            }
            Text(item.description)
                .font(.subheadline)
                .foregroundStyle(QuestLight.ink.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if let source {
                    Text("From: \(source)")
                        .font(.caption)
                        .foregroundStyle(QuestLight.ink.opacity(0.65))
                }
                Spacer()
                Text(item.category == .box ? "Open it in the inventory" : "Sells for \(item.value.formatted()) gold")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(item.chestOnly ? QuestLight.caution : QuestLight.cyan)
            }
        }
        .padding(14)
        .overlay { Rectangle().stroke(QuestLight.ink.opacity(0.75), lineWidth: 1) }
        .shadow(color: QuestLight.cyan.opacity(0.35), radius: 8)
        .accessibilityElement(children: .combine)
    }

    private func field(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(QuestLight.ink.opacity(0.7))
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(QuestLight.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

/// A new item, shown the moment it drops. Tap OK for the next one.
struct DropCardOverlay: View {
    @EnvironmentObject private var store: GameStore

    var body: some View {
        if let drop = store.pendingDrop, let item = LootCatalog.item(drop.itemId) {
            ZStack {
                Color.black.opacity(0.65).ignoresSafeArea()
                VStack(spacing: 16) {
                    Text(item.chestOnly ? "RARE ITEM ACQUIRED" : "ITEM ACQUIRED")
                        .font(.caption.weight(.bold))
                        .tracking(2)
                        .foregroundStyle(item.chestOnly ? QuestLight.caution : QuestLight.cyan)
                    ItemCard(item: item, source: drop.source)
                        .background(Color.black.opacity(0.75))
                    Button {
                        store.acknowledgeDrop()
                    } label: {
                        Text(store.snapshot.inventory.pending.count > 1 ? "NEXT" : "OK")
                            .font(.caption.weight(.semibold))
                            .tracking(1)
                            .foregroundStyle(QuestLight.ink)
                            .frame(width: 140, height: 40)
                            .overlay { Rectangle().stroke(QuestLight.ink.opacity(0.7), lineWidth: 0.8) }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("dropCardOK")
                }
                .padding(.horizontal, 24)
            }
            .transition(.opacity)
        }
    }
}

// MARK: - Inventory

/// The player's items in a grid of slots. Tap a slot for its card: sell it, or open a Sealed Chest.
struct InventorySheet: View {
    @EnvironmentObject private var store: GameStore
    @State private var tab: Tab = .all
    @State private var selected: String? = {
        #if DEBUG
        // With OPEN_INVENTORY=1, the first item is selected so its card shows.
        if ProcessInfo.processInfo.environment["OPEN_INVENTORY"] == "1" { return LootCatalog.items[0].id }
        #endif
        return nil
    }()
    @State private var note: String?

    enum Tab: String, CaseIterable, Identifiable {
        case all, equipment, materials, consumables, boxes
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .all: "square.grid.2x2.fill"
            case .equipment: "shield.fill"
            case .materials: "diamond.fill"
            case .consumables: "cross.vial.fill"
            case .boxes: "shippingbox.fill"
            }
        }
        func holds(_ item: LootItem) -> Bool {
            switch self {
            case .all: true
            case .equipment: item.category == .equipment
            case .materials: item.category == .material || item.category == .crystal
            case .consumables: item.category == .consumable
            case .boxes: item.category == .box
            }
        }
    }

    private static let columns = 5
    private static let minimumSlots = 25

    private var shown: [(item: LootItem, count: Int)] { store.snapshot.inventory.held.filter { tab.holds($0.item) } }

    var body: some View {
        NavigationStack {
            QuestSheet(title: "Inventory") {
                HStack(spacing: 6) {
                    ForEach(Tab.allCases) { option in
                        Button {
                            tab = option
                            selected = nil
                        } label: {
                            Image(systemName: option.symbol)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(tab == option ? Color.black : QuestLight.ink)
                                .frame(width: 34, height: 30)
                                .background(tab == option ? QuestLight.ink : Color.clear)
                                .overlay { Rectangle().stroke(QuestLight.ink.opacity(0.6), lineWidth: 0.8) }
                                .shadow(color: QuestLight.cyan.opacity(tab == option ? 0.8 : 0), radius: 5)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option.rawValue.capitalized)
                    }
                    Spacer()
                    Text("\(store.snapshot.gold.formatted()) G")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(QuestLight.caution)
                }

                let slots = max(Self.minimumSlots, (shown.count + Self.columns - 1) / Self.columns * Self.columns)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: Self.columns), spacing: 6) {
                    ForEach(0..<slots, id: \.self) { index in
                        slot(index < shown.count ? shown[index] : nil)
                    }
                }

                if let id = selected, let item = LootCatalog.item(id), let count = store.snapshot.inventory.counts[id], count > 0 {
                    ItemCard(item: item)
                    actions(item: item, count: count)
                } else if shown.isEmpty {
                    Text("Empty. Finish quests to find items.")
                        .font(.footnote)
                        .foregroundStyle(SystemTheme.muted)
                }
                if let note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(QuestLight.cyan)
                }
            }
            .font(.subheadline)
            .tint(SystemTheme.accent)
        }
    }

    private func slot(_ entry: (item: LootItem, count: Int)?) -> some View {
        Button {
            guard let entry else { return }
            selected = selected == entry.item.id ? nil : entry.item.id
            note = nil
            SystemSound.systemOpen.play()
        } label: {
            ZStack(alignment: .bottomLeading) {
                Rectangle()
                    .fill(Color.black.opacity(0.35))
                    .overlay {
                        Rectangle().stroke(QuestLight.ink.opacity(entry == nil ? 0.25 : 0.75), lineWidth: entry?.item.id == selected ? 2 : 1)
                    }
                    .shadow(color: QuestLight.cyan.opacity(entry == nil ? 0 : 0.5), radius: 4)
                    .overlay {
                        // Bright corner brackets on a filled slot, like the System's frames.
                        if entry != nil { CornerBrackets().stroke(Color.white.opacity(0.9), lineWidth: 1.5).padding(1) }
                    }
                if let entry {
                    ItemIconView(icon: entry.item.icon, size: 30)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if entry.count > 1 {
                        Text("\(entry.count)")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(QuestLight.ink)
                            .padding(3)
                    }
                    if entry.item.chestOnly || entry.item.category == .box {
                        Rectangle().stroke(QuestLight.caution.opacity(0.8), lineWidth: 1).padding(3)
                    }
                }
            }
            .aspectRatio(0.8, contentMode: .fit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(entry == nil)
        .accessibilityLabel(entry.map { "\($0.item.name), \($0.count)" } ?? "Empty slot")
    }

    @ViewBuilder
    private func actions(item: LootItem, count: Int) -> some View {
        if item.category == .box {
            boxButton("OPEN (\(count) LEFT)") {
                store.openChest()
                note = nil
            }
            .accessibilityIdentifier("openChestButton")
        } else {
            HStack(spacing: 8) {
                boxButton("SELL 1 · \(item.value.formatted()) G") {
                    note = "Sold for \(store.sellItem(item.id, all: false).formatted()) gold."
                }
                if count > 1 {
                    boxButton("SELL ALL · \((item.value * count).formatted()) G") {
                        note = "Sold for \(store.sellItem(item.id, all: true).formatted()) gold."
                    }
                }
            }
        }
    }

    private func boxButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(QuestLight.ink)
                .frame(maxWidth: .infinity, minHeight: 42)
                .overlay { Rectangle().stroke(QuestLight.ink.opacity(0.6), lineWidth: 0.8) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    InventorySheet()
        .environmentObject(GameStore(persistence: .memory))
}
