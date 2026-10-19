package com.paulsnow.finance.core.planning;

import java.util.Objects;

import com.paulsnow.finance.core.money.Money;

/**
 * A per-month figure derived from another frequency (BUD 02).
 * <p>
 * Uses the documented annual factor {@code occurrencesPerYear / (12 ×
 * interval)} (weekly 52/12, fortnightly 26/12, daily 365/12, quarterly 4/12,
 * annual 1/12) with half-up rounding to a minor unit. Only an exact monthly
 * amount is not an estimate.
 *
 * @param amount       the monthly equivalent
 * @param annualFactor the factor applied, for example {@code 52/12}, shown beside the estimate
 * @param isEstimate   whether the factor is not exactly one
 * @author Paul Snow
 * @since 0.0.0
 */
public record MonthlyEstimate(Money amount, String annualFactor, boolean isEstimate) {

    public MonthlyEstimate {
        Objects.requireNonNull(amount, "amount");
        Objects.requireNonNull(annualFactor, "annualFactor");
    }

    /**
     * Converts an amount that repeats every {@code interval}
     * {@code frequency} units into a monthly equivalent.
     *
     * @param amount    amount per occurrence
     * @param frequency repeat unit
     * @param interval  units between occurrences, at least 1
     * @return the monthly equivalent
     */
    public static MonthlyEstimate of(Money amount, Frequency frequency, int interval) {
        if (interval < 1) {
            throw new IllegalArgumentException("interval must be at least 1");
        }
        int numerator = frequency.occurrencesPerYear();
        long denominator = 12L * interval;
        return new MonthlyEstimate(
                new Money(Rounding.scaleHalfUp(amount.minor(), numerator, denominator), amount.currency()),
                numerator + "/" + denominator, numerator != denominator);
    }
}
