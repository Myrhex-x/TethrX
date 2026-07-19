import SwiftUI

/// xAI / Grok Build design language: a near-black canvas, white outline pills for
/// interactive elements, a grotesque display face with negative tracking, mono
/// eyebrows that read like code comments, and a single warm dusk-gradient accent.
enum Grok {
    // MARK: Canvas
    static let bg = Color(red: 0.039, green: 0.039, blue: 0.039)   // #0a0a0a
    static let raised = Color.white.opacity(0.04)                   // subtly elevated surfaces
    static let raisedPressed = Color.white.opacity(0.10)
    static let hairline = Color.white.opacity(0.13)
    static let hairlineStrong = Color.white.opacity(0.22)

    // MARK: Ink
    static let text = Color.white
    static let textDim = Color.white.opacity(0.55)
    static let textFaint = Color.white.opacity(0.32)

    // MARK: Accent — monochrome. (The warm gradient read as too loud; xAI is
    // "confidently sparse", so the sole accent is simply white.)
    static let accent = Color.white
    static let danger = Color(red: 1.0, green: 0.45, blue: 0.45)   // errors only

    // MARK: Type
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

// MARK: - Eyebrow (mono, uppercase, reads like a code comment)

struct Eyebrow: View {
    let text: String
    var comment: Bool = true
    init(_ text: String, comment: Bool = true) { self.text = text; self.comment = comment }
    var body: some View {
        Text((comment ? "// " : "") + text.uppercased())
            .font(Grok.mono(11, .medium))
            .tracking(1.4)
            .foregroundStyle(Grok.textDim)
    }
}

// MARK: - Outline pill button (the xAI interactive primitive)

struct PillButton: ButtonStyle {
    enum Kind { case prominent, subtle }
    var kind: Kind = .prominent

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(Grok.sans(15, .semibold))
            .tracking(0.2)
            .foregroundStyle(kind == .prominent ? Grok.text : Grok.textDim)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(kind == .prominent
                        ? Color.white.opacity(pressed ? 0.16 : 0.06)
                        : Color.white.opacity(pressed ? 0.08 : 0.0))
            .overlay(Capsule().stroke(kind == .prominent ? Color.white.opacity(0.9) : Grok.hairlineStrong, lineWidth: 1))
            .clipShape(Capsule())
            .contentShape(Capsule())
    }
}

// MARK: - Segmented pill (single choice among a row)

struct SegPill: ButtonStyle {
    var selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? Color.black : Grok.textDim)
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(selected ? Color.white : Color.clear)
            .overlay(Capsule().stroke(selected ? Color.clear : Grok.hairline, lineWidth: 1))
            .clipShape(Capsule())
            .contentShape(Capsule())
    }
}

// MARK: - Compact chat control chip (toggles/menus by the composer)

extension View {
    /// Small pill for chat controls; filled white when active, outline when off.
    func chip(on: Bool) -> some View {
        self
            .font(Grok.mono(11, .medium))
            .foregroundStyle(on ? Color.black : Grok.textDim)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(on ? Color.white : Color.clear)
            .overlay(Capsule().stroke(on ? Color.clear : Grok.hairline, lineWidth: 1))
            .clipShape(Capsule())
    }
}

// MARK: - Hairline-bordered input container

struct FieldBox<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(Grok.raised)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Grok.hairline, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Small circular outline icon button (send / stop / add)

struct CircleIconButton: View {
    let system: String
    var filled = false
    var danger = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(filled ? AnyShapeStyle(Grok.accent) : AnyShapeStyle(Color.clear))
                    .overlay(Circle().stroke(enabled ? Grok.hairlineStrong : Grok.hairline, lineWidth: 1))
                Image(systemName: system)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(filled ? .black : (danger ? Grok.danger : (enabled ? Grok.text : Grok.textFaint)))
            }
            .frame(width: 40, height: 40)
        }
        .disabled(!enabled)
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
