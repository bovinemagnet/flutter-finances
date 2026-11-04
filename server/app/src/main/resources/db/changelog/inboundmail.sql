--liquibase formatted sql

--changeset "Paul Snow":inboundmail-1
-- A member's private forwarding address. The token is looked up by its hash
-- and encrypted so it can be shown again; it is never stored in the clear.
create table inbound_address (
    id uuid primary key,
    workspace_id uuid not null,
    user_id uuid not null,
    token_sha256 char(64) not null unique,
    token_nonce bytea not null,
    token_ciphertext bytea not null,
    created_at timestamptz not null,
    revoked_at timestamptz
);
create unique index inbound_address_active_idx on inbound_address (workspace_id, user_id)
    where revoked_at is null;

--changeset "Paul Snow":inboundmail-2
-- A forwarded email. Sender and subject are kept only so the member can tell
-- what arrived; they expire with the message. The body is never stored.
create table inbound_message (
    id uuid primary key,
    workspace_id uuid not null,
    user_id uuid not null,
    provider varchar(32) not null,
    provider_message_id varchar(200) not null,
    sender varchar(320),
    subject varchar(200),
    received_at timestamptz not null,
    outcome varchar(16) not null check (outcome in
        ('processing', 'documents', 'no_attachment', 'rejected', 'rate_limited', 'failed')),
    expires_at timestamptz not null,
    unique (provider, provider_message_id)
);
create index inbound_message_member_idx on inbound_message (workspace_id, user_id);
create index inbound_message_expiry_idx on inbound_message (expires_at);

--changeset "Paul Snow":inboundmail-3
-- An attachment waiting for collection, or the reason it was refused.
create table inbound_document (
    id uuid primary key,
    message_id uuid not null references inbound_message (id) on delete cascade,
    attachment_index int not null,
    object_key varchar(300),
    content_type varchar(64),
    size_bytes bigint,
    sha256 char(64),
    file_name varchar(255),
    state varchar(16) not null check (state in ('waiting', 'collected', 'rejected')),
    rejection_code varchar(32),
    rejection_detail varchar(200),
    unique (message_id, attachment_index)
);
