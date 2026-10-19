--liquibase formatted sql

--changeset "Paul Snow":audit-1
-- Audit and security events (SEC 06) with minimised content: identifiers
-- and short codes only. Rows outlive a deleted workspace until the
-- retention purge (12 months by default) removes them.
create table audit_event (
    id uuid primary key,
    workspace_id uuid,
    actor_user_id uuid,
    kind varchar(64) not null,
    subject_type varchar(32),
    subject_id varchar(64),
    detail varchar(32),
    correlation_id varchar(64),
    occurred_at timestamptz not null
);
create index audit_event_workspace_idx on audit_event (workspace_id, occurred_at);
create index audit_event_occurred_idx on audit_event (occurred_at);
