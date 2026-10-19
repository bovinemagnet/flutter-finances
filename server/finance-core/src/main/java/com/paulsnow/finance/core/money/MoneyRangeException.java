package com.paulsnow.finance.core.money;

/**
 * Thrown when an amount exceeds {@link Money#MAX_MINOR_MAGNITUDE} (fixture
 * error {@code OUT_OF_RANGE}). The amount itself is deliberately not part of
 * the message so it cannot leak into logs.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public class MoneyRangeException extends ArithmeticException {

    private static final long serialVersionUID = 1L;

    public MoneyRangeException() {
        super("Amount is outside the supported range");
    }
}
