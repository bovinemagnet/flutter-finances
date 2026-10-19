package com.paulsnow.finance.core.ledger;

import com.paulsnow.finance.core.money.Money;

/**
 * One category line of a categorised entry.
 *
 * @param categoryId category identifier
 * @param amount     positive amount for the category
 * @author Paul Snow
 * @since 0.0.0
 */
public record Split(String categoryId, Money amount) {
}
