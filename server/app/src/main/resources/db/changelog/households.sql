--liquibase formatted sql

--changeset "Paul Snow":households-1
-- Workspace invitations (P1 shared households). Only the SHA-256 of the
-- single-use token is stored; the token itself is shown once to the owner.
create table workspace_invitation (
    id uuid primary key,
    workspace_id uuid not null,
    role varchar(16) not null check (role in ('member', 'viewer')),
    token_sha256 char(64) not null,
    status varchar(16) not null check (status in ('pending', 'accepted', 'revoked')),
    created_by uuid not null,
    created_at timestamptz not null,
    expires_at timestamptz not null,
    accepted_by uuid,
    accepted_at timestamptz,
    revoked_at timestamptz
);
create index workspace_invitation_workspace_idx on workspace_invitation (workspace_id);
