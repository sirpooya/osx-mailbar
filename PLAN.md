# Plan: what is still open (2026-11-16)

M20 to M29, the user's Outlook picks, are built and recorded in AGENTS.md (Milestones, Scope).
Open:

- **S/MIME sign and encrypt.** Not built. Needs: the user's signing identity in the Keychain,
  a multipart/signed MIME writer (CMSEncoder), recipients' `UserSMIMECertificate` from
  `ResolveNames` for encryption, and proof that the server accepts a `MimeContent` send.
- **Proof on the real account** for everything in the Milestones table's last column. Nothing
  from M20 to M29 has touched the real server yet.
