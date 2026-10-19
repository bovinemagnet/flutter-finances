--liquibase formatted sql

--changeset "Paul Snow":jobs-1
-- PostgreSQL job table, claimed with FOR UPDATE SKIP LOCKED. A running job
-- whose lease has expired (worker crash) is claimed again.
create table job (
    id uuid primary key,
    workspace_id uuid,
    type varchar(64) not null,
    status varchar(16) not null check (status in ('queued', 'running', 'succeeded', 'failed')),
    payload jsonb not null default '{}'::jsonb,
    result jsonb,
    attempts int not null default 0,
    max_attempts int not null,
    run_after timestamptz not null,
    locked_by varchar(128),
    locked_until timestamptz,
    last_error varchar(500),
    created_at timestamptz not null,
    updated_at timestamptz not null,
    completed_at timestamptz
);
create index job_queued_idx on job (run_after) where status = 'queued';
create index job_running_idx on job (locked_until) where status = 'running';
create index job_workspace_idx on job (workspace_id);
