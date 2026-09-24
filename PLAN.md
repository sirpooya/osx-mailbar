# PLAN.md: Mailbar

The milestones. Scope (what is wanted and what is not) lives in `AGENTS.md`, Scope. A milestone is
done when its proof is observable, not when the code compiles.

---

## M0 to M6: v1 (done 2026-09-24)
Scaffold, accounts and Keychain, menu bar count and polling, Outlook-style inbox list, reader,
actions, sign-off checks. All proven in mock mode; the details and the evidence are in git history
and in AGENTS.md, Status.

---

## M7. New-mail notifications (done 2026-09-24)
- [x] A notification per new unread message, up to four, then one summary
- [x] First poll after launch is a silent baseline; seen ids in memory only
- [x] Click opens the popover on that message
- [x] Withdrawn when the message is read, archived or deleted, here or elsewhere
- [x] Settings: on or off, and sender and subject or account name only

Proof so far: unit tests (NewMailTracker). **Not yet seen as a real banner**: that needs mail to
arrive on the real account.

## M8. Search (done 2026-09-24)
- [x] Field under the header, Cmd+F; searches the server 350 ms after typing stops
- [x] `QueryString` on Exchange 2013+, substring restriction on older servers
- [x] Results use the same rows; open, flag, archive and delete work on them

Proof: mock screenshot ("design" finds the one match), request-shape and store tests.

## M9. Attachments (done 2026-09-24)
- [x] Chips under the reader header: icon, name, size
- [x] Click opens in the default app via a private temporary copy, cleared at quit and launch
- [x] Right-click, Save As
- [x] Images drawn in the body are not listed as attachments

Proof: mock screenshot of the chip, attachment bytes test. Opening a real attachment is untried.

## M10. Launch at login (done 2026-09-24)
- [x] `SMAppService.mainApp`, a switch in Settings, General, showing what macOS actually did

Proof: switch photographed. Toggling it is the user's, from the installed app.

---

## M11. Instant new mail: EWS streaming notifications
- [ ] `Subscribe` (streaming) to the inbox, `GetStreamingEvents` held open, at most 30 min per call
- [ ] On NewMail, Modified, Moved or Deleted: refresh that account straight away
- [ ] Reconnect after the connection lapses, after wake, and after the VPN comes back; keep the
      poll as a slow fallback (every 10 minutes) in case the subscription dies quietly
- [ ] Exchange 2010 SP1 or later only; older servers keep polling

Proof: a message sent to the account shows in the menu bar within seconds, not minutes.
