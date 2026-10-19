--liquibase formatted sql

--changeset "Paul Snow":deletion-1
-- Tracked workspace deletion (SEC 05, SEC 06). Each step records when it
-- finished so the job can resume after a failure.
create table deletion_request (
    id uuid primary key,
    workspace_id uuid not null unique,
    requested_by uuid not null,
    job_id uuid not null,
    status varchar(16) not null check (status in ('pending', 'completed', 'failed')),
    steps jsonb not null default '{}'::jsonb,
    created_at timestamptz not null,
    completed_at timestamptz
);
create index deletion_request_status_idx on deletion_request (status);
