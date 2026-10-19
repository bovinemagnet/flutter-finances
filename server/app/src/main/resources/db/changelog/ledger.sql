--liquibase formatted sql

--changeset "Paul Snow":ledger-1
-- Canonical journals and postings. Money is BIGINT minor units in the
-- workspace currency; payee and notes stay in the entity store only.
create table ledger_journal (
    id uuid primary key,
    workspace_id uuid not null,
    type varchar(32) not null,
    status varchar(16) not null check (status in ('draft', 'pending', 'posted', 'reversed')),
    effective_date date not null,
    entered_at timestamptz not null,
    currency char(3) not null,
    account_id varchar(128),
    counter_account_id varchar(128),
    amount_minor bigint check (amount_minor between -999999999999999 and 999999999999999),
    refund_of uuid,
    reversal_of uuid,
    replaces uuid,
    created_at timestamptz not null,
    updated_at timestamptz not null
);
create index ledger_journal_workspace_idx on ledger_journal (workspace_id, effective_date);
-- A journal can be reversed at most once (A10).
create unique index ledger_journal_single_reversal on ledger_journal (reversal_of) where reversal_of is not null;

create table ledger_posting (
    journal_id uuid not null references ledger_journal (id) on delete cascade,
    line_no int not null,
    workspace_id uuid not null,
    account varchar(128) not null,
    amount_minor bigint not null
        check (amount_minor <> 0 and amount_minor between -999999999999999 and 999999999999999),
    primary key (journal_id, line_no)
);
create index ledger_posting_account_idx on ledger_posting (workspace_id, account);

--changeset "Paul Snow":ledger-2 splitStatements:false
-- Every journal balances to zero with at least two postings, checked at
-- commit so postings can be written in any order within the transaction.
create function ledger_check_balance(target uuid) returns void as $$
declare
    total numeric;
    lines int;
begin
    if not exists (select 1 from ledger_journal where id = target) then
        return;
    end if;
    select coalesce(sum(amount_minor), 0), count(*) into total, lines
    from ledger_posting where journal_id = target;
    if total <> 0 or lines < 2 then
        raise exception 'journal % does not balance', target using errcode = '23514';
    end if;
end;
$$ language plpgsql;

create function ledger_posting_balance_trigger() returns trigger as $$
begin
    if tg_op = 'DELETE' then
        perform ledger_check_balance(old.journal_id);
    else
        perform ledger_check_balance(new.journal_id);
        if tg_op = 'UPDATE' and old.journal_id <> new.journal_id then
            perform ledger_check_balance(old.journal_id);
        end if;
    end if;
    return null;
end;
$$ language plpgsql;

create constraint trigger ledger_posting_balanced
    after insert or update or delete on ledger_posting
    deferrable initially deferred
    for each row execute function ledger_posting_balance_trigger();

create function ledger_journal_balance_trigger() returns trigger as $$
begin
    perform ledger_check_balance(new.id);
    return null;
end;
$$ language plpgsql;

create constraint trigger ledger_journal_balanced
    after insert on ledger_journal
    deferrable initially deferred
    for each row execute function ledger_journal_balance_trigger();

-- Posted and reversed journals are immutable; the only permitted change is
-- posted to reversed by a correction. The workspace deletion job sets
-- finance.workspace_purge for its own transaction to erase a workspace.
create function ledger_journal_immutable_trigger() returns trigger as $$
begin
    if current_setting('finance.workspace_purge', true) = 'on' then
        return coalesce(new, old);
    end if;
    if tg_op = 'DELETE' then
        if old.status in ('posted', 'reversed') then
            raise exception 'posted journal % is immutable', old.id using errcode = '23514';
        end if;
        return old;
    end if;
    if old.status in ('posted', 'reversed') then
        if old.status = 'posted' and new.status = 'reversed'
            and (new.id, new.workspace_id, new.type, new.effective_date, new.entered_at, new.currency,
                 new.account_id, new.counter_account_id, new.amount_minor, new.refund_of, new.reversal_of,
                 new.replaces)
                is not distinct from
                (old.id, old.workspace_id, old.type, old.effective_date, old.entered_at, old.currency,
                 old.account_id, old.counter_account_id, old.amount_minor, old.refund_of, old.reversal_of,
                 old.replaces) then
            return new;
        end if;
        raise exception 'posted journal % is immutable', old.id using errcode = '23514';
    end if;
    return new;
end;
$$ language plpgsql;

create trigger ledger_journal_immutable
    before update or delete on ledger_journal
    for each row execute function ledger_journal_immutable_trigger();

create function ledger_posting_immutable_trigger() returns trigger as $$
declare
    parent_status varchar(16);
begin
    if current_setting('finance.workspace_purge', true) = 'on' then
        return coalesce(new, old);
    end if;
    select status into parent_status from ledger_journal where id = old.journal_id;
    if parent_status in ('posted', 'reversed') then
        raise exception 'postings of posted journal % are immutable', old.journal_id using errcode = '23514';
    end if;
    return coalesce(new, old);
end;
$$ language plpgsql;

create trigger ledger_posting_immutable
    before update or delete on ledger_posting
    for each row execute function ledger_posting_immutable_trigger();
