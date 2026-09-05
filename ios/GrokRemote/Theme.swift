import SwiftUI
import UIKit

/// The Grok app's language, as closely as a third-party client should take it: a
/// pure black canvas, sans-serif for everything a person reads, monospace reserved
/// for what is literally code, circular outline icon buttons, and generous corner
/// radii on soft translucent surfaces.
///
/// The console look this replaced (mono everywhere, `// EYEBROW` comment headers, a
/// `>` prompt in the composer) said "terminal". It is a phone.
enum Grok {
    // MARK: Canvas
    static let bg = Color.black
    static let raised = Color.white.opacity(0.07)                   // cards, bubbles, fields
    static let raisedPressed = Color.white.opacity(0.14)
    static let hairline = Color.white.opacity(0.10)
    static let hairlineStrong = Color.white.opacity(0.20)

    // MARK: Shape
    /// One radius scale, so nothing is rounded by accident. Grok's surfaces are much
    /// softer than a 10pt terminal box.
    enum R {
        static let card: CGFloat = 20
        static let bubble: CGFloat = 22
        static let field: CGFloat = 24
        static let small: CGFloat = 14
    }

    // MARK: Ink
    static let text = Color.white
    static let textDim = Color.white.opacity(0.60)
    static let textFaint = Color.white.opacity(0.38)

    // MARK: Accent — monochrome. (The warm gradient read as too loud; xAI is
    // "confidently sparse", so the sole accent is simply white.)
    static let accent = Color.white
    static let danger = Color(red: 1.0, green: 0.45, blue: 0.45)   // errors only

    // MARK: Type
    // Scaled with the user's Dynamic Type setting: `.system(size:)` alone ignores
    // it entirely, which made the text-size accessibility setting a no-op here.
    // The root view caps growth at the first accessibility size so layouts hold.
    /// Reserved for what IS code: commands, diffs, file contents, ids. Everywhere
    /// else, prose belongs in the sans face.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: UIFontMetrics.default.scaledValue(for: size), weight: weight, design: .monospaced)
    }
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: UIFontMetrics.default.scaledValue(for: size), weight: weight)
    }
    /// Body copy, at the size Grok actually uses. Bigger than a terminal wants.
    static func body(_ weight: Font.Weight = .regular) -> Font { sans(17, weight) }
    /// Secondary line under a title.
    static func caption(_ weight: Font.Weight = .regular) -> Font { sans(14, weight) }
}

// MARK: - Eyebrow (mono, uppercase, reads like a code comment)

struct Eyebrow: View {
    let text: String
    /// Kept for source compatibility; the `// ` prefix is gone either way.
    var comment: Bool = true
    /// Localizes then uppercases. The uppercasing has to stay: every key in the
    /// catalog is authored uppercase, so lowercasing here would only be right in
    /// English.
    init(_ key: LocalizedStringResource, comment: Bool = true) {
        self.text = String(localized: key).uppercased()
        self.comment = comment
    }
    var body: some View {
        Text(text)
            .font(Grok.sans(12, .semibold))
            .tracking(0.6)
            .foregroundStyle(Grok.textFaint)
    }
}

// MARK: - Outline pill button (the xAI interactive primitive)

struct PillButton: ButtonStyle {
    enum Kind { case prominent, subtle }
    var kind: Kind = .prominent

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        // Prominent is a FILLED white capsule with black ink, the way Grok's primary
        // actions read. The old outline-on-black version made every button look
        // equally optional.
        return configuration.label
            .font(Grok.sans(16, .semibold))
            .foregroundStyle(kind == .prominent ? Color.black : Grok.text)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(kind == .prominent
                        ? Color.white.opacity(pressed ? 0.85 : 1.0)
                        : Color.white.opacity(pressed ? 0.16 : 0.08))
            .clipShape(Capsule())
            .contentShape(Capsule())
    }
}

// MARK: - Segmented pill (single choice among a row)

struct SegPill: ButtonStyle {
    var selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        // Selected = an outlined capsule; unselected = bare grey text, no chrome at
        // all. That contrast is what makes Grok's header read as one control rather
        // than a row of buttons.
        configuration.label
            .font(Grok.sans(15, selected ? .semibold : .regular))
            .foregroundStyle(selected ? Grok.text : Grok.textFaint)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(selected ? Color.white.opacity(0.10) : .clear)
            .overlay(Capsule().stroke(selected ? Grok.hairlineStrong : .clear, lineWidth: 1))
            .clipShape(Capsule())
            .contentShape(Capsule())
    }
}

// MARK: - Compact chat control chip (toggles/menus by the composer)

extension View {
    /// Small capsule for chat controls. Soft translucent fill when off, solid white
    /// when on — no hairline outlines, which read as terminal chrome.
    func chip(on: Bool) -> some View {
        self
            .font(Grok.sans(13, .medium))
            .foregroundStyle(on ? Color.black : Grok.textDim)
            .padding(.horizontal, 13).padding(.vertical, 8)
            .background(on ? Color.white : Color.white.opacity(0.08))
            .clipShape(Capsule())
    }
}

// MARK: - Hairline-bordered input container

struct FieldBox<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Grok.raised)
            .clipShape(RoundedRectangle(cornerRadius: Grok.R.field, style: .continuous))
    }
}

// MARK: - Small circular outline icon button (send / stop / add)

struct CircleIconButton: View {
    let system: String
    var filled = false
    var danger = false
    var enabled = true
    /// Replaces the icon with a spinner (and disables) while an action runs, so a
    /// tapped button visibly works instead of just going quiet.
    var busy = false
    /// VoiceOver name — icon-only buttons are otherwise read as their symbol name.
    /// Stays a `String` because one caller hands over an already-translated string;
    /// the label is resolved through the string table at render time instead, so
    /// plain literals get translated and an already-translated string passes through
    /// untouched. Rendering it as `Text(a11y)` left every label English.
    var a11y: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                // Translucent fill plus a thin ring: Grok's corner buttons are legible
                // over anything without drawing a hard box around themselves.
                Circle()
                    .fill(filled ? AnyShapeStyle(Grok.accent) : AnyShapeStyle(Color.white.opacity(0.08)))
                    .overlay(Circle().stroke(filled ? .clear : Grok.hairlineStrong, lineWidth: 1))
                if busy {
                    ProgressView().controlSize(.small).tint(filled ? .black : .white)
                } else {
                    Image(systemName: system)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(filled ? .black : (danger ? Grok.danger : (enabled ? Grok.text : Grok.textFaint)))
                }
            }
            .frame(width: 42, height: 42)
            // The ring stays 40pt; the tap target has to be 44pt.
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .disabled(!enabled || busy)
        .accessibilityLabel(Text(LocalizedStringKey(a11y ?? system)))
        .accessibilityValue(busy ? Text("busy") : Text(""))
    }
}

// MARK: - Reusable dark toolbar styling

extension View {
    /// Make a NavigationStack's bar match the canvas.
    func grokBar() -> some View {
        self
            .toolbarBackground(Grok.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

// MARK: - Brand mark (the "T" logo)

/// The TethrX "T" logo, tinted to the current ink color. It's a template image, so
/// it follows `foregroundStyle` exactly like the ">_" glyph it replaces throughout.
struct TethrXMark: View {
    var size: CGFloat
    var color: Color = Grok.accent
    var body: some View {
        Image("TethrXLogo")
            .resizable()
            .renderingMode(.template)
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }
}

// MARK: - Haptics

/// Thin wrapper over UIKit feedback generators for light interaction polish.
enum Haptics {
    static func tap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    /// Grok has stopped and is waiting on you. Deliberately not the light tap every
    /// button uses: this one is meant to be felt without looking.
    static func attention() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}
