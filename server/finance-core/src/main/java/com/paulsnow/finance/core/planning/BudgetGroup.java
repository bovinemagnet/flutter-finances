package com.paulsnow.finance.core.planning;

import java.util.Objects;

/**
 * A budget group such as Needs, Wants or Savings (BUD 01).
 *
 * @param id               identifier
 * @param name             display name
 * @param shareBasisPoints share of take-home income in basis points
 * @param discretionary    whether the group's spending is discretionary (BUD 07), as Wants is
 * @author Paul Snow
 * @since 0.0.0
 */
public record BudgetGroup(String id, String name, int shareBasisPoints, boolean discretionary) {

    public BudgetGroup {
        Objects.requireNonNull(id, "id");
        if (shareBasisPoints < 0) {
            throw new IllegalArgumentException("share must not be negative");
        }
    }
}
