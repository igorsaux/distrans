# Privacy Policy

Version 1.0 — Last updated 2026-10-10

This policy explains what data the service stores, why, and how it is handled. The service is
operated by a private individual or group ("we", "us", the "administration") and is not a legal
entity. It describes the software's actual behaviour; each deployment should replace the placeholder
fields and the retention period marked below to match its own setup.

## 1. Who is responsible

The operator of the service is [operator name]. Contact: [contact email / other].
The software is self-hosted and run by that person or group, not by a company.

## 2. Data we store

Account data. When an account is created we store: the username you choose and, optionally, a
display name; an Argon2 hash of your password (the password itself is never stored or logged); an
avatar image if you upload one; and account metadata such as the numeric id, creation/update
timestamps, and whether the account is a bot. Bot accounts have no password; their token is stored
only as a hash.

Content you publish. We store the messages you post, including their text, embeds, mentions, replies
and pinned state, the reactions you add, and the metadata of any files you attach (name, size,
content type). The file contents themselves are stored in the object storage described in section 6.

Preferences and settings. We store the client settings your app writes (an opaque `userdata` value),
your per-guild and per-channel notification preferences, and, if you enable browser notifications,
your push subscriptions (the push endpoint URL and its encryption keys).

Sessions. Access tokens are short-lived and are not stored on the server. Refresh tokens are stored
only as a hash, together with an expiry time.

Moderation history. Management and moderation actions (for example editing a channel or removing a
member) are recorded in an append-only log that contains the numeric ids of the actor and the target
and the type of action. It does not contain message content.

Technical logs. Like most servers, the service writes operational logs. These may contain your IP
address, connection timestamps and connection identifiers while you connect or when an error occurs.

We do not collect your email address, real name, phone number or payment details, and we do not use
analytics, advertising or third-party trackers.

## 3. Why we store it

Data is used only to:

- provide and technically operate the service;
- authenticate you and keep your sessions valid;
- deliver your messages, files and notifications;
- apply your notification and display preferences;
- moderate content and investigate abuse or security incidents.

## 4. Cookies

The service sets a single `refresh_token` cookie. It is HttpOnly and scoped to the API path, and it
is used only to keep you signed in. The service does not set advertising or tracking cookies.

## 5. Retention and deletion

- Messages, files and accounts are kept until you delete the relevant item or until the
  administration removes it.
- Deleting a message is a soft delete: its text is cleared immediately and the row is kept so
  clients can sync the deletion.
- Refresh tokens are removed when they expire (5 days by default), when you log out, and when your
  account is deleted.
- Push subscriptions are removed when you disable notifications, when the push service reports the
  subscription as no longer valid, and when your account is deleted.
- IP addresses in operational logs are kept for [retention period, e.g. 14 days] and then rotated
  out by the operator.
- When an account is deleted we remove its password hash, display name, avatar, role assignments,
  refresh tokens, bot tokens, push subscriptions and client settings, and anonymise the account (its
  username is replaced with a non-identifying value).

  Messages and uploaded files you posted before deletion are not removed by deleting your account:
  they remain part of the conversation without your display name. To have a specific message or file
  removed, delete it before deleting your account, or ask the administration (section 8). The
  moderation log described in section 2 is append-only and is not altered by account deletion.

## 6. Sharing

We do not sell your data and we do not share it for advertising. Data leaves the server only in
these cases:

- Hosting provider. The server runs on infrastructure provided by [hosting provider].
- Object storage. If file uploads are enabled, attached files are stored with an S3-compatible
  storage provider ([storage provider]). Messages and other database content stay in the database.
- Push services. If you enable browser notifications, a notification is sent to the push service
  associated with your browser ([push service, e.g. your browser vendor]). The notification content
  is end-to-end encrypted, so the push service cannot read it; it processes only the routing
  information needed to deliver the message.
- Legal requests. We may disclose data to competent authorities when required by a valid request
  under applicable law.

## 7. Security

Passwords are hashed with Argon2. Session and bot tokens are stored only as hashes. Notification
payloads are encrypted. No system is perfectly secure, and the service is offered without a
guarantee of security.

## 8. Your choices and rights

You can edit or delete your profile, messages, files and notification settings through the service.
To access, correct, delete or export your personal data, or to ask how it is processed, contact
[contact]. We respond within a reasonable time. Some requests may be limited where we must retain
data for security or legal reasons, as described in section 5.

## 9. Children

The service is not intended for anyone under the age of 13 and does not knowingly collect data from
children. If such an account is discovered, it will be removed.

## 10. Changes

We may update this policy. Changes take effect when the updated version is published, and the
version and date at the top will change.
