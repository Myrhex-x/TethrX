import SwiftUI
import UIKit

/// The Grok app's language, as closely as a third-party client should take it: a
/// pure black canvas, sans-serif for everything a person reads, monospace reserved
/// for what is literally code, circular outline icon buttons, and generous corner
/// radii on soft translucent surfaces.
///
/// The console look this replaced (mono everywhere, `// EYEBROW` comment headers, a
/// `>` prompt in the composer) said "terminal". It is a phone.
///
/// Every token resolves per appearance (see `Appearance`). The default dark is a
/// near-black, not #000, with off-white ink: full white on full black blooms at the
/// edges of every glyph (halation, worst for anyone with astigmatism) and smears on
/// OLED while scrolling, which is most of what makes a black app tiring to read.
/// Pure black is still there for people who want it, and light is a warm paper
/// rather than a white light box.
enum Grok {
    // MARK: Ink
    /// The one foreground color everything else is a strength of: off-white on the
    /// dark canvases, near-black on paper. `ink.opacity(x)` is how a surface, a rule
    /// or a pressed state is drawn, so all of them follow the appearance for free.
    static let ink = dynamic(dark: UIColor(white: 0.93, alpha: 1),
                             light: UIColor(red: 0.086, green: 0.086, blue: 0.10, alpha: 1))
    /// Ink on a filled `ink` surface: the label of a primary button, a selected chip.
    static let onInk = dynamic(dark: UIColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1),
                               light: UIColor(red: 0.98, green: 0.98, blue: 0.97, alpha: 1))

    // MARK: Canvas
    /// The page itself. A style rather than a `Color`, because it is the one token
    /// that differs between Dark and Black, and only a style is handed the
    /// environment when it resolves (a dynamic `UIColor` sees UIKit's traits alone).
    /// Where a plain view is needed, `Grok.bg.ignoresSafeArea()` still reads the same.
    static let bg = CanvasStyle()
    static let raised = ink.opacity(0.055)                          // panels, bubbles, fields
    static let raisedPressed = ink.opacity(0.14)
    static let hairline = ink.opacity(0.10)
    static let hairlineStrong = ink.opacity(0.20)

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
    /// One height for everything sitting in the composer's control row: the add
    /// button, the chips, the mic. Measured on device that row ran 32.0, 34.3, 31.7
    /// and 32.3 points side by side, because each control was sized by whatever glyph
    /// happened to be inside it. A 2.6pt spread across four adjacent things reads as
    /// carelessness long before anyone can say why.
    static let control: CGFloat = 34

    /// A single hairline. Structure here is drawn with rules and space rather than
    /// with filled boxes stacked on filled boxes.
    static let rule = ink.opacity(0.09)

    // MARK: Text
    static let text = ink
    static let textDim = dynamic(dark: UIColor(white: 0.93, alpha: 0.66),
                                 light: UIColor(red: 0.086, green: 0.086, blue: 0.10, alpha: 0.70))
    /// The quietest text that is still text. It used to be 38% white, about 3.4:1
    /// on black, under the 4.5:1 floor for small type, and it carried every subtitle,
    /// timestamp and hint in the app. Each value here clears 4.5:1 on its own canvas.
    static let textFaint = dynamic(dark: UIColor(white: 0.93, alpha: 0.52),
                                   light: UIColor(red: 0.086, green: 0.086, blue: 0.10, alpha: 0.60))

    // MARK: Accent — monochrome. (The warm gradient read as too loud; xAI is
    // "confidently sparse", so the sole accent is simply the ink.)
    static let accent = ink
    static let danger = dynamic(dark: UIColor(red: 1.0, green: 0.47, blue: 0.47, alpha: 1),
                                light: UIColor(red: 0.76, green: 0.12, blue: 0.13, alpha: 1))   // errors only

    /// A color per appearance. Dark and Black share it: only the canvas changes
    /// between the two, and everything drawn on it is the same ink.
    static func dynamic(dark: UIColor, light: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .light ? light : dark
        })
    }

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

/// The page color: near-black, pure black or paper.
struct CanvasStyle: ShapeStyle, View {
    static let dark = Color(red: 0.063, green: 0.063, blue: 0.071)
    static let light = Color(red: 0.965, green: 0.965, blue: 0.953)

    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        let color = environment.colorScheme == .light ? Self.light
            : (environment.pureBlack ? Color.black : Self.dark)
        return color.resolve(in: environment)
    }

    /// Drawn as a view: `Grok.bg.ignoresSafeArea()` behind a screen.
    var body: some View { Rectangle().fill(self) }

    /// A fade from clear into the canvas, top to bottom, for content scrolling
    /// under a bar. `stops` are the canvas's opacity at evenly spaced points.
    func fade(_ stops: [Double]) -> some View {
        Rectangle().fill(self).mask(
            LinearGradient(colors: stops.map { Color.black.opacity($0) },
                           startPoint: .top, endPoint: .bottom))
    }
}

// MARK: - Appearance

/// How the app is lit, chosen in Settings → Appearance.
enum Appearance: String, CaseIterable, Identifiable {
    /// Follows the phone: paper by day, dark by night if the phone switches.
    case system
    /// Near-black canvas, off-white ink. The default.
    case dark
    /// True #000 canvas, the same ink: OLED pixels fully off.
    case black
    /// Warm paper canvas, near-black ink.
    case light

    static let storageKey = "appearance"
    static let fallback: Appearance = .dark
    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark, .black: return .dark
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .system: return "Automatic"
        case .dark: return "Dark"
        case .black: return "Black"
        case .light: return "Light"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .system: return "Follows your iPhone's light and dark setting."
        case .dark: return "A soft near-black with off-white text. Easiest on the eyes at night."
        case .black: return "Pure black for OLED screens. Highest contrast."
        case .light: return "A warm paper background with dark text, for daylight."
        }
    }
}

extension Appearance {
    /// The title as a plain string, for the value column of the Settings index.
    var label: String {
        switch self {
        case .system: return String(loc: "Automatic")
        case .dark: return String(loc: "Dark")
        case .black: return String(loc: "Black")
        case .light: return String(loc: "Light")
        }
    }
}

/// How big a conversation reads. Separate from Dynamic Type on purpose: someone who
/// wants a long reply set larger rarely wants every button and label in the app to
/// grow with it, and that is the only thing the system setting can do.
enum ReadingSize: String, CaseIterable, Identifiable {
    case standard, large, larger

    static let storageKey = "reading.size"
    static let fallback: ReadingSize = .standard
    var id: String { rawValue }

    var scale: CGFloat {
        switch self {
        case .standard: return 1.0
        case .large: return 1.12
        case .larger: return 1.25
        }
    }

    var title: Text {
        switch self {
        case .standard: return Text("Standard")
        case .large: return Text("Large")
        case .larger: return Text("Larger")
        }
    }

    /// Leading that grows with the type: a fixed 5pt is generous at 17 and cramped
    /// at 21, and long replies are where cramped leading costs the most.
    static func lineSpacing(for size: CGFloat) -> CGFloat { (size * 0.34).rounded() }
}

private struct ReadingScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// Set once by the conversation from `ReadingSize`, read by every bubble in it.
    var readingScale: CGFloat {
        get { self[ReadingScaleKey.self] }
        set { self[ReadingScaleKey.self] = newValue }
    }
}

/// One appearance, drawn in itself: the swatch resolves its own colors under the
/// option it stands for rather than the one the app is currently in.
struct AppearanceSwatch: View {
    let option: Appearance
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                preview
                    .frame(height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: Grok.R.small, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Grok.R.small, style: .continuous)
                        .strokeBorder(selected ? Grok.ink : Grok.hairline, lineWidth: selected ? 2 : 1))
                HStack(spacing: 6) {
                    Text(option.title).font(Grok.sans(15, selected ? .semibold : .regular))
                        .foregroundStyle(Grok.text)
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Grok.text)
                            .accessibilityHidden(true)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(option.title))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var preview: some View {
        switch option {
        case .system:
            HStack(spacing: 0) {
                page.environment(\.colorScheme, .light)
                page.environment(\.colorScheme, .dark)
            }
        case .light:
            page.environment(\.colorScheme, .light)
        case .dark:
            page.environment(\.colorScheme, .dark).environment(\.pureBlack, false)
        case .black:
            page.environment(\.colorScheme, .dark).environment(\.pureBlack, true)
        }
    }

    /// A conversation in miniature: something you said, then a reply.
    private var page: some View {
        ZStack(alignment: .topLeading) {
            Grok.bg
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Spacer(minLength: 0)
                    Capsule().fill(Grok.ink.opacity(0.10)).frame(width: 38, height: 12)
                }
                Capsule().fill(Grok.text).frame(height: 5).frame(maxWidth: 64)
                Capsule().fill(Grok.textDim).frame(height: 5).frame(maxWidth: 52)
                Capsule().fill(Grok.textFaint).frame(height: 5).frame(maxWidth: 40)
            }
            .padding(10)
        }
    }
}

/// Whether the dark canvas is pure black. Read by `CanvasStyle` as it resolves, so
/// switching between Dark and Black repaints at once, under an open Settings sheet,
/// without rebuilding anything.
private struct PureBlackKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var pureBlack: Bool {
        get { self[PureBlackKey.self] }
        set { self[PureBlackKey.self] = newValue }
    }
}

/// Applies the chosen appearance. Every sheet carries it too: a sheet is its own
/// presentation, and the dark-only app used to pin each one to `.dark` by hand.
private struct GrokScheme: ViewModifier {
    @AppStorage(Appearance.storageKey) private var raw = Appearance.fallback.rawValue
    func body(content: Content) -> some View {
        let appearance = Appearance(rawValue: raw) ?? Appearance.fallback
        content
            .environment(\.pureBlack, appearance == .black)
            .preferredColorScheme(appearance.colorScheme)
    }
}

extension View {
    func grokScheme() -> some View { modifier(GrokScheme()) }
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
    /// A `Text`, not a resolved `String`: SwiftUI resolves a `LocalizedStringKey`
    /// through the bundle, which is what follows the app's own language setting.
    /// Resolving it here with `String(localized:)` pinned every heading in the app to
    /// the language iOS launched in.
    private let label: Text
    /// Smaller under a numeral, where the label is a unit and not a heading.
    var size: CGFloat = 13
    init(_ key: LocalizedStringKey, size: CGFloat = 13) {
        self.label = Text(key); self.size = size
    }
    init(verbatim: String, size: CGFloat = 13) { self.label = Text(verbatim: verbatim); self.size = size }

    var body: some View {
        label
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
    let label: LocalizedStringKey
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
            .foregroundStyle(kind == .prominent ? Grok.onInk : Grok.text)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, compact ? 12 : 15)
            .background(kind == .prominent
                        ? Grok.ink.opacity(pressed ? 0.85 : 1.0)
                        : Grok.ink.opacity(pressed ? 0.16 : 0.08))
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
            .background(selected ? Grok.ink.opacity(0.10) : .clear)
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

/// Icon and label at one weight, in a fixed-width icon column.
///
/// The icon used to set the chip's height, so a tall glyph (a clipboard) made a
/// taller chip than a squat one (a gauge), and the row came out ragged. Here the
/// glyph is drawn inside a box it cannot exceed.
struct ChipLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 14, height: 14)
            configuration.title.lineLimit(1)
        }
    }
}

extension View {
    /// Small capsule for chat controls. Soft translucent fill when off, solid white
    /// when on — no hairline outlines, which read as terminal chrome.
    func chip(on: Bool) -> some View {
        self
            .font(Grok.sans(13, .medium))
            .foregroundStyle(on ? Grok.onInk : Grok.textDim)
            .labelStyle(ChipLabelStyle())
            .padding(.horizontal, 11)
            .frame(height: Grok.control)
            .background(on ? Grok.ink : Grok.ink.opacity(0.08))
            .clipShape(Capsule())
            .contentShape(Capsule())
    }

    /// The round twin of `chip`, for the icon-only controls that bracket the row.
    func roundControl(on: Bool = false) -> some View {
        self
            .frame(width: Grok.control, height: Grok.control)
            .background(on ? Grok.ink : Grok.ink.opacity(0.08), in: Circle())
            .contentShape(Circle())
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
                    .fill(filled ? AnyShapeStyle(Grok.accent) : AnyShapeStyle(Grok.ink.opacity(0.08)))
                    .overlay(Circle().stroke(filled ? .clear : Grok.hairlineStrong, lineWidth: 1))
                if busy {
                    ProgressView().controlSize(.small).tint(filled ? Grok.onInk : Grok.ink)
                } else {
                    Image(systemName: system)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(filled ? Grok.onInk : (danger ? Grok.danger : (enabled ? Grok.text : Grok.textFaint)))
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
    /// Make a NavigationStack's bar match the canvas. The bar's own scheme follows
    /// the app's appearance (`grokScheme`), so its title and buttons stay legible.
    func grokBar() -> some View {
        self
            .toolbarBackground(Grok.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
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
                .background(Grok.ink.opacity(0.05), in: shape)
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(colors: [Grok.ink.opacity(0.20), Grok.ink.opacity(0.06)],
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
