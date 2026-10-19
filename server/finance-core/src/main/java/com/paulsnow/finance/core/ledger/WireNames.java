package com.paulsnow.finance.core.ledger;

import java.util.function.Function;

/**
 * Looks up enum constants by their camelCase wire names. Shared by the
 * ledger and planning packages so every enum uses the same JSON spelling.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public final class WireNames {

    private WireNames() {
    }

    /**
     * Resolves {@code wire} to the constant whose wire name matches.
     *
     * @param type enum class
     * @param wire wire name
     * @param name maps a constant to its wire name
     * @param <E>  enum type
     * @return the constant
     * @throws IllegalArgumentException when no constant matches
     */
    public static <E extends Enum<E>> E lookup(Class<E> type, String wire, Function<E, String> name) {
        for (E constant : type.getEnumConstants()) {
            if (name.apply(constant).equals(wire)) {
                return constant;
            }
        }
        throw new IllegalArgumentException("Unknown " + type.getSimpleName() + " '" + wire + "'");
    }

    /**
     * Converts {@code CREDIT_CARD} to {@code creditCard}.
     *
     * @param constant enum constant
     * @return the camelCase wire name
     */
    public static String camel(Enum<?> constant) {
        String[] words = constant.name().toLowerCase(java.util.Locale.ROOT).split("_");
        StringBuilder builder = new StringBuilder(words[0]);
        for (int i = 1; i < words.length; i++) {
            builder.append(Character.toUpperCase(words[i].charAt(0))).append(words[i].substring(1));
        }
        return builder.toString();
    }
}
