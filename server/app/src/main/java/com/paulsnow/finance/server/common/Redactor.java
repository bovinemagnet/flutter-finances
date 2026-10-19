package com.paulsnow.finance.server.common;

import java.util.List;
import java.util.regex.Pattern;

/**
 * Masks sensitive values in operational log text: bearer tokens and JWTs,
 * signed URL credentials, account or card numbers, money amounts, e-mail
 * addresses and database key details (which can echo user data).
 * <p>
 * This is a safety net. Code must still never pass merchants, amounts,
 * document contents, tokens or account numbers to a logger; pattern matching
 * cannot recognise a merchant name.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public final class Redactor {

    private record Rule(Pattern pattern, String replacement) {
    }

    private static final List<Rule> RULES = List.of(
            new Rule(Pattern.compile("(?i)bearer\\s+[A-Za-z0-9._~+/=-]+"), "Bearer [REDACTED]"),
            new Rule(Pattern.compile("eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]*"), "[REDACTED_TOKEN]"),
            new Rule(Pattern.compile("(?i)(X-Amz-(?:Signature|Credential|Security-Token))=[^&\\s\"']+"),
                    "$1=[REDACTED]"),
            new Rule(Pattern.compile("Key \\(([^)]*)\\)=\\([^)]*\\)"), "Key ($1)=([REDACTED])"),
            new Rule(Pattern.compile("[\\w.+-]+@[\\w-]+\\.[\\w.-]+"), "[REDACTED_EMAIL]"),
            new Rule(Pattern.compile("(?<![\\w.])-?\\$?\\d{1,3}(?:,\\d{3})+(?:\\.\\d{1,4})?(?![\\w.])"),
                    "[REDACTED_AMOUNT]"),
            new Rule(Pattern.compile("(?<![\\w.])-?\\$?\\d+[.,]\\d{2}(?![\\w.])"), "[REDACTED_AMOUNT]"),
            new Rule(Pattern.compile("(?<![0-9A-Fa-f-])\\d{6,}(?![0-9A-Fa-f-])"), "[REDACTED_NUMBER]"));

    private Redactor() {
    }

    /**
     * Returns {@code text} with sensitive values masked.
     *
     * @param text log text, possibly null
     * @return redacted text
     */
    public static String redact(String text) {
        if (text == null || text.isEmpty()) {
            return text;
        }
        String result = text;
        for (Rule rule : RULES) {
            result = rule.pattern().matcher(result).replaceAll(rule.replacement());
        }
        return result;
    }
}
