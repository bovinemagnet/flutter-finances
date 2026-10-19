--liquibase formatted sql

--changeset "Paul Snow":extraction-1
-- Optional cloud extraction (AUTO 02). One consent record per workspace
-- names the provider and the retention disclosed to the owner.
create table extraction_consent (
    workspace_id uuid primary key,
    status varchar(16) not null check (status in ('granted', 'withdrawn')),
    provider_name varchar(100) not null,
    disclosed_retention varchar(500) not null,
    granted_by uuid not null,
    granted_at timestamptz not null,
    withdrawn_by uuid,
    withdrawn_at timestamptz,
    updated_at timestamptz not null
);

-- Recognised text of one released receipt document. Untrusted data: kept
-- as text and lines only, never parsed into ledger changes.
create table receipt_extraction (
    asset_id uuid primary key,
    receipt_id uuid not null,
    workspace_id uuid not null,
    provider_name varchar(100) not null,
    text text not null,
    lines jsonb not null,
    extracted_at timestamptz not null
);
create index receipt_extraction_receipt_idx on receipt_extraction (workspace_id, receipt_id);
