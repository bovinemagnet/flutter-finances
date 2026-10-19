package com.paulsnow.finance.core.money;

/**
 * Thrown when text is not a plain decimal amount or has more fractional
 * digits than the currency allows (fixture error {@code FORMAT}).
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public class MoneyFormatException extends IllegalArgumentException {

    private static final long serialVersionUID = 1L;

    public MoneyFormatException(String message) {
        super(message);
    }
}
