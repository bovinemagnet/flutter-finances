package com.paulsnow.finance.core.planning;

import com.paulsnow.finance.core.ledger.WireNames;

/**
 * Repeat units for schedules and budget periods (PLAN 01, BUD 02).
 * <p>
 * Day-based units advance by a fixed number of days; month-based units
 * advance by whole calendar months, so a month is never four weeks.
 * {@link #occurrencesPerYear()} is the documented annual factor used for
 * monthly equivalents.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public enum Frequency {
    DAILY(1, 0, 365),
    WEEKLY(7, 0, 52),
    FORTNIGHTLY(14, 0, 26),
    MONTHLY(0, 1, 12),
    QUARTERLY(0, 3, 4),
    ANNUALLY(0, 12, 1);

    private final int days;
    private final int months;
    private final int occurrencesPerYear;

    Frequency(int days, int months, int occurrencesPerYear) {
        this.days = days;
        this.months = months;
        this.occurrencesPerYear = occurrencesPerYear;
    }

    /** Returns days per step for day-based units, otherwise zero. */
    public int days() {
        return days;
    }

    /** Returns months per step for month-based units, otherwise zero. */
    public int months() {
        return months;
    }

    /** Returns the documented number of occurrences in a year. */
    public int occurrencesPerYear() {
        return occurrencesPerYear;
    }

    /** Returns whether the unit advances by calendar months. */
    public boolean isMonthBased() {
        return months > 0;
    }

    /** Returns the wire name, for example {@code fortnightly}. */
    public String wire() {
        return WireNames.camel(this);
    }

    /**
     * Resolves a wire name.
     *
     * @param wire wire name
     * @return the frequency
     * @throws IllegalArgumentException when unknown
     */
    public static Frequency fromWire(String wire) {
        return WireNames.lookup(Frequency.class, wire, Frequency::wire);
    }
}
