import ActivityKit
import SwiftUI
import WidgetKit

@main
struct PenaltyActivityBundle: WidgetBundle {
    var body: some Widget {
        PenaltyLiveActivity()
    }
}

struct PenaltyLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PenaltyAttributes.self) { context in
            VStack(alignment: .leading, spacing: 4) {
                Text("PENALTY ACTIVE")
                    .font(.caption.weight(.bold))
                Text(context.state.questTitle)
                    .font(.headline)
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    Text("PENALTY ACTIVE — \(context.state.questTitle)")
                        .font(.headline)
                }
            } compactLeading: {
                Text("P")
            } compactTrailing: {
                Text(context.state.questTitle)
                    .lineLimit(1)
            } minimal: {
                Text("P")
            }
        }
    }
}
