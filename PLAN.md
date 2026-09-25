# PLAN.md: Mailbar calendar

The calendar feature, from the user's OWA screenshots (2026-09-25). Scope and the rules every
milestone keeps live in `AGENTS.md`; milestones M0 to M14 are done and recorded there. A milestone
is done when its proof is observable, not when the code compiles.

Same data path as mail: the calendar lives on the same Exchange server and is read and written
over the same EWS URL and credentials. No new host, no new sign-in, no library.

**Why no library:** checked 2026-09-25. KVKCalendar (the fullest) is UIKit and reaches the Mac
only through Catalyst, not a native AppKit app like this one; swift-week-view and CalendarKit are
iOS; GECalendar and Mijick's CalendarView are date pickers, not event timelines. A week grid in
SwiftUI is a few hundred lines; a dependency would need the user's approval and would not fit.

Testing rules, as for mail: build and prove against `MAILBAR_MOCK`, which serves an invented week
of events. **Never create, change, cancel or answer a real event** unless the user names it.
Creating an event with attendees sends real invitations.

---

## Decisions (taken at the recommended defaults on 2026-09-25, when the user said "build it now"; change any of them)

1. **Where the calendar lives.** Recommended: its own resizable window, opened from a new
   "Calendar" item in the tray icon's right-click menu, with room for the week grid. Alternatives:
   a Mail | Calendar tab in the popover (380 pt wide, fits a day list only), or both (the window,
   plus a small Today list in the popover).
2. **People suggestions when inviting.** The screenshots show the company directory. `AGENTS.md`
   rules out LDAP; Exchange can search the directory itself with EWS `ResolveNames` (no LDAP
   client, same server). Recommended: allow `ResolveNames`, plus inbox senders.
3. **Rooms.** Recommended: a room picker from Exchange's room lists (`GetRoomLists`, `GetRooms`),
   with free-text location always possible. Alternative: free text only.
4. **Charm and Categorize.** Recommended: out, as they are out for mail. The scheduling assistant
   is out (crossed off in the screenshot).

---

## M15. See the calendar (done 2026-09-25)
- [x] Views: Day, Work week, Week, Month, with Today and previous/next, as in OWA
- [x] The week starts Saturday; work week is Saturday to Wednesday; Thursday and Friday shaded;
      working hours shaded, the rest dimmed (read from the server's working hours when available)
- [x] Events as blocks by time, overlaps side by side; all-day events in a strip at the top;
      recurring icon; Persian titles and locations right to left
- [x] EWS `FindItem` with a `CalendarView` (start, end) on the `calendar` folder, which expands
      recurrences server side; only the visible range is fetched, in memory only
- [x] Click an event: subject, time, location, organizer, attendees with their responses, notes
      (HTML shown with the reader's rules: no JS, remote images blocked)
- [x] Refreshed by the M11 stream (subscribe to `calendar` as well) and on window focus

Proof: mock Week, Month, Day and the detail panel photographed; the Persian title runs right to
left and truncates at its left end (full-resolution crop); 107 tests, among them the overlap
layout, Saturday weeks and fetching through the mock server. Working hours are the Settings
defaults (9 to 17), not yet read from the server. **Not yet seen with the real calendar.**
Found and fixed on the way: switching from Month to another view crashed (the month grid indexed
six weeks of a seven-day list).

## M16. Create, edit, delete
- [ ] New event: title, location or room, start and end, all day, private, repeat (never, daily,
      weekly, monthly, yearly), reminder, show as (busy, free, tentative, away), plain notes, people
- [ ] Double-click an empty slot to start one at that time
- [ ] EWS `CreateItem` `CalendarItem`: `SendToNone` with no attendees, `SendToAllAndSaveCopy`
      with attendees (that is the invitation)
- [ ] Edit with `UpdateItem` (`SendToChangedAndSaveCopy` for meetings); delete with `DeleteItem`,
      which for a meeting the user organized sends the cancellation
- [ ] People: typed addresses plus suggestions per decision 2; rooms per decision 3

Proof: mock server receives the right `CreateItem`, `UpdateItem` and `DeleteItem`; a real event
only when the user names it.

## M17. Answer invitations
- [ ] Accept, Tentative, Decline on an event the user was invited to, with or without a note
- [ ] The same three buttons on a meeting request email in the reader
- [ ] EWS `CreateItem` with `AcceptItem`, `TentativelyAcceptItem`, `DeclineItem`

Proof: mock server receives each response; a real one only when the user names the invitation.

## M18. Reminders
- [ ] A macOS notification at each event's reminder time, from events fetched for the next day
- [ ] Snooze and dismiss from the notification; click opens the event
- [ ] Settings switch; the same details rule as mail notifications (title or "Event" only)

Proof: a mock event five minutes out shows its reminder banner.

## M19. Today at a glance (only if decision 1 is "both")
- [ ] In the popover, the rest of today's events and the next one's start, with a join link when
      the event has one
