package com.paulsnow.finance.core.imports;

import static org.assertj.core.api.Assertions.assertThat;

import java.time.LocalDate;

import org.junit.jupiter.api.Test;

import com.paulsnow.finance.core.imports.CsvStatementParser.CsvError;
import com.paulsnow.finance.core.imports.CsvStatementParser.CsvResult;
import com.paulsnow.finance.core.imports.CsvStatementParser.CsvRow;

/**
 * CSV statement parsing (IMP 01): mappings, quoting, sign conventions and
 * row-level errors.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
class CsvStatementParserTest {

    private static final CsvMapping SIGNED = CsvMapping.builder()
            .dateColumn("Date").descriptionColumn("Description").amountColumn("Amount").build();

    @Test
    void parsesASignedAmountStatementWithHeader() {
        CsvResult result = CsvStatementParser.parse("""
                Date,Description,Amount
                01/07/2026,Grocer,-63.25
                03/07/2026,Salary,"3,123.45"
                """, SIGNED);
        assertThat(result.errors()).isEmpty();
        assertThat(result.rows()).containsExactly(
                new CsvRow(2, LocalDate.of(2026, 7, 1), "Grocer", -6325, "AUD", null, "01/07/2026,Grocer,-63.25"),
                new CsvRow(3, LocalDate.of(2026, 7, 3), "Salary", 312345, "AUD", null,
                        "03/07/2026,Salary,\"3,123.45\""));
    }

    @Test
    void handlesQuotesEmbeddedDelimitersNewlinesBomAndBlankLines() {
        CsvResult result = CsvStatementParser.parse("﻿Date,Description,Amount\r\n"
                + "01/07/2026,\"Cafe, \"\"The Bean\"\"\",-4.50\r\n"
                + "\r\n"
                + "02/07/2026,\"Two\nlines\",-1.00\r\n", SIGNED);
        assertThat(result.errors()).isEmpty();
        assertThat(result.rows()).extracting(CsvRow::description)
                .containsExactly("Cafe, \"The Bean\"", "Two\nlines");
        assertThat(result.rows()).extracting(CsvRow::rowNumber).containsExactly(2, 4);
    }

    @Test
    void readsDebitAndCreditColumnsAsOutflowAndInflow() {
        CsvMapping mapping = CsvMapping.builder().dateColumn("Date").descriptionColumn("Narrative")
                .debitColumn("Debit").creditColumn("Credit").referenceColumn("Ref").build();
        CsvResult result = CsvStatementParser.parse("""
                Date,Narrative,Debit,Credit,Ref
                01/07/2026,Card purchase,120.00,,A1
                02/07/2026,Refund,,40.00,A2
                03/07/2026,Both,1.00,2.00,A3
                04/07/2026,Neither,,,A4
                """, mapping);
        assertThat(result.rows()).extracting(CsvRow::amountMinor).containsExactly(-12000L, 4000L);
        assertThat(result.rows()).extracting(CsvRow::reference).containsExactly("A1", "A2");
        assertThat(result.errors()).extracting(CsvError::rowNumber, CsvError::code)
                .containsExactly(org.assertj.core.groups.Tuple.tuple(4, "AMOUNT_FORMAT"),
                        org.assertj.core.groups.Tuple.tuple(5, "MISSING_FIELD"));
    }

    @Test
    void appliesThePositiveIsOutflowConventionAndCommaDecimals() {
        CsvMapping mapping = CsvMapping.builder().delimiter(';').hasHeader(false).dateColumn("0")
                .descriptionColumn("1").amountColumn("2").signConvention(CsvMapping.SignConvention.POSITIVE_IS_OUTFLOW)
                .decimalSeparator(',').dateFormat("yyyy-MM-dd").build();
        CsvResult result = CsvStatementParser.parse("2026-07-01;Rent;1.234,50\n2026-07-02;Refund;-10,00\n", mapping);
        assertThat(result.errors()).isEmpty();
        assertThat(result.rows()).extracting(CsvRow::amountMinor).containsExactly(-123450L, 1000L);
        assertThat(result.rows()).extracting(CsvRow::rowNumber).containsExactly(1, 2);
    }

    @Test
    void reportsRowLevelErrorsWithoutDroppingGoodRows() {
        CsvResult result = CsvStatementParser.parse("""
                Date,Description,Amount
                31/02/2026,Bad date,-1.00
                01/07/2026,Bad amount,12a.00
                01/07/2026,Too precise,1.005
                01/07/2026,,-1.00
                01/07/2026,Zero,0.00
                01/07/2026,Short
                01/07/2026,Good,($5.00)
                """, SIGNED);
        assertThat(result.errors()).extracting(CsvError::code)
                .containsExactly("DATE_FORMAT", "AMOUNT_FORMAT", "AMOUNT_FORMAT", "MISSING_FIELD", "ZERO_AMOUNT",
                        "COLUMN_COUNT");
        assertThat(result.errors().getFirst().raw()).isEqualTo("31/02/2026,Bad date,-1.00");
        assertThat(result.rows()).singleElement().satisfies(row -> {
            assertThat(row.description()).isEqualTo("Good");
            assertThat(row.amountMinor()).isEqualTo(-500);
        });
    }

    @Test
    void rejectsOtherCurrenciesAndOutOfRangeAmounts() {
        CsvMapping mapping = CsvMapping.builder().dateColumn("Date").descriptionColumn("Description")
                .amountColumn("Amount").currencyColumn("Currency").build();
        CsvResult result = CsvStatementParser.parse("""
                Date,Description,Amount,Currency
                01/07/2026,Local,-1.00,AUD
                01/07/2026,Overseas,-1.00,NZD
                01/07/2026,Huge,-10000000000000.00,AUD
                """, mapping);
        assertThat(result.rows()).extracting(CsvRow::description).containsExactly("Local");
        assertThat(result.errors()).extracting(CsvError::code).containsExactly("CURRENCY_MISMATCH", "OUT_OF_RANGE");
    }

    @Test
    void reportsAMappedColumnMissingFromTheHeader() {
        CsvResult result = CsvStatementParser.parse("When,What,HowMuch\n01/07/2026,x,-1.00\n", SIGNED);
        assertThat(result.rows()).isEmpty();
        assertThat(result.errors()).singleElement().satisfies(error -> {
            assertThat(error.code()).isEqualTo("UNKNOWN_COLUMN");
            assertThat(error.column()).isEqualTo("Date");
            assertThat(error.rowNumber()).isEqualTo(1);
        });
    }

    @Test
    void reportsAnUnterminatedQuote() {
        CsvResult result = CsvStatementParser.parse("Date,Description,Amount\n01/07/2026,\"open,-1.00\n", SIGNED);
        assertThat(result.rows()).isEmpty();
        assertThat(result.errors()).extracting(CsvError::code).containsExactly("UNTERMINATED_QUOTE");
    }
}
