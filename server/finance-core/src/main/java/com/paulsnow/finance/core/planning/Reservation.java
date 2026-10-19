package com.paulsnow.finance.core.planning;

import java.util.Objects;

import com.paulsnow.finance.core.money.Money;

/**
 * Money held in an account and set aside for a goal or sinking fund
 * (BUD 05). Only confirmed reservations reserve anything; unconfirmed ones
 * are proposals.
 *
 * @param id        identifier
 * @param goalId    the goal or sinking fund
 * @param accountId the account holding the money
 * @param amount    amount reserved
 * @param confirmed whether the reservation is confirmed
 * @author Paul Snow
 * @since 0.0.0
 */
public record Reservation(String id, String goalId, String accountId, Money amount, boolean confirmed) {

    public Reservation {
        Objects.requireNonNull(id, "id");
        Objects.requireNonNull(accountId, "accountId");
        Objects.requireNonNull(amount, "amount");
    }
}
