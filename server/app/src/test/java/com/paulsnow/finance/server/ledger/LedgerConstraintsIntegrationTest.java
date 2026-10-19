package com.paulsnow.finance.server.ledger;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.sql.Timestamp;
import java.time.Instant;
import java.time.LocalDate;
import java.util.UUID;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.transaction.support.TransactionTemplate;

import com.paulsnow.finance.core.ids.Ids;
import com.paulsnow.finance.server.support.IntegrationTestSupport;

/**
 * The database enforces the ledger invariants independently of the Java
 * validation: balanced journals and immutable posted journals.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
class LedgerConstraintsIntegrationTest extends IntegrationTestSupport {

    @Autowired
    JdbcClient jdbc;

    @Autowired
    TransactionTemplate transactions;

    @Test
    void rejectsAnUnbalancedJournalAtCommit() {
        UUID workspace = UUID.randomUUID();
        UUID journal = Ids.newUuid();
        assertThatThrownBy(() -> transactions.executeWithoutResult(status -> {
            insertJournal(workspace, journal, "posted");
            insertPosting(journal, workspace, 1, "groceries", 1000);
            insertPosting(journal, workspace, 2, "bank", -999);
        })).isInstanceOf(DataAccessException.class);
        assertThat(count(journal)).isZero();
    }

    @Test
    void rejectsAJournalWithoutPostings() {
        UUID journal = Ids.newUuid();
        assertThatThrownBy(() -> transactions.executeWithoutResult(
                status -> insertJournal(UUID.randomUUID(), journal, "draft")))
                .isInstanceOf(DataAccessException.class);
    }

    @Test
    void keepsPostedJournalsAndTheirPostingsImmutable() {
        UUID workspace = UUID.randomUUID();
        UUID journal = Ids.newUuid();
        transactions.executeWithoutResult(status -> {
            insertJournal(workspace, journal, "posted");
            insertPosting(journal, workspace, 1, "groceries", 1000);
            insertPosting(journal, workspace, 2, "bank", -1000);
        });
        assertThatThrownBy(() -> jdbc.sql("update ledger_posting set amount_minor = 900 where journal_id = ? "
                + "and line_no = 1").param(journal).update()).isInstanceOf(DataAccessException.class);
        assertThatThrownBy(() -> jdbc.sql("update ledger_journal set amount_minor = 5 where id = ?")
                .param(journal).update()).isInstanceOf(DataAccessException.class);
        assertThatThrownBy(() -> jdbc.sql("delete from ledger_journal where id = ?").param(journal).update())
                .isInstanceOf(DataAccessException.class);
        assertThat(jdbc.sql("update ledger_journal set status = 'reversed' where id = ?").param(journal).update())
                .isEqualTo(1);
        assertThatThrownBy(() -> jdbc.sql("update ledger_journal set status = 'posted' where id = ?")
                .param(journal).update()).isInstanceOf(DataAccessException.class);
    }

    private void insertJournal(UUID workspace, UUID journal, String status) {
        Timestamp now = Timestamp.from(Instant.now());
        jdbc.sql("insert into ledger_journal (id, workspace_id, type, status, effective_date, entered_at, currency, "
                        + "created_at, updated_at) values (?, ?, 'expense', ?, ?, ?, 'AUD', ?, ?)")
                .params(journal, workspace, status, LocalDate.of(2026, 7, 1), now, now, now).update();
    }

    private void insertPosting(UUID journal, UUID workspace, int line, String account, long amount) {
        jdbc.sql("insert into ledger_posting (journal_id, line_no, workspace_id, account, amount_minor) "
                + "values (?, ?, ?, ?, ?)").params(journal, line, workspace, account, amount).update();
    }

    private long count(UUID journal) {
        return jdbc.sql("select count(*) from ledger_journal where id = ?").param(journal).query(Long.class).single();
    }
}
