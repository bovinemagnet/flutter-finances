package com.paulsnow.finance.core.reports;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;

/**
 * An inclusive range of local dates for reports (REP 02), matching the
 * client's {@code DateRange}.
 *
 * @param start first date
 * @param end   last date, not before {@code start}
 * @author Paul Snow
 * @since 0.0.0
 */
public record DateRange(LocalDate start, LocalDate end) {

    public DateRange {
        Objects.requireNonNull(start, "start");
        Objects.requireNonNull(end, "end");
        if (end.isBefore(start)) {
            throw new IllegalArgumentException("Range ends before it starts");
        }
    }

    /**
     * 1 January to 31 December.
     *
     * @param year calendar year
     * @return the range
     */
    public static DateRange calendarYear(int year) {
        return new DateRange(LocalDate.of(year, 1, 1), LocalDate.of(year, 12, 31));
    }

    /**
     * The Australian financial year from 1 July {@code startYear} to 30 June
     * of the following year.
     *
     * @param startYear year in which the financial year starts
     * @return the range
     */
    public static DateRange financialYear(int startYear) {
        return new DateRange(LocalDate.of(startYear, 7, 1), LocalDate.of(startYear + 1, 6, 30));
    }

    /** Returns {@code FY2026-27} for an Australian financial year, otherwise {@code start..end}. */
    public String label() {
        if (start.getMonthValue() == 7 && start.getDayOfMonth() == 1
                && end.equals(LocalDate.of(start.getYear() + 1, 6, 30))) {
            return "FY" + start.getYear() + "-" + String.format("%02d", (start.getYear() + 1) % 100);
        }
        return start + ".." + end;
    }

    /**
     * Returns whether {@code date} lies inside the range.
     *
     * @param date local date
     * @return true when {@code start <= date <= end}
     */
    public boolean contains(LocalDate date) {
        return !date.isBefore(start) && !date.isAfter(end);
    }

    /** Calendar-month slices of this range, clipped to its ends. */
    public List<DateRange> months() {
        List<DateRange> result = new ArrayList<>();
        LocalDate sliceStart = start;
        while (!sliceStart.isAfter(end)) {
            LocalDate monthEnd = sliceStart.withDayOfMonth(sliceStart.lengthOfMonth());
            LocalDate sliceEnd = monthEnd.isBefore(end) ? monthEnd : end;
            result.add(new DateRange(sliceStart, sliceEnd));
            sliceStart = sliceEnd.plusDays(1);
        }
        return List.copyOf(result);
    }

    @Override
    public String toString() {
        return start + ".." + end;
    }
}
