# TethrX Privacy Policy

*Last updated: July 21, 2026*

TethrX is an iPhone and iPad app that remotely controls Grok Build running on your own computer, through a bridge program you install and run yourself. It is designed so that we cannot see your data, because there is no server of ours in the middle.

## What we collect

**Nothing.** TethrX has no accounts, no analytics, no tracking, and no third-party SDKs. The app developer operates no server that your data passes through.

## Where your data lives

- **Your conversations, files, code, and commands** exist only on your own computer and on your phone while you view them. They travel directly between the two over your own network (local Wi-Fi, a personal hotspot, or your own VPN such as Tailscale), encrypted with HTTPS pinned to a certificate generated on your computer.
- **Your pairing token** is stored in your phone's Keychain and on your computer. It is never sent anywhere else. It is shared with the TethrX share extension through a private Keychain group that only TethrX and its own extensions can read.
- **Attached images** you send are saved to your own computer so Grok can view them, and nowhere else.
- **Anything you share into TethrX** from another app (a link, some text, a screenshot) goes only to your own computer, and only when you tap Send.
- **Usage counts** (tokens, cost, and how many turns you ran each day) are totals kept on your own computer. They contain no prompts, file names, or other content.
- **Settings and session metadata** are stored on your phone and your computer.

## Push notifications

If you enable notifications, your bridge (on your own computer) sends them to your phone through the Apple Push Notification service. The notification content — for example, that a task finished or needs approval — passes through Apple's infrastructure as required by iOS, and through nothing of ours.

## Grok Build

TethrX drives Grok Build, xAI's coding agent, which you install and sign in to on your own computer. Your use of Grok Build is governed by xAI's own terms and privacy policy. TethrX never sees or stores your xAI credentials.

## Apple

Apple provides the developer with aggregate, anonymized statistics for App Store and TestFlight distribution (such as install counts and crash reports) under Apple's own privacy terms.

## Permissions the app asks for

- **Camera** — only to scan the pairing QR code.
- **Microphone and speech recognition** — only for voice dictation of messages, processed on the phone.
- **Local network** — to find and talk to your own computer.
- **Face ID** — only to lock the app, if you turn that on.
- **Photo library** — only the images you explicitly pick to attach.
- **Notifications** — optional; needed to alert you and to let you reply from the notification.

Each of these is optional and used only for its stated purpose.

## Changes and contact

If this policy changes, the update will appear in this file with a new date. Questions: open an issue at https://github.com/Myrhex-x/TethrX/issues.
