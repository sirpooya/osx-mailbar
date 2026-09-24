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

### Changed
- The new menu bar and app icons.
- Adding an account now needs only your email and password: Sign In finds your Exchange server, your name and the right user name by itself, and tests the connection. You can still enter the server by hand.

### Fixed
- Signing in to an on-prem Exchange server that offers Negotiate before NTLM works: the password now reaches NTLM, and a wrong password shows as rejected instead of "The server did not answer".
- A mistyped password costs at most one failed logon per user name tried, not one per authentication scheme, so Sign In no longer risks locking the domain account.

