package com.paulsnow.finance.core.planning;

import java.util.Objects;

import com.paulsnow.finance.core.money.Money;

/**
 * Planned spending per period for one expense category.
 *
 * @param categoryId the category
 * @param planned    planned amount per period
 * @param groupId    the budget group, or null
 * @param rollover   overrides the plan's rollover policy for this category when set, or null
 * @author Paul Snow
 * @since 0.0.0
 */
public record BudgetAllocation(String categoryId, Money planned, String groupId, RolloverPolicy rollover) {

    public BudgetAllocation {
        Objects.requireNonNull(categoryId, "categoryId");
        Objects.requireNonNull(planned, "planned");
    }

    /**
     * Creates an allocation that follows the plan's rollover policy.
     *
     * @param categoryId the category
     * @param planned    planned amount per period
     * @param groupId    the budget group, or null
     * @return the allocation
     */
    public static BudgetAllocation category(String categoryId, Money planned, String groupId) {
        return new BudgetAllocation(categoryId, planned, groupId, null);
    }
}
