/**
 * Reports over canonical journals (REP 01, REP 04): the shared
 * {@code report.compute} definitions of {@code finance-core}'s
 * {@code LedgerReports}, computed from the workspace's live accounts,
 * categories and journals and restricted to what the calling member may see
 * ({@code spec/sync/protocol.md}, "Households").
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@org.springframework.modulith.ApplicationModule(displayName = "Reports")
package com.paulsnow.finance.server.reports;
