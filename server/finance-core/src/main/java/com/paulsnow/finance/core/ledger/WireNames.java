package com.paulsnow.finance.core.ledger;

import java.util.function.Function;

/**
 * Looks up enum constants by their camelCase wire names.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
final class WireNames {

    private WireNames() {
    }

    static <E extends Enum<E>> E lookup(Class<E> type, String wire, Function<E, String> name) {
        for (E constant : type.getEnumConstants()) {
            if (name.apply(constant).equals(wire)) {
                return constant;
            }
        }
        throw new IllegalArgumentException("Unknown " + type.getSimpleName() + " '" + wire + "'");
    }

    /** Converts {@code CREDIT_CARD} to {@code creditCard}. */
    static String camel(Enum<?> constant) {
        String[] words = constant.name().toLowerCase(java.util.Locale.ROOT).split("_");
        StringBuilder builder = new StringBuilder(words[0]);
        for (int i = 1; i < words.length; i++) {
            builder.append(Character.toUpperCase(words[i].charAt(0))).append(words[i].substring(1));
        }
        return builder.toString();
    }
}
