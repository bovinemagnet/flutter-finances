package com.paulsnow.finance.core.ledger;

import java.time.LocalDate;
import java.util.Objects;

/**
 * A user's account (FIN 01). Its ledger account shares its identifier.
 *
 * @param id                identifier, also the ledger account identifier
 * @param name              display name
 * @param type              what the user calls the account
 * @param includeInBudget   whether spending from it counts towards budgets
 * @param includeInForecast whether it appears in cash forecasts
 * @param includeInNetWorth whether its balance counts towards net worth
 * @param archived          hidden from entry but retained for history
 * @param dataSource        {@code manual}, {@code import} and so on
 * @param lastReconciledOn  last statement date reconciled, or null
 * @author Paul Snow
 * @since 0.0.0
 */
public record Account(String id, String name, AccountType type, boolean includeInBudget, boolean includeInForecast,
        boolean includeInNetWorth, boolean archived, String dataSource, LocalDate lastReconciledOn) {

    public Account {
        Objects.requireNonNull(id, "id");
        Objects.requireNonNull(type, "type");
    }

    /**
     * Starts an account with the default flags: included everywhere, not
     * archived, manual data source.
     *
     * @param id   identifier
     * @param name display name
     * @param type account type
     * @return a builder
     */
    public static Builder builder(String id, String name, AccountType type) {
        return new Builder(id, name, type);
    }

    /**
     * Builder for {@link Account}.
     *
     * @author Paul Snow
     * @since 0.0.0
     */
    public static final class Builder {
        private final String id;
        private final String name;
        private final AccountType type;
        private boolean includeInBudget = true;
        private boolean includeInForecast = true;
        private boolean includeInNetWorth = true;
        private boolean archived;
        private String dataSource = "manual";
        private LocalDate lastReconciledOn;

        private Builder(String id, String name, AccountType type) {
            this.id = id;
            this.name = name;
            this.type = type;
        }

        public Builder includeInBudget(boolean value) {
            this.includeInBudget = value;
            return this;
        }

        public Builder includeInForecast(boolean value) {
            this.includeInForecast = value;
            return this;
        }

        public Builder includeInNetWorth(boolean value) {
            this.includeInNetWorth = value;
            return this;
        }

        public Builder archived(boolean value) {
            this.archived = value;
            return this;
        }

        public Builder dataSource(String value) {
            this.dataSource = value;
            return this;
        }

        public Builder lastReconciledOn(LocalDate value) {
            this.lastReconciledOn = value;
            return this;
        }

        public Account build() {
            return new Account(id, name, type, includeInBudget, includeInForecast, includeInNetWorth, archived,
                    dataSource, lastReconciledOn);
        }
    }
}
