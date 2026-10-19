--liquibase formatted sql

--changeset "Paul Snow":workspace-1
create table app_user (
    id uuid primary key,
    subject varchar(255) not null unique,
    created_at timestamptz not null
);

create table workspace (
    id uuid primary key,
    name varchar(200) not null,
    currency char(3) not null,
    currency_exponent smallint not null check (currency_exponent between 0 and 4),
    timezone varchar(64) not null,
    status varchar(16) not null default 'active' check (status in ('active', 'deleting')),
    created_by uuid not null references app_user (id),
    created_at timestamptz not null,
    updated_at timestamptz not null
);

create table membership (
    workspace_id uuid not null references workspace (id) on delete cascade,
    user_id uuid not null references app_user (id),
    role varchar(16) not null check (role in ('owner', 'member')),
    created_at timestamptz not null,
    primary key (workspace_id, user_id)
);
create index membership_user_idx on membership (user_id);

create table device (
    id uuid primary key,
    workspace_id uuid not null references workspace (id) on delete cascade,
    user_id uuid not null references app_user (id),
    name varchar(200) not null,
    platform varchar(32) not null,
    registered_at timestamptz not null,
    revoked_at timestamptz,
    last_seen_at timestamptz
);
create index device_workspace_idx on device (workspace_id);

-- SEC 06: survives workspace deletion so that a restored backup or a
-- replayed bootstrap cannot reintroduce the deleted workspace.
create table workspace_deletion_suppression (
    workspace_id uuid primary key,
    deleted_at timestamptz not null
);

--changeset "Paul Snow":workspace-2
-- Shared households (P1): a viewer may read the workspace but not change it.
alter table membership drop constraint membership_role_check;
alter table membership add constraint membership_role_check check (role in ('owner', 'member', 'viewer'));
