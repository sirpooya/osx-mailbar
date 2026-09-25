# PLAN.md: Mailbar

Scope lives in `AGENTS.md`, Scope. M0 to M11 are done (history in git), and so are M12 to M14
below. Nothing is open; calendar waits for the user. A milestone is done when its proof is
observable, not when the code compiles.

**Simple sending, the user's word (2026-09-24).** Plain writing, no rich-text toolbar, no drafts
folder, no signatures editor, no outgoing attachments, no directory lookup. Move, follow up and
categories stay out. Calendar: the user will say later.

Testing rule for all three: **never send real mail** without the user naming the exact message and
recipient. Build and prove everything against `MAILBAR_MOCK`, where Send goes nowhere.

---

## M12. Reply and reply all (done 2026-09-25)
- [x] Reply and Reply All buttons in the reader toolbar (and Cmd+R, Cmd+Shift+R)
- [x] A composer screen in the popover: To (and Cc for reply all) filled in, editable; a plain
      text box where each paragraph runs in its own direction, right to left for Persian
- [x] Sent with EWS `ReplyToItem` / `ReplyAllToItem`, `MessageDisposition="SendAndSaveCopy"`: the
      server adds the quoted original and the `Re:` subject and keeps a copy in Sent Items, exactly
      as Outlook does, so Mailbar never rebuilds the quote itself
- [x] Send with the button or Cmd+Return; the text is kept (in memory) if sending fails
- [x] Closing the popover keeps an unsent reply in memory until Mailbar quits, never on disk

Proof: in mock mode a Persian reply all was photographed (Persian lines right to left, an English
line left to right, recipients without the user's own address), and a test sends a Persian reply
through the mock server, which received `ReplyToItem` with the fresh change key and `dir="rtl"`.
Nothing has been sent from the real account.

## M13. Forward (done 2026-09-25)
- [x] Forward button in the reader (Cmd+Shift+F); To empty, the same composer
- [x] Sent with EWS `ForwardItem`: the server carries the original body and its attachments

Proof: a test sends a forward through the mock server, which received `ForwardItem`.

## M14. New message (done 2026-09-25)
- [x] A compose button in the popover header (Cmd+N): To, Cc, Subject, text
- [x] Recipient suggestions from the senders already in the inbox list (in memory only); any
      address can be typed; no LDAP, no Global Address List
- [x] Sent with EWS `CreateItem`, `MessageDisposition="SendAndSaveCopy"`
- [x] Addresses checked for shape before Send is enabled

Proof: new message photographed; a test sends one to two addresses through the mock server, which
received `CreateItem` with the subject. A real send only to an address the user names.
