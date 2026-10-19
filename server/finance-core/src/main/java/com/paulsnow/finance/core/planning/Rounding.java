package com.paulsnow.finance.core.planning;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.math.RoundingMode;

/**
 * Exact rational scaling of minor-unit amounts.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public final class Rounding {

    private Rounding() {
    }

    /**
     * Computes {@code value × numerator ÷ denominator} exactly and rounds half
     * away from zero ({@link RoundingMode#HALF_UP}). The product is formed
     * with {@link BigInteger}, so large amounts multiplied by basis points or
     * annual factors cannot overflow before division.
     *
     * @param value       amount in minor units
     * @param numerator   multiplier
     * @param denominator positive divisor
     * @return the rounded result
     * @throws IllegalArgumentException when {@code denominator} is not positive
     * @throws ArithmeticException      when the result does not fit in a long
     */
    public static long scaleHalfUp(long value, long numerator, long denominator) {
        if (denominator <= 0) {
            throw new IllegalArgumentException("denominator must be positive");
        }
        BigInteger product = BigInteger.valueOf(value).multiply(BigInteger.valueOf(numerator));
        return new BigDecimal(product).divide(BigDecimal.valueOf(denominator), 0, RoundingMode.HALF_UP)
                .longValueExact();
    }
}
