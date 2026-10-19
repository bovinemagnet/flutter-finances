package com.paulsnow.finance.core.ledger;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.Random;

import org.junit.jupiter.api.RepeatedTest;
import org.junit.jupiter.api.Test;

import com.paulsnow.finance.core.money.Allocation;
import com.paulsnow.finance.core.money.CurrencyUnit;
import com.paulsnow.finance.core.money.Money;
import com.paulsnow.finance.core.money.MoneyRangeException;

/**
 * Randomised checks that every journal the factory builds balances, that
 * allocation is exact, and that corrections cancel the original.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
class LedgerPropertiesTest {

    private static final CurrencyUnit AUD = CurrencyUnit.AUD;

    private final Random random = new Random();

    private final Chart chart = new Chart(AUD,
            List.of(Account.builder("bank", "Bank", AccountType.TRANSACTION).build(),
                    Account.builder("card", "Card", AccountType.CREDIT_CARD).build()),
            List.of(new Category("groceries", "Groceries", CategoryKind.EXPENSE, null, false),
                    new Category("dining", "Dining", CategoryKind.EXPENSE, null, false),
                    new Category("salary", "Salary", CategoryKind.INCOME, null, false)));

    @RepeatedTest(200)
    void allocationAlwaysSumsToTotal() {
        long total = random.nextLong(-Money.MAX_MINOR_MAGNITUDE, Money.MAX_MINOR_MAGNITUDE);
        List<Long> weights = new ArrayList<>();
        int count = 1 + random.nextInt(8);
        for (int i = 0; i < count; i++) {
            weights.add((long) random.nextInt(10_000));
        }
        weights.set(0, weights.getFirst() + 1);
        List<Long> parts = Allocation.byWeights(total, weights);
        assertThat(parts.stream().mapToLong(Long::longValue).sum()).isEqualTo(total);
        assertThat(parts).hasSize(count);
    }

    @RepeatedTest(200)
    void builtJournalsAlwaysBalance() {
        long first = 1 + random.nextLong(1_000_000);
        long second = 1 + random.nextLong(1_000_000);
        Money amount = new Money(first + second, AUD);
        JournalFactory factory = new JournalFactory(chart);
        TransactionType type = List.of(TransactionType.EXPENSE, TransactionType.REFUND, TransactionType.TRANSFER,
                TransactionType.REIMBURSABLE_EXPENSE).get(random.nextInt(4));
        TransactionDraft draft = TransactionDraft.builder(type, "bank", amount, LocalDate.of(2026, 7, 1))
                .counterAccountId("card")
                .splits(List.of(new Split("groceries", new Money(first, AUD)),
                        new Split("dining", new Money(second, AUD))))
                .build();
        Journal journal = factory.build(draft);
        assertThat(JournalValidator.validate(journal.postings())).isEmpty();

        CorrectionResult correction = Corrections.correct(journal, null);
        assertThat(Corrections.isExactReversal(journal, correction.reversal())).isTrue();
        LedgerProjection ledger = new LedgerProjection(chart, correction.journals());
        assertThat(ledger.displayBalance("bank", false)).isEqualTo(Money.zero(AUD));
    }

    @Test
    void reversalWithDifferentAmountIsNotExact() {
        Journal journal = new JournalFactory(chart).build(TransactionDraft
                .builder(TransactionType.EXPENSE, "bank", new Money(1000, AUD), LocalDate.of(2026, 7, 1))
                .splits(List.of(new Split("groceries", new Money(1000, AUD)))).build());
        Journal reversal = Corrections.reverse(journal, journal.enteredAt());
        Journal wrong = new Journal(reversal.id(), reversal.type(), reversal.status(), reversal.effectiveDate(),
                reversal.enteredAt(), AUD, List.of(new Posting("groceries", -999, "AUD"),
                        new Posting("bank", 999, "AUD")),
                null, null, null, null, null, null, null, journal.id(), null);
        assertThat(Corrections.isExactReversal(journal, wrong)).isFalse();
    }

    @Test
    void parsingRejectsOverflowingTextAsOutOfRange() {
        assertThatThrownBy(() -> Money.parseMinor("9999999999999999", 4, '.'))
                .isInstanceOf(MoneyRangeException.class);
    }
}
