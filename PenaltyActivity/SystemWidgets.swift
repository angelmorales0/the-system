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
        // One entry each time a dash of the timer ring goes dark, then one as the day ends.
        if let data {
            entries += data.ringSteps(after: now).filter { $0 < data.dayEnds }.map { SystemEntry(date: $0, data: data) }
            if data.dayEnds > now { entries.append(SystemEntry(date: data.dayEnds, data: data)) }
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
        default: .small
        }
    }

    var body: some View {
        Group {
            if let data = entry.data, entry.date < data.dayEnds {
                design.view(data, size: size, now: entry.date)
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
        .containerBackground(for: .widget) { WidgetPalette.background }
    }
}

private extension WidgetSize {
    var family: WidgetFamily {
        switch self {
        case .small: .systemSmall
        case .medium: .systemMedium
        case .large: .systemLarge
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

struct NextQuestWidget: Widget { var body: some WidgetConfiguration { SystemDesignWidget(.nextQuest).body } }
struct RedSystemsWidget: Widget { var body: some WidgetConfiguration { SystemDesignWidget(.redSystems).body } }
struct SystemsGridWidget: Widget { var body: some WidgetConfiguration { SystemDesignWidget(.systemsGrid).body } }
