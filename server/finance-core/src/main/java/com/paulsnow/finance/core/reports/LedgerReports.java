package com.paulsnow.finance.core.reports;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.function.Function;

import com.paulsnow.finance.core.ledger.Account;
import com.paulsnow.finance.core.ledger.Chart;
import com.paulsnow.finance.core.ledger.Journal;
import com.paulsnow.finance.core.ledger.LedgerKind;
import com.paulsnow.finance.core.ledger.LedgerProjection;
import com.paulsnow.finance.core.ledger.Posting;
import com.paulsnow.finance.core.ledger.SystemAccounts;
import com.paulsnow.finance.core.money.Money;

/**
 * Reports over the posted ledger, with exactly the definitions of the
 * client's {@code ledger_reports.dart} (REP 01, REP 04), checked by the
 * shared {@code report.compute} fixtures:
 * <ul>
 * <li>posted and reversed journals form the posted ledger (a reversed
 * journal and its reversal cancel out); pending and draft journals are
 * ignored;</li>
 * <li>income and expenses are postings to income and expense categories, so
 * transfers between accounts are neither, and refunds reduce expenses;</li>
 * <li>net worth is the balance of accounts included in net worth plus the
 * reimbursement receivable.</li>
 * </ul>
 * Journal identifiers in rows are in effective date order, ties in the order
 * of the projection's journal list.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public final class LedgerReports {

    private LedgerReports() {
    }

    /**
     * Income, expenses and net per calendar month of {@code range}.
     *
     * @param ledger the projection
     * @param range  date range
     * @return one row per month keyed {@code YYYY-MM}
     */
    public static Report incomeVsExpenses(LedgerProjection ledger, DateRange range) {
        Chart chart = ledger.chart();
        List<DateRange> months = range.months();
        int first = monthIndex(range.start());
        long[] income = new long[months.size()];
        long[] expenses = new long[months.size()];
        List<List<String>> ids = new ArrayList<>();
        months.forEach(m -> ids.add(new ArrayList<>()));
        for (Journal journal : posted(ledger, range)) {
            int slot = monthIndex(journal.effectiveDate()) - first;
            boolean touched = false;
            for (Posting p : journal.postings()) {
                LedgerKind kind = chart.kindOf(p.ledgerAccountId());
                if (kind == LedgerKind.INCOME) {
                    income[slot] = Math.subtractExact(income[slot], p.amountMinor());
                    touched = true;
                } else if (kind == LedgerKind.EXPENSE) {
                    expenses[slot] = Math.addExact(expenses[slot], p.amountMinor());
                    touched = true;
                }
            }
            if (touched) {
                ids.get(slot).add(journal.id());
            }
        }
        List<Report.Row> rows = new ArrayList<>();
        for (int i = 0; i < months.size(); i++) {
            String key = months.get(i).start().toString().substring(0, 7);
            Map<String, Money> amounts = new LinkedHashMap<>();
            amounts.put("income", money(chart, income[i]));
            amounts.put("expenses", money(chart, expenses[i]));
            amounts.put("net", money(chart, Math.subtractExact(income[i], expenses[i])));
            rows.add(new Report.Row(key, key, amounts, Map.of(), ids.get(i)));
        }
        return new Report("Income and expenses", "Month", List.of(new Report.Column("income", "Income"),
                new Report.Column("expenses", "Expenses"), new Report.Column("net", "Net")), rows, range, null);
    }

    /**
     * Net spending per expense category (refunds reduce it), largest first.
     *
     * @param ledger the projection
     * @param range  date range
     * @return one row per category with spending in the range
     */
    public static Report spendingByCategory(LedgerProjection ledger, DateRange range) {
        Chart chart = ledger.chart();
        return spendingBy(ledger, range, "Spending by category", "Category", journal -> {
            List<Keyed> keys = new ArrayList<>();
            for (Posting p : journal.postings()) {
                if (chart.kindOf(p.ledgerAccountId()) == LedgerKind.EXPENSE) {
                    keys.add(new Keyed(p.ledgerAccountId(), chart.category(p.ledgerAccountId()).name(),
                            p.amountMinor()));
                }
            }
            return keys;
        });
    }

    /**
     * Net spending per merchant or payee, largest first. Entries without a
     * payee share the empty key, labelled {@code No payee}.
     *
     * @param ledger the projection
     * @param range  date range
     * @return one row per payee with spending in the range
     */
    public static Report spendingByPayee(LedgerProjection ledger, DateRange range) {
        Chart chart = ledger.chart();
        return spendingBy(ledger, range, "Spending by merchant", "Merchant", journal -> {
            long minor = 0;
            boolean touched = false;
            for (Posting p : journal.postings()) {
                if (chart.kindOf(p.ledgerAccountId()) == LedgerKind.EXPENSE) {
                    minor = Math.addExact(minor, p.amountMinor());
                    touched = true;
                }
            }
            String payee = journal.payee() == null ? "" : journal.payee();
            return touched ? List.of(new Keyed(payee, payee.isEmpty() ? "No payee" : payee, minor)) : List.of();
        });
    }

    /**
     * Each account's balance as a user reads it on {@code asOf} (all time
     * when null), with the journals that make it up, in chart order.
     *
     * @param ledger the projection
     * @param asOf   last effective date included, or null
     * @return one row per account
     */
    public static Report accountBalances(LedgerProjection ledger, LocalDate asOf) {
        Chart chart = ledger.chart();
        Map<String, List<String>> ids = new HashMap<>();
        Map<String, Long> totals = new HashMap<>();
        for (Journal journal : posted(ledger, null)) {
            if (asOf != null && journal.effectiveDate().isAfter(asOf)) {
                continue;
            }
            for (Posting p : journal.postings()) {
                if (!chart.hasAccount(p.ledgerAccountId())) {
                    continue;
                }
                totals.merge(p.ledgerAccountId(), p.amountMinor(), Math::addExact);
                addOnce(ids.computeIfAbsent(p.ledgerAccountId(), k -> new ArrayList<>()), journal.id());
            }
        }
        List<Report.Row> rows = new ArrayList<>();
        for (Account account : chart.accounts()) {
            long total = totals.getOrDefault(account.id(), 0L);
            long balance = account.type().isLiability() ? Math.negateExact(total) : total;
            rows.add(new Report.Row(account.id(), account.name(), Map.of("balance", money(chart, balance)), Map.of(),
                    ids.getOrDefault(account.id(), List.of())));
        }
        return new Report("Account balances", "Account", List.of(new Report.Column("balance", "Balance")), rows,
                null, asOf);
    }

    /**
     * Net worth at the end of each calendar month of {@code range} (the
     * range end for a partial last month), as
     * {@link LedgerProjection#netWorth()} defines it. Each point lists the
     * journals that changed net worth in its month.
     *
     * @param ledger the projection
     * @param range  date range
     * @return one row per month keyed by its last date
     */
    public static Report netWorthHistory(LedgerProjection ledger, DateRange range) {
        Chart chart = ledger.chart();
        Set<String> included = new HashSet<>();
        for (Account account : chart.accounts()) {
            if (account.includeInNetWorth()) {
                included.add(account.id());
            }
        }
        included.add(SystemAccounts.REIMBURSEMENT_RECEIVABLE);
        List<DateRange> months = range.months();
        int first = monthIndex(range.start());
        long[] deltas = new long[months.size()];
        List<List<String>> ids = new ArrayList<>();
        months.forEach(m -> ids.add(new ArrayList<>()));
        long opening = 0;
        for (Journal journal : posted(ledger, null)) {
            if (journal.effectiveDate().isAfter(range.end())) {
                break;
            }
            long delta = 0;
            boolean touched = false;
            for (Posting p : journal.postings()) {
                if (included.contains(p.ledgerAccountId())) {
                    delta = Math.addExact(delta, p.amountMinor());
                    touched = true;
                }
            }
            if (journal.effectiveDate().isBefore(range.start())) {
                opening = Math.addExact(opening, delta);
            } else if (touched) {
                int slot = monthIndex(journal.effectiveDate()) - first;
                deltas[slot] = Math.addExact(deltas[slot], delta);
                ids.get(slot).add(journal.id());
            }
        }
        long running = opening;
        List<Report.Row> rows = new ArrayList<>();
        for (int i = 0; i < months.size(); i++) {
            running = Math.addExact(running, deltas[i]);
            String key = months.get(i).end().toString();
            rows.add(new Report.Row(key, key, Map.of("netWorth", money(chart, running)), Map.of(), ids.get(i)));
        }
        return new Report("Net worth", "Date", List.of(new Report.Column("netWorth", "Net worth")), rows, range,
                null);
    }

    /**
     * Cash flow of an account set (REP 01). A journal whose postings to the
     * set net to zero is a transfer within the set; otherwise its net effect
     * on the set is an inflow or outflow crossing the boundary.
     *
     * @param ledger     the projection
     * @param range      date range
     * @param accountIds the account set
     * @return rows {@code inflows}, {@code outflows}, {@code internalTransfers} and {@code net}
     */
    public static Report cashFlow(LedgerProjection ledger, DateRange range, Set<String> accountIds) {
        long inflows = 0;
        long outflows = 0;
        long internal = 0;
        List<String> inIds = new ArrayList<>();
        List<String> outIds = new ArrayList<>();
        List<String> internalIds = new ArrayList<>();
        List<Journal> journals = posted(ledger, range);
        for (Journal journal : journals) {
            long net = 0;
            long moved = 0;
            boolean touched = false;
            for (Posting p : journal.postings()) {
                if (!accountIds.contains(p.ledgerAccountId())) {
                    continue;
                }
                touched = true;
                net = Math.addExact(net, p.amountMinor());
                if (p.amountMinor() > 0) {
                    moved = Math.addExact(moved, p.amountMinor());
                }
            }
            if (!touched) {
                continue;
            }
            if (net == 0) {
                if (moved == 0) {
                    continue;
                }
                internal = Math.addExact(internal, moved);
                internalIds.add(journal.id());
            } else if (net > 0) {
                inflows = Math.addExact(inflows, net);
                inIds.add(journal.id());
            } else {
                outflows = Math.subtractExact(outflows, net);
                outIds.add(journal.id());
            }
        }
        Chart chart = ledger.chart();
        Set<String> boundary = new LinkedHashSet<>(inIds);
        boundary.addAll(outIds);
        List<String> netIds = new ArrayList<>();
        for (Journal journal : journals) {
            if (boundary.contains(journal.id())) {
                netIds.add(journal.id());
            }
        }
        List<Report.Row> rows = List.of(
                new Report.Row("inflows", "Money in", Map.of("amount", money(chart, inflows)), Map.of(), inIds),
                new Report.Row("outflows", "Money out", Map.of("amount", money(chart, outflows)), Map.of(), outIds),
                new Report.Row("internalTransfers", "Transfers between these accounts",
                        Map.of("amount", money(chart, internal)), Map.of(), internalIds),
                new Report.Row("net", "Net", Map.of("amount", money(chart, Math.subtractExact(inflows, outflows))),
                        Map.of(), netIds));
        return new Report("Cash flow", "Flow", List.of(new Report.Column("amount", "Amount")), rows, range, null);
    }

    private record Keyed(String key, String label, long minor) {
    }

    private static Report spendingBy(LedgerProjection ledger, DateRange range, String title, String keyLabel,
            Function<Journal, List<Keyed>> keysOf) {
        Map<String, Long> totals = new HashMap<>();
        Map<String, String> labels = new HashMap<>();
        Map<String, List<String>> ids = new HashMap<>();
        for (Journal journal : posted(ledger, range)) {
            for (Keyed keyed : keysOf.apply(journal)) {
                totals.merge(keyed.key(), keyed.minor(), Math::addExact);
                labels.put(keyed.key(), keyed.label());
                addOnce(ids.computeIfAbsent(keyed.key(), k -> new ArrayList<>()), journal.id());
            }
        }
        List<String> keys = new ArrayList<>(totals.keySet());
        keys.sort(Comparator.<String, Long>comparing(totals::get).reversed().thenComparing(Comparator.naturalOrder()));
        List<Report.Row> rows = new ArrayList<>();
        for (String key : keys) {
            rows.add(new Report.Row(key, labels.get(key), Map.of("spending", money(ledger.chart(), totals.get(key))),
                    Map.of(), ids.get(key)));
        }
        return new Report(title, keyLabel, List.of(new Report.Column("spending", "Spending")), rows, range, null);
    }

    /** Posted-ledger journals, optionally within a range, in effective date then list order. */
    private static List<Journal> posted(LedgerProjection ledger, DateRange range) {
        List<Journal> result = new ArrayList<>();
        for (Journal journal : ledger.journals()) {
            if (journal.status().inPostedLedger() && (range == null || range.contains(journal.effectiveDate()))) {
                result.add(journal);
            }
        }
        // List.sort is stable, so ties keep the projection's order.
        result.sort(Comparator.comparing(Journal::effectiveDate));
        return result;
    }

    private static void addOnce(List<String> list, String id) {
        if (list.isEmpty() || !list.getLast().equals(id)) {
            list.add(id);
        }
    }

    private static int monthIndex(LocalDate date) {
        return date.getYear() * 12 + date.getMonthValue();
    }

    private static Money money(Chart chart, long minor) {
        return new Money(minor, chart.currency());
    }
}
