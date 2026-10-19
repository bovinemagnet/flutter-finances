package com.paulsnow.finance.server.reports;

import java.time.LocalDate;
import java.time.format.DateTimeParseException;
import java.util.stream.Stream;

import com.paulsnow.finance.core.reports.DateRange;
import com.paulsnow.finance.server.common.ApiException;

/**
 * Query parameters of {@code GET /v1/reports/{kind}}, validated. A ranged
 * report takes exactly one of {@code from} and {@code to} together,
 * {@code financialYear} (the Australian year starting 1 July of that year)
 * or {@code calendarYear}; {@code account-balances} takes only an optional
 * {@code asOf}.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
final class ReportRequest {

    /** The longest range a report may cover. */
    static final int MAX_YEARS = 100;

    private static final int MIN_YEAR = 1900;
    private static final int MAX_YEAR = 2200;

    private ReportRequest() {
    }

    /**
     * Resolves the date range of a ranged report.
     *
     * @return the range
     * @throws ApiException 400 {@code INVALID_PERIOD}
     */
    static DateRange range(String from, String to, String financialYear, String calendarYear, String asOf) {
        if (present(asOf)) {
            throw invalid("asOf applies to account-balances only.");
        }
        int forms = (present(from) || present(to) ? 1 : 0) + (present(financialYear) ? 1 : 0)
                + (present(calendarYear) ? 1 : 0);
        if (forms != 1) {
            throw invalid("Send from and to, financialYear or calendarYear.");
        }
        DateRange range;
        if (present(financialYear)) {
            range = DateRange.financialYear(year(financialYear));
        } else if (present(calendarYear)) {
            range = DateRange.calendarYear(year(calendarYear));
        } else {
            if (!present(from) || !present(to)) {
                throw invalid("Send both from and to.");
            }
            LocalDate start = date(from);
            LocalDate end = date(to);
            if (end.isBefore(start)) {
                throw invalid("to is before from.");
            }
            range = new DateRange(start, end);
        }
        if (range.end().isAfter(range.start().plusYears(MAX_YEARS))) {
            throw invalid("A report covers at most " + MAX_YEARS + " years.");
        }
        return range;
    }

    /**
     * Resolves the point in time of {@code account-balances}.
     *
     * @return the date, or null for all time
     * @throws ApiException 400 {@code INVALID_PERIOD} when a range is sent instead
     */
    static LocalDate asOf(String from, String to, String financialYear, String calendarYear, String asOf) {
        if (Stream.of(from, to, financialYear, calendarYear).anyMatch(ReportRequest::present)) {
            throw invalid("account-balances takes asOf, not a range.");
        }
        return present(asOf) ? date(asOf) : null;
    }

    private static boolean present(String value) {
        return value != null && !value.isBlank();
    }

    private static int year(String value) {
        try {
            int year = Integer.parseInt(value.strip());
            if (year >= MIN_YEAR && year <= MAX_YEAR) {
                return year;
            }
        } catch (NumberFormatException e) {
            // Reported below.
        }
        throw invalid("A year is four digits between " + MIN_YEAR + " and " + MAX_YEAR + ".");
    }

    private static LocalDate date(String value) {
        try {
            LocalDate date = LocalDate.parse(value.strip());
            if (date.getYear() >= MIN_YEAR && date.getYear() <= MAX_YEAR) {
                return date;
            }
        } catch (DateTimeParseException e) {
            // Reported below.
        }
        throw invalid("Dates are YYYY-MM-DD between " + MIN_YEAR + " and " + MAX_YEAR + ".");
    }

    private static ApiException invalid(String message) {
        return ApiException.badRequest("INVALID_PERIOD", message);
    }
}
