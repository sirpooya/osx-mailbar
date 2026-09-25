# AGENTS.md: Mailbar (macOS menu-bar mail reader for on-prem Exchange)

## Goal
A lightweight menu-bar mail reader for my work mailbox, which lives on an on-premises Microsoft
Exchange server reached over EWS. It shows the inbox unread count in the menu bar and one list, the
Inbox, in a popover, styled like Outlook's message list. I can open a message, and mark it read or
unread, flag it, archive it or delete it. Nothing else.

It replaces keeping `/Applications/Microsoft Outlook.app` (about 2 GB, always running) open all day,
so the user can delete Outlook.

Reading, plus simple sending (reply, reply all, forward, a new message; M12 to M14). No calendar
(planned in `PLAN.md`), no contacts.
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
- Anything beyond simple sending: rich-text editing, drafts, signatures, outgoing attachments.
- Move to folder, folder list, folder picker.
- Follow up, categories, rules, junk, snooze, pin.
- Contacts, tasks, notes, directory (LDAP) lookup. (Calendar: later, see above.)
- Offline mode, local search index, any disk cache.

### Wanted (v1.1, built 2026-09-24, milestones M7 to M11)
- **New-mail notifications** (M7): click one to open that message. Sender, subject and preview,
  or only the account name when "Show sender and subject" is off.
- **Search** (M8): a field under the header (Cmd+F), searching the server as you type.
- **Attachments** (M9): chips under the reader's header; click to open, right-click to save.
- **Launch at login** (M10): a switch in Settings, General.

- **Instant new mail** (M11): EWS streaming notifications; polling drops to a 10-minute safety net.

### Simple sending (M12 to M14, built 2026-09-25)
- Reply, reply all, forward, new message. Plain text writing, right to left for Persian. The
  server builds quotes and keeps copies in Sent Items (EWS `ReplyToItem`, `ForwardItem`,
  `CreateItem` with `SendAndSaveCopy`).
- Not in it: rich text, drafts folder, signatures editor, outgoing attachments, directory lookup.

### Calendar (planned 2026-09-25, `PLAN.md`, M15 to M19)
- View, create, edit, delete, answer invitations, reminders, over the same EWS server. Four
  decisions are the user's first; they are at the top of `PLAN.md`.

### Still open (the user's steps)
- Add the real account and press Sign In. This settles the user name format and the Exchange
  version, both unproven; record them here.
- Any action against real mail, on a message the user names.
- Uninstall Outlook.

Keep it minimal and dependency-light. No cloud sync, no analytics.

## Milestones
All done, 2026-09-24 and 25, every one proven in `MAILBAR_MOCK` mode (screenshots, tests). The
real-account column is what is still unproven. Work in progress is planned in `PLAN.md`
(the calendar); a milestone moves here once it is done.

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
| M9 | Attachments: open (private temp copy) or save | opening a real one |
| M10 | Launch at login | toggling it |
| M11 | Instant mail over EWS streaming, 10-minute poll as backup | a real arrival |
| M12 | Reply and reply all | a real send |
| M13 | Forward | a real send |
| M14 | New message, suggestions from inbox senders | a real send |
| M15 | Calendar window: Day, Week, Month, swipe paging, category colours, detail panel (tray menu, Cmd+K) | the real calendar |

Testing rule for sending: **never send real mail** unless the user names the exact message and
recipient. Everything else is proven against `MAILBAR_MOCK`, where Send goes nowhere.

Next: the calendar, `PLAN.md`.

## Status
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

> Do NOT add a Swift package unless a task truly needs it. Ask first. No approved exceptions yet.

## Project layout
```
project.yml              XcodeGen spec (source of truth)
Mailbar/
  App/                   AppDelegate, status item, popover, activation policy
  Accounts/              Account model, AccountStore (UserDefaults), KeychainStore (passwords)
  EWS/                   EWSClient (URLSession + auth challenge), SOAP builders, XMLParser decoding
  Core/                  MailStore (@Observable), Poller, unread count, relative time, text direction
  Views/                 Inbox list, message row, message reader, settings (Accounts pane)
  Resources/             Assets, menu bar icon, AppIcon
MailbarTests/            SOAP builder and response fixtures, relative time, account store
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
  is exactly one view.
- 2026-09-24 Row layout copies Outlook's message list: sender on line 1 (bold while unread), subject
  on line 2 with the relative time right-aligned on the same line, one line of preview on line 3 in
  secondary colour. Everything truncates to one line.
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
- 2026-09-25 **The calendar window is the one exception** (the user's request): while it is open
  the app is `.regular`, so the calendar is in the Dock and Cmd+Tab; closing it returns to
  `.accessory`. A Dock click brings the calendar forward. Do not extend this to Settings.
- 2026-09-25 Calendar swipe copies Apple's Calendar, not a transition: three pages (-1, 0, 1)
  side by side in `PagerStrip`s that the header, all-day strip and hour grid share; the strip
  follows the fingers (`CalendarPager`), and on release a spring starting at the fingers' speed
  carries it on (a third of a page, or a flick over 350 pt/s) or back. The axis locks after 4 pt
  and sideways events are consumed so the hours do not also scroll. Neighbours are fetched with
  the visible page (`fetchRange`). The earlier fade-and-slide transition was janky and is gone.
- 2026-09-25 Calendar look, the user's calls: weekend and off-hours shading neutral grey, never
  an accent tint; no band behind the day names; toolbar "‹ Today ›" on the right; no Work week.
- 2026-09-25 Event colour is **exactly what the server says**: the first category's colour from
  the master list (`GetUserConfiguration` "CategoryList" on the calendar folder, presets 0 to 24
  in `CategoryColors`). A category the list gives no colour (`color="-1"`), or does not list, is
  Outlook's pale grey. Names are guessed ONLY when the list cannot be read, and only for the exact
  default names ("Red category"): a substring guess once turned "Core Weekly" red. No category:
  the accent. Block text sits top left, as in Outlook.
- 2026-09-25 The calendar window is responsive, after Apple's Calendar: minimum 520 x 420; the
  title shortens in steps (`title`, `shortTitle`, `tinyTitle` via `ViewThatFits`); day names go
  "19 Saturday", "Sat 19", "19"; below 900 pt the detail panel floats over the grid as a card;
  event titles wrap onto the lines a block has room for, but only between words (the longest
  word is measured; if it does not fit, one truncated line, never a word broken mid-way).
- 2026-09-25 Width decides the view (the user's rule): crossing below 580 pt switches to Day,
  crossing back above switches Day to Week; on opening, narrow is Day and wide turns a leftover
  Day into Week. Only crossings switch, so a view picked by hand holds until the next crossing.
  Day labels and Month weekday names use ONE format across the row, never per column.
- 2026-09-25 Toolbar controls in Apple's style: Day, Week, Month in one capsule with a sliding
  grey pill (`ModeSwitcher`); Previous and Next as round grey buttons around a Today capsule.
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
- 2026-09-24 Menu bar icon is the user's `tray.png`, bundled byte-for-byte as `MenuBarIcon.png`
  and drawn WHOLE into an 18pt square as a template image: the artboard's padding is part of the
  design. Never crop, resize, recolour or re-weight the user's artwork in code; the user rejected
  cropping to ink and an alpha boost. Replace the file and rebuild, nothing else. App icon is the user's Icon Composer bundle,
  `Resources/AppIcon.icon` (needs Xcode 26). Both follow osx-jirabar.
- 2026-09-24 Settings is an `NSWindow` this app owns, built from `SettingsComponents.swift`
  (mac-pro skill), not a SwiftUI `Settings` scene.
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
  `dir="rtl"` on Persian ones. Recipient suggestions come only from inbox senders in memory.
  The composer's paragraphs are `.natural` direction, each on its own, matching what is sent.
- 2026-09-24 Streaming (M11): one loop per account in `MailStreamer`. Subscribe, then
  `GetStreamingEvents` for 29 minutes over a second URLSession with a 35-minute idle timeout that
  shares the in-memory cookie jar (a load-balanced Exchange pins the subscription by cookie).
  A rejected password PARKS the account (no retries until it is edited): every retry is a failed
  logon against the domain lockout counter. Same EWS URL as everything else; no new host.
- 2026-09-24 Notifications (M7): the first poll per account after launch is a silent baseline,
  ids seen are kept in memory only, and each notification is withdrawn when its message is read,
  archived or deleted anywhere. macOS stores delivered notifications on disk in Notification
  Center; that is outside this app's control, which is why the details switch exists.
- 2026-09-24 Attachments (M9) are the one sanctioned exception to "nothing on disk": Open writes
  the file to `<tmp>/Mailbar Attachments/<uuid>/` (0700 folder, 0600 file) because another app can
  only open a file, and the folder is deleted at quit and again at launch. Save writes where the
  user picks. Bytes are fetched only when one of the two is pressed.
- 2026-09-24 Search (M8) is server-side: `QueryString` (the server index Outlook uses) on 2013+,
  a subject-or-body substring restriction on older servers. Results are in memory, the
  selected account only, dropped when the popover closes. Actions on a result update it.
- 2026-09-24 Remote images: blocked by a Content-Security-Policy written before the message's own
  markup (`ReaderHTML`), plus JS off and a non-persistent data store in the web view.
  `NSAllowsArbitraryLoadsInWebContent` is on so that "Load images" also works for plain-http
  images, which ATS would otherwise refuse silently; it affects web content only, and EWS itself
  stays HTTPS-only.
- 2026-09-24 The reader closes when the popover closes, so a body and its images are never kept
  in a hidden view. The one question the app asks about the mailbox (create an Archive folder?)
  is an inline banner, not an alert, which an `NSPopover` presents badly.
- 2026-09-24 Bundle id `in.pooya.mailbar`, Debug `in.pooya.mailbar.debug`. Keychain service
  `in.pooya.mailbar.account`, defaults prefix `mailbar.`. These are storage addresses: renaming
  strands the stored passwords and settings.

## Privacy (local-first)
No telemetry, no analytics. Network calls, exhaustively:
- Each configured account's EWS URL (mail and, since M15, the calendar: same URL, same sign-in).
- While adding an account, and only when the user presses Sign In: Autodiscover at
  `https://autodiscover.<email domain>/autodiscover/autodiscover.xml`, then
  `https://<email domain>/autodiscover/autodiscover.xml`. HTTPS only; no HTTP redirect method and
  no DNS SRV lookup.
- Remote images inside a message, only when the user clicks "Load images" for that message.

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
  after "Load images").
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
Releases are cut with the `release` skill.

## Working style
- Read this file first, the Scope section above all, then `PLAN.md`.
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
