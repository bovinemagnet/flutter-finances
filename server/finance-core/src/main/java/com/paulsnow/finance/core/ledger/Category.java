package com.paulsnow.finance.core.ledger;

import java.util.Objects;

/**
 * An income or expense category. Its ledger account shares its identifier.
 * Categories can be archived; historical references remain valid.
 *
 * @param id       identifier, also the ledger account identifier
 * @param name     display name
 * @param kind     income or expense
 * @param parentId parent category, or null
 * @param archived hidden from entry but retained for history
 * @author Paul Snow
 * @since 0.0.0
 */
public record Category(String id, String name, CategoryKind kind, String parentId, boolean archived) {

    public Category {
        Objects.requireNonNull(id, "id");
        Objects.requireNonNull(kind, "kind");
    }
}
