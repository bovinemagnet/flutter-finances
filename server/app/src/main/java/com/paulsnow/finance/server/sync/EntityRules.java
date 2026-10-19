package com.paulsnow.finance.server.sync;

import java.time.LocalDate;
import java.time.format.DateTimeParseException;
import java.util.List;
import java.util.Map;

import com.paulsnow.finance.core.ledger.AccountType;
import com.paulsnow.finance.core.ledger.CategoryKind;

import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * Field rules for the entity types the server understands (account and
 * category); every other type is opaque JSON. An account's type and a
 * category's kind decide how its postings are read, so they cannot change.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
final class EntityRules {

    private enum Kind { STRING, BOOLEAN, DATE, ACCOUNT_TYPE, CATEGORY_KIND, OPTIONAL_STRING }

    private static final Map<String, Map<String, Kind>> FIELDS = Map.of(
            "account", Map.of("name", Kind.STRING, "type", Kind.ACCOUNT_TYPE, "includeInBudget", Kind.BOOLEAN,
                    "includeInForecast", Kind.BOOLEAN, "includeInNetWorth", Kind.BOOLEAN, "archived", Kind.BOOLEAN,
                    "dataSource", Kind.STRING, "lastReconciledOn", Kind.DATE),
            "category", Map.of("name", Kind.STRING, "kind", Kind.CATEGORY_KIND, "parentId", Kind.OPTIONAL_STRING,
                    "archived", Kind.BOOLEAN));

    private static final Map<String, List<String>> REQUIRED = Map.of(
            "account", List.of("name", "type"),
            "category", List.of("name", "kind"));

    private static final Map<String, String> IMMUTABLE = Map.of("account", "type", "category", "kind");

    private EntityRules() {
    }

    /**
     * Checks changed fields of an entity.
     *
     * @param entityType entity type
     * @param fields     changed fields
     * @param existing   current data, or null on creation
     * @return an error code, or null when valid
     */
    static String check(String entityType, ObjectNode fields, ObjectNode existing) {
        Map<String, Kind> rules = FIELDS.get(entityType);
        if (rules == null) {
            return null;
        }
        if (existing == null) {
            for (String required : REQUIRED.get(entityType)) {
                JsonNode value = fields.get(required);
                if (value == null || value.isNull()) {
                    return "MISSING_FIELD";
                }
            }
        }
        for (Map.Entry<String, JsonNode> field : fields.properties()) {
            Kind kind = rules.get(field.getKey());
            if (kind != null && !valid(kind, field.getValue())) {
                return "INVALID_FIELD";
            }
        }
        String immutable = IMMUTABLE.get(entityType);
        if (existing != null && fields.has(immutable) && !JsonValues.same(existing.get(immutable),
                fields.get(immutable))) {
            return "IMMUTABLE_FIELD";
        }
        return null;
    }

    private static boolean valid(Kind kind, JsonNode value) {
        return switch (kind) {
            case STRING -> value.isString() && !value.asString().isBlank() && value.asString().length() <= 200;
            case OPTIONAL_STRING -> value.isNull() || value.isString();
            case BOOLEAN -> value.isBoolean();
            case DATE -> value.isNull() || (value.isString() && isDate(value.asString()));
            case ACCOUNT_TYPE -> value.isString() && parses(() -> AccountType.fromWire(value.asString()));
            case CATEGORY_KIND -> value.isString() && parses(() -> CategoryKind.fromWire(value.asString()));
        };
    }

    private static boolean isDate(String text) {
        try {
            LocalDate.parse(text);
            return true;
        } catch (DateTimeParseException e) {
            return false;
        }
    }

    private static boolean parses(Runnable parse) {
        try {
            parse.run();
            return true;
        } catch (IllegalArgumentException e) {
            return false;
        }
    }
}
