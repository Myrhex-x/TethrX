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
                mark(22)
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
                // The leading/trailing regions sit BESIDE the sensor cutout, where
                // width is scarce and the island's curves clip anything wide — a
                // text badge there lost its last letters. Icons only up top; the
                // words live in the full-width bottom region, padded clear of the
                // rounded corners (which otherwise shaved the first character).
                DynamicIslandExpandedRegion(.leading) {
                    mark(20).padding(.leading, 6).padding(.top, 2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: glyph(context.state.phase))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.trailing, 6).padding(.top, 2)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(alignment: .lastTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(context.attributes.sessionName)
                                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                .lineLimit(1)
                            Text(context.state.detail)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text(label(context.state.phase))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(context.state.phase == "waiting" || context.state.phase == "error" ? .white : .white.opacity(0.7))
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                }
            } compactLeading: {
                mark(16)
            } compactTrailing: {
                Image(systemName: glyph(context.state.phase))
            } minimal: {
                Image(systemName: glyph(context.state.phase))
            }
        }
    }

    /// The "T" logo, tinted white for the dark Live Activity surface.
    @ViewBuilder private func mark(_ size: CGFloat) -> some View {
        Image("TethrXLogo")
            .resizable().renderingMode(.template).interpolation(.high).scaledToFit()
            .frame(width: size, height: size).foregroundStyle(.white)
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
        case "waiting": return String(localized: "APPROVE")
        case "done": return String(localized: "DONE")
        case "error": return String(localized: "ERROR")
        default: return String(localized: "WORKING")
        }
    }
}
