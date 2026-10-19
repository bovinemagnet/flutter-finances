package com.paulsnow.finance.core.planning;

import java.time.LocalDate;
import java.util.Objects;

import com.paulsnow.finance.core.money.Money;

/**
 * One signed cash movement on one eligible account.
 *
 * @param date        when it applies
 * @param accountId   the eligible account
 * @param amount      positive adds cash, negative removes it
 * @param certainty   how certain the line is
 * @param source      where the line came from
 * @param sourceId    journal id, occurrence key ({@code scheduleId@originalDate}),
 *                    reservation id or scenario change id
 * @param description description, or null
 * @author Paul Snow
 * @since 0.0.0
 */
public record ForecastLine(LocalDate date, String accountId, Money amount, ForecastCertainty certainty,
        ForecastSource source, String sourceId, String description) {

    public ForecastLine {
        Objects.requireNonNull(date, "date");
        Objects.requireNonNull(accountId, "accountId");
        Objects.requireNonNull(amount, "amount");
        Objects.requireNonNull(certainty, "certainty");
        Objects.requireNonNull(source, "source");
        Objects.requireNonNull(sourceId, "sourceId");
    }
}
