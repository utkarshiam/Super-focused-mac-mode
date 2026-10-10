import SwiftUI
import UIKit

// The iPhone mirror of the Mac's ink-and-paper tokens (Sources/Docket/Views/Theme.swift):
// near-black ink on warm paper, hairlines instead of shadows, one primary action per screen,
// spring motion. Same names and hex values; type sizes are a notch larger for the phone.

// MARK: - Colour

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// A colour that follows light/dark mode.
    static func dynamic(_ light: UIColor, _ dark: UIColor) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }

    static func dynamic(_ light: UInt32, _ dark: UInt32) -> UIColor {
        dynamic(UIColor(hex: light), UIColor(hex: dark))
    }
}

enum Palette {
    // Surfaces
    static let paper = UIColor.dynamic(0xFBFBF9, 0x0E0E0C)
    static let card = UIColor.dynamic(0xFFFFFF, 0x131310)
    static let raised = UIColor.dynamic(0xFFFFFF, 0x1C1C19)
    static let fill = UIColor.dynamic(0xF1F0EC, 0x232321)
    static let fillStrong = UIColor.dynamic(0xE9E9E5, 0x2C2C29)
    static let scrim = UIColor.dynamic(UIColor(hex: 0x0E0E0C, alpha: 0.45), UIColor(white: 0, alpha: 0.6))
    // Text and lines
    static let ink = UIColor.dynamic(0x0E0E0C, 0xE3E3E2)
    static let ink2 = UIColor.dynamic(0x5B5B56, 0x9A9A99)
    static let ink3 = UIColor.dynamic(0x8E8E89, 0x7A7A77)
    static let body = UIColor.dynamic(0x3A3A36, 0xC9C9C7)
    static let hair = UIColor.dynamic(0xE7E6E0, 0x242422)
    static let hairStrong = UIColor.dynamic(0xD9D8D3, 0x2E2E2B)
    // The primary action: ink on paper, paper on ink in dark.
    static let primary = UIColor.dynamic(0x0E0E0C, 0xFBFBF9)
    static let onPrimary = UIColor.dynamic(0xFBFBF9, 0x0E0E0C)
    // Status (badges only)
    static let dangerFg = UIColor.dynamic(0x9E2B2B, 0xF0908A)
    static let dangerBg = UIColor.dynamic(0xF9ECEC, 0x2C1A18)
    static let dangerBorder = UIColor.dynamic(0xEBC1C1, 0x4A2A27)
    static let dangerSolid = UIColor.dynamic(0xC43D3D, 0xCF4B45)
    static let warningFg = UIColor.dynamic(0x8A5A12, 0xE3B65C)
    static let warningBg = UIColor.dynamic(0xF6EFE4, 0x292214)
    static let warningBorder = UIColor.dynamic(0xE6D0AE, 0x453919)
    static let successFg = UIColor.dynamic(0x127A57, 0x8FE3C0)
    static let successBg = UIColor.dynamic(0xE8F5F0, 0x182B22)
    static let successBorder = UIColor.dynamic(0xB9E0D2, 0x25473A)
    static let neutralFg = UIColor.dynamic(0x5B5B56, 0x9A9A99)
    static let neutralBg = UIColor.dynamic(0xF1F0EC, 0x1B1B18)
    static let neutralBorder = UIColor.dynamic(0xE7E6E0, 0x2A2A27)
    static let shadow = UIColor(hex: 0x0E0E0C)
}

extension Color {
    static let paper = Color(uiColor: Palette.paper)
    static let card = Color(uiColor: Palette.card)
    static let raised = Color(uiColor: Palette.raised)
    static let fill = Color(uiColor: Palette.fill)
    static let fillStrong = Color(uiColor: Palette.fillStrong)
    static let scrim = Color(uiColor: Palette.scrim)
    static let ink = Color(uiColor: Palette.ink)
    static let ink2 = Color(uiColor: Palette.ink2)
    static let ink3 = Color(uiColor: Palette.ink3)
    static let bodyText = Color(uiColor: Palette.body)
    static let hair = Color(uiColor: Palette.hair)
    static let hairStrong = Color(uiColor: Palette.hairStrong)
    static let primaryFill = Color(uiColor: Palette.primary)
    static let onPrimary = Color(uiColor: Palette.onPrimary)
    /// A switch that's on: ink in light; a mid grey in dark, where a paper-white track would swallow the knob.
    static let toggleOn = Color(uiColor: UIColor.dynamic(0x0E0E0C, 0x6E6E6A))
    static let danger = Color(uiColor: Palette.dangerSolid)
    static let dangerText = Color(uiColor: Palette.dangerFg)
}

enum Tone {
    case neutral, success, warning, danger

    var fg: Color {
        switch self {
        case .neutral: Color(uiColor: Palette.neutralFg)
        case .success: Color(uiColor: Palette.successFg)
        case .warning: Color(uiColor: Palette.warningFg)
        case .danger: Color(uiColor: Palette.dangerFg)
        }
    }

    var bg: Color {
        switch self {
        case .neutral: Color(uiColor: Palette.neutralBg)
        case .success: Color(uiColor: Palette.successBg)
        case .warning: Color(uiColor: Palette.warningBg)
        case .danger: Color(uiColor: Palette.dangerBg)
        }
    }

    var border: Color {
        switch self {
        case .neutral: Color(uiColor: Palette.neutralBorder)
        case .success: Color(uiColor: Palette.successBorder)
        case .warning: Color(uiColor: Palette.warningBorder)
        case .danger: Color(uiColor: Palette.dangerBorder)
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
        case .title2: 24
        case .title3: 20
        case .headline: 17
        case .body, .bodyStrong: 16
        case .callout: 15
        case .subhead, .subheadStrong: 14
        case .footnote: 13
        case .caption: 12
        case .eyebrow: 11
        case .button: 16
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
        case .eyebrow: 1.4
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
    static let xl: CGFloat = 20, xxl: CGFloat = 24, x3: CGFloat = 32, x4: CGFloat = 40
    /// Screen side padding on the phone.
    static let gutter: CGFloat = 20
}

enum Radius {
    static let xs: CGFloat = 6, sm: CGFloat = 10, md: CGFloat = 14, lg: CGFloat = 16, xl: CGFloat = 20, sheet: CGFloat = 28
}

// MARK: - Motion (springs)

enum Motion {
    static let press = Animation.interpolatingSpring(mass: 0.6, stiffness: 520, damping: 24)
    static let snappy = Animation.interpolatingSpring(mass: 0.9, stiffness: 340, damping: 26)
    static let sheet = Animation.interpolatingSpring(mass: 1, stiffness: 280, damping: 30)
    static let gentle = Animation.interpolatingSpring(mass: 1, stiffness: 180, damping: 20)
    static let instant = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.09)
    static let fast = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.16)
}

enum Haptics {
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func select() { UISelectionFeedbackGenerator().selectionChanged() }
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}

// MARK: - Buttons

/// Shrink under the finger, back on a spring (buttons 0.97, cards 0.985, chips 0.95, icons 0.9).
struct PressScale: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(configuration.isPressed ? Motion.instant : Motion.press, value: configuration.isPressed)
    }
}

/// Ink pill: the one primary action on a screen.
struct PrimaryPill: ButtonStyle {
    var height: CGFloat = 46
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, height: height, primary: true, fullWidth: fullWidth)
    }
}

/// Fill pill: secondary actions.
struct SecondaryPill: ButtonStyle {
    var height: CGFloat = 40
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, height: height, primary: false, fullWidth: fullWidth)
    }
}

private struct PillBody: View {
    let configuration: ButtonStyleConfiguration
    let height: CGFloat
    let primary: Bool
    let fullWidth: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.system(size: primary ? 16 : 15, weight: .semibold))
            .tracking(-0.2)
            .lineLimit(1)
            .foregroundStyle(primary ? Color.onPrimary : Color.ink)
            .padding(.horizontal, primary ? 22 : 16)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: height)
            .background(
                Capsule().fill(primary ? Color.primaryFill.opacity(pressed ? 0.85 : 1) : (pressed ? Color.fillStrong : Color.fill))
            )
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.35)
            .scaleEffect(pressed ? 0.97 : 1)
            .animation(pressed ? Motion.instant : Motion.press, value: pressed)
    }
}

/// Round icon-only button.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 36
    var filled = true
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, size: size, filled: filled, primary: primary)
    }
}

private struct IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    let filled: Bool
    let primary: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(primary ? Color.onPrimary : Color.ink)
            .frame(width: size, height: size)
            .background(Circle().fill(primary ? Color.primaryFill : (filled || pressed ? (pressed ? Color.fillStrong : Color.fill) : Color.clear)))
            .opacity(isEnabled ? 1 : 0.3)
            .scaleEffect(pressed ? 0.9 : 1)
            .animation(pressed ? Motion.instant : Motion.press, value: pressed)
            .contentShape(Circle())
    }
}

// MARK: - Surfaces

extension View {
    /// Hairline-outlined card (no shadow: only floating things cast one).
    func hairlineCard(radius: CGFloat = Radius.lg, fill: Color = .card) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.hair, lineWidth: 1))
    }

    /// Ink-tinted float shadow for things over content (toasts).
    func floatShadow() -> some View {
        shadow(color: Color(uiColor: Palette.shadow).opacity(0.14), radius: 18, y: 6)
    }

    /// Paper behind a whole screen.
    func paperBackground() -> some View {
        background(Color.paper.ignoresSafeArea())
    }
}

/// A 1-pixel line.
struct Hairline: View {
    @Environment(\.displayScale) private var scale

    var body: some View {
        Rectangle().fill(Color.hair).frame(height: 1 / max(scale, 1))
    }
}

// MARK: - Shared primitives

/// Status chip (never a button).
struct Badge: View {
    var text: String
    var tone: Tone = .neutral
    var icon: String?

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 10, weight: .bold)) }
            Text(text).lineLimit(1)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(tone.fg)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(tone.bg))
        .overlay(Capsule().strokeBorder(tone.border, lineWidth: 1))
        .fixedSize()
    }
}

/// "45m", "1h 30m" in a quiet pill, like the Mac's task lines.
struct DurationPill: View {
    var minutes: Int

    var body: some View {
        Text(PhoneFmt.duration(minutes: minutes))
            .font(.system(size: 12, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(Color.ink2)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(Capsule().fill(Color.fill))
            .fixedSize()
    }
}

/// Small uppercase section label.
struct Eyebrow: View {
    var text: String
    var color: Color = .ink3

    init(_ text: String, color: Color = .ink3) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text).textStyle(.eyebrow).foregroundStyle(color)
    }
}

/// A selectable filter chip (selected = ink).
struct FilterChip: View {
    var title: String
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .tracking(-0.1)
                .lineLimit(1)
                .foregroundStyle(selected ? Color.onPrimary : Color.ink)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(Capsule().fill(selected ? Color.primaryFill : Color.fill))
                .fixedSize()
        }
        .buttonStyle(PressScale(scale: 0.95))
    }
}

/// An item's kind as a symbol on a soft tile, or its thumbnail.
struct KindTile: View {
    var symbol: String
    var size: CGFloat = 40
    var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(Color.fill)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundStyle(Color.ink2)
            }
        }
        .frame(width: size, height: size)
        .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(Color.hair, lineWidth: image == nil ? 0 : 1))
    }
}
