import Charts
import SwiftUI

/// Numbers behind the Insights screen, computed once per render.
struct InsightsModel {
    struct DayValue: Identifiable {
        var day: Date
        var value: Double
        var id: Date { day }
    }

    var completedPerDay: [DayValue] = []
    var focusPerDay: [DayValue] = []
    var thisWeek = 0
    var lastWeek = 0
    var focusWeekSeconds = 0
    var onTime = 0
    var withDeadline = 0
    var estimateRatio: Double?
    var timeByList: [(id: UUID?, name: String, minutes: Int)] = []
    var openCount = 0
    var overdueCount = 0
    var dueThisWeek = 0
    var outstandingMinutes = 0

    @MainActor
    init(store: Store, now: Date) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let days = (0..<14).map { cal.date(byAdding: .day, value: -13 + $0, to: today)! }
        let weekAgo = cal.date(byAdding: .day, value: -6, to: today)!
        let twoWeeksAgo = cal.date(byAdding: .day, value: -13, to: today)!
        let monthAgo = cal.date(byAdding: .day, value: -30, to: today)!

        let completed = store.tasks.filter { $0.completedAt != nil }
        completedPerDay = days.map { d in
            DayValue(day: d, value: Double(completed.filter { cal.isDate($0.completedAt!, inSameDayAs: d) }.count))
        }
        focusPerDay = days.map { d in
            let seconds = store.sessions.filter { cal.isDate($0.start, inSameDayAs: d) }.reduce(0) { $0 + $1.seconds }
            return DayValue(day: d, value: Double(seconds) / 60)
        }
        thisWeek = completed.filter { $0.completedAt! >= weekAgo }.count
        lastWeek = completed.filter { $0.completedAt! >= twoWeeksAgo && $0.completedAt! < weekAgo }.count
        focusWeekSeconds = store.sessions.filter { $0.start >= weekAgo }.reduce(0) { $0 + $1.seconds }

        let recent = completed.filter { $0.completedAt! >= monthAgo && $0.dueDate != nil }
        withDeadline = recent.count
        onTime = recent.filter { t in
            let deadline = t.dueHasTime ? t.dueDate! : cal.endOfDay(for: t.dueDate!)
            return t.completedAt! <= deadline.addingTimeInterval(60)
        }.count

        let estimated = completed.filter { $0.completedAt! >= monthAgo && ($0.estimateMinutes ?? 0) > 0 && $0.trackedSeconds >= 60 }
        if !estimated.isEmpty {
            let spent = Double(estimated.reduce(0) { $0 + $1.trackedSeconds }) / 60
            let planned = Double(estimated.reduce(0) { $0 + ($1.estimateMinutes ?? 0) })
            estimateRatio = spent / planned
        }

        var byList: [UUID?: Int] = [:]
        for s in store.sessions where s.start >= weekAgo {
            byList[store.task(s.taskID)?.listID, default: 0] += s.seconds
        }
        timeByList = byList.map { id, secs in (id, store.list(id)?.name ?? "Inbox", secs / 60) }
            .filter { $0.minutes > 0 }
            .sorted { $0.minutes > $1.minutes }

        let open = store.tasks.filter { !$0.isCompleted }
        let nextWeek = cal.date(byAdding: .day, value: 7, to: today)!
        openCount = open.count
        overdueCount = store.overdueCount(now: now)
        dueThisWeek = open.filter { t in t.dueDate.map { $0 >= today && $0 < nextWeek } ?? false }.count
        outstandingMinutes = open.reduce(0) { $0 + $1.remainingMinutes }
    }

    var weekDelta: String {
        if lastWeek == 0 { return thisWeek == 0 ? "Nothing yet. You've got this." : "Up from none the week before" }
        let change = Int((Double(thisWeek - lastWeek) / Double(lastWeek) * 100).rounded())
        return change >= 0 ? "Up \(change)% on the week before" : "Down \(-change)% on the week before"
    }
}

struct InsightsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState

    var body: some View {
        let m = InsightsModel(store: store, now: app.clock)

        ScrollView {
            VStack(alignment: .leading, spacing: Space.x3) {
                PageHeader(title: "Insights", subtitle: "How the last two weeks went")
                    .padding(.horizontal, -Space.gutter)

                hero(m).enterUp(0)

                HStack(alignment: .top, spacing: Space.md) {
                    stat("On time", m.withDeadline == 0 ? "–" : "\(Int((Double(m.onTime) / Double(m.withDeadline) * 100).rounded()))%",
                         m.withDeadline == 0 ? "No deadlines met yet" : "\(m.onTime) of \(m.withDeadline) deadlines, 30 days")
                    stat("Estimates", m.estimateRatio.map { String(format: "%.1f×", $0) } ?? "–", estimateCaption(m.estimateRatio))
                    stat("Overdue", "\(m.overdueCount)", m.overdueCount == 0 ? "Nothing slipping" : "Waiting in Calendar")
                    stat("Work left", Fmt.duration(minutes: m.outstandingMinutes), "\(m.openCount) open, \(m.dueThisWeek) due this week")
                }
                .enterUp(1)

                HStack(alignment: .top, spacing: Space.md) {
                    chartCard("Tasks finished", m.completedPerDay, unit: "Tasks")
                    chartCard("Focus minutes", m.focusPerDay, unit: "Minutes")
                }
                .enterUp(2)

                Card {
                    VStack(alignment: .leading, spacing: Space.md) {
                        Text("Where your focus went").textStyle(.title3).foregroundStyle(Color.ink)
                        if m.timeByList.isEmpty {
                            Text("No focus sessions this week. Start one from any task to track time against it.")
                                .textStyle(.callout)
                                .foregroundStyle(Color.ink2)
                        } else {
                            let top = m.timeByList.map(\.minutes).max() ?? 1
                            ForEach(m.timeByList, id: \.id) { entry in
                                HStack(spacing: Space.md) {
                                    Text(entry.name).textStyle(.subheadStrong).foregroundStyle(Color.ink).frame(width: 120, alignment: .leading).lineLimit(1)
                                    GeometryReader { g in
                                        ZStack(alignment: .leading) {
                                            Capsule().fill(Color.fillStrong)
                                            Capsule().fill(Color.primaryFill).frame(width: max(6, g.size.width * CGFloat(entry.minutes) / CGFloat(top)))
                                        }
                                    }
                                    .frame(height: 8)
                                    Text(Fmt.duration(minutes: entry.minutes))
                                        .font(.system(size: 13, weight: .bold))
                                        .monospacedDigit()
                                        .foregroundStyle(Color.ink)
                                        .frame(width: 64, alignment: .trailing)
                                }
                            }
                        }
                    }
                }
                .enterUp(3)
            }
            .padding(.horizontal, Space.gutter)
            .padding(.bottom, Space.x6)
        }
        .background(Color.paper)
    }

    /// The one answer on this screen: what got done this week.
    private func hero(_ m: InsightsModel) -> some View {
        Panel {
            HStack(alignment: .bottom, spacing: Space.x4) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Finished this week").textStyle(.eyebrow).foregroundStyle(Color.onDark58)
                    Text("\(m.thisWeek)")
                        .font(.system(size: 48, weight: .bold))
                        .tracking(-1.4)
                        .monospacedDigit()
                        .foregroundStyle(Color.white)
                    Text(m.weekDelta).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.onDark58)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Focused").textStyle(.eyebrow).foregroundStyle(Color.onDark58)
                    Text(Fmt.duration(seconds: m.focusWeekSeconds))
                        .font(.system(size: 34, weight: .bold))
                        .tracking(-0.8)
                        .monospacedDigit()
                        .foregroundStyle(Color.white)
                    Text(m.focusWeekSeconds == 0 ? "Start a focus session from any task" : "\(Fmt.duration(seconds: m.focusWeekSeconds / 7)) a day on average")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.onDark58)
                }
                Spacer()
            }
        }
    }

    private func estimateCaption(_ ratio: Double?) -> String {
        guard let ratio else { return "Needs focus time on estimated tasks" }
        if ratio > 1.15 { return "Tasks take longer than planned" }
        if ratio < 0.85 { return "You finish faster than planned" }
        return "Your estimates are spot on"
    }

    private func stat(_ title: String, _ value: String, _ caption: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(text: title)
                Text(value)
                    .font(.system(size: 28, weight: .bold))
                    .tracking(-0.6)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(Color.ink)
                Text(caption)
                    .textStyle(.footnote)
                    .foregroundStyle(Color.ink2)
                    .lineLimit(2, reservesSpace: true)
            }
        }
    }

    private func chartCard(_ title: String, _ values: [InsightsModel.DayValue], unit: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                Text(title).textStyle(.title3).foregroundStyle(Color.ink)
                Chart(values) { d in
                    BarMark(x: .value("Day", d.day, unit: .day), y: .value(unit, d.value))
                        .foregroundStyle(Color.primaryFill)
                        .cornerRadius(4)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                            .foregroundStyle(Color.ink3)
                    }
                }
                .chartYAxis {
                    AxisMarks { _ in
                        AxisGridLine().foregroundStyle(Color.hair)
                        AxisValueLabel().foregroundStyle(Color.ink3)
                    }
                }
                .frame(height: 170)
            }
        }
    }
}
