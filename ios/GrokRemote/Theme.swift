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
    static let raised = Color.white.opacity(0.05)                   // panels, bubbles, fields
    static let raisedPressed = Color.white.opacity(0.14)
    static let hairline = Color.white.opacity(0.10)
    static let hairlineStrong = Color.white.opacity(0.20)

    // MARK: Shape
    /// One radius scale, so nothing is rounded by accident.
    ///
    /// Structure is tighter than conversation: a card is a panel and reads precise,
    /// while a bubble and the composer stay soft because they are things you speak
    /// into and out of.
    enum R {
        static let card: CGFloat = 16
        static let bubble: CGFloat = 22
        static let field: CGFloat = 26
        static let small: CGFloat = 12
    }

    // MARK: Measure
    /// Screen edge to the edge of any block: card, row, banner, header, composer.
    /// One value, everywhere, or the eye reads the drift as sloppiness long before
    /// it can name it.
    static let gutter: CGFloat = 16
    /// A block's own edge to the content inside it. `gutter + pad` is therefore the
    /// left edge of every piece of reading matter in the app, whether or not the
    /// thing it sits in draws a background.
    static let pad: CGFloat = 14
    /// Between two blocks in a stack.
    static let gap: CGFloat = 10
    /// Between two groups of blocks.
    static let groupGap: CGFloat = 22

    /// A single hairline. Structure here is drawn with rules and space rather than
    /// with filled boxes stacked on filled boxes.
    static let rule = Color.white.opacity(0.09)

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
    /// A screen's own name. Big, and tracked in rather than out — the tightening is
    /// what makes a large grotesque read as engineered instead of merely large.
    static func display(_ size: CGFloat = 28) -> Font { sans(size, .semibold) }
}

extension Grok {
    /// Whether the app is currently running in a language whose script has no use for
    /// letter-spacing. Resolved once from the bundle's chosen localization rather than
    /// per string, because in a Japanese UI every label is Japanese.
    static let cjkLocale: Bool = {
        let code = Bundle.main.preferredLocalizations.first?.prefix(2).lowercased() ?? "en"
        return code == "ja" || code == "zh" || code == "ko"
    }()
}

extension Text {
    /// Tracking is Latin micro-typography. Opened out it pulls a Japanese word apart,
    /// and the negative values the display face uses make the glyphs collide, so in
    /// those languages this is simply no tracking at all.
    func latinTracking(_ amount: CGFloat) -> Text {
        tracking(Grok.cjkLocale ? 0 : amount)
    }
}

/// The one heading in the app: quiet grey, sentence case, the weight of a label
/// rather than a shout.
///
/// It replaced two others that both said the same thing in wide-tracked capitals.
/// Capitals are an instrument label, and they are convincing on a dense technical
/// panel, but almost nothing here is one: shouting "PINNED" over two conversations
/// is louder than the conversations, and a home screen that speaks quietly should
/// not open a sheet that shouts. This is the register Grok's own sidebar uses.
///
/// No line limit by default. A heading that reads "Usage" in English reads "Valores
/// por defecto para sesiones nuevas" in Spanish, and truncating a heading loses the
/// only thing on the row that says what the rows below it are. Callers that really
/// are tight on width (a folder name beside a count and a menu) ask for one.
struct ListSectionLabel: View {
    let text: String
    /// Smaller under a numeral, where the label is a unit and not a heading.
    var size: CGFloat = 13
    init(_ key: LocalizedStringResource, size: CGFloat = 13) {
        self.text = String(localized: key); self.size = size
    }
    init(verbatim: String, size: CGFloat = 13) { self.text = verbatim; self.size = size }

    var body: some View {
        Text(text)
            // Semibold at 60%, which is the only small semibold text in the app.
            // Faint grey worked over the home list, where the rows underneath are
            // white and bold, and inverted the hierarchy everywhere else: in Settings
            // a heading came out dimmer and lighter than the paragraph it headed.
            .font(Grok.sans(size, .semibold))
            .foregroundStyle(Grok.textDim)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A number worth reading as an instrument: tabular figures, a tracked caption.
struct Readout: View {
    let value: String
    let label: LocalizedStringResource
    var emphasis: Color = Grok.text

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(Grok.sans(20, .semibold)).monospacedDigit()
                .foregroundStyle(emphasis)
            ListSectionLabel(label, size: 12)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Outline pill button (the xAI interactive primitive)

struct PillButton: ButtonStyle {
    enum Kind { case prominent, subtle }
    var kind: Kind = .prominent
    /// Tighter geometry for buttons that share a row rather than owning one. A
    /// stack of full-height pills is how a card gets tall enough to need scrolling
    /// before you have read what you are approving.
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        // Prominent is a FILLED white capsule with black ink, the way Grok's primary
        // actions read. The old outline-on-black version made every button look
        // equally optional.
        return configuration.label
            .font(Grok.sans(compact ? 15 : 16, .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundStyle(kind == .prominent ? Color.black : Grok.text)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, compact ? 12 : 15)
            .background(kind == .prominent
                        ? Color.white.opacity(pressed ? 0.85 : 1.0)
                        : Color.white.opacity(pressed ? 0.16 : 0.08))
            .clipShape(Capsule())
            .contentShape(Capsule())
    }
}

// MARK: - Quiet tertiary action

/// Text alone, no capsule. For the actions a card offers but does not recommend,
/// where a third and fourth pill would make the card taller than the thing it is
/// asking about.
struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Grok.sans(13, .medium))
            .foregroundStyle(configuration.isPressed ? Grok.text : Grok.textDim)
            .lineLimit(1)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
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
            // The pill reads best at about 34pt tall, which is not a target. The extra
            // padding is transparent and sits outside the capsule, so the shape is
            // unchanged and the thing you tap is 44pt.
            .padding(.vertical, 5)
            .contentShape(Rectangle())
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
            .padding(.horizontal, 10).padding(.vertical, 8)
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

// MARK: - Liquid Glass

/// Liquid Glass, where it belongs.
///
/// iOS 26 renders the control layer as a lens: it refracts what scrolls underneath
/// it and catches light along its own rim, rather than being a frosted sheet laid
/// flat on top. That is a property of things that FLOAT above the page — the bar at
/// the bottom of the list, the composer you type into — and it is the wrong material
/// for the page itself. A conversation, an approval, a banner: glass under those
/// only puts moving content behind the words, which is the one thing this app cannot
/// afford. So it is used in exactly two places, and both of them float.
///
/// Below iOS 26 the same shapes get that era's answer to the same problem: a
/// vibrancy material, a faint tint, and a rim that is brighter at the top than the
/// bottom. The geometry is identical either way; only the material changes.
extension View {
    @ViewBuilder
    func floatingGlass<S: InsettableShape>(in shape: S, interactive: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(interactive), in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .background(Color.white.opacity(0.05), in: shape)
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(colors: [Color.white.opacity(0.20), Color.white.opacity(0.06)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
                )
        }
    }
}

/// Floating glass controls that sit near one another belong in one of these.
///
/// Inside a container they sample a single backdrop and render in one pass, so a row
/// of them reads as one instrument instead of three separate lenses that each found
/// a slightly different answer for the same patch of screen behind them. Shapes that
/// come within `mergeWithin` of each other flow together; the default is deliberately
/// tighter than any spacing this app uses, so nothing merges by accident.
struct GlassCluster<Content: View>: View {
    var mergeWithin: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: mergeWithin) { content }
        } else {
            content
        }
    }
}

extension View {
    /// The soft blur the system draws where scrolling content passes under a floating
    /// bar. Before iOS 26 that was a gradient painted by hand, which is what the
    /// callers fall back to.
    @ViewBuilder
    func softScrollEdge(_ edges: Edge.Set) -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: edges)
        } else {
            self
        }
    }

    /// Content pinned along the bottom that the list scrolls underneath.
    ///
    /// The distinction matters on iOS 26: a plain safe-area inset is just reserved
    /// space, and the system leaves the rows passing behind it perfectly sharp right
    /// down to the bezel, so the bar reads as floating in the middle of a list. A
    /// *bar* is a thing the list ends at, and the system softens the content into it.
    @ViewBuilder
    func floatingBottomBar<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if #available(iOS 26.0, *) {
            self.safeAreaBar(edge: .bottom, content: content)
        } else {
            self.safeAreaInset(edge: .bottom, content: content)
        }
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
