import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

extension WidgetData {
    /// The widgets' picture of today, from the game.
    @MainActor
    static func from(_ store: GameStore, now: Date = .now) -> WidgetData {
        let game = store.snapshot
        func state(_ status: QuestStatus) -> State {
            switch status {
            case .completed: .done
            case .failed, .expired: .failed
            case .pending: .open
            }
        }
        let quests = game.bundle.quests.filter { $0.kind != .penalty }.map { quest in
            Row(title: quest.title, progress: quest.progress.bracketLabel, state: state(quest.status),
                required: quest.kind != .optional && quest.id != ScreenTime.questId,
                fraction: quest.progress.target > 0 ? min(quest.progress.current / quest.progress.target, 1) : 0)
        }
        let today = game.bundle.dayKey
        let systems = SystemsView.tracks(game).map { track -> System in
            let limit = track.handHabit?.weeklyLimit != nil
            func mapped(_ mark: SystemsView.Mark) -> State? {
                switch mark {
                case .done: .done
                case .missed: .failed
                case .none: nil
                }
            }
            // Today's place: the last day, or today's day in a 7-day week.
            let index = track.dayKeys.firstIndex(of: today) ?? (track.marks.count - 1)
            let todayMark = track.marks.indices.contains(index) ? track.marks[index] : .none
            // A limit habit (Traveling) passes with no mark; every other row is open until it is done.
            let todayState = mapped(todayMark) ?? (limit ? .done : .open)
            var week = Array(track.marks.prefix(index + 1).suffix(7)).map(mapped)
            while week.count < 7 { week.insert(nil, at: 0) }
            return System(name: track.name, today: todayState, week: week, streak: track.streak)
        }
        let levels = store.statLevels
        let scaled = Double(StatLevelSet.overallMaxLevel) * levels.overallFraction
        let hp = store.hitPoints
        return WidgetData(
            dayKey: today,
            dayEnds: QuestDay.endOfDay(now),
            header: game.bundle.headerLine,
            quests: quests,
            systems: systems,
            penalty: store.openPenaltyQuest?.title,
            level: levels.overallLevel,
            levelProgress: levels.isAllMax ? 1 : max(0, min(scaled - Double(levels.overallLevel), 1)),
            hp: hp.current,
            maxHP: hp.max,
            updatedAt: now,
            ringStart: store.dayClock.startedAt,
            ringEnd: store.dayClock.deadline,
            warning: game.bundle.warningCopy.replacingOccurrences(of: "\n", with: " ")
        )
    }
}

extension GameStore {
    /// Saves today's picture for the widgets, and reloads them when it changed.
    /// The update time is left out of the compare, so a save with nothing new does not reload them.
    func writeWidgetData(now: Date = .now) {
        var next = WidgetData.from(self, now: now)
        if var old = WidgetData.load() {
            old.updatedAt = next.updatedAt
            old.dayEnds = next.dayEnds
            if old == next { return }
        }
        next.updatedAt = now
        guard next.save() else { return }
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
