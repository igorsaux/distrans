#!/usr/bin/env python3
"""Import a Discord guild dump (as produced by the `fetcher` tool) into Distrans.

Usage:
    importguild.py <guild_dir | archive.tar.zst> [-c config.json]
                   [--guild-name NAME] [--admin-user-id ID] [--limit N]
                   [--channels IDS]
                   [--attachments-whitelist IDS | --attachments-blacklist IDS]
                   [--discord-token TOKEN]
                   [--refresh-users] [--refresh-avatars] [--refresh-emoji]
                   [--dry-run]

The input is either a dump directory or a zstd-compressed tarball (the output of
``fetcher/pack.py``). An archive is extracted to a temporary directory, imported
with the same flow and the temporary directory is deleted afterwards; the
matching report is written next to the archive as ``<archive>.import-report.json``
(needs roughly the size of the unpacked dump in free space). Requires the
``zstandard`` package for archives.

The dump directory has the shape ``<root>/<guild_id>/``:

    guild.json              {id, name, owner_id, description, member_count}
    emojis.jsonl            {id, name, animated, url}            (optional)
    webhooks.jsonl          {id, type, name, channel_id, guild_id, avatar_url, token}
                                                                 (optional)
    members.jsonl           {id, name, global_name, nick, display_name, bot, roles[], joined_at, avatar_url}
    roles.jsonl             {id, name, color, position, permissions, managed, mentionable, hoist, is_everyone}
    channels.jsonl          {id, guild_id, name, type, parent_id, position, topic, nsfw, overrides[]}
    messages/<channel>.jsonl {id, channel_id, author_id, author_name, author_global_name,
                              content, created_at, edited_at, reply_to_id, reply_channel_id,
                              pinned, webhook_id, mentions[], attachments[], embeds[], reactions[]}

Everything is written **directly to the database** (``config.db.conninfo``) preserving
Discord ids, in a single FK-safe order:
guild -> users -> roles -> channels -> overwrites -> member_roles -> webhooks ->
avatars -> emojis -> messages -> reactions -> attachments.

WHAT IS TRANSFERRED
    * guild: id, name, avatar (from `icon_url`, transcoded with `media.avatar`)
    * users: every member, every message author, every mention and every member
      override target; username, display_name (nick -> global_name), is_bot,
      avatar (from `avatar_url`, transcoded with `media.avatar`)
    * deleted users (``author_name == "Deleted User"`` and not a current member):
      created as anonymous soft-deleted rows (deleted_at set, username 'deleted-<id>')
    * roles: id, name, position, permissions (remapped), color; @everyone (id == guild_id)
    * emojis: custom guild emoji listed in `emojis.jsonl` (id, allowlisted name,
      icon re-encoded to WebP with `media.emoji`, XXHash64 icon_hash). Custom
      emoji referenced by reactions that are not listed there belong to another
      guild and are skipped: the dump carries no icon for them, and a Discord
      reaction can hold any custom emoji the bot can see
    * webhooks: every entry of `webhooks.jsonl` whose channel is imported
      (id, channel, name, `sha256(token)` as `token_hash`, avatar re-encoded to
      WebP with `media.avatar`). Messages whose ``webhook_id`` is set are linked
      to their webhook (`app.messages.webhook_id`, `author_id` NULL) instead of
      being materialized as a user. A webhook referenced by a message but absent
      from `webhooks.jsonl` (deleted before the dump) is created as a placeholder
      so the message keeps an attribution
    * channels: kind text/news -> channel(0), category -> category(1);
      id, name, parent_id, position, topic
    * overwrites: role/member targets with remapped allow/deny
    * member_roles: role assignments from members.jsonl (minus @everyone)
    * messages: id, channel_id, author_id, content, created_at, edited_at, embeds
    * pinned messages: the dump's `pinned` flag becomes `app.messages.pinned`
      (a boolean; the dump carries no pin timestamp). On a re-run pins are
      backfilled fill-only: a pin the dump has but the DB lacks is added, while
      unpins done in-app afterwards are never cleared
    * reactions: every captured reaction user (unicode or custom emoji) as an
      `app.message_reactions` row; no timestamp (the dump has none)
    * attachments: `app.files` + `app.message_attachments` rows and `files/<sha256>`
      S3 objects, for Discord-CDN URLs only and only for selected channels
      (see ATTACHMENTS)
    * reply links (``reply_to_id``/``reply_channel_id`` in the dump) when the target
      exists in the database **in the same channel**

CONTENT NORMALIZATION
    Message content is stored mostly as-is (the client renders Discord markdown
    natively: ``__underline__``, ``-# subtext``, ``>>> quote``). Two Discord-only
    tokens are normalized so they render:
      * legacy nick mentions ``<@!id>`` become ``<@id>`` (a user mention chip);
      * a message link whose guild is the imported guild becomes root-relative
        ``/channels/<guild>/<channel>/<message>`` so the client renders a channel
        chip without a hardcoded domain. Links to other guilds, channel-only
        links and ``discord.com/channels/@me`` links stay absolute.
    Discord timestamps (``<t:...>``) are left literal. The rewrite is textual, so
    it also applies inside code spans/blocks (accepted).

GIF EMBEDS
    A Giphy/Tenor/Klipy link preview carries the provider page URL in the content
    and a direct media URL on the provider CDN in the embed; the page URL is
    replaced by the direct URL and the consumed embed is dropped, so the client
    embeds the media itself (those CDNs are on the client's trusted host list; see
    ``GIF_PROVIDER_DOMAINS``). No media is downloaded. A provider link with no
    usable embed, or whose page URL no longer appears in the content, stays a
    plain link.

TOKENS
    A webhook's execute token is only ever stored as its sha256 (`token_hash`),
    matching the server. Discord exposes the plaintext token only for Incoming
    (type 1) webhooks, so those are imported with the token from
    `webhooks.jsonl` (the archived dump already holds it). Every other webhook
    (Channel Follower / Application) and every placeholder created from a
    message gets a freshly generated 32-byte base64url token; generated
    plaintexts are written to the report under `webhook_tokens` (id -> token)
    so integrations can be reconfigured. Tokens preserved from the dump are not
    duplicated in the report (they stay in `webhooks.jsonl`).

USER FRESHNESS
    Because users are global (a Discord id may already exist from another guild),
    the importer resolves every user it sees against an in-memory cache built from
    members.jsonl plus every message author and mention (member data wins, then the
    freshest non-empty ``author_name``), and uses those values when creating rows.
    Existing ``app.users`` rows are left untouched by default; pass
    ``--refresh-users`` to overwrite their `username` and `display_name` from the
    dump (never `is_bot`, `password_hash`, `deleted_at` or avatars).

WHAT IS SKIPPED
    * channels of type voice and forum (no equivalent / not messageable)
    * reactions with an empty captured user list, and reaction users that are not
      in the DB; reactions whose custom emoji is not part of this guild (not in
      `emojis.jsonl`); custom emoji whose icon could not be fetched
    * attachments from non-Discord hosts, from channels excluded by the
      whitelist/blacklist, and files that cannot be downloaded (expired signature
      and no usable `--discord-token`, 404, ...)
    * nsfw flag, reply links whose target is missing or in another channel
    * role fields managed/mentionable/hoist (no columns)
    * message content and names are stored as-is: API validation profiles and
      codepoint limits are NOT applied, only database constraints are respected
      (emoji names are the exception: they are lowercased and mapped onto the
      server's `a-z0-9_` allowlist)
    * messages whose content is exactly the empty string and that carry neither
      embeds nor attachments
    * message files of channels that were not imported (voice/forum/orphans)
    * webhooks on channels that were not imported (voice/forum/orphans)
    * webhook fields with no columns: Discord type / `source_guild` /
      `application_id`, and the per-message `username` / `avatar_url` override
      (a Distrans webhook has one name and one avatar); soft-deleted webhooks
      cannot be dumped at all
    * `api.webhooks.max_webhooks_per_channel` is NOT enforced: like names and
      message content, direct DB writes only respect database constraints

ATTACHMENTS
    Attachment bytes are stored **raw** (no re-encode, no size cap) as the
    `files/<sha256>` S3 object with the dump's Content-Type, mirroring what the
    server itself stores for passthrough files. Discord CDN signed URLs expire
    after roughly a day, so `ex`-expired links are re-fetched message-by-message
    over the Discord REST API (only the affected messages) using
    `--discord-token` / `DISCORD_BOT_TOKEN`; without a token those attachments
    are skipped and counted.

    Which channels contribute attachments is controlled by:
      * `--attachments-whitelist IDS` - only these channels (empty = not set);
      * `--attachments-blacklist IDS` - all channels except these.
    The two are mutually exclusive; the whitelist wins when both are empty.

    Existing bytes are never re-downloaded: a message/position already linked, or
    a file id already present, or a hash already stored, is reused. The
    `app.message_attachments` link is written in the same transaction as the
    `app.files` row, so an interrupted run cannot leave a committed file without
    its link. When the file row already exists but the link does not, the link is
    (re-)created without re-downloading, so re-running with `--refresh-messages`
    repairs orphans left by older versions of this script (which staged links in
    a temp table and only flushed them at the very end, losing them on a crash).

AVATARS
    Discord CDN images are downloaded and re-encoded locally with the configured
    ``media.avatar`` settings so the stored bytes are the WebP the server serves
    (``image/webp``), with ``avatar_hash`` = XXHash64 of the stored bytes. Avatars
    are only filled when missing; ``--refresh-avatars`` re-downloads and overwrites
    them (guild, user and webhook avatars). A source that cannot be brought within
    the caps is skipped and counted.

PERMISSION MAP (Discord bit -> Distrans permission bits)
    ADMINISTRATOR        (1<<3)  -> every bit except skip_allows (skip_denies stays)
    MANAGE_CHANNELS      (1<<4)  -> create_channels, modify_channels, delete_channels,
                                    manage_overwrites
    MANAGE_GUILD         (1<<5)  -> guild_modify
    ADD_REACTIONS        (1<<6)  -> add_reactions
    VIEW_CHANNEL         (1<<10) -> read_messages
    SEND_MESSAGES        (1<<11) -> send_messages (only where VIEW_CHANNEL is granted)
    MANAGE_MESSAGES      (1<<13) -> delete_messages, delete_reactions,
                                    add_pins, delete_pins (Discord has no
                                    distinct pin bit; pinning is a
                                    MANAGE_MESSAGES action there)
    READ_MESSAGE_HISTORY (1<<16) -> read_messages
    MENTION_EVERYONE     (1<<17) -> mention_everyone
    MANAGE_ROLES         (1<<28) -> create_roles, modify_roles, delete_roles,
                                    grant_roles, revoke_roles, manage_overwrites
    MANAGE_WEBHOOKS      (1<<29) -> create_webhooks, modify_webhooks,
                                    delete_webhooks
    MANAGE_GUILD_EXPRESSIONS (1<<30) -> create_emoji, modify_emoji, delete_emoji
    VIEW_AUDIT_LOG       (1<<7)  -> view_audit_log
    everything else              -> dropped

The same map is applied to role permissions and to overwrite allow/deny masks.
Discord's `ADD_REACTIONS` is on for `@everyone` by default, so mapping it gives
`@everyone` `add_reactions` (matching `Permissions.defaultEveryone()`), and a
guild whose dump has no `@everyone` role gets that same default mask.

In Discord `SEND_MESSAGES` has no effect where `VIEW_CHANNEL` is denied, so no
target may end up able to write a channel it cannot read: an allow mask grants
`send_messages` only together with `VIEW_CHANNEL`, and a deny mask denies
`send_messages` whenever it denies `VIEW_CHANNEL`.
"""
import argparse
import datetime
import glob
import hashlib
import inspect
import json
import mimetypes
import os
import re
import secrets
import sys
import tarfile
import tempfile
import urllib.parse

import psycopg

from _common import (
    EXIT_OK,
    add_config_arg,
    configure_interactivity,
    fail,
    load_config,
    resolve_text,
)
from _media import (
    AvatarLimits,
    EMOJI_SECTION,
    download as download_bytes,
    encode_avatar,
    encode_emoji,
    normalize_cdn_size,
    normalize_emoji_url,
)
from _s3 import S3, S3Error
from _discord import Discord, DiscordError, fresh_attachment_urls, signed_url_expired

# distrans.permissions bits (mirror src/types.zig / tests/api/permissions.py).
P_READ_MESSAGES = 1 << 0
P_SEND_MESSAGES = 1 << 1
P_DELETE_MESSAGES = 1 << 2
P_CREATE_CHANNELS = 1 << 3
P_MODIFY_CHANNELS = 1 << 4
P_DELETE_CHANNELS = 1 << 5
P_CREATE_ROLES = 1 << 6
P_MODIFY_ROLES = 1 << 7
P_DELETE_ROLES = 1 << 8
P_GRANT_ROLES = 1 << 9
P_REVOKE_ROLES = 1 << 10
P_MANAGE_OVERWRITES = 1 << 11
P_SKIP_ALLOWS = 1 << 12
P_SKIP_DENIES = 1 << 13
P_GUILD_MODIFY = 1 << 14
P_ADD_REACTIONS = 1 << 15
P_DELETE_REACTIONS = 1 << 16
P_CREATE_EMOJI = 1 << 17
P_MODIFY_EMOJI = 1 << 18
P_DELETE_EMOJI = 1 << 19
P_MENTION_EVERYONE = 1 << 20
P_ADD_PINS = 1 << 21
P_DELETE_PINS = 1 << 22
P_CREATE_WEBHOOKS = 1 << 23
P_MODIFY_WEBHOOKS = 1 << 24
P_DELETE_WEBHOOKS = 1 << 25
P_VIEW_AUDIT_LOG = 1 << 26
ALL_BITS = (1 << 27) - 1

# ADMINISTRATOR gets everything but `skip_allows` (an overwrite's deny mask
# still applies to it through `skip_denies`).
ADMIN_BITS = ALL_BITS & ~P_SKIP_ALLOWS

# `Permissions.defaultEveryone()` in src/types.zig, used for the `@everyone`
# row when the dump has no `@everyone` role.
EVERYONE_BITS = P_READ_MESSAGES | P_SEND_MESSAGES | P_ADD_REACTIONS

# Discord permission bits used by the map.
D_ADMINISTRATOR = 1 << 3
D_MANAGE_CHANNELS = 1 << 4
D_MANAGE_GUILD = 1 << 5
D_ADD_REACTIONS = 1 << 6
D_VIEW_CHANNEL = 1 << 10
D_SEND_MESSAGES = 1 << 11
D_MANAGE_MESSAGES = 1 << 13
D_READ_MESSAGE_HISTORY = 1 << 16
D_MENTION_EVERYONE = 1 << 17
D_MANAGE_ROLES = 1 << 28
D_MANAGE_WEBHOOKS = 1 << 29
D_MANAGE_GUILD_EXPRESSIONS = 1 << 30
D_VIEW_AUDIT_LOG = 1 << 7

KIND_CHANNEL = 0
KIND_CATEGORY = 1
TARGET_ROLE = 0
TARGET_MEMBER = 1

MAX_POSITION = 32767
MAX_COLOR = 0xFFFFFF

IMPORTABLE_CHANNEL_TYPES = {
    "text": KIND_CHANNEL,
    "news": KIND_CHANNEL,
    "category": KIND_CATEGORY,
}

DELETED_AUTHOR_NAME = "Deleted User"

# Keep this in sync with the client's inline-image MIME allowlist.
INLINE_IMAGE_TYPES = {"image/gif", "image/jpeg", "image/png", "image/webp"}
ATTACHMENT_TOKEN_RE = re.compile(r"!?\[(?:\\.|[^\]\\])*\]\(attachment://(\d+)\)")

MAX_EMBEDS_DEFAULT = 10
MAX_EMBED_COLOR = 0xFFFFFF
AVATAR_CONCURRENCY = 8
ATTACHMENT_CONCURRENCY = 8
EMOJI_CONCURRENCY = 8

# Webhook execute token size (mirror src/services/tokens.zig::generateWebhookToken).
WEBHOOK_TOKEN_BYTES = 32

# Discord CDN hosts whose attachments are downloaded (everything else is left
# alone: arbitrary third-party hosts are not fetched).
DISCORD_HOSTS = ("discordapp.com", "discordapp.net")

# Custom emoji reaction / message form: <:name:id> or <a:name:id>.
CUSTOM_EMOJI_RE = re.compile(r"^<(?P<animated>a?):(?P<name>[^:]+):(?P<id>\d+)>$")

# Allowlist for a Distrans emoji name (mirror src/utils.zig::isAsciiEmojiNameFormat).
EMOJI_NAME_ALLOWED = set("abcdefghijklmnopqrstuvwxyz0123456789_")

# A Discord message link; the guild is compared against the imported guild so
# only same-guild links become root-relative. `www.`/`canary.`/`ptb.` and the
# legacy `discordapp.com` host are accepted.
DISCORD_MESSAGE_LINK_RE = re.compile(
    r"https?://(?:www\.|canary\.|ptb\.)?discord(?:app)?\.com/channels/"
    r"(?P<guild>\d+)/(?P<channel>\d+)/(?P<message>\d+)"
)

# Legacy nick mention (`<@!id>`), which the client does not render.
LEGACY_NICK_MENTION_RE = re.compile(r"<@!(\d+)>")

# GIF providers whose link previews are replaced by their direct media URL.
# Mirrors the client's trusted media families
# (distrans-ui/src/utils/media.ts::MEDIA_IMAGE_DOMAINS); add a host here and in
# the client to support a new provider. A page URL is converted only when the
# embed's direct media URL is on the same family.
GIF_PROVIDER_DOMAINS = ("giphy.com", "tenor.com", "tenor.co", "klipy.com")

# Provider *page* links (not the direct CDN media URLs) left unresolved.
GIF_PAGE_URL_RE = re.compile(
    r"https?://(?:[^\s/]+\.)?(?:giphy\.com/gifs/|tenor\.com/view/|klipy\.com/gifs/)"
    r"[^\s<>\"'`)\]]+"
)

MESSAGE_COPY_SQL = (
    "COPY import_messages"
    " (id, channel_id, author_id, webhook_id, content, created_at, edited_at, embeds, reply_to_id, pinned)"
    " FROM STDIN"
)
REACTION_COPY_SQL = (
    "COPY import_reactions"
    " (message_id, user_id, emoji_kind, emoji_id, unicode_emoji)"
    " FROM STDIN"
)



def map_permissions(mask, deny=False):
    """Map a 64-bit Discord permission mask to Distrans' 128-bit mask.

    Discord's `SEND_MESSAGES` only takes effect where `VIEW_CHANNEL` is
    granted, so writing always follows reading: an allow mask grants
    `send_messages` only together with `VIEW_CHANNEL`, and a deny mask denies
    `send_messages` whenever it denies `VIEW_CHANNEL`. `ADMINISTRATOR` maps to
    every bit but `skip_allows`.
    """
    mask = int(mask or 0)

    if mask & D_ADMINISTRATOR:
        return ADMIN_BITS

    out = 0

    if mask & D_MANAGE_CHANNELS:
        out |= (
            P_CREATE_CHANNELS
            | P_MODIFY_CHANNELS
            | P_DELETE_CHANNELS
            | P_MANAGE_OVERWRITES
        )

    if mask & D_MANAGE_GUILD:
        out |= P_GUILD_MODIFY

    if mask & D_ADD_REACTIONS:
        out |= P_ADD_REACTIONS

    if mask & (D_VIEW_CHANNEL | D_READ_MESSAGE_HISTORY):
        out |= P_READ_MESSAGES

    if deny:
        if mask & (D_SEND_MESSAGES | D_VIEW_CHANNEL):
            out |= P_SEND_MESSAGES
    elif mask & D_SEND_MESSAGES and mask & D_VIEW_CHANNEL:
        out |= P_SEND_MESSAGES

    if mask & D_MANAGE_MESSAGES:
        out |= P_DELETE_MESSAGES | P_DELETE_REACTIONS | P_ADD_PINS | P_DELETE_PINS

    if mask & D_MENTION_EVERYONE:
        out |= P_MENTION_EVERYONE

    if mask & D_MANAGE_ROLES:
        out |= (
            P_CREATE_ROLES
            | P_MODIFY_ROLES
            | P_DELETE_ROLES
            | P_GRANT_ROLES
            | P_REVOKE_ROLES
            | P_MANAGE_OVERWRITES
        )

    if mask & D_MANAGE_WEBHOOKS:
        out |= P_CREATE_WEBHOOKS | P_MODIFY_WEBHOOKS | P_DELETE_WEBHOOKS

    if mask & D_VIEW_AUDIT_LOG:
        out |= P_VIEW_AUDIT_LOG

    if mask & D_MANAGE_GUILD_EXPRESSIONS:
        out |= P_CREATE_EMOJI | P_MODIFY_EMOJI | P_DELETE_EMOJI

    return out


def permission_bytea(mask):
    return int(mask).to_bytes(16, "big")


def map_color(color):
    if color is None:
        return None

    color = int(color)

    if color == 0:
        return None

    return min(color, MAX_COLOR)


def clamp_position(position):
    if position is None:
        return 0

    return max(0, min(int(position), MAX_POSITION))


def parse_timestamp(value):
    if not value:
        return None

    try:
        parsed = datetime.datetime.fromisoformat(value)
    except (TypeError, ValueError):
        return None

    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=datetime.timezone.utc)

    return parsed


def iter_jsonl(path, report):
    """Yield parsed objects from a JSONL file, recording malformed lines."""
    with open(path, "r", encoding="utf-8") as f:
        for line_no, line in enumerate(f, 1):
            line = line.strip()

            if not line:
                continue

            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                report["malformed_lines"].append(f"{path}:{line_no}")


class Usernames:
    """Assigns unique usernames, respecting the ones already present in the DB."""

    def __init__(self, used):
        self.used = set(used)

    def take(self, base, user_id):
        base = base if base else f"user.{user_id}"

        if base not in self.used:
            self.used.add(base)

            return base

        candidate = f"{base}.{user_id}"

        if candidate not in self.used:
            self.used.add(candidate)

            return candidate

        suffix = 2

        while f"{candidate}.{suffix}" in self.used:
            suffix += 1

        final = f"{candidate}.{suffix}"
        self.used.add(final)

        return final


class UserCache:
    """In-memory resolution of every user referenced by the dump.

    Member rows take precedence; for non-members the freshest message author
    identity (`author_name`/`author_global_name`) wins. Mentions are recorded so
    they can be materialized as placeholder users.
    """

    def __init__(self):
        self.records = {}

    def _ensure(self, user_id):
        record = self.records.get(user_id)

        if record is None:
            record = {
                "username": None,
                "display_name": None,
                "avatar_url": None,
                "is_bot": False,
                "is_member": False,
                "deleted": False,
            }
            self.records[user_id] = record

        return record

    def add_member(self, member):
        user_id = int(member["id"])

        if member.get("name"):
            username = member["name"]
        else:
            username = None

        self.records[user_id] = {
            "username": username,
            "display_name": member.get("nick") or member.get("global_name"),
            "avatar_url": member.get("avatar_url"),
            "is_bot": bool(member.get("bot")),
            "is_member": True,
            "deleted": False,
        }

    def add_author(self, message):
        author_id = message.get("author_id")

        if author_id is None:
            return

        author_id = int(author_id)
        record = self.records.get(author_id)

        if record is not None and record.get("is_member"):
            return

        record = self._ensure(author_id)
        name = message.get("author_name")

        if name == DELETED_AUTHOR_NAME:
            record["deleted"] = True

            return

        if name:
            record["username"] = name
            global_name = message.get("author_global_name")

            if global_name:
                record["display_name"] = global_name

            record["deleted"] = False

    def add_mention(self, mention_id):
        mention_id = int(mention_id)

        if mention_id not in self.records:
            self._ensure(mention_id)


def load_dump(guild_dir, report):
    guild = None
    guild_path = os.path.join(guild_dir, "guild.json")

    if os.path.isfile(guild_path):
        with open(guild_path, "r", encoding="utf-8") as f:
            guild = json.load(f)
    else:
        report["warnings"].append(f"missing {guild_path}")

    roles = list(iter_jsonl(os.path.join(guild_dir, "roles.jsonl"), report))
    channels = list(iter_jsonl(os.path.join(guild_dir, "channels.jsonl"), report))

    members_path = os.path.join(guild_dir, "members.jsonl")
    members = (
        list(iter_jsonl(members_path, report)) if os.path.isfile(members_path) else []
    )

    if not members:
        report["warnings"].append("missing or empty members.jsonl")

    return guild, roles, channels, members


def collect_channels(channels, report):
    imported = {}

    for channel in channels:
        type_name = channel.get("type")

        if type_name not in IMPORTABLE_CHANNEL_TYPES:
            report["channels_skipped"][type_name] = (
                report["channels_skipped"].get(type_name, 0) + 1
            )

            continue

        imported[int(channel["id"])] = channel

    return imported


def collect_override_member_ids(imported_channels):
    ids = set()

    for channel in imported_channels.values():
        for overwrite in channel.get("overrides") or []:
            if overwrite.get("target_type") == "member" and overwrite.get("target_id") is not None:
                ids.add(int(overwrite["target_id"]))

    return ids


def _embed_string(value):
    return value if isinstance(value, str) and value else None


def _iso_to_millis(value):
    if not isinstance(value, str) or not value:
        return None

    try:
        parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None

    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=datetime.timezone.utc)

    return int(parsed.timestamp() * 1000)


def _embed_url_object(value):
    if not isinstance(value, dict):
        return None

    url = _embed_string(value.get("url"))

    if url is None:
        return None

    return {"url": url}


def _embed_footer(value):
    if not isinstance(value, dict):
        return None

    text = _embed_string(value.get("text"))

    if text is None:
        return None

    return {"text": text, "icon_url": _embed_string(value.get("icon_url"))}


def _embed_author(value):
    if not isinstance(value, dict):
        return None

    name = _embed_string(value.get("name"))

    if name is None:
        return None

    return {
        "name": name,
        "url": _embed_string(value.get("url")),
        "icon_url": _embed_string(value.get("icon_url")),
    }


def _embed_field(value):
    if not isinstance(value, dict):
        return None

    name = _embed_string(value.get("name"))
    field_value = _embed_string(value.get("value"))

    if name is None or field_value is None:
        return None

    inline = value.get("inline")

    return {
        "name": name,
        "value": field_value,
        "inline": bool(inline) if isinstance(inline, bool) else False,
    }


def normalize_embeds(raw_embeds, max_embeds):
    """Map Discord embeds to Distrans' `Embed` wire shape.

    Returns ``(json_text_or_none, dropped_for_limit)``. Optional fields are
    emitted as explicit nulls and `fields` is always an array, mirroring
    `utils.serializeEmbeds`. No validation-profile/codepoint limits are applied
    (same policy as message content).
    """
    if not isinstance(raw_embeds, list) or not raw_embeds:
        return None, False

    dropped = len(raw_embeds) > max_embeds
    embeds = []

    for raw in raw_embeds[:max_embeds]:
        if not isinstance(raw, dict):
            continue

        color = raw.get("color")

        if isinstance(color, bool) or not isinstance(color, int):
            color = None
        elif color < 0 or color > MAX_EMBED_COLOR:
            color = None

        fields = []

        for field in raw.get("fields") or []:
            mapped = _embed_field(field)

            if mapped is not None:
                fields.append(mapped)

        embeds.append(
            {
                "type": "rich",
                "title": _embed_string(raw.get("title")),
                "description": _embed_string(raw.get("description")),
                "url": _embed_string(raw.get("url")),
                "timestamp": _iso_to_millis(raw.get("timestamp")),
                "color": color,
                "footer": _embed_footer(raw.get("footer")),
                "image": _embed_url_object(raw.get("image")),
                "thumbnail": _embed_url_object(raw.get("thumbnail")),
                "video": _embed_url_object(raw.get("video")),
                "author": _embed_author(raw.get("author")),
                "fields": fields,
            }
        )

    if not embeds:
        return None, dropped

    return json.dumps(embeds, ensure_ascii=False, separators=(",", ":")), dropped


def resolve_reply(message, channel_id):
    """Return the reply target id, or None when it cannot be represented."""
    reply_to_id = message.get("reply_to_id")

    if reply_to_id is None:
        return None

    reply_channel_id = message.get("reply_channel_id")

    if reply_channel_id is not None and int(reply_channel_id) != channel_id:
        return None

    return int(reply_to_id)


def rewrite_message_content(content, guild_id, report):
    """Normalize Discord-only content tokens for the updated client.

    Legacy nick mentions (``<@!id>``) become plain user mentions (``<@id>``),
    which the client already renders as a chip. A Discord message link whose
    guild is the imported guild becomes root-relative
    ``/channels/<guild>/<channel>/<message>`` so the client renders a channel
    chip without a hardcoded domain; links to any other guild stay absolute.

    The rewrite is textual (content is not parsed as markdown), so it also
    applies inside code spans/blocks; that is accepted. Discord timestamps
    (``<t:...>``) are deliberately left literal.
    """
    replaced, count = LEGACY_NICK_MENTION_RE.subn(r"<\1>", content)

    if count:
        content = replaced
        report["legacy_mentions_normalized"] += count

    rewritten = [0]

    def _link(match):
        if int(match.group("guild")) != guild_id:
            return match.group(0)

        rewritten[0] += 1

        return (
            f"/channels/{match.group('guild')}/"
            f"{match.group('channel')}/{match.group('message')}"
        )

    content = DISCORD_MESSAGE_LINK_RE.sub(_link, content)

    if rewritten[0]:
        report["message_links_rewritten"] += 1

    return content


def provider_family(host):
    """Return the allowlisted GIF provider a host belongs to, or None."""
    host = (host or "").lower()

    for base in GIF_PROVIDER_DOMAINS:
        if host == base or host.endswith("." + base):
            return base

    return None


def http_host(url):
    """Return the lowercase hostname of an http(s) URL, or None."""
    if not isinstance(url, str) or not url:
        return None

    try:
        parsed = urllib.parse.urlsplit(url)
    except ValueError:
        return None

    if parsed.scheme not in ("http", "https"):
        return None

    host = (parsed.hostname or "").lower()

    return host or None


def rewrite_gif_embeds(content, raw_embeds, report):
    """Replace GIF-provider link previews with their direct media URL.

    A Giphy/Tenor/Klipy link preview carries the provider page URL in the
    content and a direct media URL on the provider's CDN in the embed
    (``video.url`` for a ``gifv``, ``image.url`` for an image). The client only
    embeds media from trusted hosts and only as direct links, so the page URL is
    swapped for the direct one (the same family the client trusts) and the
    consumed embed is dropped. Returns ``(content, remaining_embeds)``.

    An embed is left untouched when the direct URL is missing or non-https, when
    the direct host is not on the same provider family as the page URL, or when
    the page URL does not literally appear in the content (it was edited away,
    or the embed belongs to another link). No media is downloaded.
    """
    if not isinstance(raw_embeds, list) or not raw_embeds:
        if GIF_PAGE_URL_RE.search(content):
            report["gif_links_unresolved"] += len(GIF_PAGE_URL_RE.findall(content))

        return content, raw_embeds

    remaining = []
    converted = 0

    for embed in raw_embeds:
        if not isinstance(embed, dict):
            remaining.append(embed)

            continue

        page_url = embed.get("url")
        direct = None

        for key in ("video", "image"):
            candidate = embed.get(key)

            if isinstance(candidate, dict) and candidate.get("url"):
                direct = candidate.get("url")

                break

        page_family = provider_family(http_host(page_url))
        direct_family = provider_family(http_host(direct))

        if (
            not isinstance(page_url, str)
            or direct is None
            or page_family is None
            or direct_family != page_family
            or page_url not in content
        ):
            remaining.append(embed)

            continue

        content = content.replace(page_url, direct)
        converted += 1

    if converted:
        report["gif_embeds_replaced"] += converted

    if GIF_PAGE_URL_RE.search(content):
        report["gif_links_unresolved"] += len(GIF_PAGE_URL_RE.findall(content))

    return content, remaining


def is_discord_host(url):
    if not isinstance(url, str) or not url:
        return False

    host = (urllib.parse.urlsplit(url).hostname or "").lower()

    return any(host == domain or host.endswith("." + domain) for domain in DISCORD_HOSTS)


def parse_custom_emoji(text):
    """Parse ``<:name:id>`` / ``<a:name:id>`` into ``(id, name, animated)``.

    Returns ``None`` for a unicode emoji or any malformed string.
    """
    if not isinstance(text, str):
        return None

    match = CUSTOM_EMOJI_RE.match(text)

    if match is None:
        return None

    return int(match.group("id")), match.group("name"), match.group("animated") == "a"


def sanitize_emoji_name(name, min_codepoints, max_codepoints):
    """Map a Discord emoji name onto the Distrans allowlist.

    Lowercases, replaces every non-``[a-z0-9_]`` character with ``_`` and pads
    an empty/too-short name with ``emoji``. The caller is responsible for the
    final uniqueness suffix.
    """
    lowered = (name or "").lower()
    text = "".join(c if c in EMOJI_NAME_ALLOWED else "_" for c in lowered)
    text = text[:max_codepoints]

    if len(text) < min_codepoints:
        text = (text + "emoji")[:max_codepoints]

    return text


def channel_selected(channel_id, whitelist, blacklist):
    """Apply the attachment whitelist/blacklist rule for one channel id.

    Both lists default to ``None``; ``None``/empty means "not set", so with
    neither given every channel is selected.
    """
    if whitelist:
        return channel_id in whitelist

    return channel_id not in (blacklist or ())


def parse_id_list(value, flag, parser):
    if value is None:
        return None

    ids = set()

    for part in value.split(","):
        part = part.strip()

        if not part:
            continue

        if not part.isdigit():
            parser.error(f"{flag}: '{part}' is not a decimal id")

        ids.add(int(part))

    return ids


def insert_guild(cur, guild_id, name, report):
    cur.execute(
        "INSERT INTO app.guilds (id, name) VALUES (%s, %s)"
        " ON CONFLICT (id) DO NOTHING",
        (guild_id, name),
    )

    if cur.rowcount == 0:
        report["guild_existing"] = True


def upsert_everyone(cur, guild_id, roles):
    everyone = next((r for r in roles if int(r["id"]) == guild_id), None)

    if everyone is None:
        name = "@everyone"
        permissions = permission_bytea(EVERYONE_BITS)
        color = None
    else:
        name = everyone.get("name") or "@everyone"
        permissions = permission_bytea(map_permissions(everyone.get("permissions")))
        color = map_color(everyone.get("color"))

    cur.execute(
        "INSERT INTO app.roles (id, guild_id, name, position, permissions, color)"
        " VALUES (%s, %s, %s, 0, %s, %s)"
        " ON CONFLICT (id) DO UPDATE SET"
        "   name = EXCLUDED.name,"
        "   permissions = EXCLUDED.permissions,"
        "   color = EXCLUDED.color",
        (guild_id, guild_id, name, permissions, color),
    )


def insert_roles(cur, guild_id, roles, report):
    rows = []

    for role in roles:
        role_id = int(role["id"])

        if role_id == guild_id:
            continue

        rows.append(
            (
                role_id,
                guild_id,
                role.get("name") or f"role-{role_id}",
                clamp_position(role.get("position")),
                permission_bytea(map_permissions(role.get("permissions"))),
                map_color(role.get("color")),
            )
        )

    cur.executemany(
        "INSERT INTO app.roles (id, guild_id, name, position, permissions, color)"
        " VALUES (%s, %s, %s, %s, %s, %s) ON CONFLICT (id) DO NOTHING",
        rows,
    )

    report["roles_inserted"] = len(rows)


def insert_channels(cur, guild_id, imported_channels, report):
    ordered = sorted(
        imported_channels.values(),
        key=lambda c: (
            0 if c.get("type") == "category" else 1,
            clamp_position(c.get("position")),
            int(c["id"]),
        ),
    )

    rows = []

    for channel in ordered:
        channel_id = int(channel["id"])
        kind = IMPORTABLE_CHANNEL_TYPES[channel["type"]]
        name = channel.get("name") or f"channel-{channel_id}"

        parent_id = channel.get("parent_id")
        parent_id = int(parent_id) if parent_id else None

        if kind == KIND_CATEGORY:
            parent_id = None
        elif parent_id is not None and parent_id not in imported_channels:
            report["warnings"].append(
                f"channel {channel_id}: missing parent {parent_id}, importing as root"
            )
            parent_id = None

        topic = channel.get("topic") if kind == KIND_CHANNEL else None

        rows.append(
            (
                channel_id,
                guild_id,
                parent_id,
                kind,
                name,
                topic,
                clamp_position(channel.get("position")),
            )
        )

    cur.executemany(
        "INSERT INTO app.channels"
        " (id, guild_id, parent_id, kind, name, topic, position)"
        " VALUES (%s, %s, %s, %s, %s, %s, %s) ON CONFLICT (id) DO NOTHING",
        rows,
    )

    report["channels_inserted"] = len(rows)

    return {int(channel["id"]) for channel in ordered}


def insert_overwrites(cur, guild_id, imported_channels, role_ids, user_ids, report):
    rows = []

    for channel in imported_channels.values():
        channel_id = int(channel["id"])

        for overwrite in channel.get("overrides") or []:
            target_type_name = overwrite.get("target_type")
            target_id = overwrite.get("target_id")

            if target_id is None:
                continue

            target_id = int(target_id)
            allow = map_permissions(overwrite.get("allow"))
            deny = map_permissions(overwrite.get("deny"), deny=True)

            if allow == 0 and deny == 0:
                report["overwrites_skipped_empty"] += 1

                continue

            if target_type_name == "role" and target_id in role_ids:
                target_type, role_id, user_id = TARGET_ROLE, target_id, None
            elif target_type_name == "member" and target_id in user_ids:
                target_type, role_id, user_id = TARGET_MEMBER, None, target_id
            else:
                report["overwrites_skipped_missing"] += 1

                continue

            rows.append(
                (
                    guild_id,
                    channel_id,
                    target_type,
                    role_id,
                    user_id,
                    permission_bytea(allow),
                    permission_bytea(deny),
                )
            )

    cur.executemany(
        "INSERT INTO app.overwrites"
        " (guild_id, channel_id, target_type, role_id, user_id, allow, deny)"
        " VALUES (%s, %s, %s, %s, %s, %s, %s)"
        " ON CONFLICT DO NOTHING",
        rows,
    )

    report["overwrites_inserted"] = len(rows)


def insert_member_roles(cur, guild_id, members, role_ids, report):
    rows = []
    skipped = 0

    for member in members:
        user_id = int(member["id"])

        for role_id in member.get("roles") or []:
            role_id = int(role_id)

            if role_id == guild_id or role_id not in role_ids:
                skipped += 1

                continue

            rows.append((guild_id, role_id, user_id))

    cur.executemany(
        "INSERT INTO app.member_roles (guild_id, role_id, user_id)"
        " VALUES (%s, %s, %s) ON CONFLICT DO NOTHING",
        rows,
    )

    report["member_roles_inserted"] = len(rows)
    report["member_roles_skipped"] = skipped


def assign_superuser(cur, guild_id, user_id, report):
    cur.execute(
        "SELECT id FROM app.roles"
        " WHERE guild_id = %s AND name = 'superuser' AND position = %s"
        " LIMIT 1",
        (guild_id, MAX_POSITION),
    )
    row = cur.fetchone()

    if row is not None:
        role_id = int(row[0])
    else:
        cur.execute("SELECT COALESCE(MAX(id), 0) + 1 FROM app.roles")
        role_id = int(cur.fetchone()[0])

        cur.execute(
            "INSERT INTO app.roles (id, guild_id, name, position, permissions)"
            " VALUES (%s, %s, 'superuser', %s, %s) ON CONFLICT (id) DO NOTHING",
            (role_id, guild_id, MAX_POSITION, permission_bytea(ALL_BITS)),
        )

    cur.execute(
        "INSERT INTO app.member_roles (guild_id, role_id, user_id)"
        " VALUES (%s, %s, %s) ON CONFLICT DO NOTHING",
        (guild_id, role_id, user_id),
    )

    report["superuser_role_id"] = role_id


def ensure_message_schema(conn):
    with conn.cursor() as cur:
        cur.execute(
            "CREATE TEMP TABLE IF NOT EXISTS import_messages ("
            " id BIGINT,"
            " channel_id BIGINT,"
            " author_id BIGINT,"
            " webhook_id BIGINT,"
            " content TEXT,"
            " created_at TIMESTAMPTZ,"
            " edited_at TIMESTAMPTZ,"
            " embeds TEXT,"
            " reply_to_id BIGINT,"
            " pinned BOOLEAN"
            ")"
        )
        cur.execute(
            "CREATE TEMP TABLE IF NOT EXISTS import_reactions ("
            " message_id BIGINT,"
            " user_id BIGINT,"
            " emoji_kind SMALLINT,"
            " emoji_id BIGINT,"
            " unicode_emoji TEXT"
            ")"
        )

    conn.commit()


def load_emoji_dump(guild_dir, report):
    """Load the guild's own custom emoji from ``emojis.jsonl``.

    Reactions are deliberately not a source: a reaction can carry any custom
    emoji the bot can see, including emoji from other guilds, and the dump keeps
    no guild id for them. ``emojis.jsonl`` (the fetcher's ``guild.emojis``) is
    therefore the only way to tell which custom emoji belong to this guild;
    without it nothing can be attributed, so every custom emoji is skipped.
    """
    path = os.path.join(guild_dir, "emojis.jsonl")

    if not os.path.isfile(path):
        report["warnings"].append(
            "missing emojis.jsonl: custom emoji cannot be attributed to this "
            "guild and will be skipped"
        )

        return {}

    emojis = {}

    for emoji in iter_jsonl(path, report):
        emoji_id = emoji.get("id")

        if emoji_id is None:
            continue

        animated = bool(emoji.get("animated"))

        if "gif" in (urllib.parse.urlsplit(emoji.get("url") or "").path or "").lower():
            animated = True

        emojis[int(emoji_id)] = {
            "name": emoji.get("name") or f"emoji_{emoji_id}",
            "animated": animated,
        }

    return emojis


def load_webhook_dump(guild_dir, report):
    """Load the guild's webhooks from ``webhooks.jsonl``.

    A missing file is not an error: dumps produced before webhook support carry
    none, and placeholder rows are still created for webhooks referenced by
    messages. Returns ``{id: {"name", "channel_id", "avatar_url", "token"}}``.
    """
    path = os.path.join(guild_dir, "webhooks.jsonl")

    if not os.path.isfile(path):
        report["warnings"].append(
            "missing webhooks.jsonl: webhooks are only recovered from message "
            "attribution (with freshly generated tokens)"
        )

        return {}

    webhooks = {}

    for webhook in iter_jsonl(path, report):
        webhook_id = webhook.get("id")

        if webhook_id is None:
            continue

        channel_id = webhook.get("channel_id")
        channel_id = int(channel_id) if channel_id is not None else None

        token = webhook.get("token")
        token = token if isinstance(token, str) and token else None

        webhooks[int(webhook_id)] = {
            "name": webhook.get("name"),
            "channel_id": channel_id,
            "avatar_url": webhook.get("avatar_url"),
            "token": token,
        }

    return webhooks


def import_webhooks(cur, guild_id, webhook_dump, imported_channel_ids, report):
    """Insert ``app.webhooks`` rows for the dump's webhooks on imported channels.

    The token is preserved when the dump carries one (Discord exposes it only for
    Incoming webhooks); otherwise a fresh token is generated and recorded in
    ``report["webhook_tokens"]`` only when a row is actually created, so re-runs
    do not clobber the map with unused tokens. Returns the set of webhook ids
    that now have a row (whether created here or pre-existing), so message
    linking does not create placeholders for them. The per-channel cap is not
    enforced (direct DB writes only respect DB constraints).
    """
    rows = []

    for webhook_id in sorted(webhook_dump):
        meta = webhook_dump[webhook_id]
        channel_id = meta.get("channel_id")

        if channel_id is None or channel_id not in imported_channel_ids:
            report["webhooks_skipped_channel"] += 1

            continue

        token = meta.get("token")
        generated = token is None

        if generated:
            token = secrets.token_urlsafe(WEBHOOK_TOKEN_BYTES)

        rows.append(
            (
                webhook_id,
                guild_id,
                channel_id,
                meta.get("name") or f"webhook-{webhook_id}",
                hashlib.sha256(token.encode("utf-8")).digest(),
                token if generated else None,
            )
        )

    for webhook_id, webhook_guild_id, channel_id, name, token_hash, plaintext in rows:
        cur.execute(
            "INSERT INTO app.webhooks (id, guild_id, channel_id, name, token_hash)"
            " VALUES (%s, %s, %s, %s, %s) ON CONFLICT (id) DO NOTHING",
            (webhook_id, webhook_guild_id, channel_id, name, token_hash),
        )

        if cur.rowcount == 1:
            report["webhooks_imported"] += 1

            if plaintext is not None:
                report["webhook_tokens"][str(webhook_id)] = plaintext

    return {row[0] for row in rows}


def create_webhook_placeholders(cur, guild_id, pending, known_webhook_ids, report):
    """Materialize placeholders for webhooks seen only in messages.

    A message can reference a webhook that ``webhooks.jsonl`` does not list (it
    was deleted before the dump, or its channel was not imported), so a row is
    created to keep the attribution. The channel is the message's channel; a
    fresh token is generated and recorded in the report.
    """
    for webhook_id in sorted(pending):
        if webhook_id in known_webhook_ids:
            continue

        channel_id, name = pending[webhook_id]

        if channel_id is None:
            continue

        token = secrets.token_urlsafe(WEBHOOK_TOKEN_BYTES)

        cur.execute(
            "INSERT INTO app.webhooks (id, guild_id, channel_id, name, token_hash)"
            " VALUES (%s, %s, %s, %s, %s) ON CONFLICT (id) DO NOTHING",
            (
                webhook_id,
                guild_id,
                channel_id,
                name or f"webhook-{webhook_id}",
                hashlib.sha256(token.encode("utf-8")).digest(),
            ),
        )

        if cur.rowcount == 1:
            known_webhook_ids.add(webhook_id)
            report["webhook_placeholders_created"] += 1
            report["webhook_tokens"][str(webhook_id)] = token


def import_emojis(cur, guild_id, emoji_dump, limits, min_codepoints, max_codepoints, refresh, report, state):
    """Download and store the guild's custom emoji icons.

    Icons are re-encoded to WebP (``media.emoji``) and hashed with XXHash64,
    matching the server's ``app.emojis.icon_data`` / ``icon_hash`` contract.
    Emojis whose icon cannot be fetched are skipped (``icon_data`` is NOT NULL).

    ``emoji_dump`` is the guild's own emoji from ``emojis.jsonl`` (reaction
    emoji from other guilds are never added here). ``state`` carries the
    already-attempted ids and the guild's claimed names across calls so nothing
    is re-downloaded and no two rows share a ``(guild_id, name)``.
    """
    from concurrent.futures import ThreadPoolExecutor

    log = lambda message: print(f"  emoji: {message}", file=sys.stderr)  # noqa: E731

    if state.get("names") is None:
        cur.execute(
            "SELECT id, name FROM app.emojis WHERE guild_id = %s", (guild_id,)
        )
        rows = cur.fetchall()
        state["names"] = {row[1] for row in rows}
        state["existing_ids"] = {int(row[0]) for row in rows}
        state["existing_names"] = {int(row[0]): row[1] for row in rows}

    attempted = state.setdefault("attempted", set())
    existing_ids = state["existing_ids"]
    ids = [
        emoji_id
        for emoji_id in sorted(emoji_dump)
        if emoji_id not in attempted
        and (refresh or emoji_id not in existing_ids)
    ]

    if not ids:
        return

    attempted.update(ids)

    def encode_one(emoji_id):
        meta = emoji_dump[emoji_id]
        url = normalize_emoji_url(emoji_id, meta["animated"], limits.max_dimensions)

        return emoji_id, encode_emoji(url, limits, log=log)

    pending_rows = []

    with ThreadPoolExecutor(max_workers=EMOJI_CONCURRENCY) as pool:
        for emoji_id, encoded in pool.map(encode_one, ids):
            if encoded is None:
                report["emoji_icons_skipped"] += 1

                continue

            meta = emoji_dump[emoji_id]
            previous = state["existing_names"].get(emoji_id)

            if previous is not None:
                # Keep the existing name so (guild_id, name) stays stable, but
                # make sure it is not reassigned to another emoji.
                candidate = previous
            else:
                name = sanitize_emoji_name(meta["name"], min_codepoints, max_codepoints)
                candidate = name
                suffix = 2

                while candidate in state["names"]:
                    candidate = f"{name}_{suffix}"
                    suffix += 1

            state["names"].add(candidate)
            state["existing_names"][emoji_id] = candidate
            state["existing_ids"].add(emoji_id)
            pending_rows.append(
                (emoji_id, guild_id, candidate, encoded.data, encoded.hash)
            )

    if not pending_rows:
        return

    if refresh:
        cur.executemany(
            "INSERT INTO app.emojis (id, guild_id, name, icon_data, icon_hash)"
            " VALUES (%s, %s, %s, %s, %s)"
            " ON CONFLICT (id) DO UPDATE SET"
            "   icon_data = EXCLUDED.icon_data,"
            "   icon_hash = EXCLUDED.icon_hash",
            pending_rows,
        )
    else:
        cur.executemany(
            "INSERT INTO app.emojis (id, guild_id, name, icon_data, icon_hash)"
            " VALUES (%s, %s, %s, %s, %s) ON CONFLICT (id) DO NOTHING",
            pending_rows,
        )

    report["emojis_inserted"] += len(pending_rows)
    report["emoji_ids_stored"] = len(state["existing_ids"])


def import_webhook_avatars(conn, cur, webhook_dump, imported_channel_ids, limits, refresh, report):
    """Fill missing webhook avatars from the dump URLs.

    Fill-only by default, mirroring :func:`sync_avatars`: an avatar already
    stored is never re-downloaded. With ``refresh`` every webhook that has a
    dump URL is re-encoded and overwritten; a source that cannot be brought
    within the caps is skipped and counted either way.
    """
    from concurrent.futures import ThreadPoolExecutor

    log = lambda message: print(f"  webhook avatar: {message}", file=sys.stderr)  # noqa: E731

    targets = sorted(
        webhook_id
        for webhook_id, meta in webhook_dump.items()
        if meta.get("avatar_url")
        and meta.get("channel_id") is not None
        and meta.get("channel_id") in imported_channel_ids
    )

    if not targets:
        return

    cur.execute(
        "SELECT id, avatar_data IS NULL FROM app.webhooks WHERE id = ANY(%s::bigint[])",
        (targets,),
    )
    missing = {int(row[0]): bool(row[1]) for row in cur.fetchall()}
    needed = [webhook_id for webhook_id in sorted(missing) if missing[webhook_id] or refresh]

    if not needed:
        return

    def encode_one(webhook_id):
        url = normalize_cdn_size(
            webhook_dump[webhook_id]["avatar_url"], limits.max_dimensions
        )

        return webhook_id, encode_avatar(url, limits, log=log)

    processed = 0

    with ThreadPoolExecutor(max_workers=AVATAR_CONCURRENCY) as pool:
        for webhook_id, encoded in pool.map(encode_one, needed):
            if encoded is None:
                report["webhook_avatars_skipped"] += 1

                continue

            cur.execute(
                "UPDATE app.webhooks SET avatar_data = %s, avatar_hash = %s WHERE id = %s",
                (encoded.data, encoded.hash, webhook_id),
            )
            report["webhook_avatars_set"] += 1
            processed += 1

            if processed % 100 == 0:
                conn.commit()

    conn.commit()


def flush_reactions(cur, report):
    cur.execute(
        "INSERT INTO app.message_reactions"
        " (message_id, user_id, emoji_kind, emoji_id, unicode_emoji)"
        " SELECT r.message_id, r.user_id, r.emoji_kind, r.emoji_id, r.unicode_emoji"
        " FROM import_reactions r"
        " WHERE EXISTS (SELECT 1 FROM app.messages m WHERE m.id = r.message_id)"
        "   AND EXISTS ("
        "     SELECT 1 FROM app.users u"
        "     WHERE u.id = r.user_id AND u.deleted_at IS NULL"
        "   )"
        "   AND (r.emoji_kind = 0 OR EXISTS ("
        "     SELECT 1 FROM app.emojis e WHERE e.id = r.emoji_id"
        "   ))"
        " ON CONFLICT DO NOTHING"
    )
    report["reactions_inserted"] += cur.rowcount

    cur.execute(
        "SELECT count(*) FROM import_reactions r"
        " WHERE NOT EXISTS (SELECT 1 FROM app.messages m WHERE m.id = r.message_id)"
        "    OR NOT EXISTS ("
        "      SELECT 1 FROM app.users u"
        "      WHERE u.id = r.user_id AND u.deleted_at IS NULL"
        "    )"
    )
    report["reactions_skipped_no_user"] += cur.fetchone()[0]

    cur.execute(
        "SELECT count(*) FROM import_reactions r"
        " WHERE r.emoji_kind = 1"
        "   AND NOT EXISTS (SELECT 1 FROM app.emojis e WHERE e.id = r.emoji_id)"
    )
    report["reactions_skipped_no_emoji"] += cur.fetchone()[0]

    cur.execute("TRUNCATE import_reactions")



def collect_users(message, member_ids, cache, pending_ids, deleted_ids):
    author_id = message.get("author_id")

    # A webhook message has no user author: the dump's `author_id` is the
    # webhook id (the pseudo-user), and the message is linked via
    # `webhook_id` with `author_id` NULL instead.
    if author_id is not None and message.get("webhook_id") is None:
        author_id = int(author_id)
        cache.add_author(message)

        if message.get("author_name") == DELETED_AUTHOR_NAME and author_id not in member_ids:
            deleted_ids.add(author_id)

        pending_ids.add(author_id)

    for mention_id in message.get("mentions") or []:
        mention_id = int(mention_id)
        cache.add_mention(mention_id)
        pending_ids.add(mention_id)


def insert_user_rows(cur, rows):
    """Insert bounded batches and return exactly the user IDs inserted here."""
    inserted = set()

    for start in range(0, len(rows), 5000):
        batch = rows[start : start + 5000]
        values_sql = ", ".join(["(%s, %s, %s, %s, %s, %s)"] * len(batch))
        params = [value for row in batch for value in row]
        cur.execute(
            "INSERT INTO app.users"
            " (id, username, display_name, password_hash, is_bot, deleted_at)"
            f" VALUES {values_sql} ON CONFLICT (id) DO NOTHING RETURNING id",
            params,
        )
        inserted.update(int(row[0]) for row in cur.fetchall())

    return inserted


def flush_users(cur, cache, pending_ids, known_user_ids, inserted_user_ids, deleted_ids, usernames, report):
    new_ids = [user_id for user_id in pending_ids if user_id not in known_user_ids]

    if not new_ids:
        pending_ids.clear()

        return

    now = datetime.datetime.now(datetime.timezone.utc)
    rows = []

    for user_id in sorted(new_ids):
        record = cache.records.get(user_id) or {}

        if record.get("deleted") or user_id in deleted_ids:
            rows.append((user_id, f"deleted-{user_id}", None, None, False, now))
        else:
            rows.append(
                (
                    user_id,
                    usernames.take(record.get("username"), user_id),
                    record.get("display_name"),
                    None,
                    False,
                    None,
                )
            )

    actually_inserted = insert_user_rows(cur, rows)

    known_user_ids.update(new_ids)
    inserted_user_ids.update(actually_inserted)
    report["users_inserted"] += len(actually_inserted)
    pending_ids.clear()


def unique_username(usernames, base, user_id, current):
    if base == current:
        return base

    if base not in usernames.used:
        return base

    candidate = f"{base}.{user_id}"

    if candidate not in usernames.used:
        return candidate

    suffix = 2

    while f"{candidate}.{suffix}" in usernames.used:
        suffix += 1

    return f"{candidate}.{suffix}"


def refresh_users(cur, cache, usernames, inserted_user_ids, refresh_existing, report):
    """Apply cached identities to rows created in this run (and, optionally, all)."""
    user_ids = sorted(
        user_id for user_id, record in cache.records.items() if not record.get("deleted")
    )

    if not user_ids:
        return

    cur.execute(
        "SELECT id, username, display_name FROM app.users WHERE id = ANY(%s::bigint[])",
        (user_ids,),
    )
    current = {int(row[0]): (row[1], row[2]) for row in cur.fetchall()}

    for user_id in user_ids:
        if user_id not in current:
            continue

        if not refresh_existing and user_id not in inserted_user_ids:
            continue

        old_username, old_display_name = current[user_id]
        record = cache.records[user_id]
        desired_username = record.get("username")
        desired_display_name = record.get("display_name")

        new_username = old_username

        if desired_username and desired_username != old_username:
            new_username = unique_username(usernames, desired_username, user_id, old_username)
            usernames.used.discard(old_username)
            usernames.used.add(new_username)

        if new_username == old_username and desired_display_name == old_display_name:
            continue

        cur.execute(
            "UPDATE app.users SET username = %s, display_name = %s WHERE id = %s",
            (new_username, desired_display_name, user_id),
        )
        report["users_refreshed"] += 1


def anonymize_deleted_users(cur, deleted_ids, inserted_user_ids, report):
    """Anonymize only deleted-user placeholders inserted by this import."""
    new_deleted_ids = deleted_ids & inserted_user_ids

    if not new_deleted_ids:
        return

    cur.execute(
        "UPDATE app.users"
        " SET deleted_at = now(),"
        "     username = 'deleted-' || id::text,"
        "     password_hash = NULL,"
        "     display_name = NULL,"
        "     avatar_data = NULL,"
        "     avatar_hash = NULL"
        " WHERE id = ANY(%s) AND deleted_at IS NULL",
        (list(new_deleted_ids),),
    )

    report["deleted_users_anonymized"] = cur.rowcount


def sync_avatars(conn, cur, guild_id, guild, cache, limits, refresh, report):
    """Fill missing (or, with `refresh`, all) avatars from the dump URLs."""
    from concurrent.futures import ThreadPoolExecutor

    log = lambda message: print(f"  avatar: {message}", file=sys.stderr)  # noqa: E731

    icon_url = (guild or {}).get("icon_url")

    if icon_url:
        cur.execute("SELECT avatar_data IS NULL FROM app.guilds WHERE id = %s", (guild_id,))
        row = cur.fetchone()

        if row is not None and (refresh or row[0]):
            encoded = encode_avatar(
                normalize_cdn_size(icon_url, limits.max_dimensions), limits, log=log
            )

            if encoded is None:
                report["avatars_skipped"] += 1
            else:
                cur.execute(
                    "UPDATE app.guilds SET avatar_data = %s, avatar_hash = %s WHERE id = %s",
                    (encoded.data, encoded.hash, guild_id),
                )
                report["guild_avatar_set"] = 1
                conn.commit()

    targets = sorted(
        user_id
        for user_id, record in cache.records.items()
        if record.get("avatar_url") and not record.get("deleted")
    )

    if not targets:
        return

    cur.execute(
        "SELECT id, avatar_data IS NULL FROM app.users"
        " WHERE id = ANY(%s::bigint[]) AND deleted_at IS NULL",
        (targets,),
    )
    missing = {int(row[0]): bool(row[1]) for row in cur.fetchall()}
    needed = [user_id for user_id in sorted(missing) if missing[user_id] or refresh]

    if not needed:
        return

    def encode_one(user_id):
        url = normalize_cdn_size(cache.records[user_id]["avatar_url"], limits.max_dimensions)

        return user_id, encode_avatar(url, limits, log=log)

    processed = 0

    with ThreadPoolExecutor(max_workers=AVATAR_CONCURRENCY) as pool:
        for user_id, encoded in pool.map(encode_one, needed):
            if encoded is None:
                report["avatars_skipped"] += 1

                continue

            if encoded.downgraded:
                report["avatars_animation_downgraded"] += 1

            cur.execute(
                "UPDATE app.users SET avatar_data = %s, avatar_hash = %s"
                " WHERE id = %s AND deleted_at IS NULL",
                (encoded.data, encoded.hash, user_id),
            )

            if missing[user_id]:
                report["avatars_inserted"] += 1
            else:
                report["avatars_refreshed"] += 1

            processed += 1

            if processed % 100 == 0:
                conn.commit()

    conn.commit()


def import_message_file(
    cur, guild_id, channel_id, path, cache, member_ids, known_user_ids, inserted_user_ids,
    known_webhook_ids, pending_webhooks, usernames, deleted_ids, max_embeds, report,
    want_attachments=False, guild_emoji_ids=frozenset()
):
    pending_users = set()
    staged_attachments = []
    staged_reactions = []
    written = 0
    now = datetime.datetime.now(datetime.timezone.utc)

    with open(path, "r", encoding="utf-8") as f:
        with cur.copy(MESSAGE_COPY_SQL) as copy:
            for line_no, line in enumerate(f, 1):
                line = line.strip()

                if not line:
                    continue

                try:
                    message = json.loads(line)
                except json.JSONDecodeError:
                    report["malformed_lines"].append(f"{path}:{line_no}")

                    continue

                collect_users(message, member_ids, cache, pending_users, deleted_ids)

                content = (message.get("content") or "").replace("\x00", "")
                content = rewrite_message_content(content, guild_id, report)
                content, remaining_embeds = rewrite_gif_embeds(
                    content, message.get("embeds"), report
                )
                embeds, embeds_over_limit = normalize_embeds(remaining_embeds, max_embeds)

                if embeds_over_limit:
                    report["embeds_skipped_too_many"] += 1

                if not message_has_payload(message):
                    report["messages_skipped_empty"] += 1

                    continue

                message_id = int(message["id"])

                webhook_id = message.get("webhook_id")
                webhook_id = int(webhook_id) if webhook_id is not None else None

                author_id = message.get("author_id")

                if author_id is not None and webhook_id is None:
                    author_id = int(author_id)
                else:
                    author_id = None

                if webhook_id is not None:
                    pending_webhooks.setdefault(
                        webhook_id, (channel_id, message.get("author_name"))
                    )

                copy.write_row(
                    (
                        message_id,
                        channel_id,
                        author_id,
                        webhook_id,
                        content,
                        parse_timestamp(message.get("created_at")) or now,
                        parse_timestamp(message.get("edited_at")),
                        embeds,
                        resolve_reply(message, channel_id),
                        bool(message.get("pinned")),
                    )
                )

                written += 1

                for row in stage_message_reactions(
                    message, message_id, guild_emoji_ids, report
                ):
                    staged_reactions.append(row)
                    pending_users.add(row[1])

                if want_attachments:
                    for position, attachment in enumerate(message.get("attachments") or []):
                        staged_attachments.append((message_id, position, attachment))

    if staged_reactions:
        with cur.copy(REACTION_COPY_SQL) as copy:
            for row in staged_reactions:
                copy.write_row(row)

    # Before flush_messages, so the message FK resolves.
    if pending_webhooks:
        create_webhook_placeholders(
            cur, guild_id, pending_webhooks, known_webhook_ids, report
        )
        pending_webhooks.clear()

    flush_users(
        cur, cache, pending_users, known_user_ids, inserted_user_ids,
        deleted_ids, usernames, report
    )

    return written, staged_attachments


def flush_messages(cur, report):
    cur.execute(
        "INSERT INTO app.messages"
        " (id, channel_id, guild_id, author_id, webhook_id, content, created_at, edited_at, embeds, pinned)"
        " SELECT i.id, i.channel_id, c.guild_id, i.author_id, i.webhook_id, i.content, i.created_at,"
        "        i.edited_at, i.embeds, COALESCE(i.pinned, false)"
        " FROM import_messages i"
        " JOIN app.channels c ON c.id = i.channel_id"
        " WHERE NOT EXISTS (SELECT 1 FROM app.messages m WHERE m.id = i.id)"
        " RETURNING id, webhook_id"
    )
    inserted_message_ids = set()
    webhook_messages = 0

    for row in cur.fetchall():
        inserted_message_ids.add(int(row[0]))

        if row[1] is not None:
            webhook_messages += 1

    report["messages_inserted"] += len(inserted_message_ids)
    report["messages_webhook"] += webhook_messages

    # Backfill pins on re-runs, fill-only: add a pin the dump has but the DB
    # lacks, never clear one (a pin the app added, or an unpin done in-app after
    # the dump was taken, is left alone).
    cur.execute(
        "UPDATE app.messages m SET pinned = true"
        " FROM import_messages i"
        " WHERE m.id = i.id AND i.pinned AND NOT m.pinned"
    )
    report["messages_pinned"] += cur.rowcount

    cur.execute(
        "UPDATE app.messages m SET embeds = i.embeds"
        " FROM import_messages i"
        " WHERE m.id = i.id AND m.embeds IS NULL AND i.embeds IS NOT NULL"
    )

    cur.execute("SELECT count(*) FROM import_messages WHERE embeds IS NOT NULL")
    report["embeds_inserted"] += cur.fetchone()[0]

    cur.execute(
        "UPDATE app.messages m"
        " SET reply_to_id = i.reply_to_id"
        " FROM import_messages i"
        " WHERE m.id = i.id"
        "   AND m.reply_to_id IS NULL"
        "   AND i.reply_to_id IS NOT NULL"
        "   AND EXISTS ("
        "     SELECT 1 FROM app.messages t"
        "     WHERE t.id = i.reply_to_id AND t.channel_id = m.channel_id"
        "   )"
    )
    report["replies_linked"] += cur.rowcount

    cur.execute(
        "SELECT count(*) FROM import_messages i"
        " WHERE i.reply_to_id IS NOT NULL"
        "   AND NOT EXISTS ("
        "     SELECT 1 FROM app.messages t"
        "     WHERE t.id = i.reply_to_id AND t.channel_id = i.channel_id"
        "   )"
    )
    report["replies_dropped"] += cur.fetchone()[0]

    return inserted_message_ids


def clear_import_staging(cur):
    cur.execute("TRUNCATE import_messages, import_reactions")


def message_has_payload(message):
    """True when a message carries content, embeds or attachments."""
    if (message.get("content") or "").replace("\x00", ""):
        return True

    if message.get("embeds"):
        return True

    return bool(message.get("attachments"))


def stage_message_reactions(message, message_id, guild_emoji_ids, report):
    """Stage one row per captured reacting user for every reaction.

    A custom emoji must be part of this guild (``guild_emoji_ids``, from
    ``emojis.jsonl``): a Discord reaction can hold any custom emoji the bot can
    see, so one pointing elsewhere is dropped rather than linked to a foreign
    emoji row.
    """
    rows = []

    for reaction in message.get("reactions") or []:
        users = reaction.get("users") or []

        if not users:
            report["reactions_skipped_empty"] += 1

            continue

        emoji = reaction.get("emoji")
        parsed = parse_custom_emoji(emoji)

        if parsed is not None:
            emoji_id, _name, _animated = parsed
            kind, unicode_emoji = 1, None

            if emoji_id not in guild_emoji_ids:
                report["reactions_skipped_foreign"] += 1

                continue
        else:
            if not isinstance(emoji, str) or not emoji:
                continue

            emoji_id = None
            kind, unicode_emoji = 0, emoji

        for user_id in users:
            rows.append((message_id, int(user_id), kind, emoji_id, unicode_emoji))

    return rows


def guess_content_type(attachment):
    content_type = attachment.get("content_type")

    if isinstance(content_type, str) and content_type:
        return content_type

    guessed = mimetypes.guess_type(attachment.get("filename") or "")[0]

    return guessed or "application/octet-stream"


def refresh_expired_urls(client, channel_id, candidates, report):
    """Re-sign expired CDN URLs and point the candidates at the fresh ones.

    Uses the bot-only ``POST /attachments/refresh-urls`` batch endpoint (50 URLs
    per request) for the fast path; anything it cannot re-sign is looked up
    message-by-message as a fallback. Returns the candidates whose URL could not
    be refreshed (to be skipped).
    """
    expired = [
        entry for entry in candidates if signed_url_expired(entry[3].get("url"))
    ]

    if not expired:
        return []

    if client is None:
        report["attachments_skipped_expired"] += len(expired)

        return expired

    unique_urls = []
    seen = set()

    for entry in expired:
        url = entry[3].get("url")

        if url and url not in seen:
            seen.add(url)
            unique_urls.append(url)

    try:
        mapping = client.refresh_attachment_urls(unique_urls)
    except DiscordError as e:
        report["warnings"].append(
            f"channel {channel_id}: failed to refresh attachment URLs: {e}"
        )
        mapping = {}

    unresolved = []

    for entry in expired:
        url = entry[3].get("url")
        fresh = mapping.get(url)

        if fresh:
            entry[3]["url"] = fresh
        else:
            unresolved.append(entry)

    refreshed = len(expired) - len(unresolved)

    if unresolved:
        still = refresh_urls_per_message(client, channel_id, unresolved, report)
        refreshed -= len(still)
        unresolved = still

    report["attachments_refreshed"] += refreshed
    report["attachments_skipped_expired"] += len(unresolved)

    return unresolved


def refresh_urls_per_message(client, channel_id, entries, report):
    """Fallback: fetch the affected messages individually to find fresh URLs."""
    by_message = {}

    for entry in entries:
        by_message.setdefault(entry[0], []).append(entry)

    fetched = {}

    for message_id in by_message:
        try:
            fetched[message_id] = client.get_message(channel_id, message_id)
        except Exception as e:  # noqa: BLE001 - a closed channel is a skip
            report["warnings"].append(
                f"message {message_id}: failed to refresh attachment URL: {e}"
            )
            fetched[message_id] = None

    unresolved = []

    for entry in entries:
        message_id, position, att_id, att = entry
        message = fetched.get(message_id)
        fresh = fresh_attachment_urls(message) if message is not None else {}

        if att_id in fresh:
            att["url"] = fresh[att_id]
        else:
            unresolved.append(entry)

    return unresolved


def store_attachment(cur, s3, att_id, data, att, report):
    """Store downloaded bytes as a raw ``files/<sha256>`` object.

    Inserts (or reuses) the matching ``app.files`` row and returns its id and
    stored content type. Uploading even on a hash conflict restores a missing
    content-addressed object when the bytes are available.
    """
    digest = hashlib.sha256(data).hexdigest()
    name = (att.get("filename") or f"file-{att_id}").replace("\x00", "")
    content_type = guess_content_type(att)

    cur.execute(
        "INSERT INTO app.files (id, name, hash, size, content_type)"
        " VALUES (%s, %s, %s, %s, %s) ON CONFLICT DO NOTHING",
        (att_id, name, digest, len(data), content_type),
    )

    inserted = cur.rowcount == 1

    if not inserted:
        cur.execute(
            "SELECT id, content_type FROM app.files WHERE hash = %s",
            (digest,),
        )
        row = cur.fetchone()

        if row is None:
            report["warnings"].append(
                f"attachment {att_id}: existing file id conflicts with different bytes"
            )

            return None

        file_id, stored_content_type = int(row[0]), row[1]
        content_type = stored_content_type
    else:
        file_id, stored_content_type = att_id, content_type

    if s3 is None or not s3.available():
        if inserted:
            cur.execute(
                "DELETE FROM app.files WHERE id = %s AND hash = %s",
                (att_id, digest),
            )
        report["warnings"].append(
            f"attachment {att_id}: S3 is unavailable; stored bytes cannot be restored"
        )

        return None

    try:
        s3.put(f"files/{digest}", data, stored_content_type)
        report["s3_puts"] += 1
    except S3Error as e:
        if inserted:
            cur.execute(
                "DELETE FROM app.files WHERE id = %s AND hash = %s",
                (att_id, digest),
            )
        report["warnings"].append(f"attachment {att_id}: S3 upload/restore failed: {e}")

        return None

    report["attachments_uploaded"] += 1
    report["attachment_bytes_uploaded"] += len(data)

    return file_id, stored_content_type


def link_attachments(cur, links, report):
    """Insert the missing ``app.message_attachments`` rows, one per link.

    Uses ``ON CONFLICT (message_id, file_id) DO NOTHING`` and guards both FKs.
    Existing positions are preserved, and a conflicting position is skipped to
    avoid a deferred uniqueness violation aborting the channel transaction.
    """
    linked = 0
    linked_pairs = set()
    conflicting_positions = set()

    for message_id, file_id, position in links:
        pair = (message_id, file_id)

        if pair in linked_pairs:
            continue

        if (message_id, position) in conflicting_positions:
            continue

        cur.execute(
            "INSERT INTO app.message_attachments (message_id, file_id, position)"
            " SELECT %s, %s, %s"
            " WHERE EXISTS (SELECT 1 FROM app.messages m WHERE m.id = %s)"
            "   AND EXISTS (SELECT 1 FROM app.files f WHERE f.id = %s)"
            "   AND NOT EXISTS (SELECT 1 FROM app.message_attachments a"
            "                   WHERE a.message_id = %s AND a.position = %s"
            "                     AND a.file_id <> %s)"
            " ON CONFLICT (message_id, file_id) DO NOTHING",
            (message_id, file_id, position, message_id, file_id,
             message_id, position, file_id),
        )
        linked += cur.rowcount

        if cur.rowcount == 1:
            linked_pairs.add(pair)
        else:
            cur.execute(
                "SELECT 1 FROM app.message_attachments"
                " WHERE message_id = %s AND file_id = %s",
                pair,
            )

            if cur.fetchone() is not None:
                linked_pairs.add(pair)
            else:
                conflicting_positions.add((message_id, position))

    report["attachments_linked"] += linked

    return linked_pairs


def serialize_attachment_token(file_id, filename, content_type):
    """Serialize a stored file reference using the chat client's markdown form."""
    label = (filename or f"file-{file_id}").replace("\x00", "")
    label = re.sub(r"[\r\n]+", " ", label)
    label = re.sub(r"([\\\[\]()])", r"\\\1", label)
    marker = "!" if content_type in INLINE_IMAGE_TYPES else ""

    return f"{marker}[{label}](attachment://{file_id})"


def append_attachment_tokens(cur, references):
    """Append linked-file tokens without replacing imported or existing text."""
    by_message = {}

    for message_id, file_id, filename, content_type in references:
        by_message.setdefault(message_id, []).append(
            serialize_attachment_token(file_id, filename, content_type)
        )

    for message_id, tokens in by_message.items():
        cur.execute("SELECT content FROM app.messages WHERE id = %s FOR UPDATE", (message_id,))
        row = cur.fetchone()

        if row is None:
            continue

        content = row[0] or ""

        existing_ids = {
            int(match.group(1)) for match in ATTACHMENT_TOKEN_RE.finditer(content)
        }
        filtered_tokens = []

        for token in tokens:
            match = ATTACHMENT_TOKEN_RE.search(token)

            if match is None:
                filtered_tokens.append(token)
                continue

            file_id = int(match.group(1))

            if file_id in existing_ids:
                continue

            filtered_tokens.append(token)

        tokens = filtered_tokens

        if not tokens:
            continue

        newline_count = len(content) - len(content.rstrip("\n"))
        separator = "\n" * max(0, 2 - newline_count) if content else ""
        cur.execute(
            "UPDATE app.messages SET content = %s WHERE id = %s",
            (content + separator + "\n".join(tokens), message_id),
        )


def backfill_attachment_tokens(cur):
    """Backfill tokens from existing links during --refresh-messages only."""
    cur.execute(
        "SELECT ma.message_id, ma.file_id, f.name, f.content_type"
        " FROM app.message_attachments ma"
        " JOIN app.files f ON f.id = ma.file_id"
        " JOIN import_messages i ON i.id = ma.message_id"
        " ORDER BY ma.message_id, ma.position"
    )
    append_attachment_tokens(cur, cur.fetchall())


def process_attachments(cur, s3, channel_id, attachments, report, discord_client=None, message_filter=None):
    """Download, store and link the attachments of one message file.

    ``attachment`` entries are ``(message_id, position, att)`` where ``att`` is
    the raw dump object. Only Discord-CDN URLs are fetched; bytes are stored raw
    (no re-encode, no size cap) as ``files/<sha256>``. Expired signed URLs are
    refreshed in batch first.

    Links are written straight into ``app.message_attachments`` in the caller's
    transaction, next to the ``app.files`` row, so a crash can no longer commit
    a file row without its link. An attachment whose file row already exists is
    reused without a download and its missing link is re-created, so re-running
    with ``--refresh-messages`` repairs earlier orphans. Messages already linked
    at a given position are skipped. ``message_filter`` (a set) limits the work
    to those message ids; ``None`` means all. Fails soft per attachment.
    """
    from concurrent.futures import ThreadPoolExecutor

    if not attachments:
        return []

    if message_filter is not None:
        attachments = [entry for entry in attachments if entry[0] in message_filter]

        if not attachments:
            return []

    message_ids = {message_id for message_id, _, _ in attachments}
    existing_positions = set()

    if message_ids:
        cur.execute(
            "SELECT message_id, position FROM app.message_attachments"
            " WHERE message_id = ANY(%s::bigint[])",
            (sorted(message_ids),),
        )
        existing_positions = {(int(mid), int(pos)) for mid, pos in cur.fetchall()}

    links = []
    references = []
    unresolved = []
    seen_positions = set()

    for message_id, position, att in attachments:
        att_id = att.get("id")

        if att_id is None:
            report["attachments_skipped_download"] += 1

            continue

        att_id = int(att_id)

        if (message_id, position) in existing_positions or (message_id, position) in seen_positions:
            report["attachments_skipped_existing"] += 1

            continue

        seen_positions.add((message_id, position))

        url = att.get("url")

        if not is_discord_host(url):
            report["attachments_skipped_host"] += 1

            continue

        unresolved.append((message_id, position, att_id, att))

    if unresolved:
        still = set(
            id(entry)
            for entry in refresh_expired_urls(
                discord_client, channel_id, unresolved, report
            )
        )
        unresolved = [entry for entry in unresolved if id(entry) not in still]

        # One download per distinct Discord attachment id.
        unique = {}

        for entry in unresolved:
            unique.setdefault(entry[2], entry)

        def fetch_one(entry):
            try:
                data = download_bytes(entry[3]["url"])
            except Exception as e:  # noqa: BLE001 - a bad attachment must not abort
                return entry, None, str(e)

            return entry, data, None

        resolved = {}

        if unique:
            with ThreadPoolExecutor(max_workers=ATTACHMENT_CONCURRENCY) as pool:
                for entry, data, error in pool.map(fetch_one, unique.values()):
                    if data is None:
                        report["attachments_skipped_download"] += 1

                        continue

                    stored = store_attachment(cur, s3, entry[2], data, entry[3], report)

                    if stored is None:
                        report["attachments_skipped_download"] += 1

                        continue

                    resolved[entry[2]] = stored

        for message_id, position, att_id, att in unresolved:
            stored = resolved.get(att_id)

            if stored is not None:
                file_id, content_type = stored
                links.append((message_id, file_id, position))
                references.append(
                    (message_id, file_id, att.get("filename"), content_type)
                )

    if links:
        linked_pairs = link_attachments(cur, links, report)
        references = [ref for ref in references if (ref[0], ref[1]) in linked_pairs]
        append_attachment_tokens(cur, references)

    return references



def write_report(report_path, report):
    with open(report_path, "w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=2)
        f.write("\n")

    print(f"Report written to {report_path}")


def _supports_extract_filter():
    try:
        params = inspect.signature(tarfile.TarFile.extractall).parameters
    except (TypeError, ValueError):
        return False

    return "filter" in params


def safe_extract(tar, dest_dir):
    """Extract `tar` into `dest_dir`, rejecting entries that escape it."""
    if _supports_extract_filter():
        try:
            tar.extractall(dest_dir, filter="data")

            return
        except tarfile.FilterError as e:
            fail(f"unsafe archive entry: {e}")

    dest_real = os.path.realpath(dest_dir)

    for member in tar:
        if os.path.isabs(member.name):
            fail(f"unsafe archive entry: {member.name}")

        target = os.path.realpath(os.path.join(dest_real, member.name))

        if os.path.commonpath([dest_real, target]) != dest_real:
            fail(f"unsafe archive entry: {member.name}")

        if member.issym() or member.islnk():
            link_target = os.path.realpath(
                os.path.join(os.path.dirname(target), member.linkname)
            )

            if os.path.commonpath([dest_real, link_target]) != dest_real:
                fail(f"unsafe archive link: {member.name}")

        tar.extract(member, dest_dir)


def resolve_archive_root(root):
    """Find the guild dir inside an extracted archive root."""
    if os.path.isfile(os.path.join(root, "guild.json")):
        return root

    entries = [entry for entry in os.listdir(root) if entry != "__MACOSX"]

    if len(entries) == 1:
        candidate = os.path.join(root, entries[0])

        if os.path.isdir(candidate):
            return candidate

    return root


def extract_archive(archive_path, dest_dir):
    try:
        import zstandard
    except ImportError:
        fail("zstd import needs the 'zstandard' package (uv add zstandard)")

    with open(archive_path, "rb") as f:
        with zstandard.ZstdDecompressor().stream_reader(f) as reader:
            with tarfile.open(fileobj=reader, mode="r|") as tar:
                safe_extract(tar, dest_dir)

    return resolve_archive_root(dest_dir)


def max_embeds_from_config(config):
    api = config.get("api") if isinstance(config, dict) else None
    messages = api.get("messages") if isinstance(api, dict) else None
    value = messages.get("max_embeds") if isinstance(messages, dict) else None

    if isinstance(value, int) and not isinstance(value, bool) and value > 0:
        return value

    return MAX_EMBEDS_DEFAULT


def main():
    parser = argparse.ArgumentParser(
        prog="importguild",
        description="Import a fetcher guild dump directly into the Distrans database.",
    )
    add_config_arg(parser)
    parser.add_argument(
        "guild_dir",
        help="path to a <root>/<guild_id> dump directory or a .tar.zst archive",
    )
    parser.add_argument("--guild-name", default=None, help="override the guild name")
    parser.add_argument(
        "--admin-user-id",
        default=None,
        help="optional user id that gets a superuser role (all permissions, max position)",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=None,
        help="max number of message files to import (debugging aid)",
    )
    parser.add_argument(
        "--refresh-users",
        action="store_true",
        help="overwrite the username and display_name of existing users from the dump",
    )
    parser.add_argument(
        "--refresh-avatars",
        action="store_true",
        help="re-download and overwrite avatars that are already stored",
    )
    parser.add_argument(
        "--refresh-emoji",
        action="store_true",
        help="re-download and overwrite icons of emojis that already exist",
    )
    parser.add_argument(
        "--refresh-messages",
        action="store_true",
        help="re-process messages that already exist: refresh their attachment URLs "
        "and re-check for new/late attachments, and re-create any missing "
        "message_attachments link for an already-stored file (existing files and "
        "hashes are never re-downloaded or re-uploaded)",
    )
    parser.add_argument(
        "--skip-avatars",
        action="store_true",
        help="do not download user/guild avatars (debugging aid)",
    )
    parser.add_argument(
        "--attachments-whitelist",
        default=None,
        metavar="IDS",
        help="comma-separated channel ids: download attachments only from these "
        "channels (mutually exclusive with --attachments-blacklist)",
    )
    parser.add_argument(
        "--attachments-blacklist",
        default=None,
        metavar="IDS",
        help="comma-separated channel ids skipped for attachments; used only when "
        "the whitelist is empty (all other channels are downloaded)",
    )
    parser.add_argument(
        "--channels",
        default=None,
        metavar="IDS",
        help="comma-separated channel ids: import message files only for these "
        "channels (debugging aid)",
    )
    parser.add_argument(
        "--discord-token",
        default=None,
        help="bot token used to re-fetch messages whose attachment CDN URLs have "
        "expired (defaults to the DISCORD_BOT_TOKEN env var)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="parse the dump and print the plan without touching the database",
    )
    args = parser.parse_args()
    configure_interactivity(args.non_interactive)

    if args.attachments_whitelist and args.attachments_blacklist:
        parser.error(
            "--attachments-whitelist and --attachments-blacklist are mutually exclusive"
        )

    args.attachments_whitelist = parse_id_list(
        args.attachments_whitelist, "--attachments-whitelist", parser
    )
    args.attachments_blacklist = parse_id_list(
        args.attachments_blacklist, "--attachments-blacklist", parser
    )
    args.channels = parse_id_list(args.channels, "--channels", parser)

    if args.discord_token is None:
        args.discord_token = os.environ.get("DISCORD_BOT_TOKEN") or None

    input_path = os.path.abspath(args.guild_dir)
    temp_dir = None

    try:
        if os.path.isfile(input_path) and input_path.endswith((".tar.zst", ".tzst")):
            temp_dir = tempfile.TemporaryDirectory(prefix="importguild-")
            guild_dir = extract_archive(input_path, temp_dir.name)
            report_path = input_path + ".import-report.json"
        elif os.path.isdir(input_path):
            guild_dir = input_path
            report_path = os.path.join(guild_dir, "import-report.json")
        else:
            fail(f"not a directory or .tar.zst archive: {input_path}")

        return run_import(guild_dir, report_path, args)
    finally:
        if temp_dir is not None:
            temp_dir.cleanup()


def run_import(guild_dir, report_path, args):
    report = {
        "guild_dir": guild_dir,
        "roles_inserted": 0,
        "channels_inserted": 0,
        "users_inserted": 0,
        "users_refreshed": 0,
        "overwrites_inserted": 0,
        "overwrites_skipped_empty": 0,
        "overwrites_skipped_missing": 0,
        "member_roles_inserted": 0,
        "member_roles_skipped": 0,
        "messages_inserted": 0,
        "messages_pinned": 0,
        "messages_webhook": 0,
        "messages_skipped_empty": 0,
        "embeds_inserted": 0,
        "embeds_skipped_too_many": 0,
        "message_links_rewritten": 0,
        "legacy_mentions_normalized": 0,
        "gif_embeds_replaced": 0,
        "gif_links_unresolved": 0,
        "replies_linked": 0,
        "replies_dropped": 0,
        "avatars_inserted": 0,
        "avatars_refreshed": 0,
        "avatars_skipped": 0,
        "avatars_animation_downgraded": 0,
        "guild_avatar_set": 0,
        "deleted_users_anonymized": 0,
        "emojis_inserted": 0,
        "emoji_icons_skipped": 0,
        "emoji_ids_stored": 0,
        "webhooks_total": 0,
        "webhooks_imported": 0,
        "webhooks_skipped_channel": 0,
        "webhook_placeholders_created": 0,
        "webhook_avatars_set": 0,
        "webhook_avatars_skipped": 0,
        "webhook_tokens": {},
        "reactions_inserted": 0,
        "reactions_skipped_empty": 0,
        "reactions_skipped_foreign": 0,
        "reactions_skipped_no_user": 0,
        "reactions_skipped_no_emoji": 0,
        "attachments_uploaded": 0,
        "attachments_linked": 0,
        "attachments_skipped_existing": 0,
        "attachments_skipped_host": 0,
        "attachments_skipped_download": 0,
        "attachments_skipped_expired": 0,
        "attachments_refreshed": 0,
        "attachment_bytes_uploaded": 0,
        "s3_puts": 0,
        "channels_skipped": {},
        "malformed_lines": [],
        "warnings": [],
    }

    guild, roles, channels, members = load_dump(guild_dir, report)

    cache = UserCache()

    for member in members:
        cache.add_member(member)

    basename = os.path.basename(guild_dir.rstrip("/"))

    if guild and guild.get("id") is not None:
        guild_id = int(guild["id"])
    elif basename.isdigit():
        guild_id = int(basename)
    else:
        fail("cannot determine the guild id (no guild.json and directory is not a number)")

    name = args.guild_name or (guild.get("name") if guild else None)

    if not name:
        name = resolve_text(None, "Guild name")

    imported_channels = collect_channels(channels, report)
    imported_channel_ids = set(imported_channels)
    override_member_ids = collect_override_member_ids(imported_channels)

    webhook_dump = load_webhook_dump(guild_dir, report)

    message_dir = os.path.join(guild_dir, "messages")
    message_files = []

    if os.path.isdir(message_dir):
        for path in sorted(glob.glob(os.path.join(message_dir, "*.jsonl"))):
            channel_id = os.path.splitext(os.path.basename(path))[0]

            if not channel_id.isdigit():
                continue

            if int(channel_id) not in imported_channels:
                report["warnings"].append(
                    f"skipping messages of unimported channel {channel_id}"
                )

                continue

            message_files.append((int(channel_id), path))

    if args.limit is not None:
        message_files = message_files[: args.limit]

    if args.channels:
        message_files = [
            (channel_id, path)
            for channel_id, path in message_files
            if channel_id in args.channels
        ]

    report["guild_id"] = str(guild_id)
    report["guild_name"] = name
    report["roles_total"] = len(roles)
    report["channels_total"] = len(channels)
    report["channels_imported"] = len(imported_channels)
    report["members_total"] = len(members)
    report["members_cached"] = len(cache.records)
    report["message_files"] = len(message_files)
    report["webhooks_total"] = len(webhook_dump)

    print(f"Guild: {name} ({guild_id})")
    print(f"Roles: {len(roles)}, channels imported: {len(imported_channels)}/{len(channels)}")
    print(f"Members: {len(members)}, message files: {len(message_files)}")
    print(f"Webhooks: {len(webhook_dump)}")

    if report["channels_skipped"]:
        print(f"Channels skipped by type: {report['channels_skipped']}")

    if args.dry_run:
        print("Dry run: no database changes were made.")
        write_report(report_path, report)

        return EXIT_OK

    config = load_config(args.config)
    conninfo = config.get("db", {}).get("conninfo")

    if not conninfo:
        fail("'db.conninfo' is missing in the config")

    avatar_limits = AvatarLimits.from_config(config)
    emoji_limits = AvatarLimits.from_config(config, EMOJI_SECTION)
    max_embeds = max_embeds_from_config(config)
    api_emojis = (config.get("api") or {}).get("emojis") or {}
    emoji_min_codepoints = api_emojis.get("min_name_codepoints", 2)
    emoji_max_codepoints = api_emojis.get("max_name_codepoints", 32)

    s3 = None

    try:
        s3 = S3.from_config(config)
    except S3Error as e:
        fail(str(e))

    want_attachments = bool(message_files)

    if s3 is None or not s3.available():
        if message_files and (args.attachments_whitelist or not args.attachments_blacklist):
            report["warnings"].append(
                "files.s3 is not configured: attachments cannot be uploaded"
            )
        want_attachments = False

    discord_client = None

    if want_attachments and args.discord_token:
        discord_client = Discord(args.discord_token)

    role_ids = {int(role["id"]) for role in roles}
    member_ids = {int(member["id"]) for member in members}
    placeholder_ids = override_member_ids - member_ids

    emoji_dump = load_emoji_dump(guild_dir, report)
    emoji_state = {}
    known_webhook_ids = set()

    with psycopg.connect(conninfo) as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT username FROM app.users")
            usernames = Usernames([row[0] for row in cur.fetchall()])

            cur.execute("SELECT id FROM app.users")
            known_user_ids = {int(row[0]) for row in cur.fetchall()}

        inserted_user_ids = set()

        with conn.cursor() as cur:
            insert_guild(cur, guild_id, name, report)
            upsert_everyone(cur, guild_id, roles)
            insert_roles(cur, guild_id, roles, report)

            rows = []

            for member in members:
                user_id = int(member["id"])
                record = cache.records[user_id]
                rows.append(
                    (
                        user_id,
                        usernames.take(record.get("username"), user_id),
                        record.get("display_name"),
                        None,
                        bool(member.get("bot")),
                        None,
                    )
                )

            for user_id in sorted(placeholder_ids):
                rows.append(
                    (
                        user_id,
                        usernames.take(None, user_id),
                        None,
                        None,
                        False,
                        None,
                    )
                )

            actually_inserted = insert_user_rows(cur, rows)
            inserted_user_ids.update(actually_inserted)
            report["users_inserted"] += len(actually_inserted)
            known_user_ids.update(int(member["id"]) for member in members)
            known_user_ids.update(placeholder_ids)

            insert_channels(cur, guild_id, imported_channels, report)

            known_webhook_ids.update(
                import_webhooks(
                    cur, guild_id, webhook_dump, imported_channel_ids, report
                )
            )

            insert_overwrites(
                cur, guild_id, imported_channels, role_ids, known_user_ids, report
            )
            insert_member_roles(cur, guild_id, members, role_ids, report)

            if args.admin_user_id is not None:
                assign_superuser(cur, guild_id, int(args.admin_user_id), report)

            conn.commit()

        with conn.cursor() as cur:
            if not args.skip_avatars:
                sync_avatars(
                    conn, cur, guild_id, guild, cache, avatar_limits,
                    args.refresh_avatars, report
                )

                import_webhook_avatars(
                    conn, cur, webhook_dump, imported_channel_ids,
                    avatar_limits, args.refresh_avatars, report
                )

        with conn.cursor() as cur:
            import_emojis(
                cur, guild_id, emoji_dump, emoji_limits,
                emoji_min_codepoints, emoji_max_codepoints,
                args.refresh_emoji, report, emoji_state,
            )

        guild_emoji_ids = frozenset(emoji_dump)

        conn.commit()

        ensure_message_schema(conn)

        deleted_ids = set()

        for index, (channel_id, path) in enumerate(message_files, 1):
            try:
                pending_webhooks = {}

                with conn.cursor() as cur:
                    written, attachments = import_message_file(
                        cur,
                        guild_id,
                        channel_id,
                        path,
                        cache,
                        member_ids,
                        known_user_ids,
                        inserted_user_ids,
                        known_webhook_ids,
                        pending_webhooks,
                        usernames,
                        deleted_ids,
                        max_embeds,
                        report,
                        want_attachments=want_attachments
                        and channel_selected(
                            channel_id,
                            args.attachments_whitelist,
                            args.attachments_blacklist,
                        ),
                        guild_emoji_ids=guild_emoji_ids,
                    )
                    inserted_ids = flush_messages(cur, report)

                    import_emojis(
                        cur, guild_id, emoji_dump, emoji_limits,
                        emoji_min_codepoints, emoji_max_codepoints,
                        args.refresh_emoji, report, emoji_state,
                    )
                    flush_reactions(cur, report)

                    if attachments:
                        process_attachments(
                            cur, s3, channel_id, attachments, report,
                            discord_client=discord_client,
                            message_filter=None if args.refresh_messages else inserted_ids,
                        )

                    if args.refresh_messages:
                        backfill_attachment_tokens(cur)

                    clear_import_staging(cur)

                conn.commit()
                print(f"[{index}/{len(message_files)}] {os.path.basename(path)}: {written}")
            except Exception as e:  # noqa: BLE001 - keep going on a bad file
                conn.rollback()
                report["warnings"].append(f"failed to import {path}: {e}")
                print(
                    f"[{index}/{len(message_files)}] {os.path.basename(path)}: FAILED: {e}",
                    file=sys.stderr,
                )

        with conn.cursor() as cur:
            refresh_users(
                cur, cache, usernames, inserted_user_ids,
                args.refresh_users, report
            )
            anonymize_deleted_users(cur, deleted_ids, inserted_user_ids, report)

        conn.commit()

    if discord_client is not None:
        discord_client.close()

    write_report(report_path, report)

    print(
        "Done: "
        f"roles={report['roles_inserted']} "
        f"channels={report['channels_inserted']} "
        f"users={report['users_inserted']} "
        f"users_refreshed={report['users_refreshed']} "
        f"overwrites={report['overwrites_inserted']} "
        f"member_roles={report['member_roles_inserted']} "
        f"messages={report['messages_inserted']} "
        f"webhook_messages={report['messages_webhook']} "
        f"pins={report['messages_pinned']} "
        f"embeds={report['embeds_inserted']} "
        f"emojis={report['emojis_inserted']} "
        f"webhooks={report['webhooks_imported']}"
        f"+{report['webhook_placeholders_created']}p "
        f"reactions={report['reactions_inserted']} "
        f"attachments={report['attachments_uploaded']}/"
        f"{report['attachment_bytes_uploaded']}B "
        f"links={report['message_links_rewritten']} "
        f"mentions_normalized={report['legacy_mentions_normalized']} "
        f"gif_embeds={report['gif_embeds_replaced']} "
        f"replies={report['replies_linked']} "
        f"avatars={report['avatars_inserted']}+{report['avatars_refreshed']} "
        f"guild_avatar={report['guild_avatar_set']} "
        f"(empty skipped={report['messages_skipped_empty']}, "
        f"foreign reactions skipped={report['reactions_skipped_foreign']}, "
        f"avatars skipped={report['avatars_skipped']})"
    )

    return EXIT_OK


if __name__ == "__main__":
    raise SystemExit(main())
