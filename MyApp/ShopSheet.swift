import SwiftUI

/// The System's SHOP: the gold from perfect days buys a Full Recovery or one potion a day.
/// Every purchase asks first. The result shows under the gold.
struct ShopSheet: View {
    @EnvironmentObject private var store: GameStore
    @State private var pending: Purchase?
    @State private var result: String?

    /// What the player tapped, kept until they confirm.
    private enum Purchase: Identifiable {
        case fullRecovery
        case potion(Potion, PotionDose)

        var id: String {
            switch self {
            case .fullRecovery: "fullRecovery"
            case .potion(let potion, let dose): "\(potion.rawValue)-\(dose.rawValue)"
            }
        }
    }

    private var snapshot: GameSnapshot { store.snapshot }
    private var closed: Bool { snapshot.player.penaltyTier > 0 }

    var body: some View {
        QuestSheet(title: "Shop") {
            goldRow
            if closed {
                note("The shop is closed during a penalty.")
            }
            if let result {
                Text(result)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(QuestLight.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

            QuestSectionTitle(text: "Recovery")
            fullRecoveryRow

            QuestSectionTitle(text: "Potions")
            VStack(spacing: 22) {
                ForEach(Potion.allCases, id: \.self) { potion in
                    potionRow(potion)
                }
            }
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(
            get: { pending != nil },
            set: { if !$0 { pending = nil } }
        ), titleVisibility: .visible, presenting: pending) { purchase in
            Button(confirmButton(purchase)) { buy(purchase) }
            Button("Cancel", role: .cancel) {}
        } message: { purchase in
            Text(confirmMessage(purchase))
        }
    }

    // MARK: Rows

    private var goldRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.title3)
                    .foregroundStyle(QuestLight.cyan)
                    .accessibilityHidden(true)
                Text(verbatim: snapshot.gold.formatted())
                    .font(.title.weight(.semibold))
                    .monospacedDigit()
                Text("GOLD")
                    .font(.footnote.weight(.semibold))
                    .tracking(1.4)
                    .foregroundStyle(SystemTheme.muted)
            }
            .accessibilityElement(children: .combine)
            if let reward = snapshot.lastGoldReward {
                note("+\(reward.amount.formatted()) gold yesterday.")
            }
        }
    }

    private var fullRecoveryRow: some View {
        let blocker: String? = closed ? "The shop is closed during a penalty."
            : snapshot.gold < Gold.fullRecoveryPrice ? "Need \((Gold.fullRecoveryPrice - snapshot.gold).formatted()) more gold." : nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("FULL RECOVERY")
                    .font(.subheadline.weight(.semibold))
                    .tracking(1.1)
                Spacer()
                Text("You have x\(snapshot.player.fullRecoveryBank)")
                    .font(.caption)
                    .foregroundStyle(SystemTheme.muted)
            }
            HStack(spacing: 10) {
                buyButton("BUY · \(Gold.fullRecoveryPrice.formatted())", enabled: blocker == nil) {
                    pending = .fullRecovery
                }
            }
            if let blocker { blockerText(blocker) }
        }
    }

    private func potionRow(_ potion: Potion) -> some View {
        let fullBlocker = snapshot.potionBlocker(potion, dose: .full)
        let halfBlocker = potion.hasHalfDose ? snapshot.potionBlocker(potion, dose: .half) : nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(potion.name)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(potion.stat.rawValue)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(SystemTheme.muted)
            }
            note(potion.details)
            HStack(spacing: 10) {
                buyButton("DRINK · \(snapshot.potionPrice(potion, dose: .full).formatted())", enabled: fullBlocker == nil) {
                    pending = .potion(potion, .full)
                }
                if potion.hasHalfDose {
                    buyButton("HALF · \(snapshot.potionPrice(potion, dose: .half).formatted())", enabled: halfBlocker == nil) {
                        pending = .potion(potion, .half)
                    }
                }
            }
            // A half dose usually waits on logged work, so only show its reason when the full dose is open.
            if let fullBlocker {
                blockerText(fullBlocker)
            } else if potion.hasHalfDose, let halfBlocker {
                blockerText("Half dose: " + halfBlocker)
            }
        }
    }

    // MARK: Purchase

    private var confirmTitle: String {
        switch pending {
        case .fullRecovery: "Buy one Full Recovery?"
        case .potion(let potion, let dose): dose == .half ? "Drink a half dose of \(potion.name)?" : "Drink \(potion.name)?"
        case nil: ""
        }
    }

    private func confirmButton(_ purchase: Purchase) -> String {
        switch purchase {
        case .fullRecovery: "Buy for \(Gold.fullRecoveryPrice.formatted()) gold"
        case .potion(let potion, let dose): "Drink for \(snapshot.potionPrice(potion, dose: dose).formatted()) gold"
        }
    }

    private func confirmMessage(_ purchase: Purchase) -> String {
        switch purchase {
        case .fullRecovery:
            ""
        case .potion(let potion, let dose):
            if potion.needsQuest {
                dose == .half
                    ? "It completes today's \(potion.stat.rawValue) quests. Half the work must be logged first. Today pays no gold."
                    : "It clears today's \(potion.stat.rawValue) quests. Today pays no gold."
            } else {
                "It skips no quest. The excuse applies to the \(potion.stat.rawValue) score. Today pays no gold."
            }
        }
    }

    private func buy(_ purchase: Purchase) {
        switch purchase {
        case .fullRecovery: store.buyFullRecovery()
        case .potion(let potion, let dose): store.usePotion(potion, dose: dose)
        }
        result = store.verificationNote
        pending = nil
    }

    // MARK: Pieces

    private func buyButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .monospacedDigit()
                .frame(maxWidth: .infinity, minHeight: 34)
                .overlay { Rectangle().stroke(QuestLight.ink.opacity(enabled ? 0.6 : 0.25), lineWidth: 0.8) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
    }

    private func blockerText(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(SystemTheme.muted.opacity(0.8))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(SystemTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview {
    ShopSheet()
        .environmentObject(GameStore(persistence: .memory))
}
