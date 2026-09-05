import SwiftUI

/// The phone app's language, at watch scale: near-black canvas, white outline
/// pills, a mono eyebrow that reads like a code comment, red reserved for danger.
enum Grok {
    static let bg = Color.black
    static let raised = Color.white.opacity(0.08)
    static let hairline = Color.white.opacity(0.16)
    static let hairlineStrong = Color.white.opacity(0.28)

    static let text = Color.white
    static let textDim = Color.white.opacity(0.62)
    static let textFaint = Color.white.opacity(0.38)
    static let accent = Color.white
    static let danger = Color(red: 1.0, green: 0.45, blue: 0.45)

    /// The phone's radius scale, at the one size the watch is small enough to need,
    /// so nothing here is rounded by accident.
    enum R {
        static let small: CGFloat = 12
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

/// Mono, uppercase, slightly tracked: the same section marker the phone uses.
struct Eyebrow: View {
    let text: String
    /// Localized and uppercased here rather than with `.textCase`, because the
    /// tracking below has to be decided from the translated string.
    init(text key: LocalizedStringResource) { self.text = String(localized: key).uppercased() }

    var body: some View {
        Text(text)
            .font(Grok.mono(10, .medium))
            // Letter-spacing is a Latin device. Applied to Japanese or Chinese it
            // only pulls a word apart, and uppercasing does nothing there at all, so
            // in those languages this is simply a small dim label.
            .tracking(text.isCJK ? 0 : 1.0)
            .foregroundStyle(Grok.textDim)
    }
}

extension String {
    /// True when the string carries Han, Kana or Hangul, i.e. when Latin
    /// micro-typography should be left alone. The phone target has its own copy of
    /// this: the two share a look, not a module.
    var isCJK: Bool {
        unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value)      // kana
            || (0x3400...0x4DBF).contains(scalar.value)   // CJK ext A
            || (0x4E00...0x9FFF).contains(scalar.value)   // CJK unified
            || (0xF900...0xFAFF).contains(scalar.value)   // compatibility ideographs
            || (0xAC00...0xD7AF).contains(scalar.value)   // hangul
        }
    }
}

/// The TethrX "T", tinted like everything else.
struct TethrXMark: View {
    var size: CGFloat
    var color: Color = Grok.accent
    var body: some View {
        Image("TethrXLogo")
            .resizable().renderingMode(.template).interpolation(.high).scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }
}

/// Full-width outline pill. `danger` fills red, for the one button that refuses.
struct WatchPill: ButtonStyle {
    enum Kind { case prominent, subtle, danger }
    var kind: Kind = .subtle

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(Grok.sans(15, .semibold))
            // The three guards the phone's PillButton already carries, at watch
            // values. Without the inset a translated label reaches the capsule's caps
            // and the clip shaves it. Two lines rather than one truncated line,
            // because "Metti in coda un messaggio" does not fit a 41mm face at any
            // scale still worth reading; the scale factor is the backstop under that,
            // for a German compound too long to break.
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            .foregroundStyle(kind == .prominent ? Color.black : (kind == .danger ? Grok.danger : Grok.text))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(background(pressed))
            .overlay(Capsule().stroke(strokeColor, lineWidth: 1))
            .clipShape(Capsule())
            .contentShape(Capsule())
            .opacity(pressed ? 0.85 : 1)
    }

    private func background(_ pressed: Bool) -> Color {
        switch kind {
        case .prominent: return .white
        case .danger:    return Grok.danger.opacity(pressed ? 0.28 : 0.14)
        case .subtle:    return Color.white.opacity(pressed ? 0.16 : 0.06)
        }
    }
    private var strokeColor: Color {
        switch kind {
        case .prominent: return .clear
        case .danger:    return Grok.danger.opacity(0.5)
        case .subtle:    return Grok.hairlineStrong
        }
    }
}

/// A ticking "4m" for a session that is running or blocked. A badge alone is the
/// same shape at four seconds and at forty minutes.
struct ElapsedLabel: View {
    let since: Date?
    var body: some View {
        if let since {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Fmt.elapsed(since: since, now: context.date))
                    .font(Grok.sans(12)).monospacedDigit()
                    .foregroundStyle(Grok.textFaint)
            }
            .accessibilityHidden(true)
        }
    }
}
