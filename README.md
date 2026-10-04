# Docket

A fast, native macOS app for tasks and notes, with time estimates, deadlines, reminders and alarms you can't ignore.
It ships as a universal app that runs natively on Apple Silicon and Intel Macs (macOS 13 Ventura or later).

## What it does

The look follows the design language: ink on warm paper, big confident type, hairlines instead of shadows, one obvious action per screen, and fast spring animations.

**Tasks**

- Type tasks naturally: `Board prep fri 3pm 90m !!! #work @alarm15` sets the deadline, estimate, priority, list and alarm in one line.
- Each task can have a deadline (date, or date and time), a separate "do on" day, a time estimate, priority, list, tags, a checklist, notes and a repeat rule (daily, weekdays, specific weekdays, every N weeks/months, …).
- **Calendar**: today and everything after it in one view. A week strip on top, then a day-by-day agenda (overdue first, then each day's tasks, untimed first and then by time), or a full **Month** grid. Drag a task onto any day to reschedule it, or onto a list in the sidebar to move it.
- Every task shows its date and time on the right, big and bold.
- Other views: **Inbox**, **Important**, **All**, **Completed**, plus your own lists and tags.
- Undo everything with ⌘Z.

**Reminders and alarms**

- **Reminders** are macOS notifications with _Complete_, _Snooze 10 min_, _Snooze 1 hour_ and _Move to Tomorrow_ buttons.
- **Alarms** ring with a looping sound in a window that floats above everything, including full-screen apps, until you snooze, complete or dismiss them.
- Any number of reminders or alarms per task: "15 min before the deadline", "tomorrow 9:00", or a custom time.
- A **morning briefing** notification summarises the day (task count, planned hours, overdue items, first timed task).

**Planning your day**

- Optionally shows your calendar events in Calendar, next to your tasks (Settings → Planner).
- **Focus timer** on any task: counts down the estimate (or 25 min, or a stopwatch), shows in the menu bar, and logs time spent against the task.
- **Insights**: tasks completed per day, focus time, on-time rate, and how accurate your estimates are.

**Notes**

- **Read** shows a note as a finished document: headings, bold and italic, links, bullets and numbered lists, clickable checkboxes, quotes, code blocks, dividers and real tables. **Edit** shows the Markdown with live styling. ⌘E switches.
- Paste Markdown (from ChatGPT, Claude, a README…) into an empty note and it flips to the formatted view. **New Note from Clipboard** (⌥⌘V) does it in one step.
- **Photos and videos**: paste a screenshot, drag files in, or use the photo button. Click a photo to see it full size or a video to play it. Files are copied into Docket's data folder, so notes keep working if the originals move.
- **Copy as formatted text** (for Mail, Pages, Google Docs) and **Export as PDF** or Markdown (photos come along).
- Templates: meeting notes, 1:1, daily note (⌘D), decision record, idea.
- **Extract action items** turns every open checkbox in a note into a task. Ticking the box in the note completes the task, and completing the task ticks the box.
- Right-click any line → _Create Task from This Line_.

**Always within reach**

- Menu bar dropdown with today's agenda, quick add and the running timer.
- Global **Quick Capture** shortcut (default ⌃⌥T) opens a Spotlight-style box from any app. Tab switches between task and note.
- ⌘K jumps to any task, note, list or view, or creates a task from what you typed.
- Light and dark themes: follows macOS by default, or pick one in **Settings → General → Appearance**.

## Installing on another Mac

1. Open `dist/Docket-1.0.0.dmg` and drag **Docket** into **Applications**.
2. The first time you open it, macOS may say it can't verify the developer, because this build isn't notarized yet (see _Signing_ below):
   - **macOS 15 or later:** click _Done_, open **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to the Docket message, then confirm.
   - **macOS 13–14:** right-click Docket in Applications → **Open** → **Open**.
   - Or in Terminal: `xattr -dr com.apple.quarantine /Applications/Docket.app`
3. Allow notifications when asked, so reminders, the morning briefing and focus alerts can appear.
4. In **Settings → General**, turn on **Open Docket when I log in** so alarms ring even after a restart. Alarms need Docket running (it lives in the menu bar). Plain reminders arrive even when it's closed.

The first launch includes a pinned **Welcome to Docket** note with a quick-add cheat sheet, and a few sample tasks you can delete.

## Keyboard shortcuts

| Shortcut       | Action                                                      |
| -------------- | ----------------------------------------------------------- |
| ⌃⌥T (anywhere) | Quick Capture (configurable)                                |
| ⌘N / ⇧⌘N       | New task / new note                                         |
| ⌘K             | Jump to anything                                            |
| ⌘1 – ⌘7        | Calendar, Inbox, Notes, Important, All, Completed, Insights |
| ↑ / ↓          | Move through tasks or notes                                 |
| ← / →          | Previous / next day in Calendar                             |
| Esc            | Close the task panel                                        |
| Delete         | Delete the selected task (undo with ⌘Z)                     |
| ⌘↩             | Complete the selected task                                  |
| ⌘T / ⌥⌘T       | Do today / move to tomorrow                                 |
| ⇧⌘F            | Start a focus session on the selected task                  |
| ⌃⌘1 – ⌃⌘4      | Priority urgent / high / medium / low                       |
| ⌘⌫             | Delete the selected task (undo with ⌘Z)                     |
| ⌘D             | Today's daily note                                          |
| ⌘E             | Read / Edit a note                                          |
| ⌥⌘V            | New note from the clipboard (shown formatted)               |
| ⌃⌘S            | Hide or show the sidebar                                    |
| ⌘B / ⌘I        | Bold / italic in notes                                      |

## Data and backups

Everything lives in one JSON file on the Mac: `~/Library/Application Support/Docket/docket.json`. Photos and videos added to notes sit next to it in `attachments/` (they aren't inside the JSON backups, so back that folder up too if it matters).
Docket keeps a daily backup for 30 days in `…/Docket/Backups/`. If the main file is ever unreadable, Docket sets it aside and restores the newest backup automatically.
**Settings → Data** has export/import (JSON) and _Export Notes as Markdown_.

## Building

Requirements: Xcode 15 or later (built and tested here with Xcode 26.6 / Swift 6.3). No third-party dependencies.

```bash
scripts/build.sh                 # tests + universal build + Docket.app + DMG + ZIP in dist/
swift test                       # 31 unit tests (quick-add parser, recurrence, storage, note↔task sync)
swift build && .build/debug/Docket   # quick debug run (no notifications outside an .app bundle)
```

`scripts/build.sh` options: `VERSION=1.1.0`, `BUILD_NUMBER=…`, `BUNDLE_ID=com.yourco.docket`.

### Signing and notarization

By default the build is **ad-hoc signed**, which is enough to run it on your own Macs with the one-time "Open Anyway" step above.
To send it to anyone without that step, sign with a **Developer ID Application** certificate (Apple Developer Program, $99/year) and notarize:

```bash
# one time: store notarization credentials (use an app-specific password)
xcrun notarytool store-credentials docket-notary --apple-id you@company.com --team-id TEAMID

SIGN_IDENTITY="Developer ID Application: Your Company (TEAMID)" \
NOTARY_PROFILE="docket-notary" \
scripts/build.sh
```

The script signs with the hardened runtime plus the calendar entitlement, notarizes the DMG and staples the ticket.

> Ad-hoc builds get a new signature on every rebuild, so macOS may ask for calendar access again after you install an update. "Open at login" may also need the app to be in /Applications.

## Project layout

```
Sources/Docket/
  App/        entry point, AppDelegate (windows, menu bar, hotkey wiring), main menu, panels
  Models/     Task, Note, List, Reminder, Recurrence (Codable, forward-compatible decoding)
  Store/      Store (state, undo, saving), queries (calendar agenda, lists), persistence + backups, seed data
  Services/   notifications, alarms, focus timer, global hotkey, calendar
  Support/    quick-add parser, formatting, preferences
  Views/      SwiftUI views (Theme.swift holds the design tokens); MarkdownEditor wraps NSTextView
scripts/      build.sh (universal app + DMG), make-assets.swift (icon + alarm sound)
Tests/        XCTest suite
```

For layout checks, run with `DOCKET_DATA_DIR=/tmp/docket-test DOCKET_SNAPSHOT_DIR=/tmp/shots`. Docket then walks through every screen, types into the quick-add fields, saves screenshots and quits, without touching your real data.
