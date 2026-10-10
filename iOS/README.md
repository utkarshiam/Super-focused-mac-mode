# Docket for iPhone

The pocket half of Docket. Record a debrief after a meeting and get tasks with real dates in seconds;
say a task and it's scheduled; capture notes, links, photos and files; browse, search and ask your memory
(by voice too); see your topics and the map of what you know; tick off the day's tasks.

The memory itself lives on your Mac. The phone reads what the Mac publishes and drops captures for the Mac
to pick up, through a **Docket** folder in your own iCloud Drive. No server, no account.

SwiftUI, iOS 17+, iPhone only, built on the shared `MemoryKit` package at the repo root (`../Package.swift`).

## Features

Items marked *(AI)* need your own Google Gemini key (Settings on the phone); everything else works without one.

### Capture

- **One big mic** to record a debrief (below).
- **A field for anything on your mind.** Type, or tap its mic to dictate. A field holding just a link is
  saved as a link.
- **Photo** (take one or pick photos and videos from your library), **File** (from Files), **Paste link**
  (from the clipboard). Text in the field becomes the caption.
- **Task:** tap for the task composer, or long-press (or tap the small mic) to say the task instead.
- **Recent:** each capture shows as waiting, synced (in the Docket folder) or on your Mac ("3 waiting to
  sync" when the folder isn't reachable). Everything lands in Memory on the Mac.

### Record a debrief

- Walk out of a meeting, tap the mic, talk for 20 seconds or 20 minutes (Hindi, English or both), tap Stop.
- Live words while you speak, from on-device speech recognition when the language supports it.
- *(AI)* Within seconds: "Added 3 tasks", each with its real date ("Send revised quote to Rohan Mehta ·
  Fri 16 Oct"), who you're waiting on, and a one-line summary. ✕ removes a task, a tap edits its title or
  date, **Undo all** drops them. The tasks show in Today at once, marked "Just added".
- Your Mac creates the same tasks and a memory of the meeting: the audio, transcript, summary, people,
  decisions and the promises others made.
- Keeps recording with the screen locked; a phone call pauses it and **Resume** carries on. Stops by itself
  at 60 minutes. The audio is written to the phone as you speak, so even a crash keeps what was said.
- Without a key the recording still goes to your Mac: "Saved. Your Mac will turn it into tasks."

### Dictate and schedule tasks

- Say it: "Call Rohan next Friday at 3 for half an hour, remind me 15 minutes before", or "every weekday at
  9:30 standup, alarm".
- From the mic in the task composer's title, the Task tile (long-press or its small mic), or Siri.
- Stops when you tap stop or pause for about 2 seconds.
- *(AI)* The tasks are added at once. A card shows each with its real date and time, length, reminder or
  alarm, repeat and list; ✕ takes one back, **Undo all** takes them all back, a tap opens it in the composer.
- Without a key the phone reads the date, time, length and reminder itself and opens the composer filled
  in: one tap on **Add**.
- **Task composer:** title, date and time (Today and Tomorrow as quick picks), length (15m, 30m, 1h or
  custom), and under **More**: reminder (the Mac's default, none, at the time, 5/15/30/60 minutes before)
  with an Alarm switch, repeat (every day, every weekday, every week or every 2 weeks on that day, every month,
  custom days), Do on (separate from the deadline), list and priority.

### Memory: library and search

- **Library · Topics · Map**, picked at the top and remembered.
- Every memory the Mac has, newest first, with thumbnails. Filters in your lens's words: All, Decisions,
  Promises (open ones), Ideas, Insights, Links, Voice notes, Images.
- **Search** by text at once, then by meaning *(AI, when the Mac's index matches)*. Matching topics, people
  and projects show above the memories ("Topics & people").
- **A memory's page:** summary, takeaways, moments (decisions, promises, ideas, insights, with who and
  when), topics, people and projects (each opens its page), the link, the picture, the text, and a few
  related memories.

### Topics and pages

- **This week's digest** ("What you learned 5–11 Oct") and up to three **connections you haven't made**.
- **Areas** with their topics (how many memories, last seen as a real date) and how many are **Unsorted**.
  A switch shows people, organisations and projects instead.
- **Pages:** where it sits, its kind, counts, first and last seen; **What you know** with tappable [n]
  citations; key facts; **notes that disagree** with their sources and dates; open questions; sub-topics;
  related things; the timeline.

### Map

- The Mac's map of your memory: areas, topics, people, organisations and projects, coloured by area.
- Pinch and drag; labels appear as you zoom and never overlap. Tap a node for **Open page** or **Focus**
  (**Show all** to go back); chips hide kinds.
- The **date slider** steps back through the days things first appeared.

### Ask

- Ask anything you've saved, with example questions for your lenses. *(AI)*
- Answers come only from your memories, with [n] citations that open the source, the sources listed with
  dates, and follow-up questions.
- **Ask by voice:** the mic dictates the question and asks it when you tap stop.
- **Listen** reads the answer aloud (citation numbers skipped).

### Today

- Your Mac's open tasks: **Overdue**, today (as a real date, "Sat 10 Oct"), **Next 7 days** and **Later**,
  each with its date and time in bold, a repeat icon, a bell or alarm, and the Do on day when it differs.
- Tick to complete, tick again to reopen, swipe to delete (with **Undo** on the toast for a few seconds).
- Tasks you just added here show at once as "Just added" until your Mac lists them.

### Siri, Action Button and Shortcuts

- **Record:** "Record in Docket", "Start a debrief in Docket", "Record a debrief in Docket", "Start recording
  in Docket". The app opens already recording.
- **Schedule:** "Schedule a task in Docket", "Add a task in Docket", "Add a task to Docket", "Schedule in
  Docket", "New task in Docket". Siri asks "What's the task, and when?", adds it without opening the app, and
  says back what it added: "Added Call Rohan for Fri 16 Oct at 3:00 PM."
- **Action Button** (iPhone 15 Pro and later): Settings → Action Button → Shortcut → Docket → Record a debrief.
- **Shortcuts and Spotlight:** "Record a debrief" and "Add a task".
- **URL:** `docket://record` (or `docket://debrief`).

### Offline

- Captures and tasks are saved on the phone first and go out when the Docket folder is reachable.
- A debrief recorded offline: "Saved. Will turn into tasks when you're back online." It goes to Gemini when
  the network is back; after 30 minutes without success it goes to your Mac as is, and the Mac makes the tasks.
- A dictated task offline waits the same way; after 30 minutes it's added as said, with the date and time
  the phone could read.
- Memory, Topics, Map and Today show the last snapshot the Mac published.

### Sync

- Through a **Docket** folder in your iCloud Drive that the Mac and the phone share. Nothing else.
- The phone checks for a new snapshot every 15 seconds while open, on pull-to-refresh, and whenever the app
  comes to the front.
- The phone only writes captures; your Mac does the thinking (summaries, topics, pages, the map) and the
  phone shows the result.

### Privacy

- No account and no server. Everything moves through your own iCloud Drive.
- AI is opt-in. Your Gemini key is stored in this iPhone's Keychain (this device only) and never written to
  files or logs.
- With a key: Ask sends your question and the few memories that match it; search sends the query to search
  by meaning; a debrief sends the recording (with your list names and the names in your memory); a dictated
  task sends your words. A recording too big to send inline is uploaded to Gemini's Files API and deleted
  once Gemini has answered. Without a key, nothing leaves the phone except to your iCloud Drive.
- The microphone is on only while you record or dictate. The camera and photo library are used only when
  you pick a photo.

### Settings (the gear on every tab)

- **Docket folder:** choose or change it, and see its state ("Waiting for the first update from your Mac",
  when it last updated).
- **Gemini key:** paste, save or remove; a link to get a free key.
- **Voice:** the speech language for the live transcript (device default, English (India), Hindi,
  English (US), English (UK), Spanish, French, German, Portuguese (Brazil), Japanese), and how to record
  from anywhere.
- **Lenses:** shown here, changed on your Mac.
- **About:** the version.

## How it works with the Mac

```
iCloud Drive/Docket/
  Inbox/     the phone writes here: <id>.capture.json (+ "<id>--<file name>" for an attachment)
  Library/   the Mac writes here: snapshot.json, vectors.bin, Thumbs/<item id>.jpg
```

1. **On your Mac:** Settings → Memory → iPhone → turn on **Sync with iPhone**. That creates the folder and
   starts publishing.
2. **On the phone:** the gear → **Choose folder** → iCloud Drive → **Docket**. The app keeps a
   security-scoped bookmark, so it asks only once.

- **Phone → Mac.** Captures are saved first to the app's own `Documents/Pending` folder, then written into
  `Inbox/`. Notes, links, photos, videos and files become memories on the Mac. A task carries everything that
  was scheduled (`task`) and becomes a Mac task with the same id. Ticking writes `taskDone`, unticking
  `taskUndone`, deleting `taskDelete`. A voice capture carries the audio, the on-device transcript and the
  debrief (or none, and the Mac makes one).
- **Mac → phone.** About ten seconds after anything changes, the Mac publishes the library, profile, lenses,
  list names, the brain (topics, pages and the map, capped in size), the search index, thumbnails, and the
  tasks for Today: open ones overdue, due or planned from today to 7 days out, recent ones from voice notes,
  dictation and the phone, and today's finished ones.
- A ticked task stays ticked on the phone until a newer snapshot confirms it. A swiped task is hidden at
  once and the `taskDelete` goes out after the Undo window.
- The phone never writes to `Library/`. Reads and writes go through `NSFileCoordinator`, and files still
  only in iCloud are downloaded on demand. A missing or half-synced snapshot shows as "waiting" or
  "downloading" and is read again on the next pass.

## Put it on your iPhone

Docket for iPhone isn't on the App Store; you build it onto your phone with Xcode (on a Mac).

1. Open `iOS/DocketPhone.xcodeproj` in Xcode 26.
2. Select the **DocketPhone** target → **Signing & Capabilities**, tick **Automatically manage signing**,
   and choose **your own** team. The project ships with no team set.
3. If the bundle id `com.docketapp.DocketPhone` is taken, change it to something of your own
   (`com.yourname.DocketPhone`).
4. Connect your iPhone, turn on Developer Mode when iOS asks (Settings → Privacy & Security → Developer
   Mode), pick the phone as the run destination and press Run. The first time, trust the developer on the
   phone if asked (Settings → General → VPN & Device Management).
5. Then set up sync (above) and paste your Gemini key in Settings.

**Signing, the honest version:**

- Always sign with your own Apple ID or your own organisation's team. Never use a certificate or
  provisioning profile that belongs to someone else, even if it happens to be on your Mac.
- **A free Apple ID works.** Xcode adds it as a "Personal Team". Apps signed that way stop opening after
  7 days; run it from Xcode again to renew.
- **A paid Apple Developer Program membership** removes the 7-day limit and lets you ship the app to
  others through TestFlight.
- No special capabilities are needed: the Docket folder is picked through the Files picker, so there's no
  iCloud entitlement to set up.

## Build and run in the simulator

Open `iOS/DocketPhone.xcodeproj` in Xcode 26 and run the `DocketPhone` scheme on any iPhone simulator.
Sources in `iOS/DocketPhone/` are a file-system synchronized group, so a new `.swift` file is picked up
without editing the project.

From the command line (no signing needed):

```sh
xcodebuild -project iOS/DocketPhone.xcodeproj -scheme DocketPhone \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO build
```

To try real sync in the simulator, sign in to iCloud in the simulator's Settings and pick the Docket folder;
for a quick look, use demo mode below.

### Demo mode (screenshots)

Set these environment variables in the scheme (`DOCKET_PHONE_DEMO` and `DOCKET_PHONE_TAB` are there,
switched off) or with `SIMCTL_CHILD_…` and `xcrun simctl launch`:

| Variable | Effect |
| --- | --- |
| `DOCKET_PHONE_DEMO=1` | Seeds a throwaway Docket folder in the temp directory with sample memories, tasks and recent captures. Your real folder, Keychain and the network are never touched. |
| `DOCKET_PHONE_TAB=capture\|record\|debrief\|dictate\|dictated\|composer\|memory\|topics\|map\|ask\|today\|settings` | The tab to start on (`settings` opens the Settings sheet). `record` shows a recording in progress with a live transcript; `debrief` a finished result card (Hindi/English, 3 tasks); `dictate` listening for a task; `dictated` its result card; `composer` the composer with every field filled. |
| `DOCKET_PHONE_ITEM=first\|<index>\|<words>` | Opens that memory (the first one, by index, or by words in its title). |
| `DOCKET_PHONE_ENTITY=<name>` | Opens that topic's, person's or project's page ("Seed round", "Maya Chen"). |
| `DOCKET_PHONE_SEARCH=<words>` | Starts Memory → Library with that search. |
| `DOCKET_PHONE_MAP_FOCUS=<name>`, `…_MAP_SELECT=<name>`, `…_MAP_DAYS=<n>`, `…_MAP_ZOOM=<x>` | The map opens focused on a node, with a node's card open, with the time slider n days back, or zoomed in. |
| `DOCKET_PHONE_MAP_NODES=<n>`, `DOCKET_PHONE_MAP_TIMING=1` | Stress test: pads the map with made-up nodes up to n; logs each map draw's time. |

In demo mode the Ask tab starts with a ready-made answer, and further questions get canned replies. The demo
library comes with an organised brain (`MemoryBrain.debugSeed`): areas, topics, pages, a disagreement,
connections, this week's digest and the map.

## Limitations

- Needs the Mac. The phone doesn't summarise, organise or index memories itself; until a Mac publishes to
  the folder, Memory, Topics, Map and Today are empty (captures wait and sync later).
- Read-only brain and memory: renaming, merging, moving topics, editing memories and changing lenses happen
  on the Mac (the phone says so in one quiet line).
- Today shows the Mac's tasks from overdue to the next 7 days (and later ones you just added). You can
  tick, untick and delete them, but editing an existing task's details happens on the Mac.
- Reminders and alarms ring on the Mac; the phone doesn't schedule notifications.
- No Slack or Gmail on the phone, no Docket notes editor (a text capture becomes a memory), no share
  extension and no widgets yet.
- iPhone only (no iPad layout), iOS 17 or later. Not on the App Store or TestFlight; you build it yourself.

## How voice works, in detail

**Recording.** AAC in an ADTS stream (`.aac`, 16 kHz mono, about 32 kbps, so roughly 15 MB an hour),
written to `Documents/Voice/` as you speak, so even a crash keeps everything up to the last second. It
keeps going with the screen locked (background audio).

**Live transcript.** On-device speech recognition in the Speech language from Settings. It's only a hint:
Gemini writes the real transcript from the audio, in whatever language was spoken.

**Debrief.** With a Gemini key, the phone sends the recording to Gemini (`audio/aac`; inline up to 14 MB,
through the Files API above that) along with your lists and the names in your memory, and gets back the
transcript, a summary, people, decisions, promises others made, and your tasks with absolute dates. The
capture is held while the result card is open (and for 20 seconds after it first shows), so edits are
free; then it's written to the Docket folder with the audio, the on-device transcript and the debrief, and
the Mac creates the tasks with the same ids. Removing a task after that sends a `taskDelete`. Gemini errors
show as a sentence; the recording is never lost (it goes to the Mac instead).

**Spoken tasks.** With a key, `SpokenTaskParser` reads the words (with your lists and the names in your
memory) in one Gemini call; Siri waits up to 8 seconds for it, then falls back to the phone's own reading. A
task that hasn't left the phone yet is just dropped when you remove it; otherwise a `taskDelete` goes to the
Mac (and an edit is a `taskDelete` plus a new task). Without a key, the phone reads the date and time,
"for N minutes" and "remind me N minutes before" itself (`NSDataDetector`); when no date was found, the
Mac's quick-add parsing has a go when the task arrives.

## Layout

```
DocketPhone/
  App/        app entry, tab bar, toast, settings button; App Intents (Siri, Action Button,
              Shortcuts) and the docket:// URL
  Model/      AppModel (folder, snapshot, search, captures, tasks), capture queue,
              folder bookmark + iCloud file access, Ask session, voice recorder, live
              transcript, dictation + read aloud, VoiceCenter (debrief, hold, retry),
              SpokenTaskCenter + TaskTextParser (schedule by voice), demo seed,
              BrainSupport (routes, reading the brain snapshot, area colours)
  Views/      Capture, recording screen + result card, spoken-task card, task composer,
              Memory (Library, Topics, Map), entity pages, item detail, Ask, Today, Settings
  Support/    Theme (mirrors the Mac's ink-and-paper tokens), date formatting, Keychain
DocketPhone-Info.plist   background audio and the docket:// scheme (merged with generated keys)
```
