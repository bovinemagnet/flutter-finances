package com.paulsnow.finance.server.reports;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

import com.paulsnow.finance.core.ledger.Account;
import com.paulsnow.finance.core.ledger.AccountType;
import com.paulsnow.finance.core.ledger.Category;
import com.paulsnow.finance.core.ledger.CategoryKind;
import com.paulsnow.finance.core.ledger.Chart;
import com.paulsnow.finance.core.ledger.Journal;
import com.paulsnow.finance.core.ledger.LedgerProjection;
import com.paulsnow.finance.core.reports.DateRange;
import com.paulsnow.finance.core.reports.LedgerReports;
import com.paulsnow.finance.core.reports.Report;
import com.paulsnow.finance.server.common.ApiException;
import com.paulsnow.finance.server.ledger.JournalJson;
import com.paulsnow.finance.server.sync.EntityReader;
import com.paulsnow.finance.server.sync.Visibility;
import com.paulsnow.finance.server.sync.VisibilityService;
import com.paulsnow.finance.server.workspace.CurrentMember;
import com.paulsnow.finance.server.workspace.WorkspaceInfo;

import tools.jackson.databind.JsonNode;

/**
 * Computes reports with {@link LedgerReports} over the workspace's
 * canonical accounts, categories and journals, as one consistent read.
 * Accounts the member may not see, and every journal that touches one, are
 * left out before the report is computed, so totals, rows and journal
 * identifiers never reveal them.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Service
class ReportService {

    /** The report kinds, as in the shared {@code report.compute} fixtures. */
    static final List<String> KINDS = List.of("income-vs-expenses", "spending-by-category", "spending-by-payee",
            "account-balances", "net-worth-history", "cash-flow");

    /**
     * A computed report.
     *
     * @param kind             report kind
     * @param title            title
     * @param keyLabel         heading of the row label column
     * @param currency         workspace currency
     * @param currencyExponent minor unit exponent of {@code currency}
     * @param range            date range, or null for {@code account-balances}
     * @param asOf             point in time of {@code account-balances}, or null
     * @param complete         false when accounts the member may not see were left out
     * @param columns          value columns
     * @param rows             rows in display order
     */
    record ReportView(String kind, String title, String keyLabel, String currency, int currencyExponent,
            RangeView range, LocalDate asOf, boolean complete, List<ColumnView> columns, List<RowView> rows) {
    }

    /** An inclusive date range and its label, for example {@code FY2026-27}. */
    record RangeView(LocalDate start, LocalDate end, String label) {
    }

    /** A value column; {@code kind} is {@code money} or {@code count}. */
    record ColumnView(String key, String label, String kind) {
    }

    /** A row: money in minor units and counts per column key, and the journals behind it. */
    record RowView(String key, String label, Map<String, Long> amounts, Map<String, Integer> counts,
            List<String> journalIds) {
    }

    /** The validated parameters of one report. */
    record Parameters(DateRange range, LocalDate asOf, List<String> accountIds) {
    }

    private final EntityReader entities;
    private final VisibilityService visibility;

    ReportService(EntityReader entities, VisibilityService visibility) {
        this.entities = entities;
        this.visibility = visibility;
    }

    /**
     * Computes a report for the member.
     *
     * @param member     the caller
     * @param kind       one of {@link #KINDS}
     * @param parameters validated parameters
     * @return the report
     */
    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ)
    ReportView compute(CurrentMember member, String kind, Parameters parameters) {
        WorkspaceInfo workspace = member.workspace();
        Visibility sees = visibility.forMember(workspace.id(), member.user().id());
        LedgerProjection ledger = load(workspace, sees);
        Report report = switch (kind) {
            case "income-vs-expenses" -> LedgerReports.incomeVsExpenses(ledger, parameters.range());
            case "spending-by-category" -> LedgerReports.spendingByCategory(ledger, parameters.range());
            case "spending-by-payee" -> LedgerReports.spendingByPayee(ledger, parameters.range());
            case "account-balances" -> LedgerReports.accountBalances(ledger, parameters.asOf());
            case "net-worth-history" -> LedgerReports.netWorthHistory(ledger, parameters.range());
            case "cash-flow" -> LedgerReports.cashFlow(ledger, parameters.range(),
                    accountSet(ledger.chart(), parameters.accountIds()));
            default -> throw unknownReport();
        };
        return view(kind, report, workspace, sees.hidesNothing());
    }

    static ApiException unknownReport() {
        return ApiException.notFound("UNKNOWN_REPORT", "Reports are " + String.join(", ", KINDS) + ".");
    }

    private LedgerProjection load(WorkspaceInfo workspace, Visibility sees) {
        UUID workspaceId = workspace.id();
        List<Account> accounts = new ArrayList<>();
        entities.forEachLive(workspaceId, "account", entity -> {
            String id = entity.entityId().toString();
            if (!sees.hidesAccount(id)) {
                accounts.add(account(id, entity.data()));
            }
        });
        List<Category> categories = new ArrayList<>();
        entities.forEachLive(workspaceId, "category", entity -> categories.add(category(
                entity.entityId().toString(), entity.data())));
        List<Journal> journals = new ArrayList<>();
        entities.forEachLive(workspaceId, "journal", entity -> {
            if (sees.hides(entity.entityType(), entity.entityId().toString(), entity.data())) {
                return;
            }
            JournalJson.Parsed parsed = JournalJson.parse(entity.data(), workspace.currency());
            if (!parsed.malformed()) {
                journals.add(parsed.journal());
            }
        });
        return new LedgerProjection(new Chart(workspace.currency(), accounts, categories), journals);
    }

    private static Account account(String id, JsonNode data) {
        Account.Builder builder = Account.builder(id, data.path("name").asString(""),
                        AccountType.fromWire(data.path("type").asString()))
                .includeInBudget(data.path("includeInBudget").asBoolean(true))
                .includeInForecast(data.path("includeInForecast").asBoolean(true))
                .includeInNetWorth(data.path("includeInNetWorth").asBoolean(true))
                .archived(data.path("archived").asBoolean(false))
                .dataSource(data.path("dataSource").asString("manual"));
        String reconciled = data.path("lastReconciledOn").asString(null);
        if (reconciled != null) {
            builder.lastReconciledOn(LocalDate.parse(reconciled));
        }
        return builder.build();
    }

    private static Category category(String id, JsonNode data) {
        return new Category(id, data.path("name").asString(""), CategoryKind.fromWire(data.path("kind").asString()),
                data.path("parentId").asString(null), data.path("archived").asBoolean(false));
    }

    /** The cash flow account set; a hidden account is reported exactly like an unknown one. */
    private static Set<String> accountSet(Chart chart, List<String> accountIds) {
        Set<String> ids = new LinkedHashSet<>();
        for (String raw : accountIds) {
            String id;
            try {
                id = UUID.fromString(raw.strip()).toString();
            } catch (IllegalArgumentException e) {
                id = raw.strip();
            }
            if (!chart.hasAccount(id)) {
                throw ApiException.badRequest("UNKNOWN_ACCOUNT", "accountIds names an unknown account.");
            }
            ids.add(id);
        }
        return ids;
    }

    private static ReportView view(String kind, Report report, WorkspaceInfo workspace, boolean complete) {
        List<ColumnView> columns = report.columns().stream()
                .map(c -> new ColumnView(c.key(), c.label(), c.kind().name().toLowerCase(Locale.ROOT))).toList();
        List<RowView> rows = new ArrayList<>();
        for (Report.Row row : report.rows()) {
            Map<String, Long> amounts = new LinkedHashMap<>();
            Map<String, Integer> counts = new LinkedHashMap<>();
            for (Report.Column column : report.columns()) {
                if (row.amounts().containsKey(column.key())) {
                    amounts.put(column.key(), row.amounts().get(column.key()).minor());
                }
                if (row.counts().containsKey(column.key())) {
                    counts.put(column.key(), row.counts().get(column.key()));
                }
            }
            rows.add(new RowView(row.key(), row.label(), amounts, counts, row.journalIds()));
        }
        DateRange range = report.range();
        return new ReportView(kind, report.title(), report.keyLabel(), workspace.currency().code(),
                workspace.currency().exponent(),
                range == null ? null : new RangeView(range.start(), range.end(), range.label()), report.asOf(),
                complete, columns, rows);
    }
}
