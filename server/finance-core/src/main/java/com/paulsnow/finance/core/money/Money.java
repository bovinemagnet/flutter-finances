package com.paulsnow.finance.core.money;

import java.util.List;
import java.util.Objects;
import java.util.regex.Pattern;

/**
 * An exact amount of money held as signed minor units. Never binary floating
 * point.
 *
 * @param minor    signed amount in minor units, within {@link #MAX_MINOR_MAGNITUDE}
 * @param currency the currency and its exponent
 * @author Paul Snow
 * @since 0.0.0
 */
public record Money(long minor, CurrencyUnit currency) implements Comparable<Money> {

    /**
     * Largest supported magnitude in minor units (just under one
     * quadrillion). Keeping amounts well inside the signed 64-bit range means
     * sums of many postings cannot overflow before range validation catches
     * them.
     */
    public static final long MAX_MINOR_MAGNITUDE = 999_999_999_999_999L;

    private static final Pattern DIGITS = Pattern.compile("\\d+");

    public Money {
        Objects.requireNonNull(currency, "currency");
        checkMinorRange(minor);
    }

    /**
     * Returns zero in {@code currency}.
     *
     * @param currency the currency
     * @return a zero amount
     */
    public static Money zero(CurrencyUnit currency) {
        return new Money(0, currency);
    }

    /**
     * Parses plain decimal text such as {@code -1,234.50} without rounding,
     * using {@code .} as the decimal separator.
     *
     * @param text     decimal text
     * @param currency currency supplying the exponent
     * @return the parsed amount
     */
    public static Money parse(String text, CurrencyUnit currency) {
        return new Money(parseMinor(text, currency.exponent(), '.'), currency);
    }

    /**
     * Parses decimal text to minor units for a currency {@code exponent}.
     * The other of {@code .} and {@code ,} is treated as a grouping
     * separator and ignored, as are spaces. Text with more fractional digits
     * than the exponent is rejected rather than rounded.
     *
     * @param text             decimal text
     * @param exponent         currency exponent
     * @param decimalSeparator {@code .} or {@code ,}
     * @return signed minor units
     * @throws MoneyFormatException for malformed text or excess precision
     * @throws MoneyRangeException  beyond {@link #MAX_MINOR_MAGNITUDE}
     */
    public static long parseMinor(String text, int exponent, char decimalSeparator) {
        String grouping = decimalSeparator == '.' ? "," : ".";
        String cleaned = text.strip().replace(grouping, "").replace(" ", "");
        boolean negative = false;
        if (cleaned.startsWith("-")) {
            negative = true;
            cleaned = cleaned.substring(1);
        } else if (cleaned.startsWith("+")) {
            cleaned = cleaned.substring(1);
        }
        List<String> parts = split(cleaned, decimalSeparator);
        String whole = parts.getFirst().isEmpty() ? "0" : parts.getFirst();
        if (parts.size() > 2 || !DIGITS.matcher(whole).matches()
                || (parts.size() == 2 && !DIGITS.matcher(parts.get(1)).matches())) {
            throw new MoneyFormatException("Not a decimal amount");
        }
        String fraction = parts.size() == 2 ? parts.get(1) : "";
        if (fraction.length() > exponent) {
            throw new MoneyFormatException("More than " + exponent + " decimal places");
        }
        if (whole.length() > 16) {
            throw new MoneyFormatException("Amount too large");
        }
        long minor;
        try {
            long scaledWhole = Math.multiplyExact(Long.parseLong(whole), pow10(exponent));
            long fractional = fraction.isEmpty() ? 0 : Long.parseLong(padRight(fraction, exponent));
            minor = Math.addExact(scaledWhole, fractional);
        } catch (ArithmeticException e) {
            throw new MoneyRangeException();
        }
        long signed = negative ? -minor : minor;
        checkMinorRange(signed);
        return signed;
    }

    /**
     * Formats minor units as plain decimal text, for example {@code -103.47}.
     *
     * @param minor    signed minor units
     * @param exponent currency exponent
     * @return decimal text
     */
    public static String formatMinor(long minor, int exponent) {
        String sign = minor < 0 ? "-" : "";
        String digits = Long.toString(Math.abs(minor));
        while (digits.length() < exponent + 1) {
            digits = "0" + digits;
        }
        if (exponent == 0) {
            return sign + digits;
        }
        int cut = digits.length() - exponent;
        return sign + digits.substring(0, cut) + "." + digits.substring(cut);
    }

    /**
     * Throws when {@code minor} is outside the supported magnitude.
     *
     * @param minor signed minor units
     * @throws MoneyRangeException when out of range
     */
    public static void checkMinorRange(long minor) {
        if (minor > MAX_MINOR_MAGNITUDE || minor < -MAX_MINOR_MAGNITUDE) {
            throw new MoneyRangeException();
        }
    }

    /** Returns whether {@code minor} is within the supported magnitude. */
    public static boolean inRange(long minor) {
        return minor <= MAX_MINOR_MAGNITUDE && minor >= -MAX_MINOR_MAGNITUDE;
    }

    public boolean isZero() {
        return minor == 0;
    }

    public boolean isPositive() {
        return minor > 0;
    }

    public boolean isNegative() {
        return minor < 0;
    }

    public Money plus(Money other) {
        checkCurrency(other);
        return new Money(minor + other.minor, currency);
    }

    public Money minus(Money other) {
        checkCurrency(other);
        return new Money(minor - other.minor, currency);
    }

    public Money negate() {
        return new Money(-minor, currency);
    }

    public Money abs() {
        return isNegative() ? negate() : this;
    }

    /**
     * Splits this amount across {@code weights} exactly.
     *
     * @param weights non-negative weights
     * @return parts summing to this amount
     * @see Allocation#byWeights(long, List)
     */
    public List<Money> allocate(List<Long> weights) {
        return Allocation.byWeights(minor, weights).stream().map(part -> new Money(part, currency)).toList();
    }

    public String toDecimalString() {
        return formatMinor(minor, currency.exponent());
    }

    @Override
    public int compareTo(Money other) {
        checkCurrency(other);
        return Long.compare(minor, other.minor);
    }

    @Override
    public String toString() {
        return toDecimalString() + " " + currency;
    }

    private void checkCurrency(Money other) {
        if (!other.currency.equals(currency)) {
            throw new IllegalArgumentException("Currency mismatch: " + currency + " and " + other.currency);
        }
    }

    private static List<String> split(String text, char separator) {
        // Mirrors Dart's String.split: keeps empty leading and trailing parts.
        return List.of(text.split(Pattern.quote(String.valueOf(separator)), -1));
    }

    private static String padRight(String text, int length) {
        StringBuilder builder = new StringBuilder(text);
        while (builder.length() < length) {
            builder.append('0');
        }
        return builder.toString();
    }

    private static long pow10(int exponent) {
        long value = 1;
        for (int i = 0; i < exponent; i++) {
            value *= 10;
        }
        return value;
    }
}
