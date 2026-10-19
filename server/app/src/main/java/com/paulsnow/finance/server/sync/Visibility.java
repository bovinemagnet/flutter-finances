package com.paulsnow.finance.server.sync;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.function.Function;

import tools.jackson.databind.JsonNode;

/**
 * What one member of a shared household may see in a workspace
 * ({@code spec/sync/protocol.md}, "Households"):
 * <ul>
 * <li>an account is hidden when it is private (its {@code sharing} field is
 * not {@code shared}) and another user created it;</li>
 * <li>categories are always visible;</li>
 * <li>a journal is hidden when any of its postings touches a hidden
 * account;</li>
 * <li>any other entity is hidden when one of its reference fields
 * ({@link #ACCOUNT_REFERENCES}, {@link #JOURNAL_REFERENCES}) names a hidden
 * account or journal; all other metadata is visible.</li>
 * </ul>
 * Instances are short-lived (one request or command) and not thread-safe.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public final class Visibility {

    /** Fields of opaque entities that name an account. */
    public static final List<String> ACCOUNT_REFERENCES = List.of("accountId", "counterAccountId", "toAccountId",
            "fromAccountId", "accountIds");

    /** Fields of opaque entities that name a journal. */
    public static final List<String> JOURNAL_REFERENCES = List.of("journalId", "journalIds");

    private static final Visibility EVERYTHING = new Visibility(Set.of(), id -> Set.of());

    private final Set<String> hiddenAccounts;
    private final Function<String, Set<String>> journalAccounts;
    private final Map<String, Boolean> hiddenJournals = new HashMap<>();

    Visibility(Set<String> hiddenAccounts, Function<String, Set<String>> journalAccounts) {
        this.hiddenAccounts = Set.copyOf(hiddenAccounts);
        this.journalAccounts = journalAccounts;
    }

    /** Returns a visibility that hides nothing, for server-originated work. */
    public static Visibility everything() {
        return EVERYTHING;
    }

    /** Returns whether nothing is hidden. */
    public boolean hidesNothing() {
        return hiddenAccounts.isEmpty();
    }

    /** Returns the identifiers of hidden accounts. */
    public Set<String> hiddenAccounts() {
        return hiddenAccounts;
    }

    /**
     * Returns whether an account is hidden.
     *
     * @param accountId account (ledger account) identifier
     * @return true when hidden
     */
    public boolean hidesAccount(String accountId) {
        return accountId != null && hiddenAccounts.contains(normalise(accountId));
    }

    /**
     * Returns whether a stored journal is hidden, from its current postings.
     *
     * @param journalId journal identifier
     * @return true when hidden
     */
    public boolean hidesJournal(String journalId) {
        if (journalId == null || hiddenAccounts.isEmpty()) {
            return false;
        }
        String id = normalise(journalId);
        return hiddenJournals.computeIfAbsent(id,
                key -> journalAccounts.apply(key).stream().anyMatch(hiddenAccounts::contains));
    }

    /**
     * Returns whether an entity is hidden, judged from {@code data}, the
     * entity at the revision in question.
     *
     * @param entityType entity type
     * @param entityId   entity identifier
     * @param data       entity JSON, or null for a tombstone (never hidden)
     * @return true when hidden
     */
    public boolean hides(String entityType, String entityId, JsonNode data) {
        if (data == null || data.isNull() || data.isMissingNode() || hiddenAccounts.isEmpty()) {
            return false;
        }
        return switch (entityType) {
            case "account" -> hidesAccount(entityId);
            case "category" -> false;
            case "journal" -> {
                for (JsonNode posting : data.path("postings")) {
                    if (hidesAccount(posting.path("account").asString(null))) {
                        yield true;
                    }
                }
                yield false;
            }
            default -> referencesHidden(data);
        };
    }

    private boolean referencesHidden(JsonNode data) {
        for (String field : ACCOUNT_REFERENCES) {
            if (anyMatch(data.get(field), this::hidesAccount)) {
                return true;
            }
        }
        for (String field : JOURNAL_REFERENCES) {
            if (anyMatch(data.get(field), this::hidesJournal)) {
                return true;
            }
        }
        return false;
    }

    private static boolean anyMatch(JsonNode value, java.util.function.Predicate<String> test) {
        if (value == null) {
            return false;
        }
        if (value.isString()) {
            return test.test(value.asString());
        }
        if (value.isArray()) {
            for (JsonNode item : value) {
                if (item.isString() && test.test(item.asString())) {
                    return true;
                }
            }
        }
        return false;
    }

    private static String normalise(String id) {
        try {
            return UUID.fromString(id).toString();
        } catch (IllegalArgumentException e) {
            return id;
        }
    }
}
