# AGENTS.md: Mailbar (macOS menu-bar mail reader for on-prem Exchange)

## Goal
A lightweight menu-bar mail reader for my work mailbox, which lives on an on-premises Microsoft
Exchange server reached over EWS. It shows the inbox unread count in the menu bar and one list, the
Inbox, in a popover, styled like Outlook's message list. I can open a message, and mark it read or
unread, flag it, archive it or delete it. Nothing else.

It replaces keeping `/Applications/Microsoft Outlook.app` (about 2 GB, always running) open all day,
so the user can delete Outlook.

**Read only, v1.** No sending, no reply, no forward, no compose, no calendar, no contacts.
`PLAN.md` holds the exact in-scope and out-of-scope lists; it wins over anything vaguer here.

Keep it minimal and dependency-light. No cloud sync, no analytics.

## Status
2026-09-24: repo created. `AGENTS.md`, `PLAN.md` and `.gitignore` exist; no code yet.
Next: milestone M0 in `PLAN.md`.

2026-09-24: the first draft of this file assumed Microsoft 365 plus Graph plus OAuth. That was
wrong. The user's Outlook for Mac account settings show an on-prem Exchange account using EWS with
"User Name and Password" authentication. Graph, Entra ID app registrations and OAuth do not apply,
and the "confirm with IT" blocker that came with them is gone.

## The mail server (ESTABLISHED from the user's Outlook settings, do not re-research)
Context only. **None of this is hardcoded in the app, not even as a placeholder or a default.** The
user types every value into Settings when adding an account.

- Account type in Outlook for Mac: "Microsoft Exchange". Email domain `<company domain>`.
- EWS endpoint: `https://<mail host>/ews/exchange.asmx`, port 443, SSL on. This is what
  Outlook uses; the app talks to this same URL.
- Auth method in Outlook: "User Name and Password", user name in short form (no domain, no `@`).
  On-prem Exchange serves this as NTLM or Basic over HTTPS; `URLSession` answers either challenge.
  Whether the server wants `DOMAIN\user`, the short name or the UPN is **unproven**; M1 settles it.
- Directory service: `<directory server>:3268`, an Active Directory Global Catalog (LDAP, no
  SSL). Outlook uses it for address lookup when composing. **This app does not use it**: no compose,
  so no address lookup. Do not add an LDAP client.
- Message content is frequently Persian. Every text field (sender, subject, preview, body) needs
  per-string natural direction, right to left when the text is RTL. osx-jirabar's
  `Core/TextDirection.swift` is the pattern.
- The host may be internal-only. Treat "cannot reach server" as its own state ("Are you on the
  VPN?"), never as an empty inbox.
- Exchange version: unknown. Read `ServerVersionInfo` from the first SOAP response header. `Preview`
  and `Flag` need Exchange 2013 or later; `PLAN.md` M1 has the fallback if it is older.

## EWS operations, exhaustively
SOAP 1.1 POSTs to the account's EWS URL, `Content-Type: text/xml; charset=utf-8`, with a
`RequestServerVersion` header (start at `Exchange2013`).

| What | Operation |
|---|---|
| Verify an account in Settings | `GetFolder` on distinguished `inbox` |
| Unread count | `GetFolder` on `inbox`, read `UnreadCount` |
| Inbox list | `FindItem` Shallow on `inbox`, `IndexedPageItemView` of 50, sorted `DateTimeReceived` descending, properties `item:Subject`, `message:From`, `item:DateTimeReceived`, `message:IsRead`, `item:Flag`, `item:Preview`, `item:HasAttachments` |
| What changed since the last poll | `SyncFolderItems` on `inbox` with the stored `SyncState` |
| Open a message | `GetItem`, `BodyType` HTML |
| Mark read or unread | `UpdateItem` `SetItemField message:IsRead`, `ConflictResolution="AutoResolve"`, `SuppressReadReceipts="true"` |
| Flag or clear flag | `UpdateItem` `SetItemField item:Flag`, `FlagStatus` `Flagged` or `NotFlagged` |
| Delete | `DeleteItem` `DeleteType="MoveToDeletedItems"`. **Never** `HardDelete` or `SoftDelete` |
| Archive | `MoveItem` to the mailbox's Archive folder, found once with `FindFolder` (see `PLAN.md` open questions) |

Every item carries an `ItemId` plus `ChangeKey`. `UpdateItem` needs the current `ChangeKey`; on
`ErrorIrresolvableConflict`, refetch the item and retry once.

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
Run: quit the running app first, then `open` the built bundle. Replacing the bundle under a
running process invalidates its code signature.

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
- 2026-09-24 `LSUIElement: true`; the app never shows in the Dock except while a real titled
  window (Settings) is open.
- 2026-09-24 Settings is an `NSWindow` this app owns, built from `SettingsComponents.swift`
  (mac-pro skill), not a SwiftUI `Settings` scene.
- 2026-09-24 Polling, not push, for v1: `SyncFolderItems` every couple of minutes and whenever the
  popover opens, so a poll only moves what changed. EWS streaming notifications could replace this
  later without a webhook, but polling is simpler and enough.
- 2026-09-24 Bundle id `in.pooya.mailbar`, Debug `in.pooya.mailbar.debug`. Keychain service
  `in.pooya.mailbar.account`, defaults prefix `mailbar.`. These are storage addresses: renaming
  strands the stored passwords and settings.

## Privacy (local-first)
No telemetry, no analytics. Network calls, exhaustively:
- Each configured account's EWS URL, and nothing else.
- Remote images inside a message, only when the user clicks "Load images" for that message.

Passwords live only in the Keychain. Never log a password, an `Authorization` header or a message
body, not even in DEBUG.

## Caching (the user's rule, 2026-09-24: never cache anything)
**Nothing from the mailbox is ever written to disk.** No database, no file cache, no URL cache, no
WebKit cache, no thumbnails, no "offline" mode.
- The only thing kept even in memory between polls is the list data: sender, subject, preview,
  time, read and flag state, and the `ItemId`/`ChangeKey` needed to act on it. It dies with the
  process.
- A message body lives in memory only while its reader is open, and is dropped when it closes.
- **Images are never cached anywhere**, memory or disk: not remote images, not inline `cid:`
  images, not sender photos. Each time a message opens they are fetched again (and remote ones only
  after "Load images").
- `URLSession` uses `URLSessionConfiguration.ephemeral` with `urlCache = nil`.
  `WKWebView` uses `WKWebsiteDataStore.nonPersistent()`, one store per reader, released on close.
- The `SyncFolderItems` sync state is a server cursor, not mail content; it may sit in memory only
  and is simply rebuilt at launch.

## Reference material and QC
- `_samples/`: screenshots of the reference look, when supplied. Where this doc is ambiguous, the
  screenshot wins. The first reference is Outlook for Mac's message list row (sender, subject with
  time, one-line preview).
- Screenshot-QC every significant surface with the `mac-qc` skill before calling it done.
- QC hooks: `MAILBAR_MOCK=1` serves canned EWS responses (including Persian and mixed-direction
  messages) so the UI can be exercised without an account.

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
- Read this file and `PLAN.md` first. Follow the milestone order in `PLAN.md`.
- Never hardcode the user's data: no server URL, user name, email or name in code, fixtures,
  placeholders or defaults. Mock fixtures use invented names and `example.com`.
- Never delete, archive, flag or change the read state of real mail during testing without
  explicit permission. Use `MAILBAR_MOCK=1` or a message the user names. Reading the inbox list
  is fine.
- Never send mail. The app has no code path that can.
- Never quit or modify the user's Outlook install.
- Commit in small, working increments. Explain any deviation from this spec.
- Ask before adding any external dependency.
- No em dashes: prose, code comments, commit messages.

## Definition of done (v1)
- [ ] Accounts can be added, tested and deleted in Settings; passwords survive relaunch and reboot.
- [ ] Menu bar shows the inbox unread count, updated within one poll interval.
- [ ] The Inbox list matches the Outlook row layout, including right-to-left Persian text.
- [ ] A message opens, renders safely (no JS, no remote images by default) and is marked read.
- [ ] Mark unread, flag, archive and delete work from the reader and from the row.
- [ ] Unreachable server, rejected password and empty inbox each show their own state.
- [ ] Nothing from the mailbox on disk: after a session, `~/Library/Caches`, `~/Library/WebKit`
      and the app container hold no message text or images for the app's bundle id.
- [ ] Idle memory under 60 MB.
