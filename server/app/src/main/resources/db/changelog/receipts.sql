--liquibase formatted sql

--changeset "Paul Snow":receipts-1
-- Document side of receipts. Receipt metadata syncs as an entity; these
-- rows track ownership and the lifecycle of the stored bytes (SYNC 05).
create table receipt_document (
    receipt_id uuid primary key,
    workspace_id uuid not null,
    created_at timestamptz not null
);
create index receipt_document_workspace_idx on receipt_document (workspace_id);

create table receipt_asset (
    asset_id uuid primary key,
    receipt_id uuid not null references receipt_document (receipt_id) on delete cascade,
    workspace_id uuid not null,
    kind varchar(16) not null check (kind in ('source', 'derivative')),
    content_type varchar(64) not null,
    size_bytes bigint not null check (size_bytes > 0),
    sha256 char(64) not null,
    object_key varchar(512) not null unique,
    status varchar(16) not null check (status in ('pending_upload', 'quarantined', 'available', 'rejected')),
    rejection_reason varchar(64),
    created_at timestamptz not null,
    updated_at timestamptz not null,
    completed_at timestamptz,
    scanned_at timestamptz
);
create index receipt_asset_workspace_idx on receipt_asset (workspace_id, status);
