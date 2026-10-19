package com.paulsnow.finance.core.money;

import java.math.BigInteger;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.stream.IntStream;

/**
 * Exact proportional allocation of an integer amount.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public final class Allocation {

    private Allocation() {
    }

    /**
     * Splits {@code total} in proportion to non-negative integer
     * {@code weights} exactly, using the largest remainder method on the
     * magnitude: each part receives the floor of its share, then the leftover
     * units go to the largest fractional remainders, ties going to the lower
     * index. The sign of {@code total} is reapplied afterwards, so the parts
     * always sum to {@code total}.
     *
     * @param total   amount in minor units
     * @param weights non-negative weights, not all zero
     * @return one part per weight
     */
    public static List<Long> byWeights(long total, List<Long> weights) {
        if (weights.isEmpty() || weights.stream().anyMatch(w -> w < 0)) {
            throw new IllegalArgumentException("Weights must be non-negative");
        }
        BigInteger sum = weights.stream().map(BigInteger::valueOf).reduce(BigInteger.ZERO, BigInteger::add);
        if (sum.signum() == 0) {
            throw new IllegalArgumentException("Weights must not all be zero");
        }
        BigInteger magnitude = BigInteger.valueOf(total).abs();
        List<Long> parts = new ArrayList<>(weights.size());
        List<BigInteger> remainders = new ArrayList<>(weights.size());
        for (long weight : weights) {
            BigInteger[] division = magnitude.multiply(BigInteger.valueOf(weight)).divideAndRemainder(sum);
            parts.add(division[0].longValueExact());
            remainders.add(division[1]);
        }
        long leftover = magnitude.longValueExact() - parts.stream().mapToLong(Long::longValue).sum();
        List<Integer> order = IntStream.range(0, weights.size()).boxed()
                .sorted(Comparator.<Integer, BigInteger>comparing(remainders::get).reversed()
                        .thenComparing(Comparator.naturalOrder()))
                .toList();
        for (int index : order) {
            if (leftover == 0) {
                break;
            }
            parts.set(index, parts.get(index) + 1);
            leftover--;
        }
        return total < 0 ? parts.stream().map(p -> -p).toList() : List.copyOf(parts);
    }
}
