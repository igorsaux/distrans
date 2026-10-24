CREATE EXTENSION IF NOT EXISTS btree_gin;

CREATE INDEX messages_guild_created_idx
    ON app.messages (guild_id, created_at)
    WHERE deleted_at IS NULL;

CREATE INDEX messages_guild_content_trgm_idx
    ON app.messages USING gin (guild_id, content gin_trgm_ops)
    WHERE deleted_at IS NULL;

CREATE INDEX messages_guild_author_page_idx
    ON app.messages (guild_id, author_id, id DESC)
    WHERE deleted_at IS NULL;

CREATE INDEX messages_guild_pins_idx
    ON app.messages (guild_id, id DESC)
    WHERE pinned AND deleted_at IS NULL;

CREATE INDEX messages_guild_webhooks_idx
    ON app.messages (guild_id, id DESC)
    WHERE webhook_id IS NOT NULL AND deleted_at IS NULL;

DROP INDEX app.messages_content_trgm_idx;
