# Docket privacy policy

_Last updated: Sat 10 Oct 2026_

Docket (the Mac app and the iPhone app) is built so that your tasks, notes, messages and memories stay yours.
Docket has no accounts and no servers, and collects no analytics. The people who make Docket do not receive your
data.

## What stays on your devices

- **Tasks, notes and memories** are stored in files on your Mac (`~/Library/Application Support/Docket`).
- **The iPhone app** keeps its captures in its own storage until they reach your Mac.
- **Keys and sign-ins:**
  - On the Mac: your Gemini key and your Slack and Gmail sign-ins are kept in a file only your Mac user account can read.
  - On the iPhone: your Gemini key is kept in the iPhone's Keychain, on that device only.

## What leaves your devices, and only when you turn it on

- **Google Gemini (AI).** Docket sends content to Google's Gemini API only if you add your own Gemini key. It sends
  only what's needed for the feature you use:
  - **Summaries and organising:** the text of the item being summarised or organised, and its attached file (an
    image, PDF or audio recording).
  - **Ask:** your question, plus the few memories that match it.
  - **Voice:** the recording of a voice note, or the words of a dictated task.

  Google handles this content under its own terms for the Gemini API. Without a key, nothing is sent to Google.
- **Slack and Gmail (Mac only).** If you connect them, Docket reads your messages directly from Slack and Google
  to show them in Docket. Replies are sent only when you confirm them. No copy goes anywhere else.
- **iCloud Drive (iPhone sync).** If you turn on iPhone sync, Docket uses a "Docket" folder in your own iCloud Drive
  to pass captures from your iPhone to your Mac, and a snapshot of your memory and tasks from your Mac to your
  iPhone. That folder is stored by Apple under your Apple Account, like any other iCloud Drive file.
- **Apple speech recognition.** While you speak, Docket shows your words live using Apple's speech recognition. It
  runs on the device when your language supports that; otherwise Apple processes the audio under Apple's privacy
  policy. Siri requests (for example "Schedule a task in Docket") are handled by Apple in the same way.

## What we don't do

- No analytics, advertising, tracking or data selling.
- No account, and no server of our own that your data passes through.

## TestFlight

If you test Docket through TestFlight, Apple may share crash reports and any feedback you choose to send with the
developer, under Apple's TestFlight terms. You can turn this off in the TestFlight app.

## Deleting your data

- **On the Mac:** delete the Docket app and the folder `~/Library/Application Support/Docket`.
- **On the iPhone:** delete the app.
- **iPhone sync:** delete the Docket folder in iCloud Drive.
- **Gemini:** remove your Gemini key in Settings → AI, or revoke it in Google AI Studio.

## Contact

Questions about privacy: open an issue at https://github.com/utkarshiam/Super-focused-mac-mode/issues.
