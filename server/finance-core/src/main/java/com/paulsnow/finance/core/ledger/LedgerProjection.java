package com.paulsnow.finance.core.ledger;

import java.time.LocalDate;
import java.util.Collection;
import java.util.List;
import java.util.function.Predicate;

import com.paulsnow.finance.core.money.Money;

/**
 * Balances and totals derived from journals. Balances are never stored as
 * editable truth (SYNC 04); every figure is recomputed from accepted
 * journals.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public final class LedgerProjection {

    private final Chart chart;
    private final List<Journal> journals;

    public LedgerProjection(Chart chart, Collection<Journal> journals) {
        this.chart = chart;
        this.journals = List.copyOf(journals);
    }

    public Chart chart() {
        return chart;
    }

    public List<Journal> journals() {
        return journals;
    }

    /**
     * Signed ledger balance (debit positive) of any ledger account.
     *
     * @param ledgerAccountId ledger account
     * @param asOf            last effective date included, or null for all
     * @param includePending  whether pending journals count
     * @return the balance
     */
    public Money ledgerBalance(String ledgerAccountId, LocalDate asOf, boolean includePending) {
        return sum(j -> counts(j, includePending) && inRange(j.effectiveDate(), null, asOf),
                p -> p.ledgerAccountId().equals(ledgerAccountId));
    }

    /**
     * Balance as a user reads it: money held, or money owed for liabilities.
     *
     * @param accountId      user account
     * @param includePending whether pending journals count
     * @return the balance
     */
    public Money displayBalance(String accountId, boolean includePending) {
        Money balance = ledgerBalance(accountId, null, includePending);
        return chart.account(accountId).type().isLiability() ? balance.negate() : balance;
    }

    /** Net posted spending in the period; refunds reduce it. */
    public Money expenses(LocalDate from, LocalDate to) {
        return kindTotal(LedgerKind.EXPENSE, from, to, j -> j.status().inPostedLedger());
    }

    /** Net posted income in the period. */
    public Money income(LocalDate from, LocalDate to) {
        return kindTotal(LedgerKind.INCOME, from, to, j -> j.status().inPostedLedger());
    }

    /** Net pending spending in the period. */
    public Money pendingExpenses(LocalDate from, LocalDate to) {
        return kindTotal(LedgerKind.EXPENSE, from, to, j -> j.status() == JournalStatus.PENDING);
    }

    /**
     * Net posted amount for a category in the period, signed so that
     * spending and earning are both positive.
     *
     * @param categoryId category
     * @param from       first date
     * @param to         last date
     * @return the net amount
     */
    public Money categoryNet(String categoryId, LocalDate from, LocalDate to) {
        Money total = sum(j -> j.status().inPostedLedger() && inRange(j.effectiveDate(), from, to),
                p -> p.ledgerAccountId().equals(categoryId));
        return chart.category(categoryId).kind() == CategoryKind.INCOME ? total.negate() : total;
    }

    /**
     * Assets less liabilities for accounts included in net worth, plus money
     * owed to the user through reimbursements.
     *
     * @return net worth
     */
    public Money netWorth() {
        Money total = ledgerBalance(SystemAccounts.REIMBURSEMENT_RECEIVABLE, null, false);
        for (Account account : chart.accounts()) {
            if (account.includeInNetWorth()) {
                total = total.plus(ledgerBalance(account.id(), null, false));
            }
        }
        return total;
    }

    private Money kindTotal(LedgerKind kind, LocalDate from, LocalDate to, Predicate<Journal> include) {
        Money total = sum(j -> include.test(j) && inRange(j.effectiveDate(), from, to),
                p -> chart.kindOf(p.ledgerAccountId()) == kind);
        return kind == LedgerKind.INCOME ? total.negate() : total;
    }

    private Money sum(Predicate<Journal> includeJournal, Predicate<Posting> includePosting) {
        long total = 0;
        for (Journal journal : journals) {
            if (!includeJournal.test(journal)) {
                continue;
            }
            for (Posting posting : journal.postings()) {
                if (includePosting.test(posting)) {
                    total = Math.addExact(total, posting.amountMinor());
                }
            }
        }
        return new Money(total, chart.currency());
    }

    private static boolean counts(Journal journal, boolean includePending) {
        return journal.status().inPostedLedger() || (includePending && journal.status() == JournalStatus.PENDING);
    }

    private static boolean inRange(LocalDate date, LocalDate from, LocalDate to) {
        return (from == null || !date.isBefore(from)) && (to == null || !date.isAfter(to));
    }
}
