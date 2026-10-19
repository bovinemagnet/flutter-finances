package com.paulsnow.finance.core.planning;

import java.util.Comparator;
import java.util.List;
import java.util.Objects;

/**
 * A budget with its period schedule and every historical version (BUD 03).
 *
 * @param id       identifier
 * @param name     display name
 * @param schedule period schedule, including the plan's rollover policy
 * @param versions versions, ordered by effective date
 * @author Paul Snow
 * @since 0.0.0
 */
public record BudgetPlan(String id, String name, PeriodSchedule schedule, List<BudgetVersion> versions) {

    public BudgetPlan {
        Objects.requireNonNull(id, "id");
        Objects.requireNonNull(schedule, "schedule");
        versions = versions.stream().sorted(Comparator.comparing(BudgetVersion::effectiveFrom)).toList();
    }

    /**
     * Returns the version in force for {@code period}: the latest one
     * effective on or before the period start.
     *
     * @param period the period
     * @return the version, or null before the first version
     */
    public BudgetVersion versionFor(BudgetPeriod period) {
        BudgetVersion found = null;
        for (BudgetVersion version : versions) {
            if (!version.effectiveFrom().isAfter(period.start())) {
                found = version;
            }
        }
        return found;
    }
}
