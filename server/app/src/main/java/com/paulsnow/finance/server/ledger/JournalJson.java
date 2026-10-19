package com.paulsnow.finance.server.ledger;

import java.time.Instant;
import java.time.LocalDate;
import java.time.format.DateTimeParseException;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import java.util.regex.Pattern;

import com.paulsnow.finance.core.ledger.Journal;
import com.paulsnow.finance.core.ledger.JournalStatus;
import com.paulsnow.finance.core.ledger.Posting;
import com.paulsnow.finance.core.ledger.TransactionType;
import com.paulsnow.finance.core.money.CurrencyUnit;
import com.paulsnow.finance.core.money.Money;

import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.ArrayNode;
import tools.jackson.databind.node.JsonNodeFactory;
import tools.jackson.databind.node.ObjectNode;

/**
 * Reads and writes the Journal entity JSON of {@code spec/sync/protocol.md}.
 * Unknown additional fields are tolerated (NFR 12).
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public final class JournalJson {

    /** Upper bound on postings in one journal. */
    public static final int MAX_POSTINGS = 1000;

    private static final Pattern CURRENCY = Pattern.compile("[A-Z]{3}");

    private JournalJson() {
    }

    /**
     * The outcome of reading a journal.
     *
     * @param journal          the journal, or null when the JSON is malformed
     * @param currencyMismatch whether the journal's currency differs from the workspace's
     */
    public record Parsed(Journal journal, boolean currencyMismatch) {

        public boolean malformed() {
            return journal == null;
        }
    }

    /**
     * Reads a journal in the workspace currency. A different {@code currency}
     * is reported rather than reinterpreted.
     *
     * @param json     journal JSON
     * @param currency workspace currency
     * @return the parsed journal, or a malformed result
     */
    public static Parsed parse(JsonNode json, CurrencyUnit currency) {
        try {
            if (json == null || !json.isObject()) {
                return new Parsed(null, false);
            }
            String id = uuid(json, "id", true);
            TransactionType type = TransactionType.fromWire(requiredText(json, "type"));
            JournalStatus status = JournalStatus.fromWire(requiredText(json, "status"));
            LocalDate effectiveDate = LocalDate.parse(requiredText(json, "effectiveDate"));
            Instant enteredAt = Instant.parse(requiredText(json, "enteredAt"));
            String code = requiredText(json, "currency");
            if (!CURRENCY.matcher(code).matches()) {
                return new Parsed(null, false);
            }
            JsonNode lines = json.path("postings");
            if (!lines.isArray() || lines.size() > MAX_POSTINGS) {
                return new Parsed(null, false);
            }
            List<Posting> postings = new ArrayList<>();
            for (JsonNode line : lines) {
                String account = line.path("account").isString() ? line.path("account").asString() : null;
                JsonNode amount = line.path("amountMinor");
                if (account == null || account.isBlank() || account.length() > 128 || !amount.isIntegralNumber()
                        || !amount.canConvertToLong()) {
                    return new Parsed(null, false);
                }
                postings.add(new Posting(account, amount.longValue(), code));
            }
            JsonNode amountNode = json.path("amountMinor");
            Money amount = null;
            if (!amountNode.isMissingNode() && !amountNode.isNull()) {
                if (!amountNode.isIntegralNumber() || !amountNode.canConvertToLong()
                        || !Money.inRange(amountNode.longValue())) {
                    return new Parsed(null, false);
                }
                amount = new Money(amountNode.longValue(), new CurrencyUnit(code, currency.exponent()));
            }
            Set<String> tags = new LinkedHashSet<>();
            JsonNode tagNode = json.path("tags");
            if (tagNode.isArray()) {
                for (JsonNode tag : tagNode) {
                    if (!tag.isString()) {
                        return new Parsed(null, false);
                    }
                    tags.add(tag.asString());
                }
            } else if (!tagNode.isMissingNode() && !tagNode.isNull()) {
                return new Parsed(null, false);
            }
            Journal journal = new Journal(id, type, status, effectiveDate, enteredAt,
                    new CurrencyUnit(code, currency.exponent()), postings, optionalText(json, "accountId", 128),
                    optionalText(json, "counterAccountId", 128), amount, optionalText(json, "payee", 10_000),
                    optionalText(json, "notes", 10_000), tags, uuid(json, "refundOf", false),
                    uuid(json, "reversalOf", false), uuid(json, "replaces", false));
            return new Parsed(journal, !code.equals(currency.code()));
        } catch (IllegalArgumentException | DateTimeParseException | NullPointerException e) {
            return new Parsed(null, false);
        }
    }

    /**
     * Writes a journal as protocol JSON.
     *
     * @param journal the journal
     * @return the JSON object
     */
    public static ObjectNode toJson(Journal journal) {
        ObjectNode json = JsonNodeFactory.instance.objectNode();
        json.put("id", journal.id());
        json.put("type", journal.type().wire());
        json.put("status", journal.status().wire());
        json.put("effectiveDate", journal.effectiveDate().toString());
        json.put("enteredAt", journal.enteredAt().toString());
        json.put("currency", journal.currency().code());
        ArrayNode postings = json.putArray("postings");
        for (Posting posting : journal.postings()) {
            postings.addObject().put("account", posting.ledgerAccountId()).put("amountMinor", posting.amountMinor());
        }
        json.put("accountId", journal.accountId());
        json.put("counterAccountId", journal.counterAccountId());
        if (journal.amount() == null) {
            json.putNull("amountMinor");
        } else {
            json.put("amountMinor", journal.amount().minor());
        }
        json.put("payee", journal.payee());
        json.put("notes", journal.notes());
        ArrayNode tags = json.putArray("tags");
        journal.tags().stream().sorted().forEach(tags::add);
        json.put("refundOf", journal.refundOf());
        json.put("reversalOf", journal.reversalOf());
        json.put("replaces", journal.replaces());
        return json;
    }

    private static String requiredText(JsonNode json, String field) {
        JsonNode node = json.path(field);
        if (!node.isString()) {
            throw new IllegalArgumentException(field);
        }
        return node.asString();
    }

    private static String optionalText(JsonNode json, String field, int maxLength) {
        JsonNode node = json.path(field);
        if (node.isMissingNode() || node.isNull()) {
            return null;
        }
        if (!node.isString() || node.asString().length() > maxLength) {
            throw new IllegalArgumentException(field);
        }
        return node.asString();
    }

    private static String uuid(JsonNode json, String field, boolean required) {
        String value = required ? requiredText(json, field) : optionalText(json, field, 64);
        return value == null ? null : UUID.fromString(value).toString();
    }
}
