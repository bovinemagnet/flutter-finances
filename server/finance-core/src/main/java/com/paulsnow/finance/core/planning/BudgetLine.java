package com.paulsnow.finance.core.planning;

import java.util.Objects;

import com.paulsnow.finance.core.money.Money;

/**
 * One category's budget in one period (BUD 03).
 *
 * @param categoryId      the category
 * @param groupId         the budget group, or null
 * @param rollover        policy carrying {@link #remaining()} into the next period
 * @param planned         planned amount
 * @param openingRollover rollover carried in from the previous period
 * @param adjustments     total of approved adjustments
 * @param postedNet       posted spending net of refunds
 * @param pending         pending spending net of refunds
 * @author Paul Snow
 * @since 0.0.0
 */
public record BudgetLine(String categoryId, String groupId, RolloverPolicy rollover, Money planned,
        Money openingRollover, Money adjustments, Money postedNet, Money pending) {

    public BudgetLine {
        Objects.requireNonNull(categoryId, "categoryId");
        Objects.requireNonNull(rollover, "rollover");
        Objects.requireNonNull(planned, "planned");
        Objects.requireNonNull(openingRollover, "openingRollover");
        Objects.requireNonNull(adjustments, "adjustments");
        Objects.requireNonNull(postedNet, "postedNet");
        Objects.requireNonNull(pending, "pending");
    }

    private BudgetRemaining result() {
        return BudgetRemaining.of(planned, openingRollover, adjustments, postedNet, pending);
    }

    /** Returns planned + opening rollover + adjustments − posted net. */
    public Money remaining() {
        return result().remaining();
    }

    /** Returns {@link #remaining()} less pending spending. */
    public Money remainingAfterPending() {
        return result().remainingAfterPending();
    }
}
