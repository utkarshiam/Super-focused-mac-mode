import Foundation

enum NoteTemplate: String, CaseIterable, Identifiable {
    case blank, meeting, oneOnOne, daily, decision, idea

    var id: String { rawValue }

    var label: String {
        switch self {
        case .blank: "Blank Note"
        case .meeting: "Meeting Notes"
        case .oneOnOne: "1:1"
        case .daily: "Daily Note"
        case .decision: "Decision Record"
        case .idea: "Idea"
        }
    }

    var icon: String {
        switch self {
        case .blank: "doc"
        case .meeting: "person.3"
        case .oneOnOne: "person.2"
        case .daily: "sun.max"
        case .decision: "checkmark.seal"
        case .idea: "lightbulb"
        }
    }

    func body(for date: Date = Date()) -> String {
        let day = Fmt.longDay(date)
        switch self {
        case .blank:
            return ""
        case .meeting:
            return """
            # Meeting — \(day)

            **Attendees:**
            **Goal:**

            ## Agenda
            -

            ## Notes
            -

            ## Decisions
            -

            ## Action items
            - [ ]
            """
        case .oneOnOne:
            return """
            # 1:1 with  — \(day)

            ## How are things?
            -

            ## Updates & blockers
            -

            ## Feedback
            -

            ## Action items
            - [ ]
            """
        case .daily:
            return """
            # \(day)

            ## Top 3 today
            - [ ]
            - [ ]
            - [ ]

            ## Notes
            -

            ## End of day
            - Wins:
            - Tomorrow:
            """
        case .decision:
            return """
            # Decision:

            **Date:** \(day)
            **Owner:**
            **Status:** Proposed

            ## Context


            ## Options
            1.
            2.

            ## Decision & rationale


            ## Follow-ups
            - [ ]
            """
        case .idea:
            return """
            # Idea:

            ## The problem


            ## The idea


            ## Why now


            ## Next step
            - [ ]
            """
        }
    }
}

extension NoteTemplate {
    static let guideBody = """
        # Welcome to Docket 👋

        Docket keeps your **tasks**, **notes**, **reminders** and **alarms** in one fast Mac app.

        ## Capture anything, fast
        - Press **⌃⌥T** from any app to open Quick Capture (change it in Settings).
        - Or click the ✓ icon in the menu bar.
        - Type naturally — Docket picks out the details:
          - `Board prep fri 3pm 90m !!! #work @alarm15`
          - `Pay contractor invoice tomorrow #finance`
          - `Gym every mon, wed, fri 7am 1h`
          - `Ship pricing page by eod !!`

        ## Quick-add cheat sheet
        - **When:** today, tomorrow 4pm, fri, next tue 10:30, dec 3, in 2 hours, eod, eow, next week
        - **How long:** 15m, 45 min, 1h30m, 1.5h
        - **Priority:** ! low · !! medium · !!! high · !!!! urgent
        - **List or tag:** #work (matches a list name, otherwise becomes a tag)
        - **Repeat:** daily, every weekday, every mon & thu, every 2 weeks, monthly
        - **Reminders:** @remind (at deadline), @remind30 (30 min before), @alarm10 (loud alarm 10 min before)

        ## Alarms vs reminders
        - A **reminder** is a normal macOS notification with Complete / Snooze buttons.
        - An **alarm** rings and keeps ringing in a window on top of everything until you snooze or dismiss it.

        ## Your calendar
        **Calendar** is today and everything after it in one place. Click a day in the week strip to jump to it, switch to **Month** for the whole month, and drag any task onto a day to move it. Turn on calendar events in Settings to see your meetings next to your tasks.

        ## Notes that look finished
        Notes open in **Read** mode: headings, lists, checkboxes, tables and code show formatted. Press **⌘E** to edit the Markdown underneath. Paste Markdown from anywhere into an empty note, or use **New Note from Clipboard (⌥⌘V)**, and it shows formatted right away. Drag in photos or videos, or paste a screenshot.

        ## Notes → tasks
        Write meeting notes with checklists like the sample note, then click **Extract action items**. Each open item becomes a task. Ticking it in the note completes the task, and completing the task ticks it in the note.

        ## Shortcuts
        - ⌘N new task · ⇧⌘N new note · ⌘K jump to anything
        - ⌘1 Calendar · ⌘2 Inbox · ⌘3 Notes
        - ↑ ↓ move through tasks · ← → change day · esc close
        - ⌘E read or edit a note · ⌥⌘V note from clipboard · ⌃⌘S hide the sidebar
        - ⌘↩ complete selected task · ⌘D today's daily note
        """
}

extension Store {
    /// First-launch content: a guide note, a sample meeting note and a few example tasks.
    func seed() {
        let cal = calendar
        let now = Date()
        let today = cal.startOfDay(for: now)
        func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }

        let work = TaskList(name: "Work", color: .indigo, icon: "briefcase", sortOrder: 0)
        let personal = TaskList(name: "Personal", color: .green, icon: "house", sortOrder: 1)

        var tryIt = TaskItem(title: "Try quick add: type “Board prep fri 3pm 90m !!! #work @alarm15” in the bar above")
        tryIt.scheduledDate = today
        tryIt.estimateMinutes = 2
        tryIt.priority = .medium

        var update = TaskItem(title: "Send monthly investor update")
        update.listID = work.id
        update.priority = .high
        update.estimateMinutes = 60
        update.dueDate = day(2)
        update.subtasks = [Subtask(title: "Pull metrics"), Subtask(title: "Highlights & lowlights"), Subtask(title: "Asks")]
        update.reminders = [Reminder(trigger: .beforeDue(minutes: 0))]
        update.recurrence = .monthly

        var call = TaskItem(title: "Call with lawyer re: contracts")
        call.listID = work.id
        call.estimateMinutes = 30
        call.dueDate = cal.date(bySettingHour: 11, minute: 0, second: 0, of: day(1))
        call.dueHasTime = true
        call.reminders = [Reminder(trigger: .beforeDue(minutes: 10), isAlarm: true)]

        var plan = TaskItem(title: "Weekly planning")
        plan.listID = work.id
        plan.estimateMinutes = 30
        plan.recurrence = Recurrence(frequency: .weekly, weekdays: [2])
        plan.dueDate = plan.recurrence!.firstOccurrence(onOrAfter: today, calendar: cal)

        var inbox = TaskItem(title: "Review hiring pipeline")
        inbox.estimateMinutes = 45
        inbox.scheduledDate = today
        inbox.priority = .high

        var flights = TaskItem(title: "Book flights for offsite")
        flights.listID = personal.id
        flights.estimateMinutes = 20
        flights.dueDate = day(5)

        let welcome = Note(body: NoteTemplate.guideBody)

        var meeting = Note(body: """
        # Leadership sync — sample

        **Attendees:** CEO, CTO, Head of Sales
        **Goal:** Q4 priorities

        ## Notes
        - Pipeline is up 30% QoQ, enterprise deals slipping to Jan
        - Need to hire 2 senior engineers before EOY

        ## Action items
        - [ ] Send revised pricing proposal to sales tomorrow 30m #work
        - [ ] Draft senior engineer job description fri 1h !!
        - [ ] Book offsite venue next week 20m
        """)
        meeting.createdAt = now.addingTimeInterval(-3600)
        meeting.updatedAt = now.addingTimeInterval(-3600)

        var welcomeNote = welcome
        welcomeNote.isPinned = true

        var db = Database()
        db.lists = [work, personal]
        db.tasks = [tryIt, inbox, update, call, plan, flights]
        db.notes = [welcomeNote, meeting]
        apply(db)
    }
}
