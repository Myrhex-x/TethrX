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

/// Mirror of the watch app's ComplicationState. Separate module, separate copy; only
/// the coding keys have to agree. Synthesized Codable throws on a missing key even
/// when the property has a default, so a field added to both copies later must be
/// optional here, or state written by an older watch build stops decoding and the
/// face falls back to "Open TethrX on your iPhone".
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

    enum Phase { case needsYou, working, idle, unknown }

    var phase: Phase {
        if waitingCount > 0 { return .needsYou }
        if runningCount > 0 { return .working }
        return .idle
    }
}

struct ComplicationEntry: TimelineEntry {
    let date: Date
    /// Nil until the watch app has heard from the phone at least once. That says
    /// nothing about pairing, only that the phone app has not been opened yet.
    let state: ComplicationState?

    var phase: ComplicationState.Phase { state?.phase ?? .unknown }

    /// How strongly the Smart Stack should surface this: to the top while Grok is
    /// waiting on you, a little while it works, not at all otherwise. Holds until the
    /// next entry, which the watch app asks for the moment anything changes.
    var relevance: TimelineEntryRelevance? {
        switch phase {
        case .needsYou: return TimelineEntryRelevance(score: 100)
        case .working:  return TimelineEntryRelevance(score: 10)
        case .idle, .unknown: return TimelineEntryRelevance(score: 0)
        }
    }
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
        // The watch app reloads timelines the moment its state changes, including
        // when a snapshot lands while it is closed, which is the only thing that can
        // move this. The refresh is a safety net for a watch that has not heard from
        // its phone in a while.
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
        case .unknown:  return "iphone"
        }
    }

    /// The status in a word, or for a watch that has heard nothing yet, the one thing
    /// to do about it. Short enough for the inline slot and the corner's curve.
    var word: LocalizedStringKey {
        switch phase {
        case .needsYou: return "needs you"
        case .working:  return "working"
        case .idle:     return "idle"
        case .unknown:  return "Open on iPhone"
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
                .font(.title3.weight(.semibold))
                .widgetLabel { Text(entry.word) }

        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 0) {
                Label {
                    Text(verbatim: "TethrX")
                } icon: {
                    Image(systemName: entry.glyph)
                }
                .font(.headline)
                .widgetAccentable()
                .lineLimit(1)
                if entry.state == nil {
                    // The one case with an instruction rather than a status, and the
                    // first thing a new user sees: it gets both remaining lines.
                    Text("Open TethrX on your iPhone")
                        .font(.body)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                } else {
                    Text(entry.word)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

        default:   // .accessoryCircular
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: entry.glyph).font(.body.weight(.semibold))
                    if let count = entry.count {
                        Text(verbatim: "\(count)").font(.body.weight(.bold)).monospacedDigit()
                    }
                }
            }
            .accessibilityLabel(Text(verbatim: "TethrX"))
            .accessibilityValue(entry.state == nil ? Text("Open TethrX on your iPhone") : Text(entry.word))
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
