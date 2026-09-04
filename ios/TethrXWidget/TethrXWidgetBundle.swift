import WidgetKit
import SwiftUI

@main
struct TethrXWidgetBundle: WidgetBundle {
    var body: some Widget {
        TethrXLiveActivity()
        TethrXStatusWidget()
    }
}

// MARK: - Home screen status widget

/// Mirror of the app's snapshot. The widget is its own module, so it carries its own
/// copy of the shape; only the JSON keys need to agree.
struct TethrXSnapshot: Codable {
    var computer = ""
    var sessionCount = 0
    var runningCount = 0
    var activeName = ""
    var totalTokens = 0
    var costUSD: Double = 0
    var updatedAt = Date()
    var waitingCount = 0
    var waitingName = ""
    var waitingSessionId = ""
}

struct StatusEntry: TimelineEntry {
    let date: Date
    let snapshot: TethrXSnapshot?
}

struct StatusProvider: TimelineProvider {
    static let suiteName = "group.com.tethrx.app"
    static let key = "tethrx.snapshot"

    private func load() -> TethrXSnapshot? {
        guard let defaults = UserDefaults(suiteName: Self.suiteName),
              let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(TethrXSnapshot.self, from: data)
    }

    func placeholder(in context: Context) -> StatusEntry { StatusEntry(date: Date(), snapshot: nil) }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(StatusEntry(date: Date(), snapshot: load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        // The app reloads timelines whenever it publishes; this is just a safety net.
        let entry = StatusEntry(date: Date(), snapshot: load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(900))))
    }
}

struct TethrXStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TethrXStatus", provider: StatusProvider()) { entry in
            StatusWidgetView(entry: entry)
        }
        .configurationDisplayName("Grok status")
        .description("Whether your computer's Grok is working, and whether it needs you.")
        // The lock-screen families matter most here: the question this widget answers
        // is "is it waiting on me?", and that is a glance, not an unlock.
        .supportedFamilies([.systemSmall, .systemMedium,
                            .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

/// The three states the widget can report, in the order they matter.
enum GrokState {
    case needsYou, working, idle, unpaired

    static func of(_ snapshot: TethrXSnapshot?) -> GrokState {
        guard let snapshot else { return .unpaired }
        if snapshot.waitingCount > 0 { return .needsYou }
        if snapshot.runningCount > 0 { return .working }
        return .idle
    }

    var glyph: String {
        switch self {
        case .needsYou: return "hand.raised.fill"
        case .working:  return "circle.hexagongrid.fill"
        case .idle:     return "moon.zzz"
        case .unpaired: return "bolt.horizontal.circle"
        }
    }
    var word: LocalizedStringKey {
        switch self {
        case .needsYou: return "needs you"
        case .working:  return "working"
        case .idle:     return "idle"
        case .unpaired: return "not paired"
        }
    }
}

struct StatusWidgetView: View {
    let entry: StatusEntry
    @Environment(\.widgetFamily) private var family

    private var snapshot: TethrXSnapshot? { entry.snapshot }
    private var state: GrokState { GrokState.of(snapshot) }

    var body: some View {
        content.widgetURL(link)
    }

    /// A tap on "needs you" opens the session that is asking. Anything else just
    /// opens the app, which is what a widget with nothing pending should do.
    private var link: URL? {
        guard state == .needsYou, let id = snapshot?.waitingSessionId, !id.isEmpty else { return nil }
        return URL(string: "tethrx://session/\(id)")
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryInline:
            Label { Text(state.word) } icon: { Image(systemName: state.glyph) }
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 1) {
                    Image(systemName: state.glyph).font(.system(size: 14, weight: .semibold))
                    if let snapshot, snapshot.waitingCount > 0 {
                        Text(verbatim: "\(snapshot.waitingCount)").font(.system(size: 12, weight: .bold)).monospacedDigit()
                    } else if let snapshot, snapshot.runningCount > 0 {
                        Text(verbatim: "\(snapshot.runningCount)").font(.system(size: 12, weight: .bold)).monospacedDigit()
                    }
                }
            }
            .containerBackground(.clear, for: .widget)
            .accessibilityLabel(Text(verbatim: "TethrX"))
            .accessibilityValue(Text(state.word))
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: state.glyph).font(.system(size: 11, weight: .semibold))
                    Text("TETHRX").font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(0.8)
                }
                .widgetAccentable()
                Text(state.word).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 11, design: .monospaced)).opacity(0.7).lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .containerBackground(.clear, for: .widget)
        default:
            home.containerBackground(Color.black, for: .widget)
        }
    }

    /// The second line: what is waiting, what is running, or which computer this is.
    private var detail: String {
        guard let snapshot else { return String(localized: "Open TethrX to connect") }
        if snapshot.waitingCount > 0 {
            return snapshot.waitingName.isEmpty ? String(localized: "an approval is pending") : snapshot.waitingName
        }
        if snapshot.runningCount > 0, !snapshot.activeName.isEmpty { return snapshot.activeName }
        return snapshot.computer
    }

    // MARK: Home screen

    private var home: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image("TethrXLogo")
                    .resizable().renderingMode(.template).scaledToFit()
                    .frame(width: 15, height: 15).foregroundStyle(.white)
                Text("TETHRX")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.1).foregroundStyle(.white)
                Spacer(minLength: 0)
                if let s = snapshot, s.waitingCount > 0 {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                }
            }

            if let s = snapshot {
                HStack(spacing: 6) {
                    Circle()
                        .fill(state == .idle ? Color.white.opacity(0.3) : Color.white)
                        .frame(width: 7, height: 7)
                    Text(state.word)
                        .font(.system(size: family == .systemSmall ? 19 : 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.7).lineLimit(1)
                }
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(state == .needsYou ? 0.75 : 0.5))
                    .lineLimit(1).truncationMode(.tail)

                Spacer(minLength: 0)

                HStack(spacing: 12) {
                    stat("\(s.sessionCount)", "sessions")
                    if family != .systemSmall {
                        if s.totalTokens > 0 { stat(tokens(s.totalTokens), "tokens") }
                        if s.costUSD > 0 { stat(String(format: "$%.2f", s.costUSD), "cost") }
                    }
                }
            } else {
                Text("Not paired")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                Text("Open TethrX to connect")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func stat(_ value: String, _ caption: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
            Text(caption).font(.system(size: 8, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
        }
    }

    private func tokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
        if n >= 1_000 { return String(format: "%.0fk", Double(n) / 1e3) }
        return "\(n)"
    }
}
