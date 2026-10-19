package com.paulsnow.finance.core.imports;

/**
 * How the columns of a bank's CSV statement map onto a transaction (IMP 01).
 * A mapping is saved as a template and reused for later statements.
 * <p>
 * Columns are named by their header text (matched ignoring case and
 * surrounding spaces) when {@code hasHeader} is true, otherwise by their
 * zero-based position, for example {@code "0"}. Either {@code amountColumn}
 * (a signed amount) or {@code debitColumn} and {@code creditColumn} (two
 * unsigned amounts) must be given.
 *
 * @param delimiter         field separator, usually {@code ,} or {@code ;}
 * @param hasHeader         whether the first record names the columns
 * @param dateColumn        transaction date column
 * @param dateFormat        {@link java.time.format.DateTimeFormatter} pattern, default {@code dd/MM/yyyy}
 * @param descriptionColumn description (narrative) column
 * @param amountColumn      signed amount column, or null when debit and credit columns are used
 * @param debitColumn       money-out column, or null
 * @param creditColumn      money-in column, or null
 * @param signConvention    meaning of the sign in {@code amountColumn}
 * @param decimalSeparator  {@code .} or {@code ,}; the other is a grouping separator
 * @param currencyColumn    optional currency code column; other currencies are rejected
 * @param referenceColumn   optional bank reference (provider identifier) column
 * @param currency          the workspace currency code
 * @param exponent          the workspace currency exponent
 * @author Paul Snow
 * @since 0.0.0
 */
public record CsvMapping(char delimiter, boolean hasHeader, String dateColumn, String dateFormat,
        String descriptionColumn, String amountColumn, String debitColumn, String creditColumn,
        SignConvention signConvention, char decimalSeparator, String currencyColumn, String referenceColumn,
        String currency, int exponent) {

    /**
     * What the sign of a single signed amount column means.
     *
     * @author Paul Snow
     * @since 0.0.0
     */
    public enum SignConvention {
        /** Negative amounts are money out (the usual bank export). */
        NEGATIVE_IS_OUTFLOW,
        /** Positive amounts are money out (common for credit card exports). */
        POSITIVE_IS_OUTFLOW
    }

    public CsvMapping {
        dateFormat = dateFormat == null || dateFormat.isBlank() ? "dd/MM/yyyy" : dateFormat;
        signConvention = signConvention == null ? SignConvention.NEGATIVE_IS_OUTFLOW : signConvention;
        currency = currency == null || currency.isBlank() ? "AUD" : currency;
    }

    /** Returns a builder with the Australian defaults: comma, header, dd/MM/yyyy, AUD. */
    public static Builder builder() {
        return new Builder();
    }

    /**
     * Builder for {@link CsvMapping}.
     *
     * @author Paul Snow
     * @since 0.0.0
     */
    public static final class Builder {
        private char delimiter = ',';
        private boolean hasHeader = true;
        private String dateColumn;
        private String dateFormat = "dd/MM/yyyy";
        private String descriptionColumn;
        private String amountColumn;
        private String debitColumn;
        private String creditColumn;
        private SignConvention signConvention = SignConvention.NEGATIVE_IS_OUTFLOW;
        private char decimalSeparator = '.';
        private String currencyColumn;
        private String referenceColumn;
        private String currency = "AUD";
        private int exponent = 2;

        private Builder() {
        }

        public Builder delimiter(char value) {
            this.delimiter = value;
            return this;
        }

        public Builder hasHeader(boolean value) {
            this.hasHeader = value;
            return this;
        }

        public Builder dateColumn(String value) {
            this.dateColumn = value;
            return this;
        }

        public Builder dateFormat(String value) {
            this.dateFormat = value;
            return this;
        }

        public Builder descriptionColumn(String value) {
            this.descriptionColumn = value;
            return this;
        }

        public Builder amountColumn(String value) {
            this.amountColumn = value;
            return this;
        }

        public Builder debitColumn(String value) {
            this.debitColumn = value;
            return this;
        }

        public Builder creditColumn(String value) {
            this.creditColumn = value;
            return this;
        }

        public Builder signConvention(SignConvention value) {
            this.signConvention = value;
            return this;
        }

        public Builder decimalSeparator(char value) {
            this.decimalSeparator = value;
            return this;
        }

        public Builder currencyColumn(String value) {
            this.currencyColumn = value;
            return this;
        }

        public Builder referenceColumn(String value) {
            this.referenceColumn = value;
            return this;
        }

        public Builder currency(String code, int currencyExponent) {
            this.currency = code;
            this.exponent = currencyExponent;
            return this;
        }

        public CsvMapping build() {
            return new CsvMapping(delimiter, hasHeader, dateColumn, dateFormat, descriptionColumn, amountColumn,
                    debitColumn, creditColumn, signConvention, decimalSeparator, currencyColumn, referenceColumn,
                    currency, exponent);
        }
    }
}
