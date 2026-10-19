package com.paulsnow.finance.core.planning;

import java.util.List;
import java.util.Objects;

/**
 * A budget period's lines.
 *
 * @param period  the period
 * @param version the version in force, or null when the period predates the plan
 * @param lines   one line per allocation of the version
 * @author Paul Snow
 * @since 0.0.0
 */
public record BudgetPeriodEvaluation(BudgetPeriod period, BudgetVersion version, List<BudgetLine> lines) {

    public BudgetPeriodEvaluation {
        Objects.requireNonNull(period, "period");
        lines = List.copyOf(lines);
    }

    /**
     * Returns the line for a category.
     *
     * @param categoryId the category
     * @return the line, or null
     */
    public BudgetLine line(String categoryId) {
        return lines.stream().filter(l -> l.categoryId().equals(categoryId)).findFirst().orElse(null);
    }
}
