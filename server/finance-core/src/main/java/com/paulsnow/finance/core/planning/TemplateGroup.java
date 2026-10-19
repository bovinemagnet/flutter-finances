package com.paulsnow.finance.core.planning;

import java.util.List;
import java.util.Objects;

/**
 * A group's share of take-home income in basis points (5000 is 50%).
 *
 * @param id               group identifier
 * @param shareBasisPoints non-negative share in basis points
 * @author Paul Snow
 * @since 0.0.0
 */
public record TemplateGroup(String id, int shareBasisPoints) {

    /** Basis points in 100%. */
    public static final int FULL_SHARE_BASIS_POINTS = 10_000;

    /**
     * The Needs, Wants and Savings starting point (BUD 01). Users may change
     * every percentage afterwards.
     */
    public static final List<TemplateGroup> FIFTY_THIRTY_TWENTY = List.of(
            new TemplateGroup("needs", 5000),
            new TemplateGroup("wants", 3000),
            new TemplateGroup("savings", 2000));

    public TemplateGroup {
        Objects.requireNonNull(id, "id");
        if (shareBasisPoints < 0) {
            throw new IllegalArgumentException("share must not be negative");
        }
    }
}
