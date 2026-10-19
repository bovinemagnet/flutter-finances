package com.paulsnow.finance.core.planning;

import java.util.Objects;

import com.paulsnow.finance.core.money.Money;

/**
 * Remaining budget for one target in one period (BUD 03).
 *
 * @param remaining             planned + opening rollover + approved adjustments − posted net
 * @param remainingAfterPending {@code remaining} less pending spending, shown separately
 * @author Paul Snow
 * @since 0.0.0
 */
public record BudgetRemaining(Money remaining, Money remainingAfterPending) {

    public BudgetRemaining {
        Objects.requireNonNull(remaining, "remaining");
        Objects.requireNonNull(remainingAfterPending, "remainingAfterPending");
    }

    /**
     * Applies the BUD 03 formula. {@code postedNet} and {@code pending} are
     * signed so that spending is positive and refunds reduce them. Only
     * approved adjustments may be passed in.
     *
     * @param planned         planned amount for the period
     * @param openingRollover rollover carried in from the previous period
     * @param adjustments     total of approved adjustments
     * @param postedNet       posted spending net of refunds
     * @param pending         pending spending net of refunds
     * @return the remaining amounts
     */
    public static BudgetRemaining of(Money planned, Money openingRollover, Money adjustments, Money postedNet,
            Money pending) {
        Money remaining = planned.plus(openingRollover).plus(adjustments).minus(postedNet);
        return new BudgetRemaining(remaining, remaining.minus(pending));
    }
}
