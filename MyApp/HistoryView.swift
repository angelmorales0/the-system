import SwiftUI
import Charts

struct HistoryView: View {
    private let goalCards = [
        GoalHistoryMock(title: "5:30 Mile", subtitle: "Run a sub 5:30 mile", start: "6:18", current: "5:56", predicted: "5:28", samples: [
            ChartSample(label: "Aug 12", actual: 18, forecast: nil), ChartSample(label: "Aug 19", actual: 29, forecast: nil), ChartSample(label: "Aug 26", actual: 37, forecast: nil), ChartSample(label: "Sep 5", actual: 49, forecast: 49), ChartSample(label: "Sep 12", actual: nil, forecast: 63), ChartSample(label: "Sep 19", actual: nil, forecast: 76), ChartSample(label: "Sep 29", actual: nil, forecast: 90)
        ]),
        GoalHistoryMock(title: "145 lb", subtitle: "Reach 145 lb bodyweight", start: "150.2 lb", current: "149.1 lb", predicted: "145.0 lb", samples: [
            ChartSample(label: "Aug 12", actual: 16, forecast: nil), ChartSample(label: "Aug 19", actual: 28, forecast: nil), ChartSample(label: "Aug 26", actual: 39, forecast: nil), ChartSample(label: "Sep 5", actual: 50, forecast: 50), ChartSample(label: "Sep 12", actual: nil, forecast: 66), ChartSample(label: "Sep 19", actual: nil, forecast: 79), ChartSample(label: "Sep 29", actual: nil, forecast: 92)
        ])
    ]

    var body: some View {
        ScreenContainer {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 28) {
                    Spacer().frame(height: 46)
                    HistorySectionTitle("GOALS")
                    HorizontalHistoryCards { ForEach(goalCards) { GoalHistoryCard(goal: $0) } }
                    HistorySectionTitle("STATS")
                    HorizontalHistoryCards { ForEach(Stat.allCases, id: \.self) { StatHistoryCard(stat: $0) } }
                }
                .padding(.bottom, 32)
            }
        }
    }
}

private struct GoalHistoryMock: Identifiable {
    let id = UUID(); let title: String; let subtitle: String; let start: String; let current: String; let predicted: String; let samples: [ChartSample]
}

private struct ChartSample: Identifiable {
    let id = UUID(); let label: String; let actual: Double?; let forecast: Double?
}

private struct HistorySectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { SystemTitle(text: text).padding(.horizontal, 22) }
}

private struct HorizontalHistoryCards<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 14) { content }.scrollTargetLayout().padding(.horizontal, 22)
        }
        .scrollTargetBehavior(.viewAligned)
    }
}

private struct GoalHistoryCard: View {
    let goal: GoalHistoryMock
    var body: some View {
        SystemPanel {
            VStack(alignment: .leading, spacing: 15) {
                VStack(alignment: .leading, spacing: 3) { Text(goal.title).font(.title3.weight(.semibold)).foregroundStyle(.white); Text(goal.subtitle).font(.caption).foregroundStyle(SystemTheme.muted) }
                SystemDivider()
                HStack(spacing: 12) { CompactMetric(label: "START", value: goal.start); CompactMetric(label: "CURRENT", value: goal.current); CompactMetric(label: "PREDICTED", value: goal.predicted) }
                SystemHistoryChart(samples: goal.samples)
                ChartLegend()
            }
        }
        .frame(width: 330)
    }
}

/// One stat's algorithm level (0...146) and its saved daily history. No prediction line: there is no forecast model yet.
private struct StatHistoryCard: View {
    @EnvironmentObject private var store: GameStore
    let stat: Stat

    private var level: Int { store.statLevels[stat] }

    /// The last 8 saved days, scaled to the 0...100 chart. Today's live level stands in when nothing is saved yet.
    private var samples: [ChartSample] {
        var series = store.statHistory.series(for: stat).suffix(8).map { (label: Self.label($0.dayKey), level: $0.level) }
        if series.isEmpty { series = [(label: "Today", level: level)] }
        return series.map { ChartSample(label: $0.label, actual: Double($0.level) / Double(StatLevel.maxLevel) * 100, forecast: nil) }
    }

    var body: some View {
        SystemPanel {
            VStack(alignment: .leading, spacing: 15) {
                VStack(alignment: .leading, spacing: 3) { Text(stat.rawValue).font(.title3.weight(.semibold)).foregroundStyle(.white); Text(stat.fullName).font(.caption).foregroundStyle(SystemTheme.muted) }
                SystemDivider()
                HStack(spacing: 12) {
                    CompactMetric(label: "CURRENT", value: "\(level)")
                    CompactMetric(label: "MAX", value: "\(StatLevel.maxLevel)")
                    CompactMetric(label: "TO GO", value: "\(StatLevel.maxLevel - level)")
                }
                SystemHistoryChart(samples: samples)
            }
        }
        .frame(width: 330)
    }

    /// "2026-10-17" → "Oct 17".
    private static func label(_ dayKey: String) -> String {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        guard parts.count == 3, (1...12).contains(parts[1]) else { return dayKey }
        return "\(months[parts[1] - 1]) \(parts[2])"
    }
}

private struct CompactMetric: View {
    let label: String; let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) { Text(label).font(.system(size: 9, weight: .semibold)).tracking(0.7).foregroundStyle(SystemTheme.muted); Text(value).font(.caption.monospacedDigit().weight(.medium)).foregroundStyle(.white) }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SystemHistoryChart: View {
    let samples: [ChartSample]

    /// First, middle, and last labels, so any number of samples gets three ticks at most.
    private var axisLabels: [String] {
        let labels = samples.map(\.label)
        guard let first = labels.first, let last = labels.last else { return [] }
        var picked = [first, labels[labels.count / 2], last]
        picked = picked.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        return picked
    }
    var body: some View {
        Chart {
            ForEach(samples.compactMap { sample in sample.actual.map { ChartPoint(id: sample.id, label: sample.label, value: $0) } }) { point in
                LineMark(x: .value("Date", point.label), y: .value("Improvement", point.value)).interpolationMethod(.catmullRom).foregroundStyle(SystemTheme.cyan).lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                PointMark(x: .value("Date", point.label), y: .value("Improvement", point.value)).foregroundStyle(.white).symbolSize(18)
            }
            ForEach(samples.compactMap { sample in sample.forecast.map { ChartPoint(id: sample.id, label: sample.label, value: $0) } }) { point in
                LineMark(x: .value("Date", point.label), y: .value("Improvement", point.value)).interpolationMethod(.catmullRom).foregroundStyle(SystemTheme.muted.opacity(0.9)).lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
        }
        .chartYScale(domain: 0...100)
        .chartXAxis {
            AxisMarks(values: axisLabels) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(SystemTheme.cyan.opacity(0.12))
                AxisValueLabel().foregroundStyle(SystemTheme.muted).font(.system(size: 9))
            }
        }
        .chartYAxis(.hidden)
        .frame(height: 150)
    }
}

private struct ChartPoint: Identifiable { let id: UUID; let label: String; let value: Double }

private struct ChartLegend: View {
    var body: some View {
        HStack(spacing: 14) { Label("ACTUAL", systemImage: "line.diagonal"); Label("PREDICTED", systemImage: "minus") }
            .font(.system(size: 9, weight: .semibold)).foregroundStyle(SystemTheme.muted)
    }
}

#Preview { HistoryView().environmentObject(GameStore(persistence: .memory)) }
