import SwiftUI
import UIKit

/// The app's visual language: the system's own colors and materials, the way an
/// Apple app is built, with the brand kept to one mark and one monochrome accent.
///
/// Every color here is a system semantic color. That is what makes light and dark
/// look right without a second thought (Apple tuned them for both), keeps the app in
/// step with Increase Contrast and Smart Invert, and is most of why a screen reads as
/// native: the greys are the greys the rest of the phone uses.
enum Grok {
    // MARK: Ink
    /// The label color: white on dark, near-black on light. Filled primary buttons
    /// are drawn in it, with `onInk` for their own label.
    static let ink = Color(uiColor: .label)
    static let onInk = Color(uiColor: .systemBackground)

    // MARK: Canvas
    /// Screens made of lists and cards (home, Settings): the grouped background the
    /// system's Settings and Notes sit on. Black in dark, soft grey in light.
    static let bg = Color(uiColor: .systemGroupedBackground)
    /// A conversation's page: the plain background, black or white, like Messages.
    static let page = Color(uiColor: .systemBackground)
    /// A card on `bg`: elevated grey in dark, white in light.
    static let raised = Color(uiColor: .secondarySystemGroupedBackground)
    /// A panel on `page`: the same elevated grey in dark, a soft grey in light so it
    /// still reads as a surface on white.
    static let panel = Color(uiColor: .secondarySystemBackground)
    /// What you said, in a conversation: the grey a received bubble has in Messages.
    static let bubble = Color(uiColor: .systemGray5)
    static let raisedPressed = Color(uiColor: .tertiarySystemFill)
    static let hairline = Color(uiColor: .separator)
    static let hairlineStrong = Color(uiColor: .opaqueSeparator)
    /// A single hairline. Structure here is drawn with rules and space rather than
    /// with filled boxes stacked on filled boxes.
    static let rule = Color(uiColor: .separator)

    // MARK: Shape
    /// One radius scale, so nothing is rounded by accident.
    ///
    /// Structure is tighter than conversation: a card is a panel and reads precise,
    /// while a bubble and the composer stay soft because they are things you speak
    /// into and out of.
    enum R {
        static let card: CGFloat = 16
        static let bubble: CGFloat = 20
        static let field: CGFloat = 24
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
    /// button, the chips, the mic.
    static let control: CGFloat = 34

    // MARK: Text
    static let text = Color(uiColor: .label)
    static let textDim = Color(uiColor: .secondaryLabel)
    /// Apple's hierarchy has two tiers of reading text, not three: a row is a label
    /// and a secondary label. The third tier used to carry timestamps and hints at a
    /// contrast under what small type needs; those are secondary now too.
    static let textFaint = Color(uiColor: .secondaryLabel)
    /// Placeholder text only: the one place the system goes fainter than secondary.
    static let placeholder = Color(uiColor: .tertiaryLabel)

    // MARK: Accent: monochrome. The sole accent is the ink; red is for errors and
    // destructive actions, the way the system uses it.
    static let accent = Color(uiColor: .label)
    static let danger = Color(uiColor: .systemRed)

    /// A fade from clear into `color`, top to bottom, for content scrolling under a
    /// bar. `stops` are the color's opacity at evenly spaced points.
    static func fade(_ color: Color, _ stops: [Double]) -> some View {
        Rectangle().fill(color).mask(
            LinearGradient(colors: stops.map { Color.black.opacity($0) },
                           startPoint: .top, endPoint: .bottom))
    }

    // MARK: Type
    // Scaled with the user's Dynamic Type setting: `.system(size:)` alone ignores
    // it entirely, which made the text-size accessibility setting a no-op here.
    // The root view caps growth at the first accessibility size so layouts hold.
    /// Reserved for what IS code: commands, diffs, file contents, ids. Everywhere
    /// else, prose belongs in the sans face.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: scaled(size), weight: weight, design: .monospaced)
    }
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: scaled(size), weight: weight)
    }

    /// The largest text size the app lays out for. GrokRemoteApp caps SwiftUI's own
    /// text styles at the same size (`.dynamicTypeSize(...accessibility1)`).
    static let largestTextSize = UIContentSizeCategory.accessibilityMedium

    /// `size` at the reader's text size, capped where the app caps it. UIFontMetrics
    /// reads the system setting directly and never saw that cap, so every font built
    /// here kept growing to the largest accessibility size (13pt became about 40pt)
    /// while the system text styles beside it stopped, and fixed-height chips clipped.
    static func scaled(_ size: CGFloat) -> CGFloat {
        let reader = UIApplication.shared.preferredContentSizeCategory
        let capped = reader > largestTextSize ? largestTextSize : reader
        return UIFontMetrics.default.scaledValue(for: size,
                                                 compatibleWith: UITraitCollection(preferredContentSizeCategory: capped))
    }
    /// Body copy, at the size Grok actually uses. Bigger than a terminal wants.
    static func body(_ weight: Font.Weight = .regular) -> Font { sans(17, weight) }
    /// Secondary line under a title.
    static func caption(_ weight: Font.Weight = .regular) -> Font { sans(14, weight) }
    /// A screen's own name. Big, and tracked in rather than out: the tightening is
    /// what makes a large grotesque read as engineered instead of merely large.
    static func display(_ size: CGFloat = 28) -> Font { sans(size, .semibold) }
}

// MARK: - Appearance

/// How the app is lit, chosen in Settings → Appearance. Automatic is the default,
/// as it is in every Apple app: the phone already knows whether it is night.
enum Appearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "appearance"
    static let fallback: Appearance = .system
    var id: String { rawValue }

    /// The stored value, or the default. An earlier build offered a separate pure
    /// black; that is what dark is now, so the old choice lands there.
    static func stored(_ raw: String) -> Appearance {
        Appearance(rawValue: raw) ?? (raw == "black" ? .dark : fallback)
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .system: return "Automatic"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .system: return "Follows your iPhone's light and dark setting."
        case .light: return "Light backgrounds with dark text."
        case .dark: return "Black backgrounds with light text, easiest on OLED screens at night."
        }
    }

    /// The title as a plain string, for the value column of the Settings index.
    var label: String {
        switch self {
        case .system: return String(loc: "Automatic")
        case .light: return String(loc: "Light")
        case .dark: return String(loc: "Dark")
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
                        .strokeBorder(selected ? Color.accentColor : Grok.hairline, lineWidth: selected ? 2 : 1))
                HStack(spacing: 6) {
                    Text(option.title).font(.subheadline.weight(selected ? .semibold : .regular))
                        .foregroundStyle(Grok.text)
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.accentColor)
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
            page.environment(\.colorScheme, .dark)
        }
    }

    /// A conversation in miniature: something you said, then a reply.
    private var page: some View {
        ZStack(alignment: .topLeading) {
            Grok.page
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Spacer(minLength: 0)
                    Capsule().fill(Grok.bubble).frame(width: 38, height: 12)
                }
                Capsule().fill(Grok.text).frame(height: 5).frame(maxWidth: 64)
                Capsule().fill(Grok.textDim).frame(height: 5).frame(maxWidth: 52)
                Capsule().fill(Grok.textDim.opacity(0.6)).frame(height: 5).frame(maxWidth: 40)
            }
            .padding(10)
        }
    }
}

/// Applies the chosen appearance. Every sheet carries it too: a sheet is its own
/// presentation, and the dark-only app used to pin each one to `.dark` by hand.
private struct GrokScheme: ViewModifier {
    @AppStorage(Appearance.storageKey) private var raw = Appearance.fallback.rawValue
    func body(content: Content) -> some View {
        content.preferredColorScheme(Appearance.stored(raw).colorScheme)
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
            // Sentence case wherever it sits, including a list section header, which
            // would otherwise set it in capitals on some versions of iOS.
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - List rows

/// A row's symbol in a rounded square, as Settings draws them. Grey, so the brand
/// stays monochrome while the shape says "a place you can go".
struct RowIcon: View {
    let system: String
    var tint: Color = Color(uiColor: .systemGray)
    var size: CGFloat = 29
    var body: some View {
        Image(systemName: system)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The disclosure chevron a list row shows when it opens something.
struct RowChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color(uiColor: .tertiaryLabel))
            .accessibilityHidden(true)
    }
}

/// A row that shares its list cell with another control (the ••• menu) and so
/// cannot use the cell's own highlight: it draws the same grey while pressed.
struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(configuration.isPressed ? Color(uiColor: .systemGray4) : Color.clear)
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
    /// A disabled pill used to look exactly like an enabled one.
    @Environment(\.isEnabled) private var isEnabled
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
            .opacity(isEnabled ? 1 : 0.45)
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
    /// Just the glyph, for a row that is short of room. The title stays the
    /// control's spoken name.
    var iconOnly = false

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if iconOnly {
            Label(configuration)
                .labelStyle(.iconOnly)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 14, height: 14)
        } else {
            HStack(spacing: 5) {
                configuration.icon
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 14, height: 14)
                configuration.title.lineLimit(1)
            }
        }
    }
}

private struct ChipsCompactKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set on a row of chips that is short of room. A chip still at its default
    /// setting then drops its name and becomes a round icon button; a chip you
    /// have changed keeps its name, because that is the one worth reading.
    var chipsCompact: Bool {
        get { self[ChipsCompactKey.self] }
        set { self[ChipsCompactKey.self] = newValue }
    }
}

private struct ChipModifier: ViewModifier {
    let on: Bool
    @Environment(\.chipsCompact) private var compact

    func body(content: Content) -> some View {
        let iconOnly = compact && !on
        content
            .font(Grok.sans(13, .medium))
            .foregroundStyle(on ? Grok.onInk : Grok.textDim)
            .labelStyle(ChipLabelStyle(iconOnly: iconOnly))
            .padding(.horizontal, iconOnly ? 0 : 11)
            // At least the control height, and taller when the text needs it: a fixed
            // height clipped the label at the larger text sizes.
            .frame(width: iconOnly ? Grok.control : nil)
            .frame(minHeight: Grok.control)
            .background(on ? Grok.ink : Grok.ink.opacity(0.08))
            .clipShape(Capsule())
            .contentShape(Capsule())
    }
}

extension View {
    /// Small capsule for chat controls. Soft translucent fill when off, solid white
    /// when on — no hairline outlines, which read as terminal chrome. Round and
    /// icon-only when off inside a row marked `chipsCompact`.
    func chip(on: Bool) -> some View {
        modifier(ChipModifier(on: on))
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
    /// The navigation bar is the system's: translucent, with the scroll-edge effect
    /// the rest of the phone has, and glass on iOS 26. It used to be painted opaque
    /// in the canvas color, which is exactly what makes a bar look stuck on.
    func grokBar() -> some View { self }
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
    /// A choice changed (a theme, a language, a model): the click a picker wheel makes.
    /// Opening a screen or a sheet gets nothing, as in the system's own apps.
    static func select() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
    /// Grok has stopped and is waiting on you. Deliberately not the light tap every
    /// button uses: this one is meant to be felt without looking.
    static func attention() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}
