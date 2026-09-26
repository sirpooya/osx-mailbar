# AGENTS.md: Mailbar (macOS menu-bar mail reader for on-prem Exchange)

## Goal
A lightweight menu-bar mail reader for my work mailbox, which lives on an on-premises Microsoft
Exchange server reached over EWS. It shows the inbox unread count in the menu bar and one list, the
Inbox, in a popover, styled like Outlook's message list. I can open a message, and mark it read or
unread, flag it, archive it or delete it. Nothing else.

It replaces keeping `/Applications/Microsoft Outlook.app` (about 2 GB, always running) open all day,
so the user can delete Outlook.

Reading, plus simple sending (reply, reply all, forward, a new message; M12 to M14). No calendar
(M15 to M19), no contacts.
The Scope section below holds the exact in-scope and out-of-scope lists; it wins over anything
vaguer here.

## Scope
v1 (M0 to M6), v1.1 (M7 to M11) and simple sending (M12 to M14) are built, 2026-09-25, all proven
in mock mode. The Milestones section below is the record; none is open.

### Wanted (v1, built)
- **Accounts in Settings**: add, edit, test, delete; several allowed. Adding needs only email and
  password (Autodiscover finds the rest); every field stays editable. Nothing prefilled from
  anywhere but the user's own server.
- **Menu bar**: the user's icon plus the total inbox unread count.
- **One view, the Inbox.** No other folders. One view per account when there are several.
- **Outlook-style rows**: sender (bold while unread), subject with the relative time on the right
  (`14:32`, `Yesterday`, `2 days ago`, then a short date), one line of preview.
- **Read a message** in the popover: HTML rendered safely, no JavaScript, remote images off until
  "Load images". Opening marks it read.
- **Actions**: mark read or unread, flag or unflag, archive, delete (to Deleted Items).
- **Right-to-left** handled per string, for Persian mail.
- **Honest failure states**: unreachable, password rejected and empty inbox are different screens.
- **No cache**: nothing from the mailbox on disk, images cached nowhere.

### Not wanted (do not build)
- Anything beyond simple sending: rich-text editing, drafts, signatures, outgoing mail
  attachments. (Files on calendar EVENTS are in, since 2026-09-25, the user's request.)
- Move to folder, folder list, folder picker.
- Follow up, categories, rules, junk, snooze, pin.
- Contacts, tasks, notes, an LDAP client. (People suggestions for events use the server's own
  directory search, EWS `ResolveNames`, since M16; that is not LDAP. The optional people
  directory endpoint below is a read-only JSON list for pickers and photos, not a contacts store.)
- Offline mode, local search index, any disk cache.

### Wanted (v1.1, built 2026-09-24, milestones M7 to M11)
- **New-mail notifications** (M7): click one to open that message. Sender, subject and preview
  always (the "Show sender and subject" switch was removed 2026-09-25, the user's call).
- **Search** (M8): a field under the header (Cmd+F), searching the server as you type.
- **Attachments** (M9): chips under the reader's header; click for Quick Look, right-click to save.
- **Launch at login** (M10): a switch in Settings, General.

- **Instant new mail** (M11): EWS streaming notifications; polling drops to a 10-minute safety net.

### Simple sending (M12 to M14, built 2026-09-25)
- Reply, reply all, forward, new message. Plain text writing, right to left for Persian. The
  server builds quotes and keeps copies in Sent Items (EWS `ReplyToItem`, `ForwardItem`,
  `CreateItem` with `SendAndSaveCopy`).
- Not in it: rich text, drafts folder, signatures editor, outgoing attachments.

### Groups and the people directory (built 2026-09-25, the user's request)
- **Distribution groups**: `ResolveNames` reports a group as `MailboxType` `PublicDL` or
  `PrivateDL`; the event form's People and the composer's To and Cc mark it as a group with
  Expand, which swaps it in place for its members (EWS `ExpandDL`, one level; a nested group
  stays a group, to expand in turn). Typed addresses are checked with `ResolveNames` once each,
  in memory (`MailStore.knownGroups`). Unexpanded, a group is invited or mailed as itself.
- **People directory** (Settings, People directory): an optional https address returning a JSON
  list of people. Parsed generically (`DirectoryJSON`): `items`, `users`, `people`, `data` or a
  bare array; name; the work address from `workEmail`, `email`, or any field ending in "email";
  team; department; role; avatar (relative paths resolve against the endpoint). Departed people
  are dropped. It adds an "Add a team or department" picker (department, team and role popups,
  each narrowed by the ones before it; each person ticked, `DirectoryPicker`; the department
  popup was removed once and brought back the same day, because a team named like a department
  held only 3 of its 38 people and hid its engineers) beside People and on To and Cc, and puts its people with their team and
  department in the type-ahead. Roles appear ONLY in that
  filter and the picker's rows, never in an invitee's or a suggestion's subtitle (the user's
  call, 2026-09-25). Its photo wins over `GetUserPhoto` for any address it lists.
  Photos load only from the endpoint's own host; a file named `default` is the placeholder, not
  a face. **The URL is never in code** (public repo): the user types it; the real one is in
  `AGENTS.local.md`. **Unproven on the real server**: `ExpandDL` on a real group.

### Calendar (M15 to M19, built 2026-09-25)
- View, create, edit, delete, answer invitations, reminders, a Today tab in the popover, over the same
  EWS server. The four open choices were taken at these defaults when the user said "build it
  now"; any can still change:
  1. Its own resizable window from the tray menu, or Cmd+K in the popover, not a popover tab.
  2. People suggestions from the server's directory search (`ResolveNames`) plus inbox senders.
  3. A room picker from the organization's room lists, free-text location always possible.
  4. A Scheduling Assistant after all (the user's request, 2026-09-25, reversing the early "no"):
     `SchedulingAssistant`, shown as **Schedule**, the second view of the event form beside
     Event (an "Event | Schedule" switch in the title bar, as Outlook for Mac has it), never a
     sheet over the form: a sheet on a sheet was the user's objection. Same window size in both,
     the People sidebar giving way to the grid; the form's Cancel and Send serve both, so there
     is no Done, and the legend sits in the bottom bar's left. Event's toolbar (Attach, Charm, Categorize, Show as, Reminder, Private) shows in Event only; in Schedule its row holds "‹ Next free time ›" alone, at the toolbar's 13 pt, borderless. That row is one height in both (`EventEditorView.toolbarRowHeight`, 24 pt), so switching moves nothing under it. Rows for you, the invitees and
     rooms with their busy blocks from `GetUserAvailability` for the day, the meeting as a band,
     a click moves it, and it drags with the hand (open, then closed while held) or resizes from either edge (the resize cursor), in 15-minute steps within the day, never shorter than 15 minutes. The grid is one strip of days (`ScheduleTimeline`, 28 days from a week before the meeting, fetched in one request): only the work days, each only its work hours (Settings, Work time), side by side with a darker line at each day's start and its name above, so a swipe runs straight into the next working day with no evening or weekend between (the user's call, after Outlook's "Show work hours only"). The meeting's own day always shows, stretched to take it in. While a drag is under way the strip is held as it was, since a strip that changed under the hand made the band slip (the user's recording), and the drag is measured in the grid's coordinate space, not the band's; the band crosses from one day to the next. The row under the switch holds only "‹ Next free time ›" on the right, no icon (the user's call): the words and the right chevron find the next free half hour, on through later days, the left chevron the one before; no date or day arrows, since the strip names each day over its hours; Next free time finds the first open slot. Dense, after Outlook's (the user's call): 24 pt rows under Attendees and Rooms bands, thin hour and half-hour lines, and busy blocks and legend drawn with the Show as menu's own swatches (`ShowAsSwatch`: dotted, hatched, blue, purple), never colours of their own. Charm and Categorize were left out at first (crossed off in an
     early screenshot) and added 2026-09-25 when the user asked for them.
- No calendar library: checked 2026-09-25. KVKCalendar is UIKit and reaches the Mac only through
  Catalyst; swift-week-view and CalendarKit are iOS; GECalendar and Mijick's CalendarView are date
  pickers, not event timelines. The grid is SwiftUI.
- Work time is set in Settings, Calendar (the user's request, 2026-09-26, after Outlook's): the
  work week as seven day toggles, Work hours as one row, "09:00 to 17:00" (whole hours), and the time zone, the
  Mac's or one Exchange can be told (`WindowsTimeZone`), applied app-wide through
  `NSTimeZone.default` (`Keys.applyTimeZone`), so every time shown and every event written follows
  it. Not read from the server.

### Still open (the user's steps)
- Add the real account and press Sign In. This settles the user name format and the Exchange
  version, both unproven; record them here.
- Any action against real mail, on a message the user names.
- Uninstall Outlook.

Keep it minimal and dependency-light. No cloud sync, no analytics.

## Milestones
All done, 2026-09-24 and 25, every one proven in `MAILBAR_MOCK` mode (screenshots, tests). The
real-account column is what is still unproven. There is no `PLAN.md`: every milestone is done.
New work gets a plan and moves here once it lands.

| # | What | Unproven on the real account |
|---|---|---|
| M0 | Scaffold: XcodeGen, menu bar only, signed | |
| M1 | Accounts, Keychain passwords, EWS client, Settings; later email+password sign-in via Autodiscover | |
| M2 | Menu bar icon and unread count, polling | |
| M3 | Outlook-style inbox rows, right to left for Persian, failure states | |
| M4 | Reader: JS off, remote images blocked (pixel-proven), inline images from memory, fit to width | |
| M5 | Mark read or unread, flag, archive (asks before creating the folder), delete | actions on real mail |
| M6 | Sign-off: nothing on disk, idle memory 54 MB | one-hour memory |
| M7 | New-mail notifications, withdrawn when handled | a real banner |
| M8 | Server-side search, Cmd+F | |
| M9 | Attachments: Quick Look (private temp copy, deleted when the panel closes) or save | previewing a real one |
| M10 | Launch at login | toggling it |
| M11 | Instant mail over EWS streaming, 10-minute poll as backup | a real arrival |
| M12 | Reply and reply all | a real send |
| M13 | Forward | a real send |
| M14 | New message, suggestions from inbox senders | a real send |
| M15 | Calendar window: Day, Week, Month, swipe paging, category colours, detail panel (tray menu; Cmd+K in the popover) | the real calendar |
| M16 | Create, edit, delete events: form with rooms, people, repeat, reminder, show as | writing a real event |
| M17 | Answer invitations from the calendar and from the invitation email | answering a real one |
| M18 | Event reminders: one plain notification per event, no snooze | a real banner |
| M19 | Popover tabs Inbox and Today: today as a one-day calendar, Join links | a real meeting link |

Testing rule for sending: **never send real mail** unless the user names the exact message and
recipient. Everything else is proven against `MAILBAR_MOCK`, where Send goes nowhere.

Testing rule for the calendar: never create, change, cancel or answer a real event unless the
user names it; an event with people sends real invitations.

## Status
2026-09-26: **v1.0.0 released** on GitHub Releases (sirpooya/osx-mailbar), `Mailbar-1.0.0.zip`,
signed with the Apple Development certificate, not notarized (users click Open Anyway).

2026-09-25 (latest): **everything built, M0 to M19**, plus groups, the people directory, the rebuilt event form and its Schedule view (163 tests green); the popover has Inbox and
Today tabs (Today a one-day calendar). Mail (reading, actions,
search, attachments, notifications, instant arrival, simple sending) and the calendar (Day, Week,
Month; swipe paging; category colours; create, edit, delete; invitations; reminders; Today in the
popover). All proven in `MAILBAR_MOCK` mode; the Milestones table says what is still unproven on
the real account. Open with the user: why Core Weekly shows a colour its OWA view does not
(needs a read-only look at that event and the category list, which the user has not yet OK'd).

2026-09-24 (latest): **M4 to M6 built**, 51 tests green. The reader opens a message with JS off,
remote images blocked (proven with a local pixel server, both ways), inline images from memory;
opening marks read. Mark unread, flag, archive and delete work from the reader toolbar, the row's
hover buttons and its context menu, optimistic with rollback. Nothing lands on disk (checked: the
only per-app files are macOS's own Metal shader cache). Idle footprint 54 MB. All of it proven in
mock mode only; the real account still has to be added by the user.

2026-09-24: **M0 to M3 built**, 41 tests green. Settings adds, edits, tests and deletes
accounts; the menu bar shows the icon plus the total unread count; the popover lists the Inbox in
the Outlook row layout, with Persian lines right-aligned, and each failure state has its own view.
All of it is proven in `MAILBAR_MOCK` mode by screenshot. **Nothing is proven against the real
server yet**: the user has to add their account (the password never passes through Claude). That
one Test press settles the user name format and the Exchange version. Next: M4, the reader.

QC note: Accessibility is not granted to the VS Code host, so `mac-qc` can photograph windows but
cannot click the status item or hover. `macqc shot` also misses WKWebView content (it draws in
another process); `screencapture -x -l <window id>` captures it. The DEBUG launch flags in `Core/QCFlags.swift` (`--open-popover`,
`--open-settings`, `--open-editor`, `--open-message`, `--load-images`, `--hover-first-row`) put
each surface on screen without a click. `MAILBAR_MOCK_PIXEL=<url>` aims the mock tracking pixel at
a local server for the remote-image proof.

> **Another committer is active in this repo**, as in osx-jirabar: commit e2a7906 ("Add core
> functionality for account management and inbox state handling") was made and pushed at 21:20 by
> something other than Claude, sweeping up half-written files. Commit early, and do not assume the
> working tree is still yours.

2026-09-24: repo created.

2026-09-24: the first draft of this file assumed Microsoft 365 plus Graph plus OAuth. That was
wrong. The user's Outlook for Mac account settings show an on-prem Exchange account using EWS with
"User Name and Password" authentication. Graph, Entra ID app registrations and OAuth do not apply,
and the "confirm with IT" blocker that came with them is gone.

## The mail server (ESTABLISHED from the user's Outlook settings, do not re-research)
Context only. **None of this is hardcoded in the app, not even as a placeholder or a default.** The
user types every value into Settings when adding an account.

**This repo is public.** The real host names, email domain and directory server live in
`AGENTS.local.md` (gitignored). Read it when you need them; never copy them into a tracked file.

- Account type in Outlook for Mac: "Microsoft Exchange".
- EWS endpoint: the standard `https://<host>/ews/exchange.asmx`, port 443, SSL on. This is what
  Outlook uses; the app talks to this same URL.
- Auth method in Outlook: "User Name and Password", user name in short form (no domain, no `@`).
  On-prem Exchange serves this as NTLM or Basic over HTTPS; `URLSession` answers either challenge.
  Whether the server wants `DOMAIN\user`, the short name or the UPN is **unproven**; M1 settles it.
- Directory service: an Active Directory Global Catalog (LDAP, no SSL). Outlook uses it for
  address lookup when composing. **This app does not use it**: no compose, so no address lookup.
  Do not add an LDAP client.
- Message content is frequently Persian. Every text field (sender, subject, preview, body) needs
  per-string natural direction, right to left when the text is RTL. osx-jirabar's
  `Core/TextDirection.swift` is the pattern.
- The host may be internal-only. Treat "cannot reach server" as its own state ("Are you on the
  VPN?"), never as an empty inbox.
- Exchange version: unknown. Read `ServerVersionInfo` from the first SOAP response header. `Preview`
  and `Flag` need Exchange 2013 or later; older servers get the preview from text bodies and the flag from `PidTagFlagStatus` (0x1090).

## EWS operations, exhaustively
SOAP 1.1 POSTs to the account's EWS URL, `Content-Type: text/xml; charset=utf-8`, with a
`RequestServerVersion` header. The `GetFolder` probe asks for `Exchange2010_SP2`, which every
server from 2010 SP2 on accepts (asking an older server for a newer version is itself an error);
its reply's `ServerVersionInfo` decides whether `FindItem` asks for `Exchange2013` fields.

| What | Operation |
|---|---|
| Verify an account in Settings | `GetFolder` on distinguished `inbox` |
| Unread count | `GetFolder` on `inbox`, read `UnreadCount` |
| Inbox list | `FindItem` Shallow on `inbox`, `IndexedPageItemView` of 50, sorted `DateTimeReceived` descending, properties `item:Subject`, `message:From`, `item:DateTimeReceived`, `message:IsRead`, `item:Flag`, `item:Preview`, `item:HasAttachments` |
| Open a message | `GetItem`, `BodyType` HTML, with `item:Attachments` for the inline images |
| Inline images | `GetAttachment` for the `cid:` images only, at most 20 |
| Mark read or unread | `UpdateItem` `SetItemField message:IsRead`, `ConflictResolution="AlwaysOverwrite"`, no `ChangeKey`, `SuppressReadReceipts="true"` on 2013+ |
| Flag or clear flag | `UpdateItem` `SetItemField item:Flag`, `FlagStatus` `Flagged` or `NotFlagged` |
| Delete | `DeleteItem` `DeleteType="MoveToDeletedItems"`. **Never** `HardDelete` or `SoftDelete` |
| Expand a group | `ExpandDL` on the group's address; members listed one level down |
| An attendee's contact card | `ResolveNames` `ReturnFullContactData="true"` on the address; the `Contact`'s JobTitle, Department, CompanyName, OfficeLocation, Manager, PhoneNumbers, PhysicalAddresses (Business) |
| Archive | `FindFolder` for a top-level `Archive` under `msgfolderroot` (id kept in memory), then `MoveItem`. No folder: `CreateFolder` only after the user presses "Create and Archive" |

Writes send the `ItemId` without its `ChangeKey` and `AlwaysOverwrite`. Setting one boolean is
idempotent, so there is nothing to conflict with, and it removes the refetch-and-retry path the
first draft planned. Delete and move do not take a change key at all.

## Tech stack (Apple frameworks only)
- Swift 6.0. SwiftUI, hosted by AppKit for the status item, popover and settings window.
- Min target: macOS 14.0. Liquid Glass gated behind `#available(macOS 26, *)`.
- Networking: `URLSession` with a delegate that answers `NSURLAuthenticationMethodNTLM` and
  `NSURLAuthenticationMethodHTTPBasic` with the account's credential (`persistence: .none`).
  Requests built from string templates with XML escaping, responses parsed with Foundation's
  `XMLParser`. No EWS SDK, no XML package.
- TLS: normal system trust only. If the server's certificate fails, show the error. **Never** add a
  trust override or accept-anyway button.
- Message bodies: render the HTML in a `WKWebView` with JavaScript disabled and remote images
  blocked by default (tracking pixels). A per-message "Load images" button lifts the block.
- Storage: UserDefaults for configuration and the account list (no secrets), every key in one
  `Keys` enum, defaults registered at launch. Passwords in the Keychain
  (`kSecClassGenericPassword`, `kSecAttrAccessibleWhenUnlocked`), one item per account, keyed by
  the account's UUID. Never plist or UserDefaults for a password.
- Format: XcodeGen `project.yml` is the source of truth; the `.xcodeproj` is generated and ignored.

> Do NOT add a Swift package unless a task truly needs it. Ask first. Approved: Sparkle (2026-09-26,
> for updates).

## Project layout
```
project.yml              XcodeGen spec (source of truth)
Mailbar/
  App/                   AppDelegate, status item, popover, activation policy
  Accounts/              Account model, AccountStore (UserDefaults), KeychainStore, LoginKeychain
  EWS/                   EWSClient (URLSession + auth challenge, streaming), SOAP builders, XMLParser
                         decoding, Autodiscover, CalendarModels, CalendarWrite, MockMode, MockCalendar
  Core/                  MailStore, CalendarStore, Poller, MailStreamer, NotificationService,
                         EventReminders, TodayAgenda, Compose, EventDraft, ReaderHTML, CategoryColors
  Views/                 Inbox list and rows, reader, web view, composer, settings, account editor,
                         TodayDayView (the popover's Today tab)
  Views/Calendar/        Calendar window, root and toolbar, week and month grids, pager, event form,
                         detail panel
  Resources/             Menu bar icon (MenuBarIcon.png), AppIcon.icon
MailbarTests/            Request shapes, response fixtures, stores against the mock server, layout
```
Build: `xcodegen generate && xcodebuild -project Mailbar.xcodeproj -scheme Mailbar build`.

**The user runs `/Applications/Mailbar.app`, and asked (2026-09-24) for it to be rebuilt and
relaunched from there after every change.** Every time:
```bash
xcodegen generate && xcodebuild -project Mailbar.xcodeproj -scheme Mailbar -configuration Release -derivedDataPath .dd build
pkill -x Mailbar; sleep 1
ditto .dd/Build/Products/Release/Mailbar.app /Applications/Mailbar.app && open /Applications/Mailbar.app
```
Quit first: replacing the bundle under a running process invalidates its code signature.
`pkill -x Mailbar` quits BOTH the installed app and a Debug build, since they share a process name;
to stop only a QC run use `pkill -f .dd/Build/Products/Debug`, and relaunch the installed app when
a QC pass is over. Release
is bundle id `in.pooya.mailbar`, with its own defaults and Keychain items; the mock and QC flags
are compiled out of it, so screenshot QC still runs on the Debug build in `.dd`.

## Decisions (DECIDED, do not re-litigate unless you spot a real problem)
- 2026-09-24 EWS, not Graph, not IMAP. The mailbox is on-prem Exchange and EWS is the endpoint
  Outlook itself uses. Graph only exists for Exchange Online. IMAP may not even be enabled and
  cannot flag or archive the way Outlook does.
- 2026-09-24 Multiple accounts. Settings lists accounts and can add and delete them. Nothing about
  any account is baked into the app.
- 2026-09-24 One view: the Inbox. No folder list, no folder picker. The popover follows
  osx-jirabar's shape (header, list, push into a detail view, swipe right to go back), but where
  Jirabar has one view per board column, Mailbar has one per account, and with one account there
  is exactly one view. Accounts switch from the header's menu only: the sideways two-finger swipe
  between accounts was removed at the user's request (2026-09-25); do not bring it back.
- 2026-09-24 Row layout copies Outlook's message list: sender on line 1 (bold while unread) with
  the relative time right-aligned on the same line (moved up from the subject line 2026-09-25, the
  user's call) and the attachment clip before it, subject on line 2 with the flag, one line of preview on line 3
  in secondary colour. Everything truncates to one line. Hover actions sit over the subject line.
- 2026-09-24 Relative time: today shows the time (`14:32`), yesterday shows `Yesterday`, two to six
  days back shows `2 days ago` and so on, older shows a short date. The user's own words.
- 2026-09-24 Opening a message marks it read. It can be marked unread again from the reader or
  the row.
- 2026-09-24 Actions are exactly: mark read or unread, flag or unflag, archive, delete. Archive
  and delete are the only operations that move mail. No general "move to folder".
- 2026-09-24 Menu bar: `NSStatusItem` + `NSPopover`, centred under the icon. Pattern follows
  osx-jirabar.
- 2026-09-24 `LSUIElement: true` and `.accessory`: no Dock tile for the menu bar popover or
  Settings. osx-jirabar learned that flipping to `.regular` was never what let a window take
  focus; activating the app is.
- 2026-09-25 **The calendar window and Settings are the exceptions** (the user's requests):
  while either is open the app is `.regular`, so it is in the Dock and Cmd+Tab; closing the last
  of them returns to `.accessory` (`DockPresence`). A Dock click brings the calendar forward, or
  Settings when it is the only one open. The popover alone never shows a Dock tile.
- 2026-09-25 Calendar swipe copies Apple's Calendar, not a transition: three pages (-1, 0, 1)
  side by side in `PagerStrip`s that the header, all-day strip and hour grid share; the strip
  follows the fingers (`CalendarPager`), and on release a spring starting at the fingers' speed
  carries it on (a third of a page, or a flick over 350 pt/s) or back. The axis locks after 4 pt
  and sideways events are consumed so the hours do not also scroll. Neighbours are fetched with
  the visible page (`fetchRange`). The earlier fade-and-slide transition was janky and is gone.
- 2026-09-25 Calendar look, the user's calls: weekend and off-hours shading neutral grey, never
  an accent tint, and light (black at 2.8 percent, white at 3.5 in dark); no band behind the day names; toolbar "‹ Today ›" on the right; no Work week.
- 2026-09-25 Event colour is **exactly what the server says**: the first category's colour from
  the master list (`GetUserConfiguration` "CategoryList" on the calendar folder, presets 0 to 24
  in `CategoryColors`). A category the list gives no colour (`color="-1"`), or does not list, is
  Outlook's pale grey. Names are guessed ONLY when the list cannot be read, and only for the exact
  default names ("Red category"): a substring guess once turned "Core Weekly" red. No category:
  the accent. Block text sits top left, as in Outlook.
- 2026-09-25 The calendar window is responsive, after Apple's Calendar: minimum 520 x 420; the
  title shortens in steps (`title`, `shortTitle`, `tinyTitle` via `ViewThatFits`), and before the
  toolbar controls do, so they keep one size across Day, Week and Month (2026-09-26: the title
  claiming room first let Week's long title shrink the view switcher, which jumped on each change); day names go
  "19 Saturday", "Sat 19", "19"; below 900 pt the detail panel floats over the grid as a card;
  event titles wrap onto the lines a block has room for, but only between words (the longest
  word is measured; if it does not fit, one truncated line, never a word broken mid-way).
- 2026-09-25 Today (M19) is a TAB, not a strip: the user meant a one-day view beside the Inbox
  ("Inbox | Today" capsule, Cmd+1 and Cmd+2). It reuses the calendar grid's pieces (hour shading,
  `EventBlock`, `NowLine`, category colours from the same rule, `CategoryColors.tint`) and the
  reminders' fetch; opening the tab fetches at once. A strip above the inbox was built first and
  removed. With several accounts the account menu moves to the header's left.
- 2026-09-25 Drag to create, after Apple's Calendar: press on an empty slot in Day or Week and
  drag up or down; a "New Event" block follows in 15-minute steps within that one day, and
  letting go opens the event form over that range. A drag that starts on an event does nothing.
  The block is only drawn on screen: nothing reaches the server until Save or Send, and Cancel
  drops it. Double-click still makes an hour on the half hour. `--calendar-drag` (DEBUG) draws
  one for screenshots, since QC cannot synthesize a drag without Accessibility.
- 2026-09-25 The event form, rebuilt at the user's request, times after Outlook for Mac (the
  user's pick after trying a lone Duration menu and a slider): a Duration menu with All day event
  on one line (Private is a lock toggle at the end of the toolbar, the user's call), then Starts and Ends, each a date box with its calendar inside and a
  time box; the duration sets the end, editing the end updates it. Labels are right-aligned with
  a colon throughout. Location has no icon. The series end row is "Until", so it never reads as
  a second "Ends"; Category
  (the master list with its colours, several allowed, the first colours the event); Charm (OWA's
  33 icons, SF Symbols, shown before the title on blocks and in the detail panel); Files (Add
  Files or drop onto the form, bytes in memory until Save, 25 MB together at most); and a People
  sidebar on the right after OWA's, where typing suggests from `ResolveNames` plus inbox senders,
  Up, Down and Return pick (no plus button beside the field, removed 2026-09-25 as useless, the
  user's call); a click on a person opens their contact card after Outlook's (`PersonCardView`:
  at the top only the people directory's data, photo and role, team and department under the
  name, plus the address with Copy; below the line only the Exchange directory's, job title,
  department, company, office, manager, phones, business address; never mixed, the user's call), and every invitee row has a
  remove button that always shows (the user's call); each person shows Free, Busy, Tentative, Away or No information
  for the event's time (`GetUserAvailability`, UTC in the request, no zone header). Rooms are
  found by typing in Location (no separate Rooms button, the user's call): the matching rooms
  list under the field (every word, ignoring case and the Arabic and Persian ye and kaf); a click
  selects one, Add to meeting (or a double-click, or Return) books the selected one, and Check
  availability puts every listed room in Schedule as a candidate (not booked,
  never sent; `EventDraft.candidateRooms`), where ticking a room books it, after Outlook (the
  user's call; showing Free or Busy badges in the list was dropped). Nothing is sent before Save or Send; Cancel sends nothing (tested).
  **Unproven on the real server**: the charm is extended property 0x0027 in property set
  `11000E07-B51B-40D6-AF21-CAA85EDAB1D0` (Integer, 1 to 33), known from OWA and Graph, not from
  the EWS docs; and an event with files is created with `SendToNone`, given its files with
  `CreateAttachment`, then sent with `UpdateItem` `SendToAllAndSaveCopy`, so the invitations
  carry them. Edits delete and add files first, then update; changed files send to everyone.
- 2026-09-25 The event form's Title is a bordered field with its label, like Location (the
  user's call). The People sidebar shows each person's photo from `GetUserPhoto` (Exchange 2013
  and later, 96 px), initials when there is none. The directory server in Outlook's settings
  (the Global Catalog, LDAP) is still not used: `ResolveNames` and `GetUserPhoto` reach the same
  directory through the Exchange server.
- 2026-09-25 More event form calls by the user: Show as lists OWA's order, Free, Working
  elsewhere, Tentative, Busy, Away, each with Outlook's swatch (`ShowAsSwatch`, untinted images).
  A click on the form's empty space ends editing (`EndEditingArea`); labels let clicks through.
  Layout after OWA (the user's sketch): a title bar holding the Event and Schedule switch (it replaced the form's name), a toolbar under
  it with Attach, Charm and Categorize (each showing what is chosen), white like the form with no
  line between them; the form opens with no field focused or selected, not even for a frame
  (`FocusSink`, as in the account editor; the user's call, after first asking for the cursor in
  Title); the body is "Description" (OWA's
  word), never "Notes"; a bottom bar with the status line on the
  left and Cancel and Send on the right. The Files row shows only when there are files.
  Repeat follows OWA's list, worded from the start date: Never, Every day, Every Wednesday,
  Every workday (Settings' work days), Day 23 of every month, Every fourth Wednesday, Every
  September 23, and Other... (`RepeatPatternEditor`: daily, weekly on chosen days, monthly by
  day or by week, yearly, every N); a repeating event gets an Until row (no end, on a date, after
  N times: `NoEndRecurrence`, `EndDateRecurrence`, `NumberedRecurrence`). Show as and Reminder
  moved to the toolbar (Charm and Categorize show no icon until one is chosen). Dates read
  year/month/day (2026/09/25: the date picker takes the en_ZA locale, Gregorian, for that order
  alone); times are 24-hour, 09:00 (en_GB), because no locale pads a 12-hour hour and the picker
  takes no format; Shift with Up or Down moves a time by 10 minutes (`SteppingDatePicker`).
  Repeat's quick list is Never, Daily, Weekly, Monthly, Custom...; the Custom editor offers
  Daily, Weekly, Monthly (no Yearly anywhere, the user's call); Monthly then asks "day 25" or
  "the fourth Friday". Until offers None, After, By. Fields are one
  `FieldBox` look, 28 pt tall, and popups are large-size `NSPopUpButton`s of the same height,
  every row at least 28 pt and its label CENTRED on the row (baseline alignment let each native
  control move the label, the user's recording), only Description aligned on its first line;
  Duration, Repeat and Until one width, the date boxes' (134); no scroll bars, and Description (60 pt at least) fills the
  rest so the form does not scroll; the form is 690 x 556 (440 pt of
  fields, a 250 pt People sidebar, the user's marks); lengths and reminders use short units
  (30m, 1h 30m; reminders 15m, 1d, "At start", no "before"); every control shares one look, light
  grey with no border (`FieldBoxFill`, the Description box's grey; white was a misreading the
  user rejected): popups borderless inside a `FieldBox` (`PopUpMenu.boxed()`), the checkbox
  (`FieldCheckboxStyle`), Description; dates and times are
  bezel-less `NSDatePicker`s inside it, the calendar button inside the date box; popups are
  `NSPopUpButton`s at a set width (`PopUpMenu`), since a SwiftUI menu Picker ignores its frame.
  OWA's Response options sit behind a gear beside People, drawn like the team button in the
  field under it (same size and colour, the user's call; a plain button opening a popover of two
  checkboxes): Request responses
  (`calendar:IsResponseRequested`) and Allow forwarding (named Boolean `DoNotForward` in
  PublicStrings, true when forwarding is off), both on by default, sent on create and every
  update, read back for editing. `DoNotForward` is not in the EWS docs: unproven on the server.
- 2026-09-25 The Today tab swipes through days (the user's request): the calendar window's
  paging (`CalendarPager`, `PagerStrip`, axis lock in `PagerSwipe`) on a strip of three days,
  the days within two of the one shown fetched ahead in one request (`MailStore.loadNearbyDays`),
  only those within three kept, in memory. An answer is never discarded because the user swiped
  on: over the VPN a fetch outlasts a swipe, and discarding it left the days loading for ever
  (the user's recording). A failed day says "Could not load"; swiping back onto it retries. It opens on today, a "Today" capsule appears in the header once
  away, and closing the popover returns to today and drops the other days. Only swipes inside
  the popover's own window page it.
- 2026-09-25 Reminders (M18) are deliberately plain: one notification per event at its
  reminder time, no snooze, no action buttons (the user's words: "a simple notification that
  comes and goes"). Scheduled with macOS for the next 26 hours; removed from Notification
  Center once the event is over. Do not add snooze or actions without asking.
- 2026-09-25 Events (M16): one form for new and edit, in memory only. Saving an event with
  people or rooms says "Send" and sends invitations or updates; a plain appointment sends
  nothing. Deleting a meeting the user organized sends the cancellation. Invitations are
  answered (M17), never edited or deleted from here. Edits to a recurring event apply to that
  occurrence only; the repeat rule is set only when creating. Every calendar write carries the
  user's Windows time zone (`WindowsTimeZone`) so all-day and repeating events keep their days.
  Notes are plain text: an Outlook note's formatting is not kept on save.
- 2026-09-25 Width decides the view (the user's rule): crossing below 580 pt switches to Day,
  crossing back above switches Day to Week; on opening, narrow is Day and wide turns a leftover
  Day into Week. Only crossings switch, so a view picked by hand holds until the next crossing.
  Day labels and Month weekday names use ONE format across the row, never per column.
- 2026-09-26 Event form fixes, the user's catches: Send carries a paper plane; the People
  sidebar's photos and free/busy live with the open form (`CalendarStore.formPhotos`,
  `formStatuses`, dropped when the form closes), so the Event and Schedule tabs switch without
  fetching them again; typing in Location opens the room list itself (`roomQueryActive`, closed
  by Escape, a pick, Check availability or leaving the field), because the focus state alone
  went stale on the real account; an empty room list is read again (also on typing), all room
  lists are fetched at once, a spinner shows in Location while they load, and "No rooms match"
  says so when nothing fits. A room is its address, compared without case (`Room` ==), so one
  room never lists twice; long room names truncate at the head (`DirectionalText` truncation),
  keeping the room and losing the building; Schedule's name column is 270 pt.
- 2026-09-25 Tooltips name the action then its shortcut in symbols, "New Event  ⌘N", never
  "(Command N)" (the user's call). The calendar window opens at 870 x 620 (autosave name
  `MailbarCalendarWindow.v2`, so the new default applied once); event titles are medium weight
  and their leading bar 2 pt (`EventBlock.barWidth`).
- 2026-09-25 Toolbar controls in Apple's style: the account menu (with several accounts) and
  "+ New Event" as grey capsules (Cmd+N); Day,
  Week, Month in one capsule with a sliding grey pill (`ModeSwitcher`), a light border, no shadow; Previous and Next as round grey buttons around a Today
  capsule.
- 2026-09-25 Changing Day, Week, Month is a hard cut, as Apple's Calendar does it (checked frame
  by frame in a 60 fps recording): only the switcher's pill animates. Animating the mode morphed
  every column and header between layouts and read as janky. Day and Week keep the hour grid's
  scroll position across the switch.
- 2026-09-25 The calendar's surfaces avoid `windowBackgroundColor`, which the wallpaper tints:
  `CalendarSurface.background` (text background, never tinted) under an exactly neutral grey
  shade, measured at R = G = B. No refresh button; the title aligns with the grid's left line.
- 2026-09-24 The popover activates the app when it opens and draws an opaque window-background
  surface. On macOS 26 the popover glass adapts to the luminance behind it, not to Light or Dark,
  so over a dark wallpaper in Light mode it went dark under light-mode text and inverted the
  primary and secondary contrast. Do not remove the background to "get the glass back".
- 2026-09-24 Right-to-left rows use frame alignment, never `.environment(\.layoutDirection)`,
  which flips the stack's alignment guide and throws the time to the wrong side (see
  `DirectionalText`).
- 2026-09-25 Popover details, the user's calls: a Persian SUBJECT in a row starts at the left
  edge (`pinnedLeading`) while sender and preview stay right-aligned; refresh lives in the
  footer beside "Updated", not the header, and while a check runs the time gives way to a
  shimmering "Updating..." (`ShimmerText`, ported from osx-autoconnect, held for at least one
  0.9 s pass) instead of a spinner; compose sits at the header's left edge on
  both tabs; both tabs share one content height (`contentHeight`, 460) so the popover never
  resizes on a switch, and search comes and goes without a transition, so
  Inbox and Today never shift it (search shows on Inbox only); the Today tab's header is the
  date alone; Join shows only when the event holds a real meeting link and sits centred on the
  title line.
- 2026-09-24 Menu bar icon is the user's `tray.png`, bundled byte-for-byte as `MenuBarIcon.png`
  and drawn WHOLE into an 18pt square as a template image: the artboard's padding is part of the
  design. Never crop, resize, recolour or re-weight the user's artwork in code; the user rejected
  cropping to ink and an alpha boost. Replace the file and rebuild, nothing else. App icon is the user's Icon Composer bundle,
  `Resources/AppIcon.icon` (needs Xcode 26). Both follow osx-jirabar.
- 2026-09-24 Settings is an `NSWindow` this app owns, built from `SettingsComponents.swift`
  (mac-pro skill), not a SwiftUI `Settings` scene.
- 2026-09-25 Settings tabs, the user's split: General (refresh, notifications, startup),
  Accounts (the account list with the privacy note right under its card, above Add Account), Calendar
  (event reminders, work time, people directory).
  The top copies osx-launchpad's: no title strip, only the close button, the tab bar (glyph over
  label, 72 pt items, accent when selected on a 0.04 grey pill) straight under it, movable by its
  background, with 384 pt of body under the tab bar (96 pt shorter, the user's call). It opens
  on Accounts while there is none. Pickers hug their size so they end where
  the switches do. Rows carry no subtitles (the user: "too extra"). The Today tab is always on:
  its switch was removed. A click anywhere on an account row opens its editor; the editor has no
  "Edit ..." heading and opens with no field focused or selected, not even for a frame: a
  zero-size `FocusSink` first in the sheet takes first responder as it appears (clearing focus
  afterwards flashed the e-mail field selected). Footnotes are one short line each (the user:
  "briefer"). `--settings-tab=` (DEBUG) opens a tab.
- 2026-09-25 The people directory's address reads like the compliance-audit plugin's endpoints
  (the user's pick): a status dot (green read, red failed, amber only the remembered count, grey
  unset), the saved address locked behind Edit, Connect to read a new one (it locks again only
  once it worked; a failure stays open with the reason). Settings reads it on showing it, and
  the last good read's count and time are kept in UserDefaults (`peopleDirectoryCount`,
  `peopleDirectoryReadAt`, a number and a date, never the people) so "51 people" shows at once.
- 2026-09-24 Polling, not push, for v1: every couple of minutes (Settings, 1 to 10), on popover
  open, and once on wake. Each poll is `GetFolder` for the count plus `FindItem` for the newest 50.
  **Not `SyncFolderItems`**, which the first draft of this file called for: a sync from no state
  enumerates the entire inbox before it reports anything, which is thousands of items on a real
  mailbox, and two small requests every two minutes cost nothing. EWS streaming notifications could
  replace polling later without a webhook.
- 2026-09-24 The poller's refresh runs in an unstructured `Task`, because `refreshNow` restarts the
  loop by cancelling it, and that cancellation reached the requests in flight and surfaced as
  "Something went wrong" every time the popover opened mid-poll. A cancelled request never changes
  what is on screen.
- 2026-09-24 Adding an account asks for email and password only; Sign In runs Autodiscover (user's
  request) to find the EWS URL and display name, guesses the user name (short name, then the full
  address, keeping whichever the server accepts), and tests the connection. Server Details then
  opens, filled and editable; when Autodiscover is not available it opens empty, as before.
- 2026-09-25 Sending (M12 to M14): one draft at a time, in memory only, never on disk and never in
  the server's Drafts folder; a draft with text is never replaced by a new one. Replies and forwards
  use `ReplyToItem`, `ReplyAllToItem`, `ForwardItem`, so the server builds the quote, subject and
  forwarded attachments; a fresh `ChangeKey` is read right before (opening marks read, which
  changes it). The body goes as HTML built from the plain text, one `<div>` per paragraph with
  `dir="rtl"` on Persian ones. Recipient suggestions come from the people directory, the
  Exchange directory (`ResolveNames`, since the groups work) and inbox senders in memory.
  The composer's paragraphs are `.natural` direction, each on its own, matching what is sent.
- 2026-09-24 Streaming (M11): one loop per account in `MailStreamer`. Subscribe, then
  `GetStreamingEvents` for 29 minutes over a second URLSession with a 35-minute idle timeout that
  shares the in-memory cookie jar (a load-balanced Exchange pins the subscription by cookie).
  A rejected password PARKS the account (no retries until it is edited): every retry is a failed
  logon against the domain lockout counter. Same EWS URL as everything else; no new host.
- 2026-09-24 Notifications (M7): the first poll per account after launch is a silent baseline,
  ids seen are kept in memory only, and each notification is withdrawn when its message is read,
  archived or deleted anywhere. macOS stores delivered notifications on disk in Notification
  Center; that is outside this app's control. A switch once hid the details; the user had it
  removed (2026-09-25), so the only way to keep them out is turning notifications off.
- 2026-09-24 Attachments (M9) are the one sanctioned exception to "nothing on disk": a click
  shows the file in the Quick Look panel (`AttachmentPreview`, 2026-09-26, the user's call: it
  used to open in the default app, and the copy then sat on disk until quit, which for an app
  that never quits is for ever). Quick Look only shows a file, so it is written to
  `<tmp>/Mailbar Attachments/<uuid>/` (0700 folder, 0600 file) and deleted the moment the panel
  closes or shows another one; the folder is also cleared at quit and at launch. Save writes
  where the user picks. Bytes are fetched only when one of the two is pressed.
- 2026-09-24 Search (M8) is server-side: `QueryString` (the server index Outlook uses) on 2013+,
  a subject-or-body substring restriction on older servers. Results are in memory, the
  selected account only, dropped when the popover closes. Actions on a result update it.
- 2026-09-24 Remote images: blocked by a Content-Security-Policy written before the message's own
  markup (`ReaderHTML`), plus JS off and a non-persistent data store in the web view.
  `NSAllowsArbitraryLoadsInWebContent` is on so that "Load images" also works for plain-http
  images, which ATS would otherwise refuse silently; it affects web content only, and EWS itself
  stays HTTPS-only.
- 2026-09-25 A wide message fits the reader by `pageZoom` (`MessageWebView.fitToWidth`), sized
  from the content's real extent, left edge to right edge, never `scrollWidth` alone: Outlook
  wraps Persian mail in `<div dir="rtl">` inside a left-to-right page, whose overflow runs off
  the LEFT edge, where `scrollWidth` does not count it and nothing can scroll to it (the user's
  report: the message was cut off on the left). It measures again after each zoom, up to three
  times, since the page lays out anew wider. The Persian IT mock message carries the wide table
  to check it.
- 2026-09-24 The reader closes when the popover closes, so a body and its images are never kept
  in a hidden view. The one question the app asks about the mailbox (create an Archive folder?)
  is an inline banner, not an alert, which an `NSPopover` presents badly.
- 2026-09-24 Bundle id `in.pooya.mailbar`, Debug `in.pooya.mailbar.debug`. Keychain service
  `in.pooya.mailbar.account`, defaults prefix `mailbar.`. These are storage addresses: renaming
  strands the stored passwords and settings.

## Privacy (local-first)
No telemetry, no analytics. Network calls, exhaustively:
- Each configured account's EWS URL (mail and, since M15, the calendar: same URL, same sign-in;
  the directory search and room lists of M16, and the People sidebar's free/busy
  (`GetUserAvailability`) and people's photos (`GetUserPhoto`, 2013+), go to the same URL too).
- While adding an account, and only when the user presses Sign In: Autodiscover at
  `https://autodiscover.<email domain>/autodiscover/autodiscover.xml`, then
  `https://<email domain>/autodiscover/autodiscover.xml`. HTTPS only; no HTTP redirect method and
  no DNS SRV lookup.
- Remote images inside a message, only when the user clicks "Load images" for that message.
- Sparkle, Release builds only: `appcast.xml` from raw.githubusercontent.com (this repo) once a
  day and on Check for Updates, and the update zip from GitHub Releases when the user installs.
  No system profile is sent. Sparkle keeps a downloaded update in the app's Caches folder until
  it installs; that is the app, never mailbox data.
- The people directory, only when the user has set its address in Settings: one plain GET for
  the list (at most every ten minutes, when a picker, a People field, a recipient field or the
  Settings tab needs it), and GETs for photos on that same host only. No credentials are sent.

Reading the login Keychain: while adding an account, the sheet looks up internet-password items
for the address's user names, on the email's own domain only, attributes only (no prompt, no
secret read). A password is read only when the user presses Use It, behind macOS's own permission
prompt, and it goes into the password field and nowhere else until Save
(`Accounts/LoginKeychain.swift`, adapted from osx-autoconnect).

Passwords live only in the Keychain. Never log a password, an `Authorization` header or a message
body, not even in DEBUG.

## Caching (the user's rule, 2026-09-24: never cache anything)
**Nothing from the mailbox is ever written to disk.** No database, no file cache, no URL cache, no
WebKit cache, no thumbnails, no "offline" mode.
- The only thing kept even in memory between polls is the list data: sender, subject, preview,
  time, read and flag state, and the `ItemId`/`ChangeKey` needed to act on it. It dies with the
  process.
- A message body lives in memory only while its reader is open, and is dropped when it closes.
- Calendar events (M15): only the range on screen, in memory, replaced on each refresh, and all of
  it dropped when the calendar window closes.
- **Images are never cached anywhere**, memory or disk: not remote images, not inline `cid:`
  images, not sender photos. Each time a message opens they are fetched again (and remote ones only
  after "Load images"). People's photos in the event form's sidebar follow the same rule: fetched
  with `GetUserPhoto` when the form opens, held by the form alone, gone when it closes. The
  people directory's photos too: fetched by the view that shows them, held by it alone. A
  contact card's directory details are read when it opens and dropped when it closes.
- The people directory's list (names, work addresses, teams) is held in memory only, read again
  after ten minutes or a relaunch. Only the last read's count and time are stored, for Settings.
- `URLSession` uses `URLSessionConfiguration.ephemeral` with `urlCache = nil`.
  `WKWebView` uses `WKWebsiteDataStore.nonPersistent()`, one store per reader, released on close.
- Pre-2013 servers only: previews built from text bodies are held in memory for rows still in the
  list, so a poll does not refetch fifty bodies. They die with the process like everything else.

## Reference material and QC
- `_samples/`: screenshots of the reference look, when supplied. Where this doc is ambiguous, the
  screenshot wins. The first reference is Outlook for Mac's message list row (sender, subject with
  time, one-line preview).
- Screenshot-QC every significant surface with the `mac-qc` skill before calling it done.
- QC hooks: `MAILBAR_MOCK=1` serves canned EWS responses (two invented accounts, Persian and
  mixed-direction messages) so the UI can be exercised without an account; `MAILBAR_MOCK=empty`,
  `unreachable`, `rejected`, `failed`, `loading` force each state. A yellow SAMPLE DATA banner
  shows whenever it is on. DEBUG only.

## Playground convention
Dev-only tuning windows: an `@Observable` params object the shipping views read, a `Codable`
snapshot decoded key by key with defaults, a mock stage, a controls sidebar. DEBUG only, opened
with the launch flag `--playground`, as an app-owned `NSWindow`, not a `Window` scene. Build or
extend one with the `swift-playground` skill.

## Changelog
After any user-visible or behavioral change, log it:

```bash
python3 ~/Documents/GitHub/claude-skills/skills/release/changelog.py add <type> "<entry>"
```

Types: added, changed, deprecated, removed, fixed, security. Write the entry for someone reading
release notes, not a commit message. Skip pure refactors, formatting, and doc-only edits.
Releases are cut with the `release` skill, whose `.release.json` runs `scripts/release.sh <version>`:
it bumps `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` (Sparkle compares the build number),
builds Release, zips with `ditto`, signs the zip with Sparkle's `sign_update --account mailbar`,
tags and pushes, publishes the GitHub release with the changelog section, then writes and pushes
`appcast.xml` (after the zip is up, so the feed never names a missing download). Info.plist reads
both versions from the build settings.

**Sparkle (2026-09-26, the user's request).** `UpdateController`, Release builds only (a Debug
build must never offer to replace itself with the shipped app): a daily check of `SUFeedURL`
(appcast.xml on main via raw.githubusercontent.com) and "Check for Updates..." in the tray menu;
Sparkle's windows make the app `.regular` while shown (`DockPresence`). The EdDSA key is the trust
anchor, since the app is not notarized: public half `SUPublicEDKey` in `project.yml`, private half
in the login Keychain as Sparkle's item with account `mailbar`. **Lose the private key and no
installed copy can ever update again**; back it up with `generate_keys --account mailbar -x <file>`
somewhere safe, never in the tree.

## Working style
- Read this file first, the Scope section above all.
- Never hardcode the user's data: no server URL, user name, email or name in code, fixtures,
  placeholders or defaults. Mock fixtures use invented names and `example.com`.
- Never delete, archive, flag or change the read state of real mail during testing without
  explicit permission. Use `MAILBAR_MOCK=1` or a message the user names. Reading the inbox list
  is fine.
- Never send real mail during testing. Sending is proven against `MAILBAR_MOCK` only, unless the
  user names the exact message and recipient.
- Never quit or modify the user's Outlook install.
- Commit in small, working increments. Explain any deviation from this spec.
- Ask before adding any external dependency.
- No em dashes: prose, code comments, commit messages.

## Definition of done (v1)
- [~] Accounts can be added, tested and deleted in Settings; passwords survive relaunch and reboot.
      Mock and unit tests (Keychain round trip); the real account is the user's to add.
- [x] Menu bar shows the inbox unread count, updated within one poll interval (mock).
- [x] The Inbox list matches the Outlook row layout, including right-to-left Persian text (mock).
- [x] A message opens, renders safely (no JS, no remote images by default) and is marked read
      (mock; pixel block proven with a local server).
- [x] Mark unread, flag, archive and delete work from the reader and from the row (mock).
- [x] Unreachable server, rejected password and empty inbox each show their own state (mock).
- [x] Nothing from the mailbox on disk: after a session, `~/Library/Caches`, `~/Library/WebKit`
      and the app container hold no message text or images for the app's bundle id.
- [x] Idle memory under 60 MB (54 MB, Debug build, after reading a message).
