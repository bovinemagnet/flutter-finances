package com.paulsnow.finance.core.money;

import java.util.Objects;

/**
 * An ISO 4217 currency code with an explicit minor-unit exponent.
 *
 * @param code     three-letter currency code, for example {@code AUD}
 * @param exponent number of minor-unit digits, between 0 and 4
 * @author Paul Snow
 * @since 0.0.0
 */
public record CurrencyUnit(String code, int exponent) {

    /** Australian dollars, the default workspace currency. */
    public static final CurrencyUnit AUD = new CurrencyUnit("AUD", 2);

    public CurrencyUnit {
        Objects.requireNonNull(code, "code");
        if (exponent < 0 || exponent > 4) {
            throw new IllegalArgumentException("Exponent must be between 0 and 4");
        }
    }

    /**
     * Returns the currency with the exponent ISO 4217 assigns to {@code code}.
     *
     * @param code three-letter currency code
     * @return the currency unit
     * @throws IllegalArgumentException when the code is unknown or has no minor units defined
     */
    public static CurrencyUnit of(String code) {
        java.util.Currency currency = java.util.Currency.getInstance(code);
        int digits = currency.getDefaultFractionDigits();
        if (digits < 0) {
            throw new IllegalArgumentException("Currency " + code + " has no minor units");
        }
        return new CurrencyUnit(currency.getCurrencyCode(), digits);
    }

    @Override
    public String toString() {
        return code;
    }
}
