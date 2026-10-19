package com.paulsnow.finance.core.planning;

import java.time.LocalDate;
import java.util.List;
import java.util.Objects;

import com.paulsnow.finance.core.money.Money;

/**
 * One projected day: opening and closing totals across eligible accounts.
 *
 * @param date    the day
 * @param opening the previous day's closing, or the forecast opening balance
 * @param lines   the day's movements
 * @param closing {@code opening} plus every line
 * @author Paul Snow
 * @since 0.0.0
 */
public record ForecastDay(LocalDate date, Money opening, List<ForecastLine> lines, Money closing) {

    public ForecastDay {
        Objects.requireNonNull(date, "date");
        Objects.requireNonNull(opening, "opening");
        Objects.requireNonNull(closing, "closing");
        lines = List.copyOf(lines);
    }

    /**
     * Creates a day whose closing is {@code opening} plus every line.
     *
     * @param date    the day
     * @param opening the opening total
     * @param lines   the day's movements
     * @return the day
     */
    public static ForecastDay of(LocalDate date, Money opening, List<ForecastLine> lines) {
        Money closing = opening;
        for (ForecastLine line : lines) {
            closing = closing.plus(line.amount());
        }
        return new ForecastDay(date, opening, lines, closing);
    }
}
