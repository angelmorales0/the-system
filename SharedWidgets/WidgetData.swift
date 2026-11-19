import Foundation
import SwiftUI

/// What the home and lock screen widgets show. The app writes it to the app group on every save
/// (`GameStore.writeWidgetData`), and the widget extension reads it. This folder is in both targets.
struct WidgetData: Codable, Equatable {
    enum State: String, Codable {
        case done, open, failed
    }

    /// One quest row, as the quest screen shows it.
    struct Row: Codable, Equatable, Hashable {
        var title: String
        /// "[3/10km]"
        var progress: String
        var state: State
        var required: Bool
        /// 0...1, for the progress bar.
        var fraction: Double
    }

    /// One Systems row: today's state and the last 7 days, oldest first (nil: no mark that day).
    struct System: Codable, Equatable, Hashable {
        var name: String
        var today: State
        var week: [State?]
        var streak: Int
    }

    var dayKey: String
    /// The quest day ends (midnight).
    var dayEnds: Date
    /// "Bench Day"
    var header: String
    var quests: [Row]
    var systems: [System]
    /// The open penalty quest's title.
    var penalty: String?
    var level: Int
    /// 0...1 to the next level.
    var levelProgress: Double
    var hp: Int
    var maxHP: Int
    var gold: Int
    var updatedAt: Date

    var questsLeft: [Row] { quests.filter { $0.required && $0.state != .done } }
    var requiredCount: Int { quests.filter(\.required).count }
    var requiredDone: Int { quests.filter { $0.required && $0.state == .done }.count }
    /// Systems that are not blue today: failed, or still open (a hand habit not marked fails at midnight).
    var redSystems: [System] { systems.filter { $0.today != .done } }

    static let suite = "group.com.angelmorales.thesystem"
    static let key = "com.angelmorales.thesystem.widgetData.v1"

    static func load() -> WidgetData? {
        guard let data = UserDefaults(suiteName: suite)?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetData.self, from: data)
    }

    /// Saves, and returns true when the data changed.
    @discardableResult
    func save() -> Bool {
        guard self != Self.load(), let data = try? JSONEncoder().encode(self) else { return false }
        UserDefaults(suiteName: Self.suite)?.set(data, forKey: Self.key)
        return true
    }

    /// For previews and the gallery.
    static let sample = WidgetData(
        dayKey: "2026-11-19",
        dayEnds: Date().addingTimeInterval(5 * 3600 + 23 * 60),
        header: "Bench Day",
        quests: [
            Row(title: "10K Run", progress: "[6.2/10km]", state: .open, required: true, fraction: 0.62),
            Row(title: "Bench Day", progress: "[16/16]", state: .done, required: true, fraction: 1),
            Row(title: "Home by 9 pm", progress: "[0/1]", state: .open, required: true, fraction: 0),
            Row(title: "Screen Time", progress: "[212/500min]", state: .open, required: false, fraction: 0.42),
            Row(title: "Stretching", progress: "[0/20min]", state: .open, required: true, fraction: 0),
        ],
        systems: [
            System(name: "Home by 9 pm", today: .open, week: [.done, .done, .failed, .done, .done, .done, nil], streak: 3),
            System(name: "Screen Time", today: .done, week: [.done, .done, .done, .done, .failed, .done, .done], streak: 2),
            System(name: "Stretching", today: .open, week: [.done, .failed, .done, .done, .done, .done, nil], streak: 4),
            System(name: "No eating out", today: .done, week: [nil, nil, nil, nil, nil, .done, .done], streak: 2),
            System(name: "No caffeine", today: .failed, week: [nil, nil, nil, nil, nil, .done, .failed], streak: 0),
            System(name: "Only whole foods", today: .open, week: [nil, nil, nil, nil, nil, .done, nil], streak: 1),
            System(name: "Log written", today: .done, week: [.done, .done, .done, .failed, .done, .done, .done], streak: 3),
        ],
        penalty: nil,
        level: 42,
        levelProgress: 0.63,
        hp: 812,
        maxHP: 1040,
        gold: 3_480,
        updatedAt: Date()
    )
}

/// The app's colors, for the widgets.
enum WidgetPalette {
    static let ink = Color(red: 0.87, green: 0.97, blue: 1)
    static let cyan = Color(red: 0.20, green: 0.80, blue: 1)
    static let blue = Color(red: 0.08, green: 0.42, blue: 1)
    static let red = Color(red: 1, green: 0.12, blue: 0.32)
    static let gold = Color(red: 1, green: 0.84, blue: 0.2)
    static let dim = Color(red: 0.87, green: 0.97, blue: 1).opacity(0.45)
    static let background = LinearGradient(colors: [Color(red: 0.02, green: 0.05, blue: 0.12), Color(red: 0.03, green: 0.10, blue: 0.22)],
                                           startPoint: .top, endPoint: .bottom)

    static func color(_ state: WidgetData.State) -> Color {
        switch state {
        case .done: cyan
        case .open: ink.opacity(0.85)
        case .failed: red
        }
    }
}
