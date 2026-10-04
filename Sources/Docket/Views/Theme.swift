import AppKit
import SwiftUI

// Docket's design language is the octo-patient (Curo) "ink and paper" system:
// near-black ink on warm paper, big confident type, hairlines instead of shadows,
// one obvious next step, fast physical motion. Values below are copied from
// octo-patient/constants (Colors, Type, Layout, Motion) — change them there first.

// MARK: - Colour

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// A colour that follows the window's light/dark appearance.
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    static func dynamic(_ light: UInt32, _ dark: UInt32) -> NSColor {
        dynamic(NSColor(hex: light), NSColor(hex: dark))
    }
}

enum Palette {
    // Surfaces
    static let paper = NSColor.dynamic(0xFBFBF9, 0x0E0E0C)
    static let card = NSColor.dynamic(0xFFFFFF, 0x131310)
    static let raised = NSColor.dynamic(0xFFFFFF, 0x1C1C19)
    static let panel = NSColor.dynamic(0x131310, 0x1A1A17)
    static let fill = NSColor.dynamic(0xF1F0EC, 0x232321)
    static let fillStrong = NSColor.dynamic(0xE9E9E5, 0x2C2C29)
    static let thumb = NSColor.dynamic(0xFFFFFF, 0x3B3B38)
    static let pressed = NSColor.dynamic(NSColor(hex: 0x0E0E0C, alpha: 0.05), NSColor(white: 1, alpha: 0.06))
    static let scrim = NSColor.dynamic(NSColor(hex: 0x0E0E0C, alpha: 0.45), NSColor(white: 0, alpha: 0.6))
    // Text and lines
    static let ink = NSColor.dynamic(0x0E0E0C, 0xE3E3E2)
    static let ink2 = NSColor.dynamic(0x5B5B56, 0x9A9A99)
    static let ink3 = NSColor.dynamic(0xA3A39E, 0x6E6E6B)
    static let body = NSColor.dynamic(0x3A3A36, 0xC9C9C7)
    static let hair = NSColor.dynamic(0xE7E6E0, 0x242422)
    static let hairStrong = NSColor.dynamic(0xD9D8D3, 0x2E2E2B)
    // The primary action: ink on paper, paper on ink in dark.
    static let primary = NSColor.dynamic(0x0E0E0C, 0xFBFBF9)
    static let onPrimary = NSColor.dynamic(0xFBFBF9, 0x0E0E0C)
    // Status (badges only)
    static let dangerFg = NSColor.dynamic(0x9E2B2B, 0xF0908A)
    static let dangerBg = NSColor.dynamic(0xF9ECEC, 0x2C1A18)
    static let dangerBorder = NSColor.dynamic(0xEBC1C1, 0x4A2A27)
    static let dangerSolid = NSColor.dynamic(0xC43D3D, 0xCF4B45)
    static let warningFg = NSColor.dynamic(0x8A5A12, 0xE3B65C)
    static let warningBg = NSColor.dynamic(0xF6EFE4, 0x292214)
    static let warningBorder = NSColor.dynamic(0xE6D0AE, 0x453919)
    static let warningSolid = NSColor.dynamic(0xB7791F, 0xD9A441)
    static let successFg = NSColor.dynamic(0x127A57, 0x8FE3C0)
    static let successBg = NSColor.dynamic(0xE8F5F0, 0x182B22)
    static let successBorder = NSColor.dynamic(0xB9E0D2, 0x25473A)
    static let successSolid = NSColor.dynamic(0x17976A, 0x5FD6A6)
    static let neutralFg = NSColor.dynamic(0x5B5B56, 0x9A9A99)
    static let neutralBg = NSColor.dynamic(0xF1F0EC, 0x1B1B18)
    static let neutralBorder = NSColor.dynamic(0xE7E6E0, 0x242422)
    static let shadow = NSColor(hex: 0x0E0E0C)
}

extension Color {
    static let paper = Color(nsColor: Palette.paper)
    static let card = Color(nsColor: Palette.card)
    static let raised = Color(nsColor: Palette.raised)
    static let panel = Color(nsColor: Palette.panel)
    static let fill = Color(nsColor: Palette.fill)
    static let fillStrong = Color(nsColor: Palette.fillStrong)
    static let thumb = Color(nsColor: Palette.thumb)
    static let pressedTint = Color(nsColor: Palette.pressed)
    static let scrim = Color(nsColor: Palette.scrim)
    static let ink = Color(nsColor: Palette.ink)
    static let ink2 = Color(nsColor: Palette.ink2)
    static let ink3 = Color(nsColor: Palette.ink3)
    static let bodyText = Color(nsColor: Palette.body)
    static let hair = Color(nsColor: Palette.hair)
    static let hairStrong = Color(nsColor: Palette.hairStrong)
    static let primaryFill = Color(nsColor: Palette.primary)
    static let onPrimary = Color(nsColor: Palette.onPrimary)
    static let danger = Color(nsColor: Palette.dangerSolid)
    static let dangerText = Color(nsColor: Palette.dangerFg)
    static let warning = Color(nsColor: Palette.warningSolid)
    static let success = Color(nsColor: Palette.successSolid)
    // Inside an inverted Panel (constant in both themes).
    static let onDark88 = Color.white.opacity(0.88)
    static let onDark58 = Color.white.opacity(0.58)
    static let onDarkHair = Color.white.opacity(0.10)
}

enum Tone {
    case neutral, info, success, warning, danger, primary

    var fg: Color {
        switch self {
        case .neutral: Color(nsColor: Palette.neutralFg)
        case .info: .ink
        case .success: Color(nsColor: Palette.successFg)
        case .warning: Color(nsColor: Palette.warningFg)
        case .danger: Color(nsColor: Palette.dangerFg)
        case .primary: .onPrimary
        }
    }

    var bg: Color {
        switch self {
        case .neutral, .info: Color(nsColor: Palette.neutralBg)
        case .success: Color(nsColor: Palette.successBg)
        case .warning: Color(nsColor: Palette.warningBg)
        case .danger: Color(nsColor: Palette.dangerBg)
        case .primary: .primaryFill
        }
    }

    var border: Color {
        switch self {
        case .neutral, .info: Color(nsColor: Palette.neutralBorder)
        case .success: Color(nsColor: Palette.successBorder)
        case .warning: Color(nsColor: Palette.warningBorder)
        case .danger: Color(nsColor: Palette.dangerBorder)
        case .primary: .primaryFill
        }
    }
}

// MARK: - Type (system face, tight tracking on big sizes)

enum TextStyle {
    case largeTitle, title1, title2, title3, headline, body, bodyStrong, callout, subhead, subheadStrong, footnote, caption, eyebrow, button

    var size: CGFloat {
        switch self {
        case .largeTitle: 34
        case .title1: 28
        case .title2: 22
        case .title3: 20
        case .headline: 16
        case .body, .bodyStrong: 15
        case .callout: 14
        case .subhead, .subheadStrong: 13
        case .footnote: 12
        case .caption: 11.5
        case .eyebrow: 10.5
        case .button: 14
        }
    }

    var weight: Font.Weight {
        switch self {
        case .largeTitle, .title1, .title2, .eyebrow: .bold
        case .title3, .headline, .bodyStrong, .subheadStrong, .button: .semibold
        case .caption: .medium
        default: .regular
        }
    }

    var tracking: CGFloat {
        switch self {
        case .largeTitle: -0.8
        case .title1: -0.6
        case .title2: -0.4
        case .title3: -0.3
        case .headline, .button: -0.2
        case .body, .bodyStrong, .callout: -0.1
        case .caption: 0.1
        case .eyebrow: 1.6
        default: 0
        }
    }

    var font: Font { .system(size: size, weight: weight) }
}

extension View {
    func textStyle(_ style: TextStyle) -> some View {
        font(style.font)
            .tracking(style.tracking)
            .textCase(style == .eyebrow ? .uppercase : nil)
    }
}

// MARK: - Space, radius

enum Space {
    static let xxs: CGFloat = 2, xs: CGFloat = 4, sm: CGFloat = 8, md: CGFloat = 12, lg: CGFloat = 16
    static let xl: CGFloat = 20, xxl: CGFloat = 24, x3: CGFloat = 32, x4: CGFloat = 40, x6: CGFloat = 64
    /// Screen side padding.
    static let gutter: CGFloat = 28
}

enum Radius {
    static let xs: CGFloat = 6, sm: CGFloat = 10, md: CGFloat = 14, lg: CGFloat = 16, xl: CGFloat = 20, sheet: CGFloat = 28
}

// MARK: - Motion (springs from octo-patient Motion.ts)

enum Motion {
    static let press = Animation.interpolatingSpring(mass: 0.6, stiffness: 520, damping: 24)
    static let snappy = Animation.interpolatingSpring(mass: 0.9, stiffness: 340, damping: 26)
    static let sheet = Animation.interpolatingSpring(mass: 1, stiffness: 280, damping: 30)
    static let gentle = Animation.interpolatingSpring(mass: 1, stiffness: 180, damping: 20)
    static let bouncy = Animation.interpolatingSpring(mass: 0.8, stiffness: 220, damping: 13)
    static let instant = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.09)
    static let fast = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.16)
    static let base = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.24)
    static let slow = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.36)
}

enum Haptics {
    /// Trackpad tick for "something finished well" (completing a task, dropping on a day).
    static func success() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    static func select() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

// MARK: - Press feel

/// Shrink under the pointer, back on a spring (buttons 0.97, cards 0.985, chips 0.95, icons 0.9).
struct PressScale: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(configuration.isPressed ? Motion.instant : Motion.press, value: configuration.isPressed)
    }
}

/// Ink pill: the one primary action.
struct PrimaryPill: ButtonStyle {
    var height: CGFloat = 36

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, height: height, primary: true)
    }
}

/// Fill pill: secondary actions.
struct SecondaryPill: ButtonStyle {
    var height: CGFloat = 36
    /// For user text (a note title): the label shrinks and truncates instead of widening the pill.
    var truncates = false

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, height: height, primary: false, truncates: truncates)
    }
}

private struct PillBody: View {
    let configuration: ButtonStyleConfiguration
    let height: CGFloat
    let primary: Bool
    var truncates = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .textStyle(.button)
            .lineLimit(1)
            .fixedSize(horizontal: !truncates, vertical: true)
            .foregroundStyle(primary ? Color.onPrimary : Color.ink)
            .padding(.horizontal, primary ? 18 : 16)
            .frame(height: height)
            .background(
                Capsule().fill(primary
                    ? Color.primaryFill.opacity(pressed ? 0.85 : (hovering && isEnabled ? 0.9 : 1))
                    : (pressed || (hovering && isEnabled) ? Color.fillStrong : Color.fill))
            )
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(pressed ? 0.97 : 1)
            .animation(pressed ? Motion.instant : Motion.press, value: pressed)
            .onHover { h in withAnimation(Motion.fast) { hovering = h } }
    }
}

/// Round icon-only button.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 32
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, size: size, filled: filled)
    }
}

private struct IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    let filled: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.ink)
            .frame(width: size, height: size)
            .background(Circle().fill(filled || (hovering && isEnabled) || pressed ? (hovering && isEnabled && filled ? Color.fillStrong : Color.fill) : Color.clear))
            .opacity(isEnabled ? 1 : 0.35)
            .scaleEffect(pressed ? 0.9 : 1)
            .animation(pressed ? Motion.instant : Motion.press, value: pressed)
            .onHover { h in withAnimation(Motion.fast) { hovering = h } }
            .contentShape(Circle())
    }
}

/// Pill and circle menus: SwiftUI draws the label (padding, frame and colours kept), the shape sits
/// behind it, the whole shape is clickable, and it reacts to hover and press like the other pills.
struct MenuChromeStyle<S: Shape>: ButtonStyle {
    let shape: S
    let fill: Color
    let hoverFill: Color

    func makeBody(configuration: Configuration) -> some View {
        MenuChromeBody(configuration: configuration, shape: shape, fill: fill, hoverFill: hoverFill)
    }
}

private struct MenuChromeBody<S: Shape>: View {
    let configuration: ButtonStyleConfiguration
    let shape: S
    let fill: Color
    let hoverFill: Color
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .background(shape.fill((hovering && isEnabled) || pressed ? hoverFill : fill))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(pressed ? 0.97 : 1)
            .animation(pressed ? Motion.instant : Motion.press, value: pressed)
            .onHover { h in withAnimation(Motion.fast) { hovering = h } }
    }
}

extension View {
    /// Styles a Menu as a pill or circle. Put the padding/frame inside the label; it sets the size.
    /// `truncates` lets a long value (a list name, a repeat rule) shrink with "…" instead of pushing the row wider.
    func menuChrome<S: Shape>(_ shape: S, fill: Color = .fill, hoverFill: Color = .fillStrong, truncates: Bool = false) -> some View {
        menuStyle(.button)
            .buttonStyle(MenuChromeStyle(shape: shape, fill: fill, hoverFill: hoverFill))
            .menuIndicator(.hidden)
            .fixedSize(horizontal: !truncates, vertical: true)
    }
}

// MARK: - Entering content

private struct EnterUpActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// True only while a list is making its entrance; rows built later (while scrolling) just appear.
    var enterUpActive: Bool {
        get { self[EnterUpActiveKey.self] }
        set { self[EnterUpActiveKey.self] = newValue }
    }
}

/// Wrap a lazy list so its rows fade up when it first shows, but not when they're created by scrolling.
struct EnterUpWindow<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var active = true

    var body: some View {
        content
            .environment(\.enterUpActive, active)
            .task {
                try? await Task.sleep(nanoseconds: 450_000_000)
                active = false
            }
    }
}

/// Fade up, staggered 45ms per index (capped at 8), on the gentle spring.
struct EnterUp: ViewModifier {
    var index: Int
    @Environment(\.enterUpActive) private var active
    @State private var shown = false

    func body(content: Content) -> some View {
        let visible = shown || !active
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 10)
            .onAppear {
                guard !shown else { return }
                if active {
                    withAnimation(Motion.gentle.delay(Double(min(index, 8)) * 0.045)) { shown = true }
                } else {
                    shown = true
                }
            }
    }
}

extension View {
    func enterUp(_ index: Int = 0) -> some View { modifier(EnterUp(index: index)) }

    /// Hairline-outlined card (no shadow: only floating things cast one).
    func hairlineCard(radius: CGFloat = Radius.xl, fill: Color = .card) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.hair, lineWidth: 1))
    }

    /// Ink-tinted float shadow for things over content (toasts, palettes, panels).
    func floatShadow(strong: Bool = false) -> some View {
        shadow(color: Color(nsColor: Palette.shadow).opacity(strong ? 0.18 : 0.12), radius: strong ? 28 : 16, y: strong ? 12 : 6)
    }
}

// MARK: - Shared primitives

/// A big bold time with the AM/PM set small: **11:00** AM
struct BigTime: View {
    var date: Date
    var size: CGFloat = 17
    var color: Color = .ink

    var body: some View {
        let parts = Fmt.timeParts(date)
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(parts.clock)
                .font(.system(size: size, weight: .bold))
                .tracking(-0.3)
                .monospacedDigit()
            if let period = parts.period {
                Text(period)
                    .font(.system(size: size * 0.62, weight: .bold))
                    .tracking(0.2)
            }
        }
        .foregroundStyle(color)
        .fixedSize()
    }
}

/// Status chip (never a button).
struct Badge: View {
    var text: String
    var tone: Tone = .neutral
    var icon: String?

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 9.5, weight: .bold)) }
            Text(text).lineLimit(1)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(tone.fg)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(tone.bg))
        .overlay(Capsule().strokeBorder(tone.border, lineWidth: tone == .primary ? 0 : 1))
    }
}

/// Two to four views on a pill track with a sliding thumb.
struct SegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [(Value, String)]
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, label in
                Button {
                    withAnimation(Motion.snappy) { selection = value }
                    Haptics.select()
                } label: {
                    Text(label)
                        .textStyle(.subheadStrong)
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(selection == value ? Color.ink : Color.ink2)
                        .padding(.horizontal, 14)
                        .frame(height: 26)
                        .background {
                            if selection == value {
                                Capsule().fill(Color.thumb)
                                    .shadow(color: Color(nsColor: Palette.shadow).opacity(0.12), radius: 3, y: 1)
                                    .matchedGeometryEffect(id: "thumb", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.fillStrong))
    }
}
