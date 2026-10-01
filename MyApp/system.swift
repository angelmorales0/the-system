import SwiftUI

@main struct MyApp: App {
    @StateObject private var gameStore = GameStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(gameStore)
        }
    }
}
