# Outlook for Mac: feature map for Mailbar

Source: the installed `/Applications/Microsoft Outlook.app`, version 16.78 (build 23100802, 2023),
read with REA and plain file inspection on 2026-11-16. Evidence: Info.plist (REA
`ev_0cd98f86...`), the English menu strings (`DocumentMenus`, `ViewMenus`, `OutlookApp`,
`MessageListView`), the Preferences pane strings, `Outlook.sdef` (AppleScript commands), the
bundled nibs and the `CalendarWidgetExtension.appex`. This is what Outlook *ships*, not what it
was observed doing; nothing was run.

A deeper pass (about 400 features with evidence, the EWS operation inventory, local data before
deleting Outlook, and web research on other EWS clients) lives in the gitignored
`_samples/outlook-re/`: `feature-catalog.md`, `ews-inventory.md`, `local-data.md`,
`web-research.md`. Note: Snooze, Pin, reactions, Focused Inbox and Copilot belong to the "new
Outlook" engine, which never ran against on-prem Exchange; Outlook also never uses EWS
`ReplyToItem`/`ReplyAllToItem` (it builds replies itself), so Mailbar's use of them is unproven.

Legend: **Have** = Mailbar does it. **Build** = fits Mailbar, with the EWS call. **Out** = excluded
by the AGENTS.md Scope today (listed so you can change your mind).

## 1. Top picks (most value for a menu-bar reader)

| # | Feature | Outlook evidence | EWS route | Effort |
|---|---|---|---|---|
| 1 | Undo Send (hold a sent message a few seconds) | Edit menu "Undo Send" | Local delay before `CreateItem`/`ReplyToItem` | S |
| 2 | Schedule Send / Delay Send | "Schedule Send", `SendLater` sheet | `CreateItem` with `PidTagDeferredSendTime` (0x3FEF) | M |
| 3 | Automatic Replies (out of office) | `OLAutoreplyDialog`, sdef `set autoreply data` | `GetUserOofSettings` / `SetUserOofSettings` | M |
| 4 | MailTips while writing (outside recipients, their auto-replies, large groups) | compose infobars, `GetMailTips` | `GetMailTips` (2010+) | M |
| 5 | Mark All as Read | "Mark All as Read" | `MarkAllItemsAsRead` (2013+) or batched `UpdateItem` | S |
| 6 | Swipe gestures on rows | Viewing pane: "Swipe Left/Right Action" (Archive, Delete, Flag, Mark as Read) | Existing actions | S |
| 7 | Conversations (threads) | "Show as Conversations", "Expand only one conversation" | `FindConversation`, `GetConversationItems` | L |
| 8 | Block sender / Mark as Junk | "Block Sender", "Mark as Junk/Not Junk", Junk pane | `MarkAsJunk` (2013+) | S |
| 9 | Ignore Conversation | "Ignore Conversation", "Stop Ignoring" | `ApplyConversationAction` Always Delete | S |
| 10 | Follow-up flag with due date (Today, Tomorrow, This Week, Next Week) | `SetToDoMenu` | `UpdateItem` `item:Flag` StartDate/DueDate | S |

## 2. Mail list and reading

- Have: Inbox, Sent, Flagged, Archive, Deleted, Junk; unread bold; preview line; attachment clip; search; RTL.
- Build: Focused / Other split (Outlook "Switch to Focused/Other"): needs Exchange Online's
  inference; on-prem has no Focused classifier, so **skip**.
- Build: "Mentions (@)" filter (Outlook list filter): `QueryString` "to:me" or body contains your name. S.
- Build: filters "Unread", "Flagged", "Has attachments", "To me" (ViewMenus "Filter By"). `Restriction`. S.
- Build: sort by Date, From, Size, Subject, Priority (MessageListView columns). `SortOrder`. S.
- Build: priority icon (High/Low) on rows. `item:Importance`. S.
- Build: display density Compact / Cozy / Roomy (ViewMenus "Display Density"). S.
- Build: show sender photo on rows ("Show Sender Image"). `GetUserPhoto` or directory photo, memory only. S.
- Build: group headers by date ("Show Messages in Groups"). S.
- Build: "View Source" (MessageListView). `GetItem` `item:MimeContent`. S.
- Build: Undelete from Deleted Items ("Undelete"). `MoveItem` back to Inbox. S.
- Build: Quick reply field inside the reader (Outlook's newer inline reply). S.
- Build: Print a message ("Print..."). WKWebView print. S.
- Build: Read receipts honoured or ignored (Outlook "Request a Read Receipt"). Currently suppressed; keep.
- Build: Actionable messages / cards (`OLActionableMessage.js`, `cardRenderHelper_mac.js`). Needs JS; **skip** (JS off is a rule).
- Out: Move to folder, Copy to folder, folder tree, custom folders, public folders, shared mailboxes,
  other user's folder ("Other User's Folder...", "Shared Mailbox...", "Public Folders...").
- Out: Categories on mail ("Categorize"), Pin, Rules.

## 3. Composing and sending

- Have: reply, reply all, forward, new; plain text; RTL; recipient suggestions; groups with Expand.
- Build: Undo Send, Schedule Send (see top picks).
- Build: Forward as Attachment ("Forward As Attachment"). `CreateItem` with an `ItemAttachment`. M.
- Build: Redirect / Resend ("Redirect", "Resend"). M.
- Build: Bcc field and "Automatically copy myself" (Composing pane). S.
- Build: Importance High / Low ("Priority"). `item:Importance` on `CreateItem`. S.
- Build: Request delivery / read receipt. `IsDeliveryReceiptRequested`, `IsReadReceiptRequested`. S.
- Build: Check Names ("Check Names...", `OLCheckNamesWindow`). Already `ResolveNames`; show unresolved in red. S.
- Build: Reply to selected text only ("Only reply to selected text"). S.
- Build: Spelling check (macOS native in the text view). S.
- Build: `mailto:` handler (Info.plist `CFBundleURLTypes` mailto). Opens the composer. S.
- Out: Signatures, rich text / HTML formatting, outgoing attachments, drafts, templates (`.emltpl`),
  S/MIME sign and encrypt, IRM permissions ("Restrict Permissions"), Loop components.

## 4. Calendar

- Have: Day / Week / Month, create / edit / delete, invitations, propose new time, Scheduling
  Assistant, rooms, reminders, Today tab, work hours, time zone, categories, charms.
- Build: Work Week and Three Day views (ViewMenus). Work Week was declined in AGENTS.md; Three Day is new. S.
- Build: Second (and third) time zone column in Day and Week (Calendar pane, "Add a Time Zone..."). M.
- Build: Week numbers ("Show week numbers"). S.
- Build: Time scale 5 / 10 / 15 / 30 / 60 min (ViewMenus "Time Scale"). S.
- Build: Shorten meetings (end 5 or 10 min early, "Shorten duration for all events"). S.
- Build: "Allow attendees to propose another time" default (Calendar pane). Already a per-event toggle. S.
- Build: Reply / Reply All / Email all attendees from an event ("New Email to Attendees"). S.
- Build: Forward an event ("Forward Event", "Forward Series"). `ForwardItem` on the calendar item. S.
- Build: Cancel series vs occurrence, edit the series ("All events in the series"). M.
- Build: View all proposals on your meeting ("View All Proposals"). M.
- Build: Open a shared calendar ("Shared Calendar...", `OLCalendarPermissions`). `FindItem` on another
  mailbox's `calendar`. M.
- Build: Overlay several calendars ("Overlay"). M.
- Build: Weather on the calendar (`OLWeatherView`). Needs an outside service; **skip** (privacy rule).
- Build: Open `.ics` files (Info.plist document type). Parse and offer "Add to Calendar". M.
- Out: Teams / Skype online meeting creation (needs Microsoft 365).

## 5. Menu bar, notifications, system integration

- Have: unread count, notifications with sender and preview, launch at login, Today tab.
- Build: **macOS widget** for the next meetings (Outlook ships `CalendarWidgetExtension.appex`,
  a WidgetKit extension). M.
- Build: **Focus filter** (Info.plist `INShareFocusStatusIntent`, "Outlook will silence notifications"):
  a Focus filter that picks which accounts notify. M.
- Build: Notification sounds per event: new mail, sent, reminder (Notifications pane "Sound set"). S.
- Build: Badge choice: all unread vs only Inbox (Notifications pane "Badge count"). S.
- Build: Notification actions: Mark as Read, Archive, Delete from the banner. S. (Reminders stay plain by rule.)
- Build: Handoff / Spotlight user activities (`com.microsoft.Office.Outlook.view.mail`). M.
- Build: AppleScript or Shortcuts actions (Outlook's sdef has send, reply, search, accept meeting,
  query free/busy, set autoreply). App Intents for "Unread count", "Next meeting", "Send message". M.
- Build: Open `.eml` files in the reader (Info.plist `.eml` editor role). S.
- Build: Services menu "Send selection by Mailbar". S.

## 6. Account and mailbox tools

- Have: add / edit / test / delete, Autodiscover, Keychain.
- Build: Password expiry warning (sdef `query password expiration`). `GetPasswordExpirationDate` (2010 SP2+). S.
- Build: Mailbox size and quota (sdef `query folder size`). `GetFolder` `PidTagMessageSize` / extended props. S.
- Build: Empty Deleted Items / Empty Junk ("Delete All", "Permanently Delete"). `EmptyFolder`. S.
  Note: AGENTS.md forbids HardDelete in actions; this would need your explicit OK.
- Build: Delegates (sdef `get/add/update delegate users`). `GetDelegate`, `AddDelegate`. L, low value.
- Build: Sync status / error log window ("Sync Errors", `ErrorLogWindow`). Show the last failures. S.
- Build: Offline address book download (sdef `download oab now`). **Skip** (no cache rule).
- Out: Import / export `.olm` `.pst`, On My Computer folders, IMAP / POP / LDAP accounts, Work Offline.

## 7. People, tasks, notes

- Have: contact cards from `ResolveNames` and the directory; groups.
- Out: Contacts editing, contact lists, Tasks ("Task List", `TaskEditorView`), Notes, To Do pane.
  If ever wanted: tasks are `FindItem` on `tasks`, and flagged mail already doubles as a to-do list.

## 8. Explicitly not worth copying

Ribbon and toolbar customization, text encodings menu, themes ("Classic / Colorful"), Copilot / AI
features, add-ins (`osf`, Agave), Microsoft 365 groups, Intune policies, telemetry and feedback,
"Revert to Legacy Outlook".
