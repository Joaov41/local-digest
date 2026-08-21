# Local Digest social posts

These are launch drafts for the current native macOS build. Replace the link
if the repository moves, and update the wording if distribution status changes.

## Reddit

**Title:** I’m building Local Digest, a native macOS app for searching your personal archive

I’m working on Local Digest, a native SwiftUI macOS app that lets you search and ask questions across the personal sources you choose to authorize:

- Mail and Notes
- Messages
- Contacts
- Calendar
- Reminders

It builds a local SQLite full-text index, so questions can use historical records instead of only the newest item. You can ask things like “What did Rui tell me last night?” and Local Digest plans the person, date, and source constraints before producing an answer with inspectable source citations.

The app is read-only by design. Retrieved messages, notes, events, and emails are shown as evidence, and Local Digest never edits, deletes, or creates personal items. Source permissions and indexed counts are visible, Messages reports when Full Disk Access is needed, and Mail/Notes use read-only automation access.

Refreshing is designed to run in the background. The last completed snapshot remains searchable while a sync or full rebuild is in progress, and a failed fetch does not erase the previous source snapshot.

For answers, the project supports Apple’s on-device Foundation Model and an optional Private Cloud Compute provider. With the cloud provider selected, only the bounded evidence needed for the current answer is sent to Apple’s service; the local index remains on the Mac.

This is an early macOS 27 project, not a finished App Store release yet. I’m sharing the code and would love feedback on the source adapters, permissions model, and the kinds of questions you would want to ask across your own archive:

https://github.com/Joaov41/local-digest/tree/native-local-digest

## X

### Post 1

I’m building Local Digest, a native macOS app for searching your personal archive.

Ask across Mail, Messages, Notes, Contacts, Calendar, and Reminders. It plans person/date/source constraints, searches a local SQLite index, and returns answers with inspectable citations.

### Post 2

It is read-only by design: retrieved evidence is inspectable, but the app never edits, deletes, or creates personal items.

Sync and full rebuild run in the background while the last completed snapshot stays searchable.

### Post 3

Answers can use Apple’s on-device Foundation Model or Private Cloud Compute. With PCC selected, only bounded evidence for the current answer is sent to Apple’s service.

Early macOS 27 project: https://github.com/Joaov41/local-digest/tree/native-local-digest

#macOS #SwiftUI #AppleDeveloper
