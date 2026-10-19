package com.paulsnow.finance.server.ledger;

import java.sql.Timestamp;
import java.time.Clock;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import java.util.function.Function;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;

import com.paulsnow.finance.core.ledger.Corrections;
import com.paulsnow.finance.core.ledger.Journal;
import com.paulsnow.finance.core.ledger.JournalStatus;
import com.paulsnow.finance.core.ledger.JournalValidator;
import com.paulsnow.finance.core.ledger.LedgerError;
import com.paulsnow.finance.core.ledger.Posting;
import com.paulsnow.finance.core.ledger.SystemAccounts;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;

/**
 * Validates and stores canonical journals. Callers run these methods inside
 * the transaction that also records the command's idempotency and change
 * records (SYNC 02).
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Service
public class LedgerService {

    /** Every rejection code this service reports, for metrics. */
    public static final List<String> REJECTION_CODES = List.of("EMPTY", "TOO_FEW_POSTINGS", "UNBALANCED",
            "MIXED_CURRENCY", "ZERO_AMOUNT", "OUT_OF_RANGE", "CURRENCY_MISMATCH", "UNKNOWN_LEDGER_ACCOUNT",
            "INVALID_STATUS", "INVALID_TYPE", "REVERSAL_MISMATCH", "REPLACEMENT_MISMATCH", "INVALID_JOURNAL",
            "POSTED_JOURNAL_IMMUTABLE");

    private final JdbcClient jdbc;
    private final Clock clock;
    private final MeterRegistry meters;

    LedgerService(JdbcClient jdbc, Clock clock, MeterRegistry meters) {
        this.jdbc = jdbc;
        this.clock = clock;
        this.meters = meters;
        REJECTION_CODES.forEach(this::rejectedCounter);
    }

    /**
     * Applies the protocol's journal rules: the shared posting rules
     * ({@code journal.validate}), the workspace currency, posting accounts
     * that are live account or category entities or known system accounts,
     * and a status other than {@code reversed}.
     *
     * @param parsed       the parsed (well-formed) journal
     * @param liveEntities returns the subset of identifiers that are live account or category entities
     * @return error codes, empty when valid
     */
    public List<String> validate(JournalJson.Parsed parsed, Function<Set<String>, Set<String>> liveEntities) {
        Journal journal = parsed.journal();
        Set<String> errors = new LinkedHashSet<>();
        if (parsed.currencyMismatch()) {
            errors.add("CURRENCY_MISMATCH");
        }
        for (LedgerError error : JournalValidator.validate(journal.postings())) {
            errors.add(error.code());
        }
        Set<String> entityAccounts = new LinkedHashSet<>();
        for (Posting posting : journal.postings()) {
            String account = posting.ledgerAccountId();
            if (SystemAccounts.isSystem(account)) {
                if (!SystemAccounts.KINDS.containsKey(account)) {
                    errors.add("UNKNOWN_LEDGER_ACCOUNT");
                }
            } else {
                entityAccounts.add(account);
            }
        }
        if (!entityAccounts.isEmpty() && !liveEntities.apply(entityAccounts).containsAll(entityAccounts)) {
            errors.add("UNKNOWN_LEDGER_ACCOUNT");
        }
        if (journal.status() == JournalStatus.REVERSED) {
            errors.add("INVALID_STATUS");
        }
        return List.copyOf(errors);
    }

    /**
     * Returns whether {@code reversal} negates {@code original} exactly.
     *
     * @param original the posted journal
     * @param reversal proposed reversal journal
     * @return true when exact
     */
    public boolean isExactReversal(Journal original, Journal reversal) {
        return Corrections.isExactReversal(original, reversal);
    }

    /** Counts rejected journals by code for operations dashboards. */
    public void recordRejection(List<String> codes) {
        codes.forEach(code -> rejectedCounter(code).increment());
    }

    /** Inserts a new journal with its postings. */
    public void insert(UUID workspaceId, Journal journal) {
        Timestamp now = Timestamp.from(clock.instant());
        jdbc.sql("insert into ledger_journal (id, workspace_id, type, status, effective_date, entered_at, currency, "
                        + "account_id, counter_account_id, amount_minor, refund_of, reversal_of, replaces, "
                        + "created_at, updated_at) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
                .params(UUID.fromString(journal.id()), workspaceId, journal.type().wire(), journal.status().wire(),
                        journal.effectiveDate(), Timestamp.from(journal.enteredAt()), journal.currency().code(),
                        journal.accountId(), journal.counterAccountId(),
                        journal.amount() == null ? null : journal.amount().minor(), uuid(journal.refundOf()),
                        uuid(journal.reversalOf()), uuid(journal.replaces()), now, now)
                .update();
        insertPostings(workspaceId, journal);
    }

    /** Replaces a draft or pending journal and its postings. */
    public void replace(UUID workspaceId, Journal journal) {
        UUID id = UUID.fromString(journal.id());
        jdbc.sql("delete from ledger_posting where journal_id = ? and workspace_id = ?").params(id, workspaceId)
                .update();
        jdbc.sql("update ledger_journal set type = ?, status = ?, effective_date = ?, entered_at = ?, currency = ?, "
                        + "account_id = ?, counter_account_id = ?, amount_minor = ?, refund_of = ?, reversal_of = ?, "
                        + "replaces = ?, updated_at = ? where id = ? and workspace_id = ?")
                .params(journal.type().wire(), journal.status().wire(), journal.effectiveDate(),
                        Timestamp.from(journal.enteredAt()), journal.currency().code(), journal.accountId(),
                        journal.counterAccountId(), journal.amount() == null ? null : journal.amount().minor(),
                        uuid(journal.refundOf()), uuid(journal.reversalOf()), uuid(journal.replaces()),
                        Timestamp.from(clock.instant()), id, workspaceId)
                .update();
        insertPostings(workspaceId, journal);
    }

    /** Marks a posted journal reversed as part of a correction. */
    public void markReversed(UUID workspaceId, String journalId) {
        jdbc.sql("update ledger_journal set status = 'reversed', updated_at = ? where id = ? and workspace_id = ?")
                .params(Timestamp.from(clock.instant()), UUID.fromString(journalId), workspaceId).update();
    }

    /** Deletes a draft or pending journal; posted ones are refused by the database. */
    public void deleteUnposted(UUID workspaceId, String journalId) {
        jdbc.sql("delete from ledger_journal where id = ? and workspace_id = ?")
                .params(UUID.fromString(journalId), workspaceId).update();
    }

    /**
     * Returns whether any journal posts to {@code ledgerAccountId}.
     *
     * @param workspaceId     workspace
     * @param ledgerAccountId account or category identifier
     * @return true when referenced
     */
    public boolean isReferenced(UUID workspaceId, String ledgerAccountId) {
        return jdbc.sql("select exists (select 1 from ledger_posting where workspace_id = ? and account = ?)")
                .params(workspaceId, ledgerAccountId).query(Boolean.class).single();
    }

    /**
     * A journal that touches an account, for import matching.
     *
     * @param journalId     journal
     * @param effectiveDate effective date
     * @param accountMinor  net amount posted to the account (positive is money in)
     * @param status        status
     * @param type          entry type
     */
    public record AccountMovement(UUID journalId, LocalDate effectiveDate, long accountMinor, String status,
            String type) {
    }

    /**
     * Lists non-draft, non-reversed journals posting {@code accountMinor}
     * to an account between two dates, for duplicate and transfer detection.
     *
     * @param workspaceId  workspace
     * @param account      ledger account; null for any other account
     * @param excluding    account to exclude when {@code account} is null
     * @param accountMinor net amount on the account
     * @param from         first date
     * @param to           last date
     * @return matching movements
     */
    public List<AccountMovement> movements(UUID workspaceId, String account, String excluding, long accountMinor,
            LocalDate from, LocalDate to) {
        String accountFilter = account != null ? "p.account = ?" : "p.account <> ? and p.account not like 'system:%'";
        return jdbc.sql("select j.id, j.effective_date, sum(p.amount_minor) as net, j.status, j.type "
                        + "from ledger_journal j join ledger_posting p on p.journal_id = j.id "
                        + "where j.workspace_id = ? and " + accountFilter + " and j.status in ('pending', 'posted') "
                        + "and j.type <> 'reversal' and j.effective_date between ? and ? "
                        + "group by j.id, j.effective_date, j.status, j.type, p.account having sum(p.amount_minor) = ? "
                        + "order by j.effective_date, j.id")
                .params(workspaceId, account != null ? account : excluding, from, to, accountMinor)
                .query((rs, row) -> new AccountMovement(rs.getObject("id", UUID.class),
                        rs.getObject("effective_date", LocalDate.class), rs.getLong("net"), rs.getString("status"),
                        rs.getString("type")))
                .list();
    }

    /**
     * The net amount one journal posts to one ledger account.
     *
     * @param journalId     journal
     * @param effectiveDate effective date
     * @param account       ledger account (user account, category or system account)
     * @param netMinor      net amount on that account
     */
    public record PostingMovement(UUID journalId, LocalDate effectiveDate, String account, long netMinor) {
    }

    /**
     * Lists the net movement per journal and ledger account of every
     * pending or posted, non-reversal journal dated in a range, for
     * matching imported statement rows in memory.
     *
     * @param workspaceId workspace
     * @param from        first date
     * @param to          last date
     * @return movements ordered by date
     */
    public List<PostingMovement> movementsBetween(UUID workspaceId, LocalDate from, LocalDate to) {
        return jdbc.sql("select j.id, j.effective_date, p.account, sum(p.amount_minor) as net "
                        + "from ledger_journal j join ledger_posting p on p.journal_id = j.id "
                        + "where j.workspace_id = ? and j.status in ('pending', 'posted') and j.type <> 'reversal' "
                        + "and j.effective_date between ? and ? group by j.id, j.effective_date, p.account "
                        + "order by j.effective_date, j.id")
                .params(workspaceId, from, to)
                .query((rs, row) -> new PostingMovement(rs.getObject("id", UUID.class),
                        rs.getObject("effective_date", LocalDate.class), rs.getString("account"), rs.getLong("net")))
                .list();
    }

    /**
     * Removes every journal of a workspace (deletion job only).
     *
     * @param workspaceId workspace being deleted
     * @return journals removed
     */
    public int purgeWorkspace(UUID workspaceId) {
        jdbc.sql("select set_config('finance.workspace_purge', 'on', true)").query(String.class).single();
        jdbc.sql("delete from ledger_posting where workspace_id = ?").param(workspaceId).update();
        return jdbc.sql("delete from ledger_journal where workspace_id = ?").param(workspaceId).update();
    }

    private void insertPostings(UUID workspaceId, Journal journal) {
        List<Object[]> rows = new ArrayList<>();
        int line = 1;
        for (Posting posting : journal.postings()) {
            rows.add(new Object[] { UUID.fromString(journal.id()), line++, workspaceId, posting.ledgerAccountId(),
                    posting.amountMinor() });
        }
        for (Object[] row : rows) {
            jdbc.sql("insert into ledger_posting (journal_id, line_no, workspace_id, account, amount_minor) "
                    + "values (?, ?, ?, ?, ?)").params(row).update();
        }
    }

    private Counter rejectedCounter(String code) {
        return Counter.builder("finance.ledger.journals.rejected")
                .description("Journals rejected by validation, by error code")
                .tag("code", code)
                .register(meters);
    }

    private static UUID uuid(String value) {
        return value == null ? null : UUID.fromString(value);
    }
}
