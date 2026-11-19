import SwiftUI
import WidgetKit

/// One moment of a widget: the app's last saved data, or nil before the app ever saved any.
struct SystemEntry: TimelineEntry {
    let date: Date
    let data: WidgetData?
}

/// Reads what the app saved. The app reloads every widget when its data changes; the timeline also
/// runs again at midnight, so a new day never shows yesterday's quests.
struct SystemProvider: TimelineProvider {
    func placeholder(in context: Context) -> SystemEntry {
        SystemEntry(date: .now, data: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (SystemEntry) -> Void) {
        completion(SystemEntry(date: .now, data: context.isPreview ? (WidgetData.load() ?? .sample) : WidgetData.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SystemEntry>) -> Void) {
        let data = WidgetData.load()
        let now = Date.now
        var entries = [SystemEntry(date: now, data: data)]
        if let ends = data?.dayEnds, ends > now {
            entries.append(SystemEntry(date: ends, data: data))
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
    }
}

/// Draws a design in a widget: the app's background, and a note when the saved day is over.
struct SystemWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let design: WidgetDesign
    let entry: SystemEntry

    private var size: WidgetSize {
        switch family {
        case .systemSmall: .small
        case .systemMedium: .medium
        case .systemLarge, .systemExtraLarge: .large
        case .accessoryCircular: .circular
        case .accessoryRectangular: .rectangular
        case .accessoryInline: .inline
        default: .small
        }
    }

    private var isLock: Bool { [.circular, .rectangular, .inline].contains(size) }

    var body: some View {
        Group {
            if let data = entry.data, entry.date < data.dayEnds {
                design.view(data, size: size)
            } else if isLock {
                Text(size == .inline ? "Open The System" : "OPEN THE SYSTEM")
                    .font(.system(size: 12, weight: .bold))
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "bolt.horizontal.circle")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(WidgetPalette.cyan)
                    Text("A NEW DAY HAS ARRIVED")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(WidgetPalette.ink)
                    Text("Open The System to see today's quests.")
                        .font(.system(size: 10))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(WidgetPalette.dim)
                }
            }
        }
        .containerBackground(for: .widget) {
            if isLock { Color.clear } else { WidgetPalette.background }
        }
    }
}

private extension WidgetSize {
    var family: WidgetFamily {
        switch self {
        case .small: .systemSmall
        case .medium: .systemMedium
        case .large: .systemLarge
        case .circular: .accessoryCircular
        case .rectangular: .accessoryRectangular
        case .inline: .accessoryInline
        }
    }
}

/// One widget per design. The design's id is the widget kind.
struct SystemDesignWidget {
    let design: WidgetDesign
    let kind: String

    init(_ design: WidgetDesign) {
        self.design = design
        kind = design.rawValue
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SystemProvider()) { entry in
            SystemWidgetView(design: design, entry: entry)
        }
        .configurationDisplayName(design.name)
        .description(design.summary)
        .supportedFamilies(design.sizes.map(\.family))
    }
}

struct QuestsLeftWidget: Widget { var body: some WidgetConfiguration { SystemDesignWidget(.questsLeft).body } }
struct QuestListWidget: Widget { var body: some WidgetConfiguration { SystemDesignWidget(.questList).body } }
struct RedSystemsWidget: Widget { var body: some WidgetConfiguration { SystemDesignWidget(.redSystems).body } }
struct SystemsGridWidget: Widget { var body: some WidgetConfiguration { SystemDesignWidget(.systemsGrid).body } }
struct DailyBoardWidget: Widget { var body: some WidgetConfiguration { SystemDesignWidget(.dailyBoard).body } }
struct CountdownWidget: Widget { var body: some WidgetConfiguration { SystemDesignWidget(.countdown).body } }
struct StatusWidget: Widget { var body: some WidgetConfiguration { SystemDesignWidget(.status).body } }
struct NextQuestWidget: Widget { var body: some WidgetConfiguration { SystemDesignWidget(.nextQuest).body } }
struct PenaltyWatchWidget: Widget { var body: some WidgetConfiguration { SystemDesignWidget(.penalty).body } }
struct LockProgressWidget: Widget { var body: some WidgetConfiguration { SystemDesignWidget(.lockProgress).body } }
struct LockSummaryWidget: Widget { var body: some WidgetConfiguration { SystemDesignWidget(.lockSummary).body } }
struct LockInlineWidget: Widget { var body: some WidgetConfiguration { SystemDesignWidget(.lockInline).body } }

/// A bundle lists at most 10 widgets, so the designs come in two groups.
struct HomeScreenWidgets: WidgetBundle {
    var body: some Widget {
        QuestsLeftWidget()
        QuestListWidget()
        RedSystemsWidget()
        SystemsGridWidget()
        DailyBoardWidget()
        CountdownWidget()
        StatusWidget()
        NextQuestWidget()
        PenaltyWatchWidget()
    }
}

struct LockScreenWidgets: WidgetBundle {
    var body: some Widget {
        LockProgressWidget()
        LockSummaryWidget()
        LockInlineWidget()
    }
}
