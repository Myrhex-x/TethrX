import WidgetKit
import SwiftUI

/// Complications for the watch face.
///
/// The point of a watch app like this one is not the app: it is knowing, without
/// raising your wrist very far, that Grok has stopped and is waiting on you. That is
/// a face complication, not a launcher. The watch app writes what it knows into the
/// shared app group; nothing here touches the network or the phone.
@main
struct TethrXWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        TethrXComplication()
    }
}

// MARK: - What the watch app leaves for us

/// Mirror of the watch app's snapshot. Separate module, separate copy; only the
/// coding keys have to agree.
struct ComplicationState: Codable {
    var waitingCount = 0
    var runningCount = 0
    var sessionCount = 0
    /// The session that is blocked, so the complication can name it and open it.
    var waitingName = ""
    var waitingSessionId = ""
    var updatedAt = Date()

    static let suiteName = "group.com.tethrx.app"
    static let key = "tethrx.watch.state"

    static func load() -> ComplicationState? {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ComplicationState.self, from: data)
    }

    enum Phase { case needsYou, working, idle, unpaired }

    var phase: Phase {
        if waitingCount > 0 { return .needsYou }
        if runningCount > 0 { return .working }
        return .idle
    }
}

struct ComplicationEntry: TimelineEntry {
    let date: Date
    let state: ComplicationState?

    var phase: ComplicationState.Phase { state?.phase ?? .unpaired }
}

struct ComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> ComplicationEntry {
        ComplicationEntry(date: Date(), state: ComplicationState(waitingCount: 1, runningCount: 1,
                                                                 sessionCount: 3, waitingName: "acme-app"))
    }
    func getSnapshot(in context: Context, completion: @escaping (ComplicationEntry) -> Void) {
        completion(ComplicationEntry(date: Date(), state: ComplicationState.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ComplicationEntry>) -> Void) {
        // The watch app reloads timelines the moment its state changes, which is the
        // only thing that can move this. The refresh is a safety net for a watch that
        // has not heard from its phone in a while.
        let entry = ComplicationEntry(date: Date(), state: ComplicationState.load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(1800))))
    }
}

struct TethrXComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TethrXComplication", provider: ComplicationProvider()) { entry in
            ComplicationView(entry: entry)
                .containerBackground(.clear, for: .widget)
                .widgetURL(entry.link)
        }
        .configurationDisplayName("Grok status")
        .description("Whether Grok is working, and whether it needs you.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

extension ComplicationEntry {
    /// A complication that is reporting a block should open THAT session, not the list.
    var link: URL? {
        guard let id = state?.waitingSessionId, !id.isEmpty, phase == .needsYou else { return nil }
        return URL(string: "tethrx://session/\(id)")
    }

    var glyph: String {
        switch phase {
        case .needsYou: return "hand.raised.fill"
        case .working:  return "circle.hexagongrid.fill"
        case .idle:     return "moon.zzz"
        case .unpaired: return "bolt.horizontal.circle"
        }
    }
    var word: LocalizedStringKey {
        switch phase {
        case .needsYou: return "needs you"
        case .working:  return "working"
        case .idle:     return "idle"
        case .unpaired: return "not paired"
        }
    }
    /// The number worth showing on a face: what is blocked, else what is running.
    var count: Int? {
        guard let state else { return nil }
        if state.waitingCount > 0 { return state.waitingCount }
        if state.runningCount > 0 { return state.runningCount }
        return nil
    }
}

struct ComplicationView: View {
    let entry: ComplicationEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline:
            Label { Text(entry.word) } icon: { Image(systemName: entry.glyph) }

        case .accessoryCorner:
            Image(systemName: entry.glyph)
                .font(.system(size: 17, weight: .semibold))
                .widgetLabel { Text(entry.word) }

        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: entry.glyph).font(.system(size: 11, weight: .semibold))
                    Text(verbatim: "TETHRX").font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(0.6)
                }
                .widgetAccentable()
                Text(entry.word).font(.system(size: 15, weight: .semibold))
                // Shrunk rather than cut. This second line is the one that tells a
                // brand-new user how to fix an unpaired watch, and at full size it
                // overruns a 41mm face in English and every translation of it. Sans,
                // because it is a sentence: the mono face was also costing width.
                Text(detail).font(.system(size: 11)).opacity(0.7)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

        default:   // .accessoryCircular
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: entry.glyph).font(.system(size: 13, weight: .semibold))
                    if let count = entry.count {
                        Text(verbatim: "\(count)").font(.system(size: 13, weight: .bold)).monospacedDigit()
                    }
                }
            }
            .accessibilityLabel(Text(verbatim: "TethrX"))
            .accessibilityValue(Text(entry.word))
        }
    }

    /// The second line: what is blocked, or how much is going on.
    private var detail: String {
        guard let state = entry.state else { return String(localized: "Open TethrX on your iPhone") }
        if state.waitingCount > 0, !state.waitingName.isEmpty { return state.waitingName }
        if state.runningCount > 0 {
            return state.runningCount == 1
                ? String(localized: "1 session running")
                : String(localized: "\(state.runningCount) sessions running")
        }
        return state.sessionCount == 1
            ? String(localized: "1 session")
            : String(localized: "\(state.sessionCount) sessions")
    }
}
