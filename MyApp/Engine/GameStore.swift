import SwiftUI

enum GamePersistence {
    /// Saved on this device. Checkbox completion and XP survive relaunch.
    case standard
    /// Previews and checks. Does not touch UserDefaults.
    case memory
}

@MainActor
final class GameStore: ObservableObject {
    @Published private(set) var snapshot: GameSnapshot
    private let catalog: FallbackCatalog
    private let persistence: GamePersistence

    init(persistence: GamePersistence = .standard) {
        let catalog = FallbackCatalog.bundled()
        self.catalog = catalog
        self.persistence = persistence
        switch persistence {
        case .memory:
            snapshot = GameSnapshot.fresh(catalog: catalog)
        case .standard:
            snapshot = GameSnapshot.loadFromUserDefaults() ?? GameSnapshot.fresh(catalog: catalog)
            snapshot.refreshIfNeeded(catalog: catalog)
            persist()
        }
    }

    var player: PlayerState { snapshot.player }
    var bundle: QuestBundle { snapshot.bundle }
    var goalQuests: [Quest] { bundle.goalQuests }

    func toggleQuest(id: String) {
        var next = snapshot
        next.toggleQuest(id: id)
        snapshot = next
        persist()
    }

    func refreshForToday() {
        var next = snapshot
        next.refreshIfNeeded(catalog: catalog)
        snapshot = next
        persist()
    }

    private func persist() {
        guard persistence == .standard else { return }
        snapshot.saveToUserDefaults()
    }
}
