package com.paulsnow.finance.server.extraction;

import java.util.ArrayList;
import java.util.List;

/**
 * What a provider may return: recognised text and its lines. There is
 * deliberately no field for amounts, merchants, dates or actions; any such
 * reading of the text is done on the client, deterministically and with the
 * user's confirmation.
 *
 * @param text  recognised text
 * @param lines recognised lines in reading order
 * @author Paul Snow
 * @since 0.0.0
 */
public record ExtractedText(String text, List<String> lines) {

    /** Longest stored text, in characters. */
    static final int MAX_TEXT = 20_000;

    /** Most stored lines. */
    static final int MAX_LINES = 500;

    /** Longest stored line, in characters. */
    static final int MAX_LINE = 500;

    public ExtractedText {
        text = text == null ? "" : text;
        lines = lines == null ? List.of() : lines.stream().map(l -> l == null ? "" : l).toList();
    }

    /**
     * Returns a copy safe to store and serve: control characters other than
     * line breaks and tabs are removed and sizes are bounded, because the
     * text comes from an untrusted document through an external service.
     *
     * @return the bounded, cleaned copy
     */
    ExtractedText sanitised() {
        List<String> cleanLines = new ArrayList<>();
        for (String line : lines) {
            if (cleanLines.size() == MAX_LINES) {
                break;
            }
            cleanLines.add(truncate(clean(line, false), MAX_LINE));
        }
        return new ExtractedText(truncate(clean(text, true), MAX_TEXT), cleanLines);
    }

    private static String clean(String value, boolean keepBreaks) {
        StringBuilder out = new StringBuilder(value.length());
        value.codePoints().filter(c -> !Character.isISOControl(c) || (keepBreaks && (c == '\n' || c == '\t')))
                .forEach(out::appendCodePoint);
        return out.toString().strip();
    }

    private static String truncate(String value, int max) {
        if (value.length() <= max) {
            return value;
        }
        int end = Character.isHighSurrogate(value.charAt(max - 1)) ? max - 1 : max;
        return value.substring(0, end);
    }
}
