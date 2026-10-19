package com.paulsnow.finance.core.planning;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;

import com.paulsnow.finance.core.money.Money;

/**
 * Group amounts from a template plus the money left unassigned (BUD 01).
 *
 * @param amounts    amount per group identifier, in template order
 * @param unassigned income less every group amount; negative when shares exceed 100%
 * @author Paul Snow
 * @since 0.0.0
 */
public record TemplateAllocation(Map<String, Money> amounts, Money unassigned) {

    public TemplateAllocation {
        amounts = Collections.unmodifiableMap(new LinkedHashMap<>(amounts));
        Objects.requireNonNull(unassigned, "unassigned");
    }

    /**
     * Splits take-home {@code income} across {@code groups} by basis points.
     * <p>
     * The groups together receive {@code income × Σshares ÷ 10000}, rounded
     * half away from zero; that total is then split with the largest
     * remainder method, so the amounts are exact and a 100% template uses
     * every cent. All amounts are zero when the shares total zero.
     *
     * @param income take-home income per period
     * @param groups groups with their shares
     * @return the allocation
     */
    public static TemplateAllocation allocate(Money income, List<TemplateGroup> groups) {
        List<Long> shares = new ArrayList<>(groups.size());
        long shareTotal = 0;
        for (TemplateGroup group : groups) {
            shares.add((long) group.shareBasisPoints());
            shareTotal += group.shareBasisPoints();
        }
        long groupTotal = Rounding.scaleHalfUp(income.minor(), shareTotal, TemplateGroup.FULL_SHARE_BASIS_POINTS);
        Money total = new Money(groupTotal, income.currency());
        List<Money> parts = shareTotal == 0
                ? Collections.nCopies(groups.size(), Money.zero(income.currency()))
                : total.allocate(shares);
        Map<String, Money> amounts = new LinkedHashMap<>();
        for (int i = 0; i < groups.size(); i++) {
            amounts.put(groups.get(i).id(), parts.get(i));
        }
        return new TemplateAllocation(amounts, income.minus(total));
    }
}
