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

- [ ] `project.yml` (bundle id `in.pooya.mailbar`, Debug `.debug`, macOS 14, `LSUIElement`)
- [ ] Source tree: `Mailbar/{App,Accounts,EWS,Core,Views,Resources}`, `MailbarTests/`
- [ ] `git init`, first commit
- [ ] Placeholder status item, no Dock tile

Proof: `open` the built app, an icon in the menu bar, nothing in the Dock.

---

## M1. Accounts, Keychain, first EWS call
Model: Opus 5.5 with thinking. Secrets, the auth challenge, and keeping passwords out of logs.

- [ ] `Account` model (UUID, description, full name, email, EWS URL, user name), list stored in
      UserDefaults, no secret fields
- [ ] `KeychainStore`: one password per account UUID, service `in.pooya.mailbar.account`
- [ ] `EWSClient`: ephemeral `URLSession`, delegate answers NTLM and Basic challenges
- [ ] `GetFolder inbox` returns `UnreadCount`; read `ServerVersionInfo` and record the version
- [ ] If the server is older than Exchange 2013: preview comes from a truncated text body and the
      flag uses the extended property `PidTagFlagStatus` (0x1090)
- [ ] Settings window, Accounts pane: list, "+" opens the add sheet, "-" deletes (with confirm,
      removes the Keychain item too), a Test button showing the unread count or the exact failure
- [ ] Unit tests: SOAP builders against fixtures, Keychain round trip on a throwaway service

Proof: add the real account, Test shows the true unread count. Quit, relaunch, Test again with no
re-typing. `defaults read in.pooya.mailbar` contains no password.

---

## M2. Menu bar count and polling
Model: Sonnet 5 for wiring, Opus 5.5 for the icon (`menubar-icon-theming` skill).

- [ ] `NSStatusItem` plus `NSPopover`, centred under the icon
- [ ] Icon plus unread count, legible in light, dark, template and colour
- [ ] `Poller`: every couple of minutes, on popover open, and after wake from sleep
- [ ] Unreachable and rejected are states on the icon, not a silent zero

Proof: mark a message read in Outlook Web or on the phone, the count drops within one poll.

---

## M3. Inbox list
Model: Opus 5.5. The row is the whole product; the failure split is easy to collapse.

- [ ] `FindItem` 50 newest, then `SyncFolderItems` for changes, all in memory only
- [ ] Row: sender, subject plus relative time, one-line preview, unread weight, flag marker
- [ ] Relative time formatter with unit tests (today, yesterday, 2 to 6 days, older, time zones)
- [ ] Per-string text direction for Persian and mixed text
- [ ] Unreachable, rejected and empty states, each with its own view and action
- [ ] `MAILBAR_MOCK=1` fixtures with invented senders, Persian and English
- [ ] Multi-account header, per open question 1

Proof: `mac-qc` screenshot of the list next to Outlook's, Persian rows right-aligned.

---

## M4. Reader
Model: Opus 5.5. WebView sandboxing and the no-cache rule.

- [ ] `GetItem` HTML body in a `WKWebView`: JS off, `nonPersistent()` data store, remote loads
      blocked until "Load images" for that message
- [ ] Inline `cid:` images fetched into memory and dropped on close, never written anywhere
- [ ] Opening marks read (`UpdateItem`, read receipts suppressed)
- [ ] Push from the list, swipe right to go back (osx-jirabar pattern)

Proof: open a newsletter, no network request to its image hosts until "Load images". After closing,
`~/Library/Caches` and `~/Library/WebKit` hold nothing for the bundle id.

---

## M5. Actions
Model: Sonnet 5, with permission before touching real mail.

- [ ] Mark unread, flag or unflag, archive, delete, from the reader toolbar and the row
      (hover buttons plus a context menu)
- [ ] Delete is `MoveToDeletedItems` only
- [ ] Archive moves to the folder settled in open question 2
- [ ] `ChangeKey` conflict: refetch and retry once
- [ ] Optimistic update in the list, rolled back with an error if the server refuses

Proof: in mock mode, each action updates the list. Against the real mailbox, only on a message the
user names.

---

## M6. QC and v1 sign-off
- [ ] Every item in `AGENTS.md` "Definition of done" checked, with a screenshot where it is visual
- [ ] Idle memory under 60 MB after an hour
- [ ] The user uninstalls Outlook
