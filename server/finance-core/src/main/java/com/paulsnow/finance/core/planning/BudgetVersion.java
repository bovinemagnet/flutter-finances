package com.paulsnow.finance.core.planning;

import java.time.LocalDate;
import java.util.HashSet;
import java.util.List;
import java.util.Objects;
import java.util.Set;

import com.paulsnow.finance.core.money.Money;

/**
 * The allocations that apply from {@code effectiveFrom} until the next
 * version (BUD 03). {@code income} is planned take-home income per period;
 * the application never estimates tax or compulsory superannuation.
 *
 * @param id            identifier
 * @param effectiveFrom start of the first period this version governs
 * @param income        planned take-home income per period
 * @param groups        budget groups
 * @param allocations   one allocation per category
 * @author Paul Snow
 * @since 0.0.0
 */
public record BudgetVersion(String id, LocalDate effectiveFrom, Money income, List<BudgetGroup> groups,
        List<BudgetAllocation> allocations) {

    /**
     * Validates the version.
     *
     * @throws IllegalArgumentException when an allocation names an unknown
     *                                  group or a category is allocated twice
     */
    public BudgetVersion {
        Objects.requireNonNull(id, "id");
        Objects.requireNonNull(effectiveFrom, "effectiveFrom");
        Objects.requireNonNull(income, "income");
        groups = List.copyOf(groups);
        allocations = List.copyOf(allocations);
        Set<String> groupIds = new HashSet<>();
        groups.forEach(g -> groupIds.add(g.id()));
        Set<String> targets = new HashSet<>();
        for (BudgetAllocation allocation : allocations) {
            if (allocation.groupId() != null && !groupIds.contains(allocation.groupId())) {
                throw new IllegalArgumentException("Unknown budget group " + allocation.groupId());
            }
            if (!targets.add(allocation.categoryId())) {
                throw new IllegalArgumentException("Duplicate allocation for " + allocation.categoryId());
            }
        }
    }

    /**
     * Returns the allocation for a category.
     *
     * @param categoryId the category
     * @return the allocation, or null
     */
    public BudgetAllocation allocationFor(String categoryId) {
        return allocations.stream().filter(a -> a.categoryId().equals(categoryId)).findFirst().orElse(null);
    }

    /**
     * Returns a group by identifier.
     *
     * @param groupId the group
     * @return the group, or null
     */
    public BudgetGroup group(String groupId) {
        return groups.stream().filter(g -> g.id().equals(groupId)).findFirst().orElse(null);
    }
}
