--liquibase formatted sql

--changeset "Paul Snow":ops-1
-- Latest reported outcome of each backup kind (NFR 08), so every API
-- instance exposes the same last success and recovery point.
create table ops_backup_status (
    kind varchar(16) primary key check (kind in ('database', 'objects', 'restore-drill')),
    last_success_at timestamptz,
    recovery_point_at timestamptz,
    last_failure_at timestamptz,
    updated_at timestamptz not null
);
