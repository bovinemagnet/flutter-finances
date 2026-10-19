package com.paulsnow.finance.core.planning;

import java.time.LocalDate;
import java.util.Objects;

import com.paulsnow.finance.core.money.Money;

/**
 * A change to one category's budget in one period (BUD 03). Unapproved
 * adjustments are proposals and do not affect remaining.
 *
 * @param id          identifier
 * @param categoryId  the category
 * @param periodStart start of the period adjusted
 * @param amount      signed change
 * @param approved    whether the adjustment is approved
 * @author Paul Snow
 * @since 0.0.0
 */
public record BudgetAdjustment(String id, String categoryId, LocalDate periodStart, Money amount,
        boolean approved) {

    public BudgetAdjustment {
        Objects.requireNonNull(id, "id");
        Objects.requireNonNull(categoryId, "categoryId");
        Objects.requireNonNull(periodStart, "periodStart");
        Objects.requireNonNull(amount, "amount");
    }
}
