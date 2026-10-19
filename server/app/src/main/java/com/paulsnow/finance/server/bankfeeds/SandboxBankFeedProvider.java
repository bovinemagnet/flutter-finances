package com.paulsnow.finance.server.bankfeeds;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.LocalDate;
import java.time.ZoneOffset;
import java.util.List;
import java.util.UUID;

/**
 * A deterministic fake institution for development and tests, enabled only
 * by {@code finance.bank-feeds.sandbox.enabled=true}. Consent is granted at
 * once (no redirect) for 90 days. Its transactions appear on a fixed
 * timeline measured from when the connection was first made, so moving the
 * clock forward exercises each reconciliation case in turn:
 * <ul>
 * <li>day 0: three posted transactions and one pending purchase;</li>
 * <li>day 1: the pending purchase posts under a new id, and a subscription posts;</li>
 * <li>day 2: the provider changes a transaction's id, and reverses the subscription.</li>
 * </ul>
 * Pages hold two transactions, so a backfill also exercises paging.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
class SandboxBankFeedProvider implements BankFeedProvider {

    static final String ID = "sandbox";

    private static final Duration CONSENT = Duration.ofDays(90);
    private static final Duration ACCESS = Duration.ofHours(1);
    private static final int PAGE_SIZE = 2;
    private static final String EVERYDAY = "sbx-acc-everyday";
    private static final String CARD = "sbx-acc-card";

    /** One scripted transaction: available from {@code day} days after the anchor. */
    private record Scripted(int day, String id, String accountId, String status, long amountMinor, int dateOffset,
            String description, String pendingId, String previousId, String reversalOf) {
    }

    private static final List<Scripted> TIMELINE = List.of(
            new Scripted(0, "sbx-t-001", EVERYDAY, "posted", -5423, -3, "CORNER GROCER", null, null, null),
            new Scripted(0, "sbx-t-002", EVERYDAY, "posted", 250_000, -2, "SALARY EXAMPLE PTY LTD", null, null,
                    null),
            new Scripted(0, "sbx-p-003", EVERYDAY, "pending", -450, -1, "CAFE", null, null, null),
            new Scripted(0, "sbx-t-004", CARD, "posted", -6000, -1, "FUEL STATION", null, null, null),
            new Scripted(1, "sbx-t-005", EVERYDAY, "posted", -450, 0, "CAFE", "sbx-p-003", null, null),
            new Scripted(1, "sbx-t-006", CARD, "posted", -1299, 0, "STREAMING SERVICE", null, null, null),
            new Scripted(2, "sbx-t-004b", CARD, "posted", -6000, -1, "FUEL STATION", null, "sbx-t-004", null),
            new Scripted(2, "sbx-t-007", CARD, "posted", 1299, 1, "STREAMING SERVICE REVERSAL", null, null,
                    "sbx-t-006"));

    private final Clock clock;

    SandboxBankFeedProvider(Clock clock) {
        this.clock = clock;
    }

    @Override
    public String id() {
        return ID;
    }

    @Override
    public ConsentStart startConsent(ConsentRequest request) {
        Instant now = clock.instant();
        long anchor = request.existingReference() == null ? now.getEpochSecond()
                : Long.parseLong(request.existingReference().split("\\.")[1]);
        String reference = request.existingReference() == null ? "sbx." + anchor + "." + request.connectionId()
                : request.existingReference();
        return ConsentStart.granted(new ProviderGrant(reference, "sandbox-bank", "Sandbox Bank",
                tokens(anchor, now.getEpochSecond()), now.plus(CONSENT)));
    }

    @Override
    public ProviderGrant completeConsent(String state, String code) {
        throw new ConsentRejectedException();
    }

    @Override
    public List<ProviderAccount> listAccounts(ProviderTokens tokens) {
        requireActive(tokens);
        return List.of(new ProviderAccount(EVERYDAY, "Everyday account", "transaction", "xx12"),
                new ProviderAccount(CARD, "Rewards card", "credit_card", "xx34"));
    }

    @Override
    public TransactionPage fetchTransactions(ProviderTokens tokens, String accountId, String cursor) {
        long[] parts = requireActive(tokens);
        Instant anchor = Instant.ofEpochSecond(parts[0]);
        LocalDate anchorDate = LocalDate.ofInstant(anchor, ZoneOffset.UTC);
        Instant now = clock.instant();
        List<Scripted> available = TIMELINE.stream().filter(t -> t.accountId().equals(accountId))
                .filter(t -> !anchor.plus(Duration.ofDays(t.day())).isAfter(now)).toList();
        int start = cursor == null ? 0 : Math.min(Integer.parseInt(cursor), available.size());
        int end = Math.min(start + PAGE_SIZE, available.size());
        List<ProviderTransaction> page = available.subList(start, end).stream()
                .map(t -> new ProviderTransaction(t.id(), t.accountId(), t.status(), t.amountMinor(), "AUD",
                        anchorDate.plusDays(t.dateOffset()), t.description(), t.pendingId(),
                        t.previousId(), t.reversalOf()))
                .toList();
        return new TransactionPage(page, Integer.toString(end), end < available.size());
    }

    @Override
    public ConsentStatus consentStatus(ProviderTokens tokens) {
        Instant expires = Instant.ofEpochSecond(parse(tokens.accessToken())[1]).plus(CONSENT);
        return new ConsentStatus(clock.instant().isBefore(expires) ? "active" : "expired", expires);
    }

    @Override
    public ProviderTokens refresh(ProviderTokens tokens) {
        long[] parts = parse(tokens.refreshToken());
        if (!clock.instant().isBefore(Instant.ofEpochSecond(parts[1]).plus(CONSENT))) {
            throw new ConsentExpiredException();
        }
        return tokens(parts[0], parts[1]);
    }

    @Override
    public void revoke(ProviderTokens tokens) {
        // Nothing is held at the sandbox.
    }

    private long[] requireActive(ProviderTokens tokens) {
        long[] parts = parse(tokens.accessToken());
        if (!"active".equals(consentStatus(tokens).status())) {
            throw new ConsentExpiredException();
        }
        return parts;
    }

    private ProviderTokens tokens(long anchor, long consentStart) {
        String suffix = anchor + "." + consentStart + "." + UUID.randomUUID();
        return new ProviderTokens("sbx-at." + suffix, "sbx-rt." + suffix, clock.instant().plus(ACCESS));
    }

    /** Returns the anchor and consent start encoded in a sandbox token. */
    private static long[] parse(String token) {
        String[] parts = token.split("\\.");
        return new long[] { Long.parseLong(parts[1]), Long.parseLong(parts[2]) };
    }
}
