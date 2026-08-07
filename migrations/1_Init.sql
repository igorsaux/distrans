CREATE SCHEMA app;

-- Case-insensitive substring search over message content (messages_content_trgm_idx).
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Allow the ON DELETE CASCADE from app.guilds to delete the @everyone role:
-- the trigger must only reject direct top-level DELETEs, not cascade-originated
-- ones (pg_trigger_depth() > 1 when fired from a referential action).
CREATE FUNCTION app.forbid_delete_everyone() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.id = OLD.guild_id AND pg_trigger_depth() = 1 THEN
        RAISE EXCEPTION 'cannot delete @everyone role';
    END IF;
    RETURN OLD;
END;
$$;

-- Shared BEFORE UPDATE trigger function for changed-since sync: unconditionally
-- stamp `updated_at` so no write path can forget it (edits, soft-deletes, bulk
-- reorders, upserts) without touching each query.
CREATE FUNCTION app.touch_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION bytea_or_128(state bytea, next_val bytea)
RETURNS bytea AS $$
DECLARE
    result bytea;
BEGIN
    IF state IS NULL THEN RETURN next_val; END IF;
    IF next_val IS NULL THEN RETURN state; END IF;

    result := 
        set_byte(E'\\x00000000000000000000000000000000'::bytea, 0, get_byte(state, 0) | get_byte(next_val, 0));
        
    FOR i IN 1..15 LOOP
        result := set_byte(result, i, get_byte(state, i) | get_byte(next_val, i));
    END LOOP;

    RETURN result;
END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;

CREATE OR REPLACE AGGREGATE bit_or(bytea) (
    SFUNC = bytea_or_128,
    STYPE = bytea
);

CREATE TABLE app.users (
    id            BIGINT PRIMARY KEY,
    username      TEXT NOT NULL UNIQUE,
    display_name  TEXT,
    password_hash TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_bot        BOOLEAN NOT NULL DEFAULT false,
    deleted_at    TIMESTAMPTZ,
    avatar_data   BYTEA,
    avatar_hash   TEXT,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT users_bot_no_password
        CHECK (NOT is_bot OR password_hash IS NULL),

    CONSTRAINT users_avatar_consistency
        CHECK ((avatar_data IS NULL) = (avatar_hash IS NULL)),

    CONSTRAINT users_deleted_is_anonymous
        CHECK (
            deleted_at IS NULL OR (
                password_hash IS NULL AND
                avatar_data   IS NULL AND
                avatar_hash   IS NULL AND
                display_name  IS NULL
            )
        )
);

CREATE INDEX users_updated_idx ON app.users (updated_at);

CREATE TRIGGER users_touch_updated_at
    BEFORE UPDATE ON app.users
    FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();

CREATE TABLE app.bot_tokens (
    user_id    BIGINT NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
    token_hash BYTEA NOT NULL PRIMARY KEY
);

CREATE TABLE app.guilds (
    id          BIGINT PRIMARY KEY,
    name        TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    avatar_data BYTEA,
    avatar_hash TEXT,

    CONSTRAINT guilds_avatar_consistency
        CHECK ((avatar_data IS NULL) = (avatar_hash IS NULL))
);

CREATE TABLE app.roles (
    id          BIGINT PRIMARY KEY,
    guild_id    BIGINT NOT NULL REFERENCES app.guilds(id) ON DELETE CASCADE,
    name        TEXT NOT NULL,
    position    SMALLINT NOT NULL DEFAULT 0,
    permissions BYTEA NOT NULL,
    color       INTEGER,
    mentionable BOOLEAN NOT NULL DEFAULT true,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE (guild_id, id),

    CONSTRAINT roles_persmissions_valid
        CHECK (octet_length(permissions) = 16),

    CONSTRAINT roles_position_nonneg
        CHECK (position >= 0),

    CONSTRAINT roles_everyone_is_zero
        CHECK (id <> guild_id OR position = 0),

    -- Role positions are a unique, dense rank per guild: @everyone is always 0,
    -- every other role holds 1..N. The constraint is DEFERRABLE INITIALLY
    -- DEFERRED so a single-statement renumbering / reorder may pass through
    -- transient duplicates and is only checked at the end of the transaction.
    CONSTRAINT roles_position_unique UNIQUE (guild_id, position)
        DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX idx_roles_guild_id ON app.roles (guild_id);
CREATE INDEX roles_guild_updated_idx ON app.roles (guild_id, updated_at);

CREATE TRIGGER roles_protect_everyone
    BEFORE DELETE ON app.roles
    FOR EACH ROW EXECUTE FUNCTION app.forbid_delete_everyone();

CREATE TRIGGER roles_touch_updated_at
    BEFORE UPDATE ON app.roles
    FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();

CREATE TABLE app.member_roles (
    guild_id BIGINT NOT NULL,
    role_id  BIGINT NOT NULL,
    user_id  BIGINT NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,

    PRIMARY KEY (guild_id, user_id, role_id),

    FOREIGN KEY (guild_id, role_id)
        REFERENCES app.roles (guild_id, id)
        ON DELETE CASCADE
);

CREATE TABLE app.channels (
    id         BIGINT PRIMARY KEY,
    guild_id   BIGINT NOT NULL REFERENCES app.guilds(id) ON DELETE CASCADE,
    parent_id  BIGINT REFERENCES app.channels(id) ON DELETE SET NULL,
    kind       SMALLINT NOT NULL DEFAULT 0, -- 0=text, 1=category
    name       TEXT NOT NULL,
    topic      TEXT,
    position   SMALLINT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT channels_kind_valid
        CHECK (kind IN (0, 1)),

    CONSTRAINT channels_category_root_only
        CHECK (kind <> 1 OR parent_id IS NULL),

    UNIQUE (guild_id, id),

    FOREIGN KEY (guild_id, parent_id)
        REFERENCES app.channels (guild_id, id)
        ON DELETE CASCADE
);

CREATE INDEX channels_guild_idx
    ON app.channels (guild_id, parent_id, position, id);
CREATE INDEX channels_guild_updated_idx ON app.channels (guild_id, updated_at);

CREATE TRIGGER channels_touch_updated_at
    BEFORE UPDATE ON app.channels
    FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();

CREATE TABLE app.overwrites (
    guild_id    BIGINT NOT NULL,
    channel_id  BIGINT NOT NULL,
    target_type SMALLINT NOT NULL, -- 0=role, 1=member
    role_id     BIGINT,
    user_id     BIGINT REFERENCES app.users(id) ON DELETE CASCADE,
    target_id   BIGINT GENERATED ALWAYS AS (COALESCE(role_id, user_id)) STORED,
    allow       BYTEA NOT NULL DEFAULT '\x00000000000000000000000000000000'
                CHECK (octet_length(allow) = 16),
    deny        BYTEA NOT NULL DEFAULT '\x00000000000000000000000000000000'
                CHECK (octet_length(deny) = 16),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT overwrites_target_type_valid CHECK (target_type IN (0, 1)),

    CONSTRAINT overwrites_single_target CHECK (
        (target_type = 0 AND role_id IS NOT NULL AND user_id IS NULL) OR
        (target_type = 1 AND role_id IS NULL     AND user_id IS NOT NULL)
    ),

    CONSTRAINT overwrites_not_empty CHECK (
        allow <> '\x00000000000000000000000000000000' OR deny <> '\x00000000000000000000000000000000'
    ),

    PRIMARY KEY (channel_id, target_type, target_id),

    FOREIGN KEY (guild_id, channel_id)
        REFERENCES app.channels (guild_id, id)
        ON DELETE CASCADE,

    FOREIGN KEY (guild_id, role_id)
        REFERENCES app.roles (guild_id, id)
        ON DELETE CASCADE
);

CREATE INDEX overwrites_guild_updated_idx ON app.overwrites (guild_id, updated_at);

CREATE TRIGGER overwrites_touch_updated_at
    BEFORE UPDATE ON app.overwrites
    FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();

CREATE TABLE app.emojis (
    id         BIGINT PRIMARY KEY,
    guild_id   BIGINT NOT NULL REFERENCES app.guilds(id) ON DELETE CASCADE,
    name       TEXT   NOT NULL,
    icon_data  BYTEA  NOT NULL,
    icon_hash  TEXT   NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE (guild_id, name),
    UNIQUE (id, guild_id)
);

CREATE INDEX emojis_guild_updated_idx ON app.emojis (guild_id, updated_at);

CREATE TRIGGER emojis_touch_updated_at
    BEFORE UPDATE ON app.emojis
    FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();

-- Deletion is a soft-delete
-- so messages posted by the webhook keep their attribution.
CREATE TABLE app.webhooks (
    id          BIGINT PRIMARY KEY,
    guild_id    BIGINT NOT NULL REFERENCES app.guilds(id) ON DELETE CASCADE,
    channel_id  BIGINT NOT NULL,
    name        TEXT   NOT NULL,
    token_hash  BYTEA  NOT NULL,
    avatar_data BYTEA,
    avatar_hash TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at  TIMESTAMPTZ,

    CONSTRAINT webhooks_token_hash_len CHECK (octet_length(token_hash) = 32),
    CONSTRAINT webhooks_avatar_consistency CHECK ((avatar_data IS NULL) = (avatar_hash IS NULL)),
    CONSTRAINT webhooks_avatar_hash_len CHECK (avatar_hash IS NULL OR char_length(avatar_hash) = 16),

    UNIQUE (token_hash),

    FOREIGN KEY (guild_id, channel_id) REFERENCES app.channels(guild_id, id) ON DELETE CASCADE
);

CREATE INDEX webhooks_channel_idx ON app.webhooks (channel_id) WHERE deleted_at IS NULL;

CREATE TABLE app.messages (
    id               BIGINT PRIMARY KEY,
    channel_id       BIGINT NOT NULL REFERENCES app.channels(id) ON DELETE CASCADE,
    author_id        BIGINT REFERENCES app.users(id) ON DELETE SET NULL,
    content          TEXT NOT NULL DEFAULT '',
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    reply_to_id      BIGINT,
    deleted_at       TIMESTAMPTZ,
    edited_at        TIMESTAMPTZ,
    embeds           TEXT,
    mention_everyone BOOLEAN  NOT NULL DEFAULT false,
    mention_user_ids BIGINT[] NOT NULL DEFAULT '{}',
    mention_role_ids BIGINT[] NOT NULL DEFAULT '{}',
    pinned           BOOLEAN NOT NULL DEFAULT false,
    webhook_id       BIGINT REFERENCES app.webhooks(id) ON DELETE SET NULL,
    -- Denormalized owning guild so per-guild search can scan (guild_id, id DESC)
    -- without joining app.channels. A channel can never move across guilds
    -- (Move only re-parents within one guild), so the value is immutable once set.
    guild_id         BIGINT NOT NULL,
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT messages_channel_id_uq
        UNIQUE (channel_id, id),

    CONSTRAINT messages_reply_fk
        FOREIGN KEY (channel_id, reply_to_id)
        REFERENCES app.messages (channel_id, id),

    CONSTRAINT messages_guild_fk
        FOREIGN KEY (guild_id) REFERENCES app.guilds(id) ON DELETE CASCADE,

    CONSTRAINT messages_no_self_reply
        CHECK (reply_to_id IS NULL OR reply_to_id <> id),

    CONSTRAINT messages_deleted_is_anonymous
        CHECK (deleted_at IS NULL OR content = ''),

    CONSTRAINT messages_author_xor_webhook
        CHECK (NOT (author_id IS NOT NULL AND webhook_id IS NOT NULL))
);

-- Channel pages, newest first.
CREATE INDEX messages_channel_page_idx
    ON app.messages (channel_id, id DESC)
    WHERE deleted_at IS NULL;

-- Keyset scan of a guild's live messages, newest first (message search).
CREATE INDEX messages_guild_page_idx
    ON app.messages (guild_id, id DESC)
    WHERE deleted_at IS NULL;

-- Case-insensitive substring search over message content.
CREATE INDEX messages_content_trgm_idx
    ON app.messages USING gin (content gin_trgm_ops)
    WHERE deleted_at IS NULL;

-- Array-overlap filters for mention lookups.
CREATE INDEX messages_mention_users_idx
    ON app.messages USING gin (mention_user_ids)
    WHERE deleted_at IS NULL;

CREATE INDEX messages_mention_roles_idx
    ON app.messages USING gin (mention_role_ids)
    WHERE deleted_at IS NULL;

CREATE INDEX messages_channel_pins_idx
    ON app.messages (channel_id, id)
    WHERE pinned AND deleted_at IS NULL;

-- Supports the loose index scan in repo.guilds.GetChannels: the channel list
-- reports each channel's newest live message. The scan walks the guild's
-- channels in channel_id order and probes the index once per non-empty channel,
-- so the cost is O(channels) and does not degrade to O(channels x messages)
-- when most channels are empty. A plain LATERAL ORDER BY id DESC LIMIT 1 per
-- channel cannot use the (channel_id, id DESC) index here: the planner expects
-- a match within a few entries for every channel, so it scans messages_pkey
-- backwards and, for an empty channel, walks the whole index. This index makes
-- the per-channel probe an index-only seek, and the skip-scan only visits
-- non-empty channels.
CREATE INDEX messages_guild_channel_last_idx
    ON app.messages (guild_id, channel_id, id DESC)
    WHERE deleted_at IS NULL;

CREATE INDEX messages_channel_updated_idx ON app.messages (channel_id, updated_at);

CREATE TRIGGER messages_touch_updated_at
    BEFORE UPDATE ON app.messages
    FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();

CREATE TABLE app.refresh_tokens (
    token_hash BYTEA NOT NULL PRIMARY KEY,
    user_id    BIGINT NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
    expires_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX idx_refresh_tokens_expires ON app.refresh_tokens(expires_at);
CREATE INDEX refresh_tokens_user_id_idx ON app.refresh_tokens (user_id);

CREATE TABLE app.message_reactions (
    message_id      BIGINT      NOT NULL REFERENCES app.messages(id) ON DELETE CASCADE,
    user_id         BIGINT      NOT NULL REFERENCES app.users(id)    ON DELETE CASCADE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    emoji_kind      SMALLINT    NOT NULL, -- 0 unicode, 1 custom
    emoji_id        BIGINT REFERENCES app.emojis(id) ON DELETE CASCADE,
    unicode_emoji   TEXT,

    CONSTRAINT reactions_kind_valid CHECK (emoji_kind IN (0, 1)),
    CONSTRAINT reactions_target_shape CHECK (
        (emoji_kind = 0 AND unicode_emoji IS NOT NULL AND emoji_id IS NULL) OR
        (emoji_kind = 1 AND unicode_emoji IS NULL     AND emoji_id IS NOT NULL)
    )
);

CREATE UNIQUE INDEX reactions_uniq
ON app.message_reactions (message_id, user_id, emoji_id, unicode_emoji)
NULLS NOT DISTINCT;

CREATE TABLE app.files (
    id           BIGINT PRIMARY KEY,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    name         TEXT NOT NULL,
    hash         TEXT NOT NULL UNIQUE,
    size         BIGINT NOT NULL DEFAULT 0,
    content_type TEXT NOT NULL
);

CREATE TABLE app.message_attachments (
    message_id BIGINT NOT NULL REFERENCES app.messages(id) ON DELETE CASCADE,
    file_id    BIGINT NOT NULL REFERENCES app.files(id),
    position   SMALLINT NOT NULL DEFAULT 0,

    PRIMARY KEY (message_id, file_id),

    CONSTRAINT message_attachments_position_nonneg CHECK (position >= 0),
    UNIQUE (message_id, position) DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX message_attachments_file_idx
    ON app.message_attachments (file_id);

CREATE TABLE app.userdata (
    user_id    BIGINT PRIMARY KEY REFERENCES app.users(id) ON DELETE CASCADE,
    data       TEXT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE app.guild_notification_settings (
    user_id           BIGINT NOT NULL REFERENCES app.users(id)  ON DELETE CASCADE,
    guild_id          BIGINT NOT NULL REFERENCES app.guilds(id) ON DELETE CASCADE,
    level             SMALLINT NOT NULL DEFAULT 0, -- 0=all_messages, 1=only_mentions, 2=nothing
    suppress_everyone BOOLEAN NOT NULL DEFAULT false,
    suppress_roles    BOOLEAN NOT NULL DEFAULT false,
    push              BOOLEAN NOT NULL DEFAULT true,
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

    PRIMARY KEY (user_id, guild_id),

    CONSTRAINT guild_notification_settings_level_valid
        CHECK (level IN (0, 1, 2))
);

CREATE INDEX guild_notification_settings_guild_idx
    ON app.guild_notification_settings (guild_id);

CREATE TABLE app.channel_notification_settings (
    user_id    BIGINT NOT NULL REFERENCES app.users(id)    ON DELETE CASCADE,
    channel_id BIGINT NOT NULL REFERENCES app.channels(id) ON DELETE CASCADE,
    level      SMALLINT NOT NULL DEFAULT 0, -- 0=inherit, 1=all_messages, 2=only_mentions, 3=nothing
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    PRIMARY KEY (user_id, channel_id),

    CONSTRAINT channel_notification_settings_level_valid
        CHECK (level IN (0, 1, 2, 3))
);

CREATE INDEX channel_notification_settings_channel_idx
    ON app.channel_notification_settings (channel_id);

-- The endpoint is globally unique: one browser push subscription belongs to
-- exactly one account (the account logged in in that browser profile), so
-- endpoint_hash is keyed alone rather than (user_id, endpoint_hash).
CREATE TABLE app.push_subscriptions (
    id            BIGINT PRIMARY KEY,
    user_id       BIGINT NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
    endpoint      TEXT   NOT NULL,
    endpoint_hash BYTEA  NOT NULL,
    p256dh        BYTEA  NOT NULL,
    auth          BYTEA  NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT push_subscriptions_p256dh_len CHECK (octet_length(p256dh) = 65),
    CONSTRAINT push_subscriptions_auth_len CHECK (octet_length(auth) = 16),

    CONSTRAINT push_subscriptions_endpoint_hash_key UNIQUE (endpoint_hash)
);

CREATE INDEX push_subscriptions_user_idx ON app.push_subscriptions (user_id);

-- Append-only per-guild audit log of management actions (channel / role /
-- overwrite / emoji / webhook / guild / moderation). A row records the actor
-- and the target ids only; there is no before/after payload. Rows are never
-- pruned or updated.
--
-- target_id / channel_id deliberately carry no foreign key: deleting the
-- referenced channel / role / emoji / webhook / message must not erase its
-- history. actor_id / target_user_id reference users with ON DELETE SET NULL so
-- a hard-deleted user leaves the row intact.
--
-- `action` is BIGINT (not SMALLINT) so the read filter can pass a bigint[]
-- parameter produced by the shared array encoder and keep the
-- (guild_id, action, id) index usable. Values are a small append-only enum
-- (see AuditAction in src/types.zig).
CREATE TABLE app.audit_log (
    id             BIGINT PRIMARY KEY,
    guild_id       BIGINT NOT NULL REFERENCES app.guilds(id) ON DELETE CASCADE,
    actor_id       BIGINT REFERENCES app.users(id) ON DELETE SET NULL,
    action         BIGINT NOT NULL,
    target_id      BIGINT,
    target_user_id BIGINT REFERENCES app.users(id) ON DELETE SET NULL,
    channel_id     BIGINT,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX audit_log_guild_page_idx   ON app.audit_log (guild_id, id DESC);
CREATE INDEX audit_log_guild_actor_idx  ON app.audit_log (guild_id, actor_id, id DESC);
CREATE INDEX audit_log_guild_action_idx ON app.audit_log (guild_id, action, id DESC);
