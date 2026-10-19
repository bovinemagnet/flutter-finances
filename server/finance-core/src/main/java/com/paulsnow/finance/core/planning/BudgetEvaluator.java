package com.paulsnow.finance.core.planning;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;

import com.paulsnow.finance.core.ledger.CategoryKind;
import com.paulsnow.finance.core.ledger.Chart;
import com.paulsnow.finance.core.ledger.Journal;
import com.paulsnow.finance.core.ledger.JournalStatus;
import com.paulsnow.finance.core.ledger.LedgerProjection;
import com.paulsnow.finance.core.ledger.Posting;
import com.paulsnow.finance.core.money.Money;

/**
 * Evaluates a {@link BudgetPlan} against the ledger period by period
 * (BUD 03).
 * <p>
 * Category figures follow {@link LedgerProjection#categoryNet}: posted and
 * reversed journals form the posted view, pending journals the pending view,
 * and income categories are negated so earning and spending are both
 * positive. Category totals ignore the paying account, so pending card
 * purchases count. Rollover starts at zero in the first period of the first
 * version and is carried forward with each line's policy. Periods are
 * cached, so evaluating consecutive periods is linear.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public final class BudgetEvaluator {

    private final BudgetPlan plan;
    private final LedgerProjection ledger;
    private final List<BudgetAdjustment> adjustments;
    private final Map<Long, BudgetPeriodEvaluation> cache = new HashMap<>();

    /**
     * Creates an evaluator.
     *
     * @param plan        the plan
     * @param ledger      the ledger
     * @param adjustments adjustments for this plan; unapproved ones are ignored
     */
    public BudgetEvaluator(BudgetPlan plan, LedgerProjection ledger, List<BudgetAdjustment> adjustments) {
        this.plan = Objects.requireNonNull(plan, "plan");
        this.ledger = Objects.requireNonNull(ledger, "ledger");
        this.adjustments = adjustments.stream().filter(BudgetAdjustment::approved).toList();
    }

    public BudgetPlan plan() {
        return plan;
    }

    /**
     * Evaluates the period containing {@code date}.
     *
     * @param date the date
     * @return the evaluation
     */
    public BudgetPeriodEvaluation evaluateAt(LocalDate date) {
        return evaluate(plan.schedule().indexOf(date));
    }

    /**
     * Evaluates {@code period}, which must belong to the plan's schedule.
     *
     * @param period the period
     * @return the evaluation
     */
    public BudgetPeriodEvaluation evaluate(BudgetPeriod period) {
        return evaluate(plan.schedule().indexOf(period.start()));
    }

    private BudgetPeriodEvaluation evaluate(long index) {
        BudgetPeriodEvaluation cached = cache.get(index);
        if (cached != null) {
            return cached;
        }
        long first = plan.versions().isEmpty() ? index
                : plan.schedule().indexOf(plan.versions().getFirst().effectiveFrom());
        long start = index;
        while (start > first && !cache.containsKey(start - 1)) {
            start--;
        }
        for (long k = start; k <= index; k++) {
            cache.put(k, compute(k, k > first ? cache.get(k - 1) : null));
        }
        return cache.get(index);
    }

    private BudgetPeriodEvaluation compute(long index, BudgetPeriodEvaluation previous) {
        BudgetPeriod period = plan.schedule().periodAt(index);
        BudgetVersion version = plan.versionFor(period);
        List<BudgetLine> lines = new ArrayList<>();
        if (version != null) {
            Activity activity = activity(period);
            for (BudgetAllocation allocation : version.allocations()) {
                lines.add(line(allocation, period, activity,
                        previous == null ? null : previous.line(allocation.categoryId())));
            }
        }
        return new BudgetPeriodEvaluation(period, version, lines);
    }

    private BudgetLine line(BudgetAllocation allocation, BudgetPeriod period, Activity activity,
            BudgetLine previous) {
        Money zero = Money.zero(ledger.chart().currency());
        String id = allocation.categoryId();
        Money adjusted = zero;
        for (BudgetAdjustment a : adjustments) {
            if (a.categoryId().equals(id) && a.periodStart().equals(period.start())) {
                adjusted = adjusted.plus(a.amount());
            }
        }
        return new BudgetLine(id, allocation.groupId(),
                allocation.rollover() != null ? allocation.rollover() : plan.schedule().rollover(),
                allocation.planned(),
                previous == null ? zero : previous.rollover().nextOpening(previous.remaining()),
                adjusted,
                new Money(activity.posted().getOrDefault(id, 0L), zero.currency()),
                new Money(activity.pending().getOrDefault(id, 0L), zero.currency()));
    }

    private Activity activity(BudgetPeriod period) {
        Chart chart = ledger.chart();
        Map<String, Long> posted = new HashMap<>();
        Map<String, Long> pending = new HashMap<>();
        for (Journal journal : ledger.journals()) {
            boolean inPosted = journal.status().inPostedLedger();
            if ((!inPosted && journal.status() != JournalStatus.PENDING) || !period.contains(journal.effectiveDate())) {
                continue;
            }
            Map<String, Long> target = inPosted ? posted : pending;
            for (Posting posting : journal.postings()) {
                String id = posting.ledgerAccountId();
                if (chart.hasCategory(id)) {
                    long sign = chart.category(id).kind() == CategoryKind.INCOME ? -1 : 1;
                    target.merge(id, sign * posting.amountMinor(), Math::addExact);
                }
            }
        }
        return new Activity(posted, pending);
    }

    private record Activity(Map<String, Long> posted, Map<String, Long> pending) {
    }
}
