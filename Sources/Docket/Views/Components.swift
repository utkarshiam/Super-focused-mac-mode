import AppKit
import SwiftUI

extension Priority {
    /// Priority is shown as a status badge, never as decoration.
    var tone: Tone? {
        switch self {
        case .urgent: .danger
        case .high: .warning
        default: nil
        }
    }

    /// Ring colour of the completion circle.
    var ringColor: Color {
        switch self {
        case .urgent: .danger
        case .high: .warning
        default: .ink3
        }
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .followsWindowActiveState

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        updateNSView(v, context: context)
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
        v.state = state
    }
}

extension View {
    /// Body of the borderless floating panels (menu bar dropdown, quick capture): a raised card
    /// with a hairline. Solid, not translucent, so it reads over anything.
    func floatingPanelChrome() -> some View {
        background(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous).fill(Color.raised))
            .clipShape(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous).strokeBorder(Color.hairStrong, lineWidth: 1))
            .tint(Color.ink)
    }
}

/// Completion circle. Ink ring (danger/warning for urgent/high), fills with ink and pops a check.
struct CheckCircle: View {
    var done: Bool
    var priority: Priority
    var size: CGFloat = 22
    var action: () -> Void
    @State private var hovering = false
    @State private var pop = false

    var body: some View {
        Button {
            if !done {
                // Grow, then settle on the bouncy spring (two steps, so the pop is actually drawn).
                withAnimation(Motion.instant) { pop = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
                    withAnimation(Motion.bouncy) { pop = false }
                }
            }
            action()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(done ? Color.primaryFill : priority.ringColor, lineWidth: 1.5)
                    .background(Circle().fill(done ? Color.primaryFill : (hovering ? Color.pressedTint : Color.clear)))
                if done || hovering {
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.45, weight: .heavy))
                        .foregroundStyle(done ? Color.onPrimary : Color.ink3)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .animation(Motion.bouncy, value: done)
            .scaleEffect(pop ? 1.25 : 1)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Motion.fast) { hovering = h } }
        .help(done ? "Mark as not done" : "Mark as done")
    }
}

/// Neutral pill used to preview what quick add understood.
struct Chip: View {
    var icon: String?
    var text: String
    var tone: Tone = .neutral

    var body: some View {
        Badge(text: text, tone: tone, icon: icon)
    }
}

struct EmptyState: View {
    var icon: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: Space.md) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Color.ink)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Color.fill))
            Text(title)
                .textStyle(.title3)
                .foregroundStyle(Color.ink)
            Text(message)
                .textStyle(.callout)
                .foregroundStyle(Color.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Space.x4)
        .enterUp()
    }
}

/// Hairline card (radius 20, padding 20).
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hairlineCard()
    }
}

/// The one inverted hero per screen.
struct Panel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous).fill(Color.panel))
            .environment(\.colorScheme, .dark)
    }
}

/// Chips previewing what quick add understood.
struct ParsedPreview: View {
    var parsed: ParsedTask
    var lists: [TaskList]

    var body: some View {
        HStack(spacing: 6) {
            if let due = parsed.dueDate {
                Chip(icon: "calendar", text: Fmt.due(due, hasTime: parsed.dueHasTime), tone: .info)
                    .layoutPriority(3)
            }
            if let est = parsed.estimateMinutes {
                Chip(icon: "hourglass", text: Fmt.duration(minutes: est))
                    .layoutPriority(1)
            }
            if parsed.priority != .none {
                Chip(icon: "flag", text: parsed.priority.label, tone: parsed.priority.tone ?? .neutral)
                    .layoutPriority(1)
            }
            if let id = parsed.listID, let list = lists.first(where: { $0.id == id }) {
                Chip(icon: list.icon, text: list.name)
            }
            ForEach(parsed.tags, id: \.self) { Chip(icon: "number", text: $0) }
            if let rec = parsed.recurrence {
                Chip(icon: "repeat", text: rec.summary)
                    .layoutPriority(2)
            }
            ForEach(Array(parsed.reminders.enumerated()), id: \.offset) { _, r in
                Chip(icon: r.isAlarm ? "alarm" : "bell",
                     text: r.minutesBefore == 0 ? (r.isAlarm ? "Alarm" : "Remind") : "\(Fmt.duration(minutes: r.minutesBefore)) before",
                     tone: r.isAlarm ? .warning : .neutral)
                .layoutPriority(1)
            }
        }
        .transition(.opacity.combined(with: .offset(y: -4)))
    }
}

struct KeyCap: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.ink2)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.fill))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.hair))
    }
}

/// Wide-tracked uppercase micro-label above a section.
struct Eyebrow: View {
    var text: String
    var color: Color = .ink3
    var body: some View {
        Text(text).textStyle(.eyebrow).foregroundStyle(color)
    }
}

extension View {
    /// Row press tint on hover for custom rows.
    func hoverHighlight(cornerRadius: CGFloat = Radius.sm) -> some View { modifier(HoverHighlight(cornerRadius: cornerRadius)) }
}

private struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(hovering ? Color.pressedTint : .clear))
            .onHover { h in withAnimation(Motion.fast) { hovering = h } }
    }
}
