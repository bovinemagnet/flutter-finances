--liquibase formatted sql

--changeset "Paul Snow":imports-1
-- CSV import batches (IMP 01-03). The same file with the same mapping for
-- the same account is the same batch, so re-importing it is idempotent.
create table import_batch (
    id uuid primary key,
    workspace_id uuid not null,
    account_id varchar(128) not null,
    file_sha256 char(64) not null,
    mapping_sha256 char(64) not null,
    file_name varchar(255),
    mapping jsonb not null,
    status varchar(16) not null check (status in ('previewed', 'committing', 'committed', 'rolled_back')),
    row_count int not null,
    error_count int not null,
    summary jsonb not null,
    result jsonb,
    created_at timestamptz not null,
    committed_at timestamptz
);
create unique index import_batch_identity_idx
    on import_batch (workspace_id, account_id, file_sha256, mapping_sha256);

-- Raw rows and source hashes are preserved separately from the journals
-- they produce, so corrections never erase evidence of origin.
create table import_row (
    batch_id uuid not null references import_batch (id) on delete cascade,
    row_number int not null,
    workspace_id uuid not null,
    raw text not null,
    raw_sha256 char(64) not null,
    status varchar(16) not null
        check (status in ('new', 'duplicate', 'error', 'committed', 'skipped', 'rolled_back')),
    error_code varchar(64),
    effective_date date,
    amount_minor bigint,
    description text,
    reference varchar(255),
    fingerprint char(64),
    occurrence int,
    dedupe_key varchar(400),
    journal_id uuid,
    command_id uuid,
    matches jsonb,
    primary key (batch_id, row_number)
);
create unique index import_row_committed_key_idx on import_row (workspace_id, dedupe_key) where status = 'committed';

--changeset "Paul Snow":imports-2
-- Rows carry the shared csv.fingerprint text (dedupe_key) and its SHA-256
-- (fingerprint); committed fingerprints are unique per workspace, so the
-- same statement line can never be committed twice (A12) while identical
-- same-day purchases keep distinct occurrence numbers (A11).
alter table import_row alter column dedupe_key type text;
drop index import_row_committed_key_idx;
create unique index import_row_committed_fingerprint_idx on import_row (workspace_id, fingerprint)
    where status = 'committed';
alter table import_batch add column job_id uuid;
