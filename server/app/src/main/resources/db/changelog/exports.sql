--liquibase formatted sql

--changeset "Paul Snow":exports-1
-- Portable JSON archives (EXP 01, DATA 01) written to object storage.
-- accepted_through records the last change sequence the archive contains.
create table export_archive (
    id uuid primary key,
    workspace_id uuid not null,
    job_id uuid not null,
    status varchar(16) not null check (status in ('pending', 'ready', 'failed')),
    object_key varchar(512),
    sha256 char(64),
    size_bytes bigint,
    accepted_through bigint,
    created_at timestamptz not null,
    completed_at timestamptz
);
create index export_archive_workspace_idx on export_archive (workspace_id);
