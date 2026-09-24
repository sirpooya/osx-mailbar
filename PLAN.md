# PLAN.md: Mailbar

What is in and what is out, then the milestone order. Nothing in a later milestone starts before the
milestone above it is observable on screen or against the server. Check boxes as they land; the
"Proof" line is what counts as done, not "the code compiles".

---

## Scope

### Wanted (v1)
- **Accounts in Settings**: add, test, delete. Several accounts allowed. Fields mirror Outlook's
  Exchange account sheet: account description, full name, email address, EWS server URL, user
  name, password. Nothing prefilled.
- **Menu bar**: icon plus inbox unread count.
- **One view, the Inbox.** No other folders.
- **Outlook-style rows**: sender (bold while unread), subject with the relative time on the right
  (`14:32`, `Yesterday`, `2 days ago`, then a short date), one line of preview.
- **Read a message** in the popover: HTML rendered safely, no JavaScript, remote images off until
  "Load images".
- **Opening marks it read.** Mark read and mark unread by hand too.
- **Three actions**: flag or unflag, archive, delete (to Deleted Items).
- **Right-to-left** handled per string, for Persian mail.
- **Honest failure states**: server unreachable, password rejected, and empty inbox are three
  different screens.
- **No cache**: nothing from the mailbox on disk, images cached nowhere (see `AGENTS.md`).

### Not wanted (do not build)
- Sending of any kind: compose, reply, reply all, forward, drafts.
- Move to folder, folder list, folder picker.
- Follow up, categories, rules, junk, snooze, pin.
- Calendar, contacts, tasks, notes, directory (LDAP) lookup.
- Offline mode, local search index, any disk cache.

### Maybe later (not v1, ask before starting)
- New-mail notification, click to open that message.
- Search within the inbox.
- Opening or saving attachments.
- Launch at login.
- EWS streaming notifications instead of polling.
- Autodiscover (fill the EWS URL from the email address).

---

## Open questions (answer before the milestone that needs it)
1. **Several accounts, one popover** (M3): one account per view with a header dropdown and swipe
   between them, the osx-jirabar way, or one merged inbox? Default until told otherwise: one view
   per account, and the menu bar count is the total.
2. **Where archive goes** (M5): Outlook for Mac's Archive button moves mail to a folder named
   `Archive` in the mailbox. Confirm that folder exists on this mailbox. If it does not, ask before
   the app creates one.
3. **User name format** (M1): short name, `DOMAIN\name` or `name@domain`. Settled by testing, not
   by asking; recorded in `AGENTS.md` once known.

---

## M0. Scaffold
Model: Sonnet 5. Template filling and one `xcodegen` run.

- [x] `project.yml` (bundle id `in.pooya.mailbar`, Debug `.debug`, macOS 14, `LSUIElement`)
- [x] Source tree: `Mailbar/{App,Accounts,EWS,Core,Views,Resources}`, `MailbarTests/`
- [x] `git init`, first commit
- [x] Placeholder status item, no Dock tile

Proof: `open` the built app, an icon in the menu bar, nothing in the Dock.

---

## M1. Accounts, Keychain, first EWS call
Model: Opus 5.5 with thinking. Secrets, the auth challenge, and keeping passwords out of logs.

- [x] `Account` model (UUID, description, full name, email, EWS URL, user name), list stored in
      UserDefaults, no secret fields
- [x] `KeychainStore`: one password per account UUID, service `in.pooya.mailbar.account`
- [x] `EWSClient`: ephemeral `URLSession`, delegate answers NTLM and Basic challenges
- [x] `GetFolder inbox` returns `UnreadCount`; read `ServerVersionInfo` and record the version
- [x] If the server is older than Exchange 2013: preview comes from a truncated text body and the
      flag uses the extended property `PidTagFlagStatus` (0x1090)
- [x] Settings window, Accounts pane: list, "+" opens the add sheet, "-" deletes (with confirm,
      removes the Keychain item too), a Test button showing the unread count or the exact failure
- [x] Unit tests: SOAP builders against fixtures, Keychain round trip on a throwaway service

Status 2026-09-24: built and proven in mock mode. **The real-account proof is still open** and is
the user's to run, since it needs their password.

Proof: add the real account, Test shows the true unread count. Quit, relaunch, Test again with no
re-typing. `defaults read in.pooya.mailbar` contains no password.

---

## M2. Menu bar count and polling
Model: Sonnet 5 for wiring, Opus 5.5 for the icon (`menubar-icon-theming` skill).

- [x] `NSStatusItem` plus `NSPopover`, centred under the icon
- [x] Icon plus unread count, legible in light, dark, template and colour
- [x] `Poller`: every couple of minutes, on popover open, and after wake from sleep
- [x] Unreachable and rejected are states on the icon, not a silent zero

Status 2026-09-24: count and dimmed-on-failure icon built; count proven by screenshot in mock
mode. The dimmed icon is unverified by pixels, and the proof below needs the real account.

Proof: mark a message read in Outlook Web or on the phone, the count drops within one poll.

---

## M3. Inbox list
Model: Opus 5.5. The row is the whole product; the failure split is easy to collapse.

- [x] `FindItem` 50 newest plus `GetFolder` for the count on every poll, all in memory only
      (not `SyncFolderItems`: see AGENTS.md, Decisions)
- [x] Row: sender, subject plus relative time, one-line preview, unread weight, flag marker
- [x] Relative time formatter with unit tests (today, yesterday, 2 to 6 days, older, time zones)
- [x] Per-string text direction for Persian and mixed text
- [x] Unreachable, rejected and empty states, each with its own view and action
- [x] `MAILBAR_MOCK=1` fixtures with invented senders, Persian and English
- [x] Multi-account header, per open question 1

Status 2026-09-24: done in mock mode; list, loading, unreachable and rejected photographed.
Open question 1 was taken at its default: one view per account, a menu in the title, and a swipe.

Proof: `mac-qc` screenshot of the list next to Outlook's, Persian rows right-aligned.

---

## M4. Reader
Model: Opus 5.5. WebView sandboxing and the no-cache rule.

- [x] `GetItem` HTML body in a `WKWebView`: JS off, `nonPersistent()` data store, remote loads
      blocked by a Content-Security-Policy until "Load images" for that message
- [x] Inline `cid:` images fetched into memory and dropped on close, never written anywhere
- [x] Opening marks read (`UpdateItem`, read receipts suppressed on 2013 and later)
- [x] Push from the list, swipe right to go back (osx-jirabar pattern); closing the popover closes
      the message too, so its body is released

Status 2026-09-24: done in mock mode. The pixel proof was run for real: the mock's tracking pixel
pointed at a local HTTP server, which logged **nothing** with images blocked and **one GET** with
them allowed (the positive control). The swipe back is built but unverified: synthetic input needs
the Accessibility grant.

Proof: open a newsletter, no network request to its image hosts until "Load images". After closing,
`~/Library/Caches` and `~/Library/WebKit` hold nothing for the bundle id.

---

## M5. Actions
Model: Sonnet 5, with permission before touching real mail.

- [x] Mark unread, flag or unflag, archive, delete, from the reader toolbar and the row
      (hover buttons plus a context menu)
- [x] Delete is `MoveToDeletedItems` only
- [x] Archive moves to the top-level `Archive` folder. Open question 2 settled in-app: when the
      mailbox has none, nothing moves and a banner asks "Create and Archive" or "Cancel"
- [x] ~~`ChangeKey` conflict: refetch and retry once~~ Not needed: writes omit the change key and
      use `AlwaysOverwrite`, since setting one field is idempotent (AGENTS.md, Decisions)
- [x] Optimistic update in the list, rolled back with an error banner if the server refuses; a poll
      already in flight cannot undo an action on screen

Status 2026-09-24: done in mock mode, end to end against the stateful mock server (ActionTests).
**Nothing has been tried on the real mailbox**, by rule: that needs a message the user names.

Proof: in mock mode, each action updates the list. Against the real mailbox, only on a message the
user names.

---

## M6. QC and v1 sign-off
- [x] Every item in `AGENTS.md` "Definition of done" checked, with a screenshot where it is visual
      (see the list there for which are mock-only)
- [x] Idle memory under 60 MB: 54 MB footprint for the Debug build, idle with the popover closed
      after reading a message with images loaded. Not yet measured over a full hour
- [ ] The user adds the real account and presses Test (the one step Claude cannot do)
- [ ] The user uninstalls Outlook
