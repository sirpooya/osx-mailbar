# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries accumulate under [Unreleased] as work lands, and move into a versioned
section when a release is cut.

## [Unreleased]

### Added
- Automatic updates: Mailbar checks for a new version once a day and offers to install it. Check for Updates... is in the menu bar icon's right-click menu.

### Changed
- Schedule's name column is wider, so room names fit.
- Long room names are shortened from the building name, so the room itself stays visible.

### Fixed
- Dragging the meeting in Schedule now follows the pointer; before, it lagged and slipped as the grid shifted under it. Schedule always shows the whole day.
- Location shows a spinner while the rooms load, fetches all room lists at once, and says when no rooms match.
- A room no longer shows up twice in Schedule when its address is spelled with different capitals.

## [1.0.0] - 2026-09-26

### Added
- Settings window where you add, edit, test and delete Exchange accounts. Passwords are kept in your Keychain.
- Menu bar icon and app icon.
- Unread count next to the menu bar icon, refreshed every couple of minutes, when you open the list, and after the Mac wakes.
- Inbox list in the popover, laid out like Outlook: sender, subject with the time (today's time, Yesterday, 2 days ago, then the date), and a one-line preview. Persian mail reads right to left.
- Clear screens for a password that is not accepted, a server that cannot be reached, and a genuinely empty inbox.
- Several accounts: pick one from the title menu or swipe between them.
- Click a message to read it in the popover. Opening it marks it read. Remote images stay blocked until you click Load images, so tracking pixels cannot report that you opened it.
- Mark as read or unread, flag, archive and delete, from the message toolbar, from buttons that appear when you hover a row, or by right-clicking. Delete moves mail to Deleted Items.
- If your mailbox has no Archive folder yet, Mailbar asks before creating one.
- Adding an account offers a password already saved in Keychain Access (by Outlook or Safari) for your email's domain: press Use It and macOS asks permission, so there is nothing to type.
- New-mail notifications. Click one to open that message. Turn off Show sender and subject to have notifications name only the account.
- Search the inbox: press Cmd+F or the magnifier and type. Results come from your server.
- Attachments show under the message. Click one to open it, or right-click to save it.
- Launch at login, in Settings, General.
- Reply, Reply All and Forward from an open message, and a new message from the pencil button. Plain writing, right to left for Persian, Command Return to send. Your server adds the quoted original and keeps a copy in Sent Items.
- Calendar. Right-click the menu bar icon and choose Calendar (Command K) for Day, Work week, Week and Month views of your Exchange calendar, laid out like Outlook on the web, with the week starting Saturday. Click an event to see who is invited and how they answered.
- Swipe left or right with two fingers in the calendar to go to the next or previous day, week or month.
- Calendar events show their Outlook category colours.
- The calendar switches to Day view when its window is made narrower than about 580 points, and back to Week when it is widened again.
- Create, edit and delete calendar events: the + button (Command N) or a double-click on an empty slot opens a form with location and room booking, start and end, all day, private, repeat, reminder, show as, notes and people, with names suggested from your company directory. Deleting a meeting you organized sends the cancellation.
- Answer invitations with Accept, Tentative or Decline and an optional note, from the calendar or from the invitation email.
- Event reminders: one notification at each event's reminder time, and clicking it opens the event in the calendar. Turn it off in Settings, Notifications.
- Drag on an empty part of the calendar's Day or Week grid to create an event over that time range, in 15-minute steps. Nothing is sent to the server until you press Save; Cancel discards it.
- The event form has a People sidebar: type a name or address to get suggestions from the company directory, and see whether each person is free at that time.
- Events can have a category (with its colour) and a charm icon, set in the event form; the charm shows beside the title in the calendar.
- Files can be attached to events, from Add Files or by dropping them on the form, and an event's files open or save from its detail panel.
- Search the room list in the event form by any part of a room's name.
- Swipe sideways with two fingers on the popover's Today tab to go through the days; a Today button brings you back.
- The event form's People list shows each person's photo from Exchange.
- People suggestions in the event form show each person's photo from Exchange.
- The event form has OWA's Response options: choose whether to request responses and whether invitees may forward the invitation.
- Repeat offers OWA's choices worded from the start date (every day, every Wednesday, every workday, day 23 of every month, every fourth Wednesday, every September 23) and Other for any pattern, with an end date or a number of times.
- In the event form's time fields, Shift with the Up or Down arrow moves the time by 10 minutes.
- Distribution groups show as groups in the event form's People and in a message's To and Cc, with Expand to put their members in their place.
- Settings, People directory: set the address of a JSON list of people to add a whole team or department at once when inviting people or writing mail, with their photos.
- Command-comma opens Settings while the popover is open.
- The team picker filters by department, team and role, each list holding only what the one before leaves.
- Click a person in the event form's People to see their contact card from the Exchange directory: job title, department, office, manager, phones and address.
- Scheduling Assistant in the event form: everyone's busy times across the day, click a time to move the meeting there, or jump to the next free time.

### Changed
- The new menu bar and app icons.
- Adding an account now needs only your email and password: Sign In finds your Exchange server, your name and the right user name by itself, and tests the connection. You can still enter the server by hand.
- New mail now appears the moment it arrives, instead of at the next check. Mailbar keeps one quiet connection to your server open and checks the old way only every 10 minutes as a backup.
- While the calendar is open, Mailbar shows in the Dock and in Command Tab. Close the calendar and it is back to the menu bar only.
- Swiping in the calendar now follows your fingers and settles on the next or previous week the way Apple's Calendar does, with the neighbouring weeks already filled in.
- Calendar weekends and off-hours are shaded grey, the day names sit on a plain background, and Previous, Today and Next sit together at the right. Work week view is removed.
- Calendar grey shading is a true neutral grey, event text sits in the top left of each block, and the refresh button is gone: the calendar keeps itself up to date.
- The calendar adapts to a narrow window the way Apple's Calendar does: shorter titles and day names, event titles that wrap between words, and event details that float over the grid instead of squeezing it. Day, Week and Month now sit in one capsule, and Previous, Today and Next are round buttons.
- Today in the popover: a tab beside the Inbox (Command 1, Command 2) shows today as a one-day calendar, with Join buttons on Teams, Zoom, Meet and Webex meetings. Click an event to open it in the calendar.
- The Today tab's header shows only the date.
- Refresh moved from the popover header to the footer, beside the last update time.
- Persian subjects in the inbox start at the left edge, in line with the other rows.
- The Join button on a Today meeting is centred on the event's title line.
- New message sits at the left of the popover header on both Inbox and Today; the search button no longer slides the header icons when switching tabs.
- Inbox rows show the received time on the sender line; the hover actions sit over the subject line instead.
- The attachment icon sits beside the time on the sender line.
- The footer's refresh icon is the same grey as the footer text.
- The calendar's Day, Week, Month switcher no longer casts a shadow.
- Switching the calendar between Day, Week and Month now changes view at once, as Apple's Calendar does, instead of morphing the grid; Day and Week keep the hours you had scrolled to.
- The event form sets a date, a start time and a duration instead of an end time.
- The event title is a normal text field with a Title label, like Location.
- The event form sets its length with a dotted slider, in half hours up to 8 hours, instead of a menu.
- Show as lists Free, Working elsewhere, Tentative, Busy and Away, each with Outlook's colour swatch.
- The event form has Attach, Charm and Categorize in a toolbar at the top, and Cancel and Send at the bottom.
- The event form's Attach, Charm and Categorize sit in their own toolbar under the title.
- The event form is back to separate Start and End fields, each with a date, a calendar and a time, and the length shown beside End.
- The event form opens with the cursor in the title, and its body field is called Description.
- The event form's toolbar is white, with no line under the title.
- Rooms are found by typing in Location: pick one and press Add to meeting, or check which of the listed rooms are free.
- Show as and Reminder moved into the event form's toolbar; the fields are taller, and each date box holds its own calendar button.
- The event form's times follow Outlook for Mac: a Duration menu beside All day event, then Starts and Ends; labels are right-aligned.
- Event dates read year/month/day, as 2026/09/25.
- The event form's Response options gear is lighter, and the Attach button's icon sits closer to its word.
- Event times are 24-hour with a leading zero, such as 09:00, so they line up.
- Repeat's Other editor offers Daily, Weekly, Monthly and Yearly as Outlook does, with Monthly on a day or on a weekday of the month.
- The calendar toolbar's add button reads New Event, and the Day, Week, Month switcher has a lighter border.
- Repeat lists Outlook's Never, Daily, Weekly, Monthly, Yearly and Other, with a line saying what the choice means.
- The event form's Description fills the space down to the buttons, attached files sit just above it, and the toolbar's icons share one size.
- The event form opens with no field selected.
- Recipient suggestions in the composer now include your company directory, not only people who have written to you.
- Settings has two tabs: General (accounts, refresh, notifications, startup) and Calendar (Today tab, event reminders, people directory).
- Settings now has three tabs, General, Accounts and Calendar, under a clean top bar with only the close button; it opens on Accounts when none is set up.
- Settings rows drop their subtitles, account rows open their editor on a click, and the account editor opens without a heading or a focused field.
- The people directory shows a status dot, keeps its saved address locked behind Edit with Connect to change it, and remembers how many people it last read.
- Settings descriptions are one short line each.
- The privacy note moved to the Accounts tab, under the account list.
- The Response options gear beside People matches the team button's size and colour.
- The privacy note in Settings sits right under the account list.
- The event form is narrower and shorter, its menus are as tall as its fields, and Until no longer shifts the form when it changes.
- Reminders and durations use short units: 15m, 1h 30m, 1d.
- The event form's toolbar menus share one text colour and one chevron.
- Private is a lock button in the event form's toolbar: tap it to make the event private or not.
- Each person in the event form's People has a remove button that always shows, not only on hover.
- The Private toggle shows its name, with an outlined lock that fills when the event is private.
- Reminder choices read simply 5m, 15m, 1h, 1d, without "before".
- The calendar's weekend and off-hours shading is lighter, in the calendar window and the Today tab.
- The event form's menus, checkbox and Description share the text fields' white look.
- The contact card shows the people directory's role, team and department under the name, and the Exchange directory's details below the line.
- The event form's fields, menus, checkbox and Description are one light grey, without borders.
- The event form's button always reads Send; the note about invitations is gone.
- Repeat offers Daily, Weekly, Monthly and Custom; Until offers None, After and By.
- Private, when on, is a neutral grey pill; the People heading is quieter; the Add people field matches the other fields.
- The event form's People heading is black, and the toolbar sits closer to the fields.
- While Mailbar checks for mail, the footer shows a shimmering "Updating..." instead of a spinner.
- Check availability in the room list adds the rooms to the Scheduling Assistant to compare; tick one there to book it.
- Booked rooms show as neutral grey chips.
- The event form's scroll bars are hidden, and the form no longer scrolls unless its content is taller than the window.
- The calendar toolbar's account menu is a rounded capsule like the buttons beside it.
- Scheduling Assistant is denser, like Outlook's: shorter rows grouped under Attendees and Rooms, with thin hour lines. Busy, tentative, away and working-elsewhere times look the same as in the Show as menu.
- Duration, Repeat and Until are as wide as the date boxes, so their edges line up.
- The Settings window is shorter.
- Mailbar shows in the Dock while Settings is open, as it does for the calendar.
- The Scheduling Assistant is now Schedule, a view inside the event form: switch between Event and Schedule at the top, with Cancel and Send working in both. It no longer opens as a separate sheet.
- The calendar opens at a smaller size, and event titles and their colour bars are lighter.
- Tooltips show shortcuts as symbols, such as New Event ⌘N.
- The event form's Send button has a paper plane icon.
- In Schedule, drag the meeting with the hand to move it, or drag either edge to make it longer or shorter, in 15-minute steps.
- Calendar event titles are regular weight.
- Schedule shows only what it needs at the top: the day with its arrows and Next free time, in place of the event toolbar.
- The rooms-to-compare line under Location shows a room icon.
- Schedule's date and Next free time match the size of the event toolbar's buttons.

### Removed
- A two-finger sideways swipe in the menu bar popover no longer switches accounts; use the account menu in the header.
- The pin icon in the event form's Location field.
- The placeholder icons on the event form's Charm and Categorize buttons.
- The Today tab switch in Settings; the Today tab is always there.
- The plus button in the event form's People field; Return or a click on a suggestion adds a person.
- The "Show sender and subject" switch; notifications and reminders always show them.
- The note under Notifications in Settings.
- Yearly from Repeat's Custom editor.

### Fixed
- Signing in to an on-prem Exchange server that offers Negotiate before NTLM works: the password now reaches NTLM, and a wrong password shows as rejected instead of "The server did not answer".
- A mistyped password costs at most one failed logon per user name tried, not one per authentication scheme, so Sign In no longer risks locking the domain account.
- Wide emails such as newsletters now zoom out to fit the reader instead of running off the right edge. Images keep the proportions the sender gave them.
- Large images in an email now shrink to fit the reader, keeping their shape, so there is no sideways scrolling.
- Calendar events take exactly the colour their category has in Outlook; a category without a colour is grey, as in Outlook, instead of a guessed colour.
- The popover header keeps one height when switching between Inbox and Today.
- Inbox and Today are the same height, so switching tabs no longer resizes the popover or makes it jump.
- Cmd+K opens the calendar from the popover; before, it only worked while the menu bar icon's right-click menu was open.
- A new event started at a minute past the half hour instead of on it.
- Swiping through days on the Today tab no longer leaves the other days loading for ever on a slow connection.
- On the Today tab the date now moves with its day during a swipe, instead of sliding ahead of the grid and under the Today button.
- Clicking empty space in the event form now ends editing the field you were typing in.
- The Description label lines up with the first line of its box.
- Dates and times in the event form sit centred in their boxes and start at the same inset as the other fields.
- The date picker no longer shows a focus ring when it opens.
- A new message or a forward opens with the cursor in To, not Cc.
- Command-comma opens Settings from every Mailbar window, including the calendar, on any keyboard layout.
- The account editor no longer flashes the e-mail field selected as it opens.
- The event form no longer flashes its Title field focused as it opens.
- Wide Persian emails fit the reader instead of being cut off on the left.
- The room list under Location is no longer covered by the Description box.
- The room list under Location is as wide as the field and sits above everything below it.
- People's photos are drawn smoothly instead of jagged.
- Changing Until no longer shifts its label or the row's height; Repeat and Until are the same width.
- The repeat summary beside Repeat stays on one line.
- Switching the event form between Event and Schedule no longer reloads people's photos and free or busy.
- Typing in Location always lists the matching rooms, and the room list loads again if it came back empty.

