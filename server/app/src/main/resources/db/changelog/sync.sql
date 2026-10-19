--liquibase formatted sql

--changeset "Paul Snow":sync-1
-- Canonical entity state for the change feed and snapshots. Deleted
-- entities keep their row (a tombstone) permanently so that no pending
-- command can resurrect them; their data is dropped after the horizon.
create table sync_entity (
    workspace_id uuid not null,
    entity_id uuid not null,
    entity_type varchar(64) not null,
    revision bigint not null check (revision >= 1),
    data jsonb,
    field_revisions jsonb not null default '{}'::jsonb,
    deleted boolean not null default false,
    deleted_at timestamptz,
    created_at timestamptz not null,
    updated_at timestamptz not null,
    primary key (workspace_id, entity_id)
);
create index sync_entity_snapshot_idx on sync_entity (workspace_id, entity_type, entity_id) where not deleted;

-- Ordered change log. Writers hold a per-workspace advisory lock while
-- appending, so sequences commit in order within a workspace.
create table sync_change (
    sequence bigserial primary key,
    workspace_id uuid not null,
    entity_type varchar(64) not null,
    entity_id uuid not null,
    revision bigint not null,
    op varchar(8) not null check (op in ('upsert', 'delete')),
    data jsonb,
    command_id uuid,
    device_id uuid,
    created_at timestamptz not null
);
create index sync_change_feed_idx on sync_change (workspace_id, sequence);
create index sync_change_entity_idx on sync_change (workspace_id, entity_id, sequence);

-- SYNC 02: the stored result of every command, keyed by its commandId.
create table sync_idempotency (
    workspace_id uuid not null,
    command_id uuid not null,
    payload_hash char(64) not null,
    status varchar(32) not null,
    result jsonb not null,
    created_at timestamptz not null,
    primary key (workspace_id, command_id)
);

-- Last position each device pulled, for backlog monitoring.
create table sync_device_cursor (
    device_id uuid primary key,
    workspace_id uuid not null,
    last_sequence bigint not null,
    pulled_at timestamptz not null
);

-- Highest change sequence whose tombstone has been purged; cursors before
-- it are expired (HTTP 410) because a delete would be missed.
create table sync_purge_watermark (
    workspace_id uuid primary key,
    purged_through bigint not null,
    purged_at timestamptz not null
);

--changeset "Paul Snow":sync-2
-- Shared households: the user who created an entity (null when the server
-- created it), which decides who may see a private account, and a flag on
-- change records that change what other members may see, so the feed can
-- tell a member that an entity left their view.
alter table sync_entity add column created_by uuid;
alter table sync_change add column visibility_change boolean not null default false;
