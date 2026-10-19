--liquibase formatted sql

--changeset "Paul Snow":bankfeeds-1
-- Bank feed connections (BANK 02): what was shared, why, the consent's
-- status and expiry, and the feed's health.
create table bank_feed_connection (
    id uuid primary key,
    workspace_id uuid not null,
    provider varchar(32) not null,
    provider_reference varchar(200),
    institution_id varchar(100),
    institution_name varchar(200),
    data_scope jsonb not null,
    purpose varchar(500) not null,
    consent_status varchar(16) not null check (consent_status in ('pending', 'active', 'expired', 'revoked')),
    consent_state_sha256 char(64),
    consent_expires_at timestamptz,
    last_refresh_at timestamptz,
    error_code varchar(64),
    error_at timestamptz,
    rate_limit_attempts int not null default 0,
    next_refresh_at timestamptz,
    created_by uuid not null,
    created_at timestamptz not null,
    updated_at timestamptz not null,
    revoked_at timestamptz
);
create index bank_feed_connection_workspace_idx on bank_feed_connection (workspace_id);
create unique index bank_feed_connection_reference_idx on bank_feed_connection (provider, provider_reference)
    where provider_reference is not null;

-- Accounts the consent shares, with each account's provider cursor.
create table bank_feed_account (
    connection_id uuid not null references bank_feed_connection (id) on delete cascade,
    provider_account_id varchar(100) not null,
    workspace_id uuid not null,
    name varchar(200) not null,
    type varchar(32),
    masked_number varchar(32),
    provider_cursor varchar(500),
    primary key (connection_id, provider_account_id)
);

-- Provider tokens, AES-GCM encrypted with a key held outside the
-- database. Deleted on revocation.
create table bank_feed_token (
    connection_id uuid primary key references bank_feed_connection (id) on delete cascade,
    workspace_id uuid not null,
    nonce bytea not null,
    ciphertext bytea not null,
    updated_at timestamptz not null
);

-- Provider records (BANK 03), kept apart from canonical journals. Each is
-- an import proposal the user accepts or dismisses; nothing is posted
-- automatically. Settlement, reversal and id changes are explicit links.
create table bank_feed_record (
    id uuid primary key,
    workspace_id uuid not null,
    connection_id uuid not null references bank_feed_connection (id) on delete cascade,
    provider_account_id varchar(100) not null,
    provider_transaction_id varchar(200) not null,
    previous_provider_ids jsonb not null default '[]'::jsonb,
    status varchar(16) not null check (status in ('pending', 'posted')),
    amount_minor bigint not null,
    currency char(3) not null,
    transaction_date date not null,
    description text,
    pending_record_id uuid,
    settled_by_record_id uuid,
    reversal_of_record_id uuid,
    reversed_by_record_id uuid,
    proposal_status varchar(16) not null
        check (proposal_status in ('open', 'superseded', 'accepted', 'dismissed')),
    journal_id uuid,
    decided_by uuid,
    decided_at timestamptz,
    first_seen_at timestamptz not null,
    updated_at timestamptz not null
);
create unique index bank_feed_record_provider_idx
    on bank_feed_record (connection_id, provider_account_id, provider_transaction_id);
create index bank_feed_record_workspace_idx on bank_feed_record (workspace_id);

-- Webhook deliveries already processed, for replay protection.
create table bank_feed_webhook_delivery (
    provider varchar(32) not null,
    delivery_id varchar(200) not null,
    received_at timestamptz not null,
    primary key (provider, delivery_id)
);
