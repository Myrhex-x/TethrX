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
                .containerBackground(Color.black, for: .widget)
        }
        .configurationDisplayName("Grok status")
        .description("Whether your computer's Grok is working, and what it's cost.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct StatusWidgetView: View {
    let entry: StatusEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image("TethrXLogo")
                    .resizable().renderingMode(.template).scaledToFit()
                    .frame(width: 15, height: 15).foregroundStyle(.white)
                Text("TETHRX")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.1).foregroundStyle(.white)
                Spacer(minLength: 0)
            }

            if let s = entry.snapshot {
                HStack(spacing: 6) {
                    Circle()
                        .fill(s.runningCount > 0 ? Color.white : Color.white.opacity(0.3))
                        .frame(width: 7, height: 7)
                    Text(s.runningCount > 0 ? "working" : "idle")
                        .font(.system(size: family == .systemSmall ? 19 : 22, weight: .semibold))
                        .foregroundStyle(.white)
                }
                if s.runningCount > 0, !s.activeName.isEmpty {
                    Text(s.activeName)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                } else if !s.computer.isEmpty {
                    Text(s.computer)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45)).lineLimit(1).truncationMode(.tail)
                }

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

    private func stat(_ value: String, _ caption: String) -> some View {
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
