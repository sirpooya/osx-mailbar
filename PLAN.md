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
- [x] Views: Day, Week, Month (Work week removed at the user's request), with "‹ Today ›" at the
      right of the toolbar
- [x] Swipe as Apple's Calendar does: the week follows the fingers, springs on or back by
      distance and speed; neighbours prefetched so they slide in with their events
- [x] Events in their Outlook category colours, from the mailbox's master category list
      (`GetUserConfiguration` CategoryList), falling back to the name ("Green category")
- [x] The week starts Saturday; Thursday, Friday and hours outside 9 to 17 in neutral grey (the
      user's call, not the accent tint); the day names on a plain background, as Apple's Calendar
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

## M16. Create, edit, delete (done 2026-09-25)
- [x] New event: title, location or room, start and end, all day, private, repeat (never, daily,
      weekly, monthly, yearly), reminder, show as (busy, free, tentative, away), plain notes, people
- [x] Double-click an empty slot to start one at that time
- [x] EWS `CreateItem` `CalendarItem`: `SendToNone` with no attendees, `SendToAllAndSaveCopy`
      with attendees (that is the invitation)
- [x] Edit with `UpdateItem` (`SendToChangedAndSaveCopy` for meetings); delete with `DeleteItem`,
      which for a meeting the user organized sends the cancellation
- [x] People: typed addresses plus suggestions per decision 2; rooms per decision 3

Proof (2026-09-25): the form photographed with a room and a person ("Send" instead of "Save");
tests create, rename and delete (cancel) an event through the mock server and check the request
shapes: schema order, `SendToNone` for an appointment, `SendToAllAndSaveCopy` with people,
midnight-to-midnight all-day, weekly recurrence, time zone header. Directory suggestions use EWS
`ResolveNames` (decision 2), rooms `GetRoomLists`/`GetRooms` (decision 3). Edits apply to one
occurrence of a series. **Nothing written to the real calendar.**


## M17. Answer invitations (done 2026-09-25)
- [x] Accept, Tentative, Decline on an event the user was invited to, with or without a note
- [x] The same three buttons on a meeting request email in the reader
- [x] EWS `CreateItem` with `AcceptItem`, `TentativelyAcceptItem`, `DeclineItem`

Proof (2026-09-25): the answer bar photographed on an invitation in the detail panel and on the
invitation email; tests answer both ways through the mock server and see the event's response
change. **No real invitation answered.**


## M18. Reminders (done 2026-09-25)
- [x] One plain notification at each event's reminder time: title, time, place. No snooze and no
      buttons (the user's call); it comes and goes like any banner
- [x] Scheduled with macOS from the next 26 hours of events, refreshed after polls (at most every
      five minutes) and at once when the stream reports a calendar change; moved, declined,
      cancelled or deleted events lose their reminder
- [x] Clicking it opens the calendar on the event; once the event has ended it leaves
      Notification Center
- [x] Settings, Notifications: "Event reminders"; with "Show sender and subject" off, it says "Event"

Proof: tests for what is scheduled (reminder set, still to come, not cancelled or declined) and
its wording. **Not yet seen as a real banner**: that needs an event with a reminder on the real
calendar (sample mode does not schedule real notifications).

## M19. Today at a glance (only if decision 1 is "both")
- [ ] In the popover, the rest of today's events and the next one's start, with a join link when
      the event has one
