# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries accumulate under [Unreleased] as work lands, and move into a versioned
section when a release is cut.

## [Unreleased]

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

### Changed
- The new menu bar and app icons.
- Adding an account now needs only your email and password: Sign In finds your Exchange server, your name and the right user name by itself, and tests the connection. You can still enter the server by hand.
- New mail now appears the moment it arrives, instead of at the next check. Mailbar keeps one quiet connection to your server open and checks the old way only every 10 minutes as a backup.
- While the calendar is open, Mailbar shows in the Dock and in Command Tab. Close the calendar and it is back to the menu bar only.
- Swiping in the calendar now follows your fingers and settles on the next or previous week the way Apple's Calendar does, with the neighbouring weeks already filled in.
- Calendar weekends and off-hours are shaded grey, the day names sit on a plain background, and Previous, Today and Next sit together at the right. Work week view is removed.
- Calendar grey shading is a true neutral grey, event text sits in the top left of each block, and the refresh button is gone: the calendar keeps itself up to date.
- The calendar adapts to a narrow window the way Apple's Calendar does: shorter titles and day names, event titles that wrap between words, and event details that float over the grid instead of squeezing it. Day, Week and Month now sit in one capsule, and Previous, Today and Next are round buttons.

### Fixed
- Signing in to an on-prem Exchange server that offers Negotiate before NTLM works: the password now reaches NTLM, and a wrong password shows as rejected instead of "The server did not answer".
- A mistyped password costs at most one failed logon per user name tried, not one per authentication scheme, so Sign In no longer risks locking the domain account.
- Wide emails such as newsletters now zoom out to fit the reader instead of running off the right edge. Images keep the proportions the sender gave them.
- Large images in an email now shrink to fit the reader, keeping their shape, so there is no sideways scrolling.
- Calendar events take exactly the colour their category has in Outlook; a category without a colour is grey, as in Outlook, instead of a guessed colour.

