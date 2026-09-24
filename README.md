# Mailbar

A lightweight macOS menu-bar mail reader for on-premises Microsoft Exchange, over EWS.

Mailbar shows your inbox unread count in the menu bar and opens a popover with one list, the Inbox,
laid out like Outlook's message list. Open a message, mark it read or unread, flag it, archive it or
delete it. Nothing else. It exists so you can stop keeping a 2 GB mail client open all day just to
glance at your inbox.

> **Status: v1 built.** Accounts (email and password, the rest found by Autodiscover), the menu
> bar unread count, the inbox list, the reader and the actions are in place, tested against mock
> data. Scope and decisions live in [AGENTS.md](AGENTS.md).

## Features (v1)

- **Menu bar unread count**, refreshed by polling every couple of minutes, whenever the
  popover opens, and once after the Mac wakes.
- **Outlook-style rows**: sender (bold while unread), subject with relative time (`14:32`,
  `Yesterday`, `2 days ago`, then a short date), one line of preview.
- **Safe reader**: HTML bodies render in a `WKWebView` with JavaScript off and remote images blocked
  until you click "Load images" for that message.
- **Four actions**: mark read or unread, flag or unflag, archive, delete (to Deleted Items only,
  never a hard delete).
- **Right-to-left text** handled per string, so Persian, Arabic and mixed-direction mail reads
  correctly.
- **Multiple accounts**, each added in Settings. Nothing about any server is built into the app.
- **Honest failure states**: "server unreachable" (are you on the VPN?), "password rejected" and
  "empty inbox" are three different screens, never a silent zero.

### Deliberately not included

Read only. No compose, reply, forward or drafts. No folder list or "move to folder". No calendar,
contacts or directory lookup. No offline mode.

## Privacy

- **Nothing from your mailbox is written to disk.** No database, no file cache, no URL cache, no
  WebKit cache. List data lives in memory and dies with the process; a message body lives only while
  its reader is open. Images are never cached anywhere.
- **Passwords live only in the Keychain**, one item per account. Never in UserDefaults, never logged.
- **No telemetry, no analytics.** The only network traffic is to each account's EWS URL, plus a
  message's remote images when you explicitly ask for them.
- **Normal TLS trust only.** A bad server certificate is shown as an error; there is no "accept
  anyway".

## Requirements

- macOS 14 or later (Liquid Glass on macOS 26)
- An on-premises Exchange mailbox reachable over EWS (Exchange 2013 or later preferred) with user
  name and password authentication (NTLM or Basic over HTTPS)
- To build: Xcode 16+ (Swift 6) and [XcodeGen](https://github.com/yonaskolb/XcodeGen)

Exchange Online (Microsoft 365) is not the target; it uses Graph and OAuth instead of EWS passwords.

## Build and run

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project Mailbar.xcodeproj -scheme Mailbar build
```

Quit any running copy before opening a freshly built bundle, since replacing it under a running
process invalidates its code signature.

Mailbar runs as a menu-bar app with no Dock icon. Open Settings from the popover, add an account
(email, EWS URL such as `https://mail.example.com/ews/exchange.asmx`, user name, password), and press
Test to see the unread count.

### Trying it without an account

```bash
MAILBAR_MOCK=1 open <path to Mailbar.app>
```

Mock mode serves canned EWS responses with invented senders, including Persian and mixed-direction
messages, so the whole UI can be exercised offline.

## How it talks to Exchange

Plain SOAP 1.1 over `URLSession`, parsed with Foundation's `XMLParser`. No EWS SDK and no third-party
packages; Apple frameworks only.

| What | EWS operation |
|---|---|
| Verify account, unread count | `GetFolder` on `inbox` |
| Inbox list | `FindItem`, 50 newest by `DateTimeReceived` |
| Changes since last poll | `SyncFolderItems` |
| Open a message | `GetItem`, HTML body |
| Read state, flag | `UpdateItem` (read receipts suppressed) |
| Delete | `DeleteItem` with `MoveToDeletedItems` |
| Archive | `MoveItem` to the mailbox's Archive folder |

## Project layout

```
project.yml      XcodeGen spec (source of truth; the .xcodeproj is generated)
Mailbar/
  App/           AppDelegate, status item, popover
  Accounts/      Account model, account store, Keychain passwords
  EWS/           EWS client, SOAP builders, XML decoding, mock mode
  Core/          Mail store, poller, relative time, text direction
  Views/         Inbox rows, reader, Settings
MailbarTests/    SOAP fixtures, relative time, account store
```

[AGENTS.md](AGENTS.md) holds the full spec and design decisions; [CHANGELOG.md](CHANGELOG.md)
tracks user-visible changes.
