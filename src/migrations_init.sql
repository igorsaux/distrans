CREATE SCHEMA IF NOT EXISTS _migration;

CREATE TABLE IF NOT EXISTS _migration.history (
    version    BIGINT PRIMARY KEY UNIQUE,
    name       TEXT NOT NULL,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
