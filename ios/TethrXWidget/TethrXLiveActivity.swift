import SwiftUI
import WidgetKit
import ActivityKit

/// Live Activity: a glanceable "Grok is working… / waiting for your approval"
/// status on the lock screen and Dynamic Island.
struct TethrXLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TethrXActivityAttributes.self) { context in
            // Lock screen / banner
            HStack(spacing: 12) {
                Text(">_").font(.system(size: 20, weight: .bold, design: .monospaced)).foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.sessionName)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
                    Text(context.state.detail)
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer(minLength: 6)
                badge(context.state.phase)
            }
            .padding(16)
            .activityBackgroundTint(Color.black)
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(">_").font(.system(size: 18, weight: .bold, design: .monospaced)).foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.trailing) { badge(context.state.phase) }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.sessionName).font(.system(size: 14, weight: .semibold, design: .monospaced))
                        Text(context.state.detail).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Text(">_").font(.system(size: 13, weight: .bold, design: .monospaced))
            } compactTrailing: {
                Image(systemName: glyph(context.state.phase))
            } minimal: {
                Image(systemName: glyph(context.state.phase))
            }
        }
    }

    @ViewBuilder private func badge(_ phase: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: glyph(phase)).font(.system(size: 11, weight: .semibold))
            Text(label(phase)).font(.system(size: 11, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(phase == "waiting" || phase == "error" ? .white : .white.opacity(0.7))
    }

    private func glyph(_ phase: String) -> String {
        switch phase {
        case "waiting": return "hand.raised.fill"
        case "done": return "checkmark"
        case "error": return "exclamationmark.triangle.fill"
        default: return "circle.hexagongrid.fill"
        }
    }
    private func label(_ phase: String) -> String {
        switch phase {
        case "waiting": return "APPROVE"
        case "done": return "DONE"
        case "error": return "ERROR"
        default: return "WORKING"
        }
    }
}
