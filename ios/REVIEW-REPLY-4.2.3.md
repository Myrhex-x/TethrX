# Reply to App Review — Guideline 4.2.3(i)

Submission `f6888598-bcb8-4cb1-869d-a23c19fcb695` · v1.0 (2) · reviewed 2026-08-05

Paste the text below into the App Store Connect message thread, then submit the
new build. Send the reply and the build together, so the reviewer opens the
version that has the fix.

---

Thank you for the review, and for the detail about what you ran into.

We have submitted a new build that reworks the first-run experience, and we would
also like to clarify one point about the requirement you encountered.

**Nothing needs to be installed from the App Store, or on the iPhone.** Grok Build
is not an iOS app. It is xAI's command-line coding agent for a desktop computer,
run in a terminal on a Mac or PC that the user already owns. TethrX is a remote
control for that computer, in the same way an SSH client is a remote control for a
server. The previous build's setup wizard described installing it *on the user's
computer*, which we can see read as a requirement to install another app on the
device. That wording, and its position as the first screen, was our mistake.

**What we changed in this build:**

1. **The app now opens on a working screen, not a setup checklist.** The launch
   screen is a usable workspace, and nothing on it asks the user to install
   anything.

2. **A prompt library that works entirely on the device.** From the moment the app
   is opened, with no computer, no pairing and no network, the user can write,
   dictate, edit, search, organise, copy and share reusable coding-task prompts.
   These are stored on the phone and are a permanent part of the app: they also
   appear above the message field in every session once a computer is connected.

3. **A full guided tour is now the primary button on the launch screen.** It opens
   the entire app - session list, conversation, tool approvals, file diffs,
   settings - populated with sample data and no hardware of any kind. In the
   previous build this existed only as a small text link below the setup steps,
   which is why it was easy to miss.

4. **Connecting a computer is now an optional, clearly-labelled secondary action.**
   It opens a separate screen that states up front: "These steps all happen on the
   computer you want to control. Nothing extra is needed on this phone."

**To verify without any hardware:**

- Launch the app. The first screen is the prompt workspace. Type a task into the
  "write a task…" field and tap **+** - it is saved on the device and persists
  across relaunches. Tap **Write a longer prompt** for the full editor, including
  dictation.
- Tap **Take the tour** to walk through the complete app with sample data.

Neither step requires Grok Build, a computer, a network connection, or any account.

**If you would like to test the connected experience,** the companion program is
open source and starts on any Mac with Node 20+ using a single command,
`npx tethrx-bridge`. It prints a QR code that the app scans to pair. It is
published at https://github.com/Myrhex-x/TethrX and on npm as `tethrx-bridge`. We
are glad to provide a screen recording of the full flow if that is more convenient.

Thank you again for your time.
