# Mailbar

A lightweight macOS menu-bar mail and calendar client for on-premises Microsoft Exchange, over EWS.

Mailbar shows your inbox unread count in the menu bar and opens a popover with the Inbox, laid out
like Outlook's message list, and a Today tab with the day's calendar. Its calendar opens in its own window. It
exists so you can stop keeping a 2 GB mail client open all day.

> **Status: built and in daily use.** Everything below is in place and tested against mock data.
> Scope and decisions live in [AGENTS.md](AGENTS.md).

## Mail

- **Menu bar unread count**, updated the moment mail arrives (EWS streaming notifications), with a
  slow poll as a safety net.
- **Outlook-style rows**: sender (bold while unread), subject with relative time (`14:32`,
  `Yesterday`, `2 days ago`, then a short date), one line of preview.
- **Safe reader**: HTML bodies render with JavaScript off and remote images blocked until you click
  "Load images". Wide newsletters and large images are fitted to the window.
- **Actions**: mark read or unread, flag, archive, delete (to Deleted Items only).
- **Simple sending**: reply, reply all, forward and new messages, in plain text. Your server adds
  the quoted original and keeps a copy in Sent Items.
- **Search** the whole inbox on the server (Cmd+F), **attachments** to open or save, and
  **new-mail notifications**.
- **Right-to-left text** handled per paragraph, so Persian and mixed-direction mail reads correctly.

## Calendar

- **Day, Week and Month**, laid out like Outlook on the web, the week starting Saturday; opened
  from the menu bar icon's right-click menu, or Cmd+K in the popover.
- Swipe between weeks the way Apple's Calendar does; events in their Outlook category colours; a
  narrow window switches to Day.
- **Create, edit and delete events**: drag on the grid to draw one, then a form after Outlook's,
  with rooms found by typing in Location, people (suggested from your company directory, with
  photos and free or busy), repeat (Daily, Weekly, Monthly or custom, until a date or a count),
  reminder, show as, category, charm, private, files, and response options. A **Scheduling
  Assistant** shows everyone's busy times for the day and finds the next free slot.
  **Answer invitations** from the calendar or the invitation email.
- **Today tab**: swipe sideways to go through the days.
- **Reminders**: one notification at each event's reminder time.
- **Today in the popover**: an Inbox | Today switch; Today shows the day as a one-day calendar, with
  Join buttons for Teams, Zoom, Meet and Webex.

## General

- **Multiple accounts.** Adding one needs only your email and password: Autodiscover finds the
  server. Nothing about any server is built into the app.
- **Honest failure states**: "server unreachable" (are you on the VPN?), "password rejected" and
  "empty inbox" are different screens, never a silent zero.
- Launch at login. Menu bar only, except while the calendar window is open.

### Deliberately not included

No folder list or "move to folder". No follow up, categories, rules or drafts. No rich-text
formatting, signatures or outgoing attachments. No contacts. No offline mode.

## Privacy

- **Nothing from your mailbox is written to disk.** No database, no file cache, no URL cache, no
  WebKit cache. List data and the calendar live in memory and die with the process; a message body
  lives only while its reader is open. Images are never cached anywhere. The one exception is an
  attachment you choose to open, which waits in a private temporary folder until Mailbar quits.
  macOS itself keeps the notifications it shows; turn notifications off to keep mail and event
  details out of Notification Center.
- **Passwords live only in the Keychain**, one item per account. Never in UserDefaults, never logged.
- **No telemetry, no analytics.** The only network traffic is to each account's EWS URL, the
  Autodiscover lookup when you add an account, and a message's remote images when you ask for them.
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

Mailbar runs as a menu-bar app. Open Settings from the popover, choose Add Account, enter your
email and password, and press Sign In; Autodiscover fills in the server, and you can still type it
by hand.

### Trying it without an account

```bash
MAILBAR_MOCK=1 open <path to Mailbar.app>
```

Mock mode serves canned EWS responses with invented senders and a sample calendar, including
Persian and mixed-direction text, so the whole UI can be exercised offline. Nothing is sent.

## How it talks to Exchange

Plain SOAP 1.1 over `URLSession`, parsed with Foundation's `XMLParser`. No EWS SDK and no third-party
packages; Apple frameworks only.

| What | EWS operation |
|---|---|
| Find the server | Autodiscover (POX, HTTPS only) |
| Verify account, unread count | `GetFolder` on `inbox` |
| Inbox list, search | `FindItem`, 50 newest; `QueryString` for search |
| New mail at once | `Subscribe` + `GetStreamingEvents` |
| Open a message, attachments | `GetItem`, `GetAttachment` |
| Read state, flag | `UpdateItem` (read receipts suppressed) |
| Delete, archive | `DeleteItem` (`MoveToDeletedItems`), `MoveItem` |
| Reply, forward, send | `ReplyToItem`, `ReplyAllToItem`, `ForwardItem`, `CreateItem` |
| Calendar | `FindItem` with `CalendarView`, `GetItem`, `CreateItem`, `UpdateItem`, `DeleteItem` |
| Answer invitations | `AcceptItem`, `TentativelyAcceptItem`, `DeclineItem` |
| People and rooms | `ResolveNames`, `GetRoomLists`, `GetRooms`, `GetUserPhoto` |
| Free or busy, the event form's Schedule view | `GetUserAvailability` |
| Files on events | `CreateAttachment`, `DeleteAttachment` |
| Category colours | `GetUserConfiguration` (`CategoryList`) |

## Project layout

```
project.yml      XcodeGen spec (source of truth; the .xcodeproj is generated)
Mailbar/
  App/           AppDelegate, status item, popover
  Accounts/      Account model, account store, Keychain passwords, Keychain login offer
  EWS/           EWS client, SOAP builders, XML decoding, Autodiscover, calendar requests, mock mode
  Core/          Mail and calendar stores, poller, streamer, notifications, reminders, drafts
  Views/         Inbox rows, reader, composer, Settings
  Views/Calendar/  Calendar window: week and month grids, pager, event form, detail panel
MailbarTests/    SOAP fixtures and request shapes, stores against the mock server, layout rules
```

[AGENTS.md](AGENTS.md) holds the full spec and design decisions; [CHANGELOG.md](CHANGELOG.md)
tracks user-visible changes.
