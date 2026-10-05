<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="Docket app icon">
</p>

<h1 align="center">Docket</h1>

<p align="center">
  <b>Tasks and notes for people whose day is already full.</b><br>
  A fast, native Mac app with real dates on every line, alarms you can't sleep through,<br>
  Markdown notes that look finished, and AI that turns a brain dump into a plan.
</p>

<p align="center">
  <img alt="macOS 13 or later" src="https://img.shields.io/badge/macOS-13%2B-0E0E0C?logo=apple&logoColor=white">
  <img alt="Universal: Apple Silicon and Intel" src="https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-universal-0E0E0C">
  <img alt="SwiftUI and AppKit" src="https://img.shields.io/badge/SwiftUI%20%2B%20AppKit-native-F05138?logo=swift&logoColor=white">
  <img alt="No third-party dependencies" src="https://img.shields.io/badge/dependencies-none-0E0E0C">
  <img alt="Local-first" src="https://img.shields.io/badge/data-on%20your%20Mac-0E0E0C">
</p>

<p align="center">
  <img src="docs/images/hero.png" alt="Docket's calendar list with a task open, in light and dark mode" width="100%">
</p>

---

## Why Docket

Most to-do apps are built for planning. Docket is built for the day you're actually having.

- **Every line tells you when.** No "Today" and "Tomorrow" headings to decode. Each task shows its real date, its time, and how long it takes, big and bold on the right.
- **Typing is the interface.** `Board prep fri 3pm 90m !!! #work @alarm15` sets the deadline, the estimate, the priority, the list and a loud alarm in one line. Prefer clicking? Pick the date, time and list from the menus under the field.
- **Alarms that actually stop you.** Reminders are normal notifications. Alarms ring in a window that floats above everything, full-screen apps included, until you deal with them.
- **AI that plans, not chats.** Write what's on your mind and get real tasks back: dates resolved, durations estimated, big work split into steps. Nothing is added until you say so.
- **Your inbox and Slack, triaged.** React with 📌 in Slack or star an email, and Docket suggests the task.
- **Yours.** Everything lives in one JSON file on your Mac. No account, no server, no tracking.

## Tour

### One calendar, every date

Overdue work first, then every dated task in order. Drag to reorder a day (dragging never changes a date), switch to **Month** to move a task to another day, or press **⌥⌘C** for compact rows when the list gets long.

<p align="center">
  <img src="docs/images/calendar.png" alt="The Calendar list: each task shows its date, time and duration on the right" width="49%">
  <img src="docs/images/compact.png" alt="Compact rows: one line per task" width="49%">
</p>

### Add a task in one line, or with three clicks

Docket parses dates ("next tue 10:30", "eod", "in 2 hours"), durations, priorities, lists, repeats and reminders as you type, and shows what it understood. The **Date**, **Time** and **List** menus under the field do the same without any syntax.

<p align="center">
  <img src="docs/images/quick-add.png" alt="Quick add parsing a task as you type, with date, time and list menus" width="80%">
</p>

### Plan with AI

Press **⌘J**, write a brain dump, and review the tasks Docket proposes: titles, dates, durations, priorities, lists and steps, each one editable. **Break down with AI** splits a big task into steps, **Order my day** suggests an order for today's work, and **Find Tasks with AI** pulls action items out of meeting notes. Powered by Google Gemini with your own key.

<p align="center">
  <img src="docs/images/ai-plan.png" alt="Plan with AI: reviewing four proposed tasks before adding them" width="80%">
</p>

### Many tasks at once

⌘-click, ⇧-click or ⌘A to select, then press **T** (today), **M** (tomorrow), **W** (next week) or **X** (done). The panel on the right changes list, priority, tags, estimate or who you're waiting on for all of them. One ⌘Z undoes the lot.

<p align="center">
  <img src="docs/images/bulk-edit.png" alt="Three tasks selected, with the bulk edit panel" width="80%">
</p>

### Search everything

**⌘F** searches every task and note: titles, notes, steps, lists, tags and people. Use `"quotes"` for a phrase and `#tag` to narrow it down.

<p align="center">
  <img src="docs/images/search.png" alt="Search results for 'board' across tasks and notes" width="80%">
</p>

### From Slack and Gmail

Connect Slack and Gmail in **Settings → Connections**. Messages you react to with 📌, messages that @mention you, starred emails and emails waiting on your reply become suggested tasks. Add them in one click, edit them first, or dismiss them. Focus sessions can set your Slack status, and you can share your plan to a channel.

<p align="center">
  <img src="docs/images/slack-gmail.png" alt="Suggested tasks from Slack and Gmail" width="80%">
</p>

### Delegation and slipping work

Put a name in **Waiting on** and the task moves to **Waiting** with that person shown on the row. Tasks that get pushed back again and again earn a gentle nudge: *do it, delegate it, or drop it*. Clear the day and Docket notices.

<p align="center">
  <img src="docs/images/slipping.png" alt="An overdue task that slipped four times, with the do it, delegate it or drop it card" width="80%">
</p>

### Notes that look finished

Notes open formatted: headings, lists, clickable checkboxes, quotes, tables, code, photos and videos. **⌘E** shows the Markdown. Paste Markdown from ChatGPT, Claude or a README into an empty note and it renders right away. Checklist items become tasks that stay in sync with the note.

<p align="center">
  <img src="docs/images/notes.png" alt="A note in Read mode with a table, checklist and photo" width="80%">
</p>

### Always within reach

A menu bar dropdown with today's list and quick add. A global **Quick Capture** shortcut (⌃⌥T) from any app. **⌘K** jumps to any task, note, list or view.

<p align="center">
  <img src="docs/images/quick-capture.png" alt="Quick Capture over another app" width="60%">
  <img src="docs/images/menubar.png" alt="The menu bar dropdown" width="30%">
</p>

## Install

1. Download the latest `Docket-x.y.z.dmg` from [Releases](../../releases/latest) and drag **Docket** into **Applications**.
2. Releases aren't notarized yet, so macOS asks you to confirm the first launch:
   - **macOS 15 or later:** try to open Docket, click **Done**, then **System Settings → Privacy & Security → Open Anyway**.
   - **macOS 13–14:** right-click Docket in Applications → **Open** → **Open**.
3. Allow notifications so reminders and the morning briefing can appear. Turn on **Open Docket when I log in** (Settings → General) so alarms ring after a restart.

The first launch includes a **Welcome to Docket** note with a cheat sheet, and a few sample tasks you can delete.

## Set up AI (optional)

1. Get a free API key from [Google AI Studio](https://aistudio.google.com/apikey).
2. Paste it into **Settings → AI**. It's stored in your macOS keychain and never shown again.
3. Press **⌘J** and write something like *"board meeting thursday 10am, deck by wednesday, dry run with Sam before that"*.

The default model is `gemini-3.5-flash`; you can change it in the same place. Only the text you send to an AI feature (plus your list and tag names) leaves your Mac. With Slack or Gmail connected, new messages are sent too, so Docket can tell which ones need a task.

## Connect Slack (optional)

Docket talks to Slack through a small Slack app of your own, so messages go straight from Slack to your Mac.

1. **Settings → Connections → Create app.** Slack opens with everything filled in. Pick your workspace and click **Create**.
2. On the app's page, click **Install to Workspace** and allow it.
3. Copy the **User OAuth Token** (it starts with `xoxp-`), paste it into Docket and click **Connect**.

It asks for these user scopes: `reactions:read`, `search:read`, `users:read` (who sent what), `users.profile:write` and `dnd:write` (focus status), `chat:write` (sharing your plan), and `channels:read`, `groups:read`, `im:read`, `mpim:read` (the channel picker).

## Connect Gmail (optional)

Gmail uses Google sign-in in your browser, which needs an OAuth client ID from Google Cloud. It's a one-time, five-minute setup; **Settings → Connections** links to each step:

1. Create a Google Cloud project.
2. Turn on the **Gmail API**.
3. Set up the **OAuth consent screen**. On Google Workspace choose **Internal**. Otherwise choose **External** and add your own address as a test user. (External apps in testing mode need reconnecting about once a week.)
4. Create an **OAuth client ID** of type **Desktop app**, and paste its ID and secret into Docket.
5. Click **Connect Gmail** and sign in.

Docket asks for read-only access (`gmail.readonly`). It never sends, deletes or changes email.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌃⌥T (anywhere) | Quick Capture (configurable) |
| ⌘N / ⇧⌘N | New task / new note |
| ⌘K | Jump to anything |
| ⌘F | Search tasks and notes (find in a note while editing it) |
| ⌘J | Plan with AI |
| ⌘1 – ⌘9 | Calendar, Inbox, Notes, Important, All, Completed, Insights, Waiting, From Slack & Gmail |
| ↑ / ↓, ⇧↑ / ⇧↓ | Move through tasks, extend the selection |
| ⌘-click, ⇧-click, ⌘A | Select several tasks |
| T / M / W / X | Selected tasks: today / tomorrow / next week / done |
| ⌥⌘↑ / ⌥⌘↓ | Move a task up or down within its day |
| Return / Esc | Open or close the task panel |
| Delete | Delete the selected tasks (⌘Z brings them back) |
| ⌘↩ | Complete the selected task |
| ⇧⌘F | Start a focus session on the selected task |
| ⌃⌘1 – ⌃⌘4 | Priority: urgent, high, medium, low |
| ⌥⌘C | Compact rows |
| ⌃⌘S | Hide or show the sidebar |
| ⌘D | Today's daily note |
| ⌘E | Read or edit a note |
| ⌥⌘V | New note from the clipboard |

## Quick-add syntax

| Type | Examples |
| --- | --- |
| When | `today`, `tomorrow 4pm`, `fri`, `next tue 10:30`, `dec 3`, `in 2 hours`, `eod`, `eow`, `next week` |
| How long | `15m`, `45 min`, `1h30m`, `1.5h` |
| Priority | `!` low · `!!` medium · `!!!` high · `!!!!` urgent |
| List or tag | `#work` (a list with that name, otherwise a tag) |
| Repeat | `daily`, `every weekday`, `every mon & thu`, `every 2 weeks`, `monthly` |
| Reminders | `@remind`, `@remind30` (30 min before), `@alarm10` (a loud alarm 10 min before) |

## Your data

- Everything lives in `~/Library/Application Support/Docket/docket.json`, with photos and videos from notes in `attachments/` next to it.
- Docket keeps a daily backup for 30 days in `Backups/`. If the data file is ever unreadable or missing, it restores the newest backup on its own.
- **Settings → Data** exports everything (attachments included) and imports it on another Mac, or exports notes as Markdown.
- API keys and tokens live in the macOS keychain, never in the data file.

## Build from source

Requirements: macOS 13+, Xcode 15 or later (Swift 5.10). No third-party dependencies.

```bash
git clone https://github.com/utkarshiam/Super-focused-mac-mode.git docket && cd docket
swift build && .build/debug/Docket     # quick debug run
swift test                             # the unit tests
scripts/build.sh                       # tests + universal Docket.app + DMG + ZIP in dist/
```

`scripts/build.sh` takes `VERSION=1.2.0`, `BUILD_NUMBER=…` and `BUNDLE_ID=com.yourco.docket`.

**Signing and notarization.** Builds are ad-hoc signed by default, which is fine for your own Macs. To ship without the "Open Anyway" step, sign with a Developer ID and notarize:

```bash
xcrun notarytool store-credentials docket-notary --apple-id you@company.com --team-id TEAMID   # once
SIGN_IDENTITY="Developer ID Application: Your Company (TEAMID)" NOTARY_PROFILE="docket-notary" scripts/build.sh
```

**Private builds with a built-in key.** To hand a build to someone without them pasting a key, put `GEMINI_API_KEY` (and optionally `GEMINI_MODEL`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`) in a `.env` file at the project root and run `EMBED_SECRETS=1 scripts/build.sh`. The keys end up inside the app, so never publish a DMG built that way. `.env` is git-ignored.

## How it's built

```
Sources/Docket/
  App/           entry point, AppDelegate (windows, menu bar, hotkey), menus, app state, panels
  Models/        tasks, notes, lists, reminders, repeat rules (Codable, forward-compatible)
  Store/         the store (state, undo, saving), queries, search, bulk actions, persistence + backups
  AI/            Gemini client and prompts (structured JSON output)
  Integrations/  Slack, Gmail, Google sign-in (loopback + PKCE), suggestions
  Services/      notifications, alarms, focus timer, global hotkey, calendar, media library
  Support/       quick-add parser, formatting, preferences, keychain, secrets
  Views/         SwiftUI views; Theme.swift holds the design tokens; a TextKit Markdown renderer
scripts/         build.sh (universal app + DMG), make-assets.swift (icon + alarm sound)
Tests/           XCTest suite
```

- **Design.** Ink on warm paper: big confident type, hairlines instead of shadows, one obvious action per screen, fast spring animations. Every colour, size and curve comes from the tokens in `Theme.swift`, and dark mode is first-class.
- **Notes.** Markdown is rendered with TextKit into real tables, checkboxes, quotes, code blocks and media, and Edit mode styles the Markdown live as you type.
- **Screenshots without clicking.** `DOCKET_DATA_DIR=/tmp/docket DOCKET_SNAPSHOT_DIR=/tmp/shots .build/debug/Docket` walks through every screen with sample data, types into the quick-add fields, saves screenshots and quits, without touching your real data. `DOCKET_SNAPSHOT_STEP=3` slows it down.

## Contributing

Issues and pull requests are welcome. Please keep changes in the existing style (the design tokens, the plain-English copy, real dates rather than "Today"), add tests for logic, and run `swift test` before opening a PR. For UI changes, the screenshot mode above is the quickest way to check light and dark mode at the minimum window size.

## License

A license hasn't been chosen yet. Until a `LICENSE` file is added, all rights are reserved.
