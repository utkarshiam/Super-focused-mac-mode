import SwiftUI

/// Ink-and-paper date picker (deadlines, plan dates, custom reminders): quick picks, a month grid
/// and an optional time. Fixed 300pt wide, and every row is flexible so nothing can push it wider.
struct DatePopover: View {
    @Binding var date: Date?
    @Binding var hasTime: Bool
    var allowsTime: Bool
    var title: String?
    /// Reminders always need a time: the switch is hidden and the time row always shows.
    var timeRequired: Bool
    var confirmLabel: String
    var close: () -> Void
    var onConfirm: (() -> Void)?

    @State private var month = Calendar.current.startOfDay(for: Date())
    @Namespace private var ns

    init(date: Binding<Date?>, hasTime: Binding<Bool>, allowsTime: Bool, title: String? = nil, timeRequired: Bool = false,
         confirmLabel: String = "Done", close: @escaping () -> Void, onConfirm: (() -> Void)? = nil) {
        _date = date
        _hasTime = hasTime
        self.allowsTime = allowsTime
        self.title = title
        self.timeRequired = timeRequired
        self.confirmLabel = confirmLabel
        self.close = close
        self.onConfirm = onConfirm
    }

    private var cal: Calendar { Calendar.current }
    private var showsTime: Bool { allowsTime && (timeRequired || hasTime) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if let title {
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Text(title)
                        .font(.system(size: 17, weight: .bold))
                        .tracking(-0.2)
                        .foregroundStyle(Color.ink)
                    Spacer(minLength: 0)
                    if let date {
                        Text(Fmt.due(date, hasTime: showsTime))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.ink2)
                            .lineLimit(1)
                    }
                }
            }
            quickPicks
            monthGrid
            if allowsTime { timeSection }
            footer
        }
        .padding(Space.lg)
        .frame(width: 300)
        .background(Color.raised)
        .tint(Color.ink)
        .onAppear { month = startOfMonth(date ?? Date()) }
    }

    // MARK: Quick picks

    private var quickPicks: some View {
        let today = cal.startOfDay(for: Date())
        // First four distinct days, so two tiles never light up together (e.g. Sunday's "Next Monday" is tomorrow).
        let weekday = cal.component(.weekday, from: today)
        let candidates: [(String, Date)] = [
            ("Today", today),
            ("Tomorrow", cal.date(byAdding: .day, value: 1, to: today)!),
            ("This weekend", cal.date(byAdding: .day, value: (7 - weekday + 7) % 7, to: today)!),
            ("Next Monday", Recurrence(frequency: .weekly, weekdays: [2]).advance(today)),
            ("In a week", cal.date(byAdding: .day, value: 7, to: today)!),
        ]
        var seen = Set<Date>()
        let picks = Array(candidates.filter { seen.insert($0.1).inserted }.prefix(4))
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.sm), GridItem(.flexible(), spacing: Space.sm)], spacing: Space.sm) {
            ForEach(picks, id: \.0) { label, day in
                QuickPick(label: label, detail: "\(Fmt.weekdayShort(day)) \(Fmt.dayMonth(day))", selected: isSelected(day)) {
                    select(day)
                }
            }
        }
    }

    // MARK: Month grid

    private var monthGrid: some View {
        let first = month
        let gridStart = cal.dateInterval(of: .weekOfYear, for: first)?.start ?? first
        let days = (0..<42).map { cal.date(byAdding: .day, value: $0, to: gridStart)! }
        let today = cal.startOfDay(for: Date())
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        let offset = cal.firstWeekday - 1
        let name = DateFormatter()
        name.setLocalizedDateFormatFromTemplate("MMMM")

        return VStack(spacing: 6) {
            HStack(spacing: Space.xs) {
                (Text(name.string(from: first)).foregroundColor(.ink) + Text(" \(String(cal.component(.year, from: first)))").foregroundColor(.ink3))
                    .font(.system(size: 15, weight: .bold))
                    .tracking(-0.2)
                Spacer(minLength: 0)
                Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(IconButtonStyle(size: 28))
                    .help("Previous month")
                Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(IconButtonStyle(size: 28))
                    .help("Next month")
            }
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { i in
                    Text(symbols[(offset + i) % 7])
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(Color.ink3)
                        .frame(maxWidth: .infinity)
                }
            }
            VStack(spacing: 2) {
                ForEach(0..<6, id: \.self) { week in
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { col in
                            let day = days[week * 7 + col]
                            DayCell(day: day, inMonth: cal.isDate(day, equalTo: first, toGranularity: .month),
                                    isToday: day == today, isSelected: isSelected(day), ns: ns) {
                                select(day)
                            }
                        }
                    }
                }
            }
            .id(first)
            .transition(.opacity)
        }
    }

    // MARK: Time

    private var timeSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Rectangle().fill(Color.hair).frame(height: 1)
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.ink2)
                Text("Time")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ink)
                Spacer(minLength: 0)
                if showsTime {
                    PillMenu(text: Fmt.hourLabel(currentHour), values: Array(0..<24), label: Fmt.hourLabel) { setTime(hour: $0, minute: currentMinute) }
                    Text(":")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.ink2)
                    PillMenu(text: String(format: "%02d", currentMinute), values: Array(stride(from: 0, to: 60, by: 5)), label: { String(format: "%02d", $0) }) {
                        setTime(hour: currentHour, minute: $0)
                    }
                }
                if !timeRequired {
                    Toggle("", isOn: timeToggle)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.mini)
                        .help(hasTime ? "Remove the time" : "Add a time")
                }
            }
            if showsTime {
                HStack(spacing: 6) {
                    ForEach([9, 12, 15, 18], id: \.self) { h in
                        let on = currentHour == h && currentMinute == 0 && date != nil
                        Button { setTime(hour: h, minute: 0) } label: {
                            Text(chipLabel(h))
                                .font(.system(size: 12, weight: .semibold))
                                .monospacedDigit()
                                .lineLimit(1)
                                .foregroundStyle(on ? Color.onPrimary : Color.ink)
                                .frame(maxWidth: .infinity)
                                .frame(height: 28)
                                .background(Capsule().fill(on ? Color.primaryFill : Color.fill))
                        }
                        .buttonStyle(PressScale(scale: 0.95))
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Motion.base, value: showsTime)
    }

    private var timeToggle: Binding<Bool> {
        Binding(get: { hasTime }, set: { on in
            withAnimation(Motion.base) {
                if on {
                    let day = date.map { cal.startOfDay(for: $0) } ?? cal.startOfDay(for: Date())
                    let t = defaultTime(on: day)
                    date = cal.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: day)
                    hasTime = true
                } else {
                    if let d = date { date = cal.startOfDay(for: d) }
                    hasTime = false
                }
            }
        })
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Space.sm) {
            if date != nil && !timeRequired {
                Button("Clear") {
                    withAnimation(Motion.base) {
                        date = nil
                        hasTime = false
                    }
                    close()
                }
                .buttonStyle(SecondaryPill(height: 32))
            }
            Spacer(minLength: 0)
            Button(confirmLabel) {
                onConfirm?()
                close()
            }
            .buttonStyle(PrimaryPill(height: 32))
            .keyboardShortcut(.defaultAction)
            .disabled(timeRequired && date == nil)
        }
    }

    // MARK: Logic

    private func isSelected(_ day: Date) -> Bool {
        date.map { cal.isDate($0, inSameDayAs: day) } ?? false
    }

    private func startOfMonth(_ d: Date) -> Date {
        cal.dateInterval(of: .month, for: d)?.start ?? cal.startOfDay(for: d)
    }

    private func shiftMonth(_ delta: Int) {
        withAnimation(Motion.base) { month = cal.date(byAdding: .month, value: delta, to: month)! }
        Haptics.select()
    }

    private var currentHour: Int {
        if let date, showsTime, hasTime || timeRequired { return cal.component(.hour, from: date) }
        return defaultTime(on: date ?? Date()).hour
    }

    private var currentMinute: Int {
        if let date, showsTime, hasTime || timeRequired { return cal.component(.minute, from: date) / 5 * 5 }
        return defaultTime(on: date ?? Date()).minute
    }

    /// The next whole hour for today, otherwise 9:00 for reminders and 17:00 for deadlines.
    private func defaultTime(on day: Date) -> (hour: Int, minute: Int) {
        if cal.isDateInToday(day) {
            return (min(23, cal.component(.hour, from: Date()) + 1), 0)
        }
        return (timeRequired ? 9 : 17, 0)
    }

    private func select(_ day: Date) {
        let target = showsTime
            ? cal.date(bySettingHour: currentHour, minute: currentMinute, second: 0, of: day)!
            : cal.startOfDay(for: day)
        withAnimation(Motion.snappy) {
            date = target
            if !cal.isDate(day, equalTo: month, toGranularity: .month) { month = startOfMonth(day) }
        }
        Haptics.select()
        // A plain date is one click: show the selection land, then close.
        if !showsTime && onConfirm == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { close() }
        }
    }

    private func setTime(hour: Int, minute: Int) {
        let day = date.map { cal.startOfDay(for: $0) } ?? cal.startOfDay(for: Date())
        withAnimation(Motion.snappy) {
            date = cal.date(bySettingHour: hour, minute: minute, second: 0, of: day)
            hasTime = true
        }
    }

    private func chipLabel(_ h: Int) -> String {
        Fmt.uses12Hour ? Fmt.hourLabel(h) : String(format: "%02d:00", h)
    }
}

private struct QuickPick: View {
    let label: String
    let detail: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 11.5, weight: .medium))
                    .opacity(0.65)
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Color.onPrimary : Color.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(selected ? Color.primaryFill : (hovering ? Color.fillStrong : Color.fill))
            )
            .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
        .buttonStyle(PressScale(scale: 0.97))
        .onHover { h in withAnimation(Motion.fast) { hovering = h } }
    }
}

private struct DayCell: View {
    let day: Date
    let inMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let ns: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("\(Calendar.current.component(.day, from: day))")
                .font(.system(size: 13, weight: isSelected || isToday ? .bold : .medium))
                .monospacedDigit()
                .foregroundStyle(isSelected ? Color.onPrimary : (inMonth ? Color.ink : Color.ink3))
                .frame(width: 32, height: 32)
                .background {
                    if isSelected {
                        Circle().fill(Color.primaryFill).matchedGeometryEffect(id: "selected-day", in: ns)
                    } else if hovering {
                        Circle().fill(Color.pressedTint)
                    }
                }
                .overlay {
                    if isToday && !isSelected {
                        Circle().strokeBorder(Color.ink, lineWidth: 1.5)
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale(scale: 0.9))
        .onHover { h in withAnimation(Motion.fast) { hovering = h } }
    }
}

/// Custom repeat rule: every N days/weeks/months/years, and which weekdays for weekly rules.
struct CustomRepeatEditor: View {
    @State private var rule: Recurrence
    var onSave: (Recurrence) -> Void
    @Environment(\.dismiss) private var dismiss

    init(initial: Recurrence, onSave: @escaping (Recurrence) -> Void) {
        _rule = State(initialValue: initial)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Repeat")
                    .font(.system(size: 17, weight: .bold))
                    .tracking(-0.2)
                    .foregroundStyle(Color.ink)
                Text(rule.summary)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Space.sm) {
                Text("Every")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ink2)
                Button { withAnimation(Motion.snappy) { rule.interval = max(1, rule.interval - 1) } } label: { Image(systemName: "minus") }
                    .buttonStyle(IconButtonStyle(size: 28, filled: true))
                    .disabled(rule.interval <= 1)
                Text("\(rule.interval)")
                    .font(.system(size: 17, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.ink)
                    .frame(minWidth: 28)
                Button { withAnimation(Motion.snappy) { rule.interval = min(365, rule.interval + 1) } } label: { Image(systemName: "plus") }
                    .buttonStyle(IconButtonStyle(size: 28, filled: true))
                Spacer(minLength: 0)
            }

            SegmentedControl(selection: $rule.frequency, options: Recurrence.Frequency.allCases.map { ($0, $0.unit.capitalized) })

            if rule.frequency == .weekly {
                HStack(spacing: 6) {
                    ForEach(1...7, id: \.self) { i in
                        let wd = (i % 7) + 1 // Mon..Sun
                        let on = rule.weekdays.contains(wd)
                        Button {
                            withAnimation(Motion.snappy) {
                                if on { rule.weekdays.removeAll { $0 == wd } } else { rule.weekdays = (rule.weekdays + [wd]).sorted() }
                            }
                            Haptics.select()
                        } label: {
                            Text(String(Calendar.current.veryShortWeekdaySymbols[wd - 1]))
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(on ? Color.onPrimary : Color.ink)
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(on ? Color.primaryFill : Color.fill))
                        }
                        .buttonStyle(PressScale(scale: 0.9))
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack {
                Spacer()
                Button("Set repeat") {
                    onSave(rule)
                    dismiss()
                }
                .buttonStyle(PrimaryPill(height: 32))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.lg)
        .frame(width: 300)
        .background(Color.raised)
        .tint(Color.ink)
        .animation(Motion.base, value: rule.frequency)
    }
}

/// A pill that opens a menu of numbers (hours, minutes).
struct PillMenu: View {
    let text: String
    let values: [Int]
    let label: (Int) -> String
    let pick: (Int) -> Void

    var body: some View {
        Menu {
            ForEach(values, id: \.self) { v in
                Button(label(v)) { pick(v) }
            }
        } label: {
            Text(text)
                .font(.system(size: 13, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Color.ink)
                .padding(.horizontal, 9)
                .frame(height: 28)
        }
        .menuChrome(Capsule())
    }
}

/// "9 AM : 30" for a minutes-since-midnight setting.
struct TimeOfDayPicker: View {
    @Binding var minutes: Int

    var body: some View {
        let hour = minutes / 60, minute = minutes % 60
        HStack(spacing: 4) {
            PillMenu(text: Fmt.hourLabel(hour), values: Array(0..<24), label: Fmt.hourLabel) { minutes = $0 * 60 + minute }
            Text(":").font(.system(size: 13, weight: .bold)).foregroundStyle(Color.ink2)
            PillMenu(text: String(format: "%02d", minute), values: Array(stride(from: 0, to: 60, by: 5)), label: { String(format: "%02d", $0) }) {
                minutes = hour * 60 + $0
            }
        }
    }
}

/// − value + with round buttons.
struct NumberStepper: View {
    @Binding var value: Int
    var range: ClosedRange<Int>
    var step: Int
    var format: (Int) -> String

    var body: some View {
        HStack(spacing: 6) {
            Button { withAnimation(Motion.snappy) { value = max(range.lowerBound, value - step) } } label: { Image(systemName: "minus") }
                .buttonStyle(IconButtonStyle(size: 26, filled: true))
                .disabled(value <= range.lowerBound)
            Text(format(value))
                .font(.system(size: 13.5, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Color.ink)
                .frame(minWidth: 52)
            Button { withAnimation(Motion.snappy) { value = min(range.upperBound, value + step) } } label: { Image(systemName: "plus") }
                .buttonStyle(IconButtonStyle(size: 26, filled: true))
                .disabled(value >= range.upperBound)
        }
    }
}
