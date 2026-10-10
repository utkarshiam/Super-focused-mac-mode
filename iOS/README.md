# Docket for iPhone

The phone half of Docket Memory. Record a debrief after a meeting and get tasks with real dates in
seconds; capture notes, links, photos, files and tasks; browse and search your memory; ask it
questions (by voice too); tick off today's tasks. The memory itself lives on your
Mac. The phone reads what the Mac publishes and drops captures for the Mac to pick up.

SwiftUI, iOS 17+, built on the shared `MemoryKit` package at the repo root (`../Package.swift`).

## Build and run

Open `iOS/DocketPhone.xcodeproj` in Xcode 26 and run the `DocketPhone` scheme on a simulator.
Sources in `iOS/DocketPhone/` are a file-system synchronized group, so a new `.swift` file is
picked up without editing the project.

From the command line:

```sh
xcodebuild -project iOS/DocketPhone.xcodeproj -scheme DocketPhone \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO build
```

**On your own iPhone:** in Xcode, select the DocketPhone target → Signing & Capabilities, tick
"Automatically manage signing" and choose your own team. A free Apple ID works; Xcode adds it as a
"Personal Team". If the bundle id `com.docketapp.DocketPhone` is taken, change it to something of
your own. Then pick your phone as the run destination. The project ships with no team set.

### Demo mode (screenshots)

Set these environment variables in the scheme (they're there, switched off) or with
`SIMCTL_CHILD_…` and `xcrun simctl launch`:

| Variable | Effect |
| --- | --- |
| `DOCKET_PHONE_DEMO=1` | Seeds a throwaway Docket folder in the temp directory with sample memories, tasks and recent captures. Your real folder, Keychain and the network are never touched. |
| `DOCKET_PHONE_TAB=capture\|record\|debrief\|memory\|topics\|map\|ask\|today\|settings` | The tab to start on (`settings` opens the Settings sheet). `record` shows a recording in progress with a live transcript; `debrief` shows a finished result card (Hindi/English, 3 tasks). |
| `DOCKET_PHONE_ITEM=first\|<index>\|<words>` | Opens that memory (the first one, by index, or by words in its title). |
| `DOCKET_PHONE_ENTITY=<name>` | Opens that topic's, person's or project's page ("Seed round", "Maya Chen"). |
| `DOCKET_PHONE_SEARCH=<words>` | Starts Memory → Library with that search. |
| `DOCKET_PHONE_MAP_FOCUS=<name>`, `…_MAP_SELECT=<name>`, `…_MAP_DAYS=<n>`, `…_MAP_ZOOM=<x>` | The map opens focused on a node, with a node's card open, with the time slider n days back, or zoomed in. |
| `DOCKET_PHONE_MAP_NODES=<n>`, `DOCKET_PHONE_MAP_TIMING=1` | Stress test: pads the map with made-up nodes up to n; logs each map draw's time. |

In demo mode the Ask tab starts with a ready-made answer, and further questions get canned replies.
The demo library comes with an organised brain (`MemoryBrain.debugSeed`): areas, topics, pages, a
disagreement, connections, this week's digest and the map.

## Topics, pages and the map

Memory has three views, picked at the top and remembered: **Library · Topics · Map**. All of it is
read from what the Mac publishes (`snapshot.brain`); the phone never changes the brain. Renaming,
merging and moving happen on the Mac, and the phone says so in one quiet line.

- **Topics:** this week's digest ("What you learned 5–11 Oct") and up to three connections you
  haven't made, then areas with their topics (count, last seen as a real date) and the unsorted
  count. A switch shows people, organisations and projects instead (in the lens's words).
- **Pages:** breadcrumb, kind, counts, first and last seen; What you know with tappable [n]
  citations; key facts; notes that disagree (with their sources and dates); open questions;
  sub-topics; related things; the timeline. Topic, people and project chips on a memory open them.
- **Map:** the Mac's layout drawn in one Canvas, coloured by area with the Mac's palette. Pinch and
  drag; labels appear as you zoom and never overlap; tap a node for Open page or Focus (Show all to
  go back); chips hide kinds; the slider steps through the days things first appeared.
- **Search** in Library also matches topic, people and project names ("Topics & people", above
  the memories).

## Voice debriefs

The big mic on Capture records a debrief: walk out of a meeting, talk for 20 seconds or 20 minutes
(Hindi, English or both), tap Stop. Within seconds the result card says "Added 3 tasks", each with
its real date ("Send revised quote to Rohan Mehta · Fri 16 Oct"), who you're waiting on, and a
one-line summary. ✕ removes a task, a tap edits its title or date, Undo all drops them. The tasks
show in Today at once, marked "Just added", until your Mac's task list has them.

- **Recording.** AAC in an ADTS stream (`.aac`, 16 kHz mono, about 32 kbps, so roughly 15 MB an
  hour), written to `Documents/Voice/` as you speak, so even a crash keeps everything up to the
  last second. It keeps going with the screen locked (background audio). A phone call pauses it and
  keeps what was recorded; Resume carries on in the same file. It stops by itself at 60 minutes.
- **Live transcript.** On-device speech recognition in the Speech language from Settings (device
  default, English (India), Hindi, English (US) and a few more). It's only a hint: Gemini writes the
  real transcript from the audio, in whatever language was spoken.
- **Debrief.** With a Gemini key, the phone sends the recording to Gemini (`audio/aac`; inline up to
  14 MB, through the Files API above that) along with your lists and the names in your memory, and
  gets back the transcript, a summary, people, decisions, promises others made, and your tasks with
  absolute dates. The capture is held while the result card is open (and for 20 seconds after it
  first shows), so edits are free; then it's written to the Docket folder with the audio, the
  on-device transcript and the debrief, and the Mac creates the tasks with the same ids. Removing a
  task after that sends a `taskDelete`.
- **Offline.** "Saved. Will turn into tasks when you're back online." The recording waits on the
  phone and goes to Gemini when the network comes back. If that hasn't worked after 30 minutes, it's
  written without a debrief and your Mac turns it into tasks.
- **No key.** Written at once without a debrief: "Saved. Your Mac will turn it into tasks."
- **Gemini errors** show as a sentence; the recording is never lost (it goes to the Mac instead).

### Start without opening the app

- **Siri:** "Record in Docket", "Start a debrief in Docket". The app opens already recording.
- **Action Button** (iPhone 15 Pro and later): Settings → Action Button → Shortcut → Docket →
  Record a debrief.
- **Spotlight / Shortcuts:** "Record a debrief" and "Add a task" (asks for the title, works without
  opening the app).
- **URL:** `docket://record`.

### Voice everywhere

- The mic in Ask's field dictates the question and asks it when you tap stop.
- Listen on an answer reads it aloud (citation markers skipped).
- The mic in the Capture field dictates a note.

## How sync works

There's no server. The Mac and the phone share a folder in iCloud Drive (usually
`iCloud Drive/Docket`):

```
Docket/
  Inbox/     the phone writes here: <id>.capture.json (+ "<id>--<file name>" for an attachment)
  Library/   the Mac writes here: snapshot.json, vectors.bin, Thumbs/<item id>.jpg
```

1. On your Mac: Settings → Memory → iPhone. That creates the folder and starts publishing.
2. On the phone: Settings (gear) → Choose folder → iCloud Drive → Docket. The app keeps a
   security-scoped bookmark, so it only needs asking once.

Captures are saved first to the app's own `Documents/Pending` folder, then written into `Inbox/`.
Without a folder, or when writing fails, they wait there ("3 waiting to sync") and go out as soon
as the folder is reachable. The Recent list shows each one as waiting, synced (in the folder) or
on your Mac (the Mac took it in and removed it from the Inbox).

Ticking a task writes a `taskDone` capture, unticking it a `taskUndone`. The task stays ticked on
the phone until a newer snapshot from the Mac confirms it. Swiping a task away hides it at once with
Undo on the toast for five seconds, then writes a `taskDelete`.

The phone never writes to `Library/`. Reads and writes go through `NSFileCoordinator`, and files
that are still only in iCloud are downloaded on demand. A missing or half-synced snapshot shows as
"waiting" or "downloading" and is read again on the next pass (every 15 seconds while the app is
open, on pull-to-refresh, and whenever the app comes to the front).

## Privacy

- No account and no server. Everything moves through your own iCloud Drive.
- AI is opt-in. Paste your own Google Gemini key in Settings. It's stored in this iPhone's
  Keychain (this device only) and never written to files or logs.
- With a key, Ask sends your question and the few memories that match it to Gemini, and search
  sends the query to Gemini to search by meaning. Without a key nothing leaves the phone, and text
  search still works.
- With a key, a voice debrief sends the recording and the names in your memory to Gemini. A file
  too big to send inline is uploaded to Gemini's Files API and deleted again once it has answered.
- The microphone is on only while you record or dictate. Speech recognition runs on the iPhone
  when the language supports it. The camera and photo library are used only when you pick a photo.

## Layout

```
DocketPhone/
  App/        app entry, tab bar, toast, settings button
  App/        also App Intents (Siri, Action Button, Shortcuts) and the docket:// URL
  Model/      AppModel (folder, snapshot, search, captures, tasks), capture queue,
              folder bookmark + iCloud file access, Ask session, voice recorder, live
              transcript, dictation + read aloud, VoiceCenter (debrief, hold, retry), demo seed,
              BrainSupport (routes, reading the brain snapshot, area colours)
  Views/      Capture, recording screen + result card, task composer, Memory (Library, Topics,
              Map), entity pages, item detail, Ask,
              Today, Settings
DocketPhone-Info.plist   background audio and the docket:// scheme (merged with generated keys)
  Support/    Theme (mirrors the Mac's ink-and-paper tokens), date formatting, Keychain
```
