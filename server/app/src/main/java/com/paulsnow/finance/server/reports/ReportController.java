package com.paulsnow.finance.server.reports;

import java.util.List;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import com.paulsnow.finance.server.common.ApiException;
import com.paulsnow.finance.server.workspace.CurrentMember;

import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.tags.Tag;

/**
 * Report endpoints (REP 01). Any member, including a viewer, may read
 * reports; each sees only what the households visibility rules allow.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@RestController
@Tag(name = "Reports")
class ReportController {

    private final ReportService reports;

    ReportController(ReportService reports) {
        this.reports = reports;
    }

    @GetMapping("/v1/reports/{kind}")
    @Operation(summary = "Compute a report over the posted ledger: from and to, financialYear or calendarYear "
            + "(account-balances takes asOf; cash-flow also needs accountIds)")
    ReportService.ReportView report(CurrentMember member, @PathVariable String kind,
            @RequestParam(required = false) String from, @RequestParam(required = false) String to,
            @RequestParam(required = false) String financialYear,
            @RequestParam(required = false) String calendarYear, @RequestParam(required = false) String asOf,
            @RequestParam(required = false) List<String> accountIds) {
        if (!ReportService.KINDS.contains(kind)) {
            throw ReportService.unknownReport();
        }
        ReportService.Parameters parameters;
        if ("account-balances".equals(kind)) {
            parameters = new ReportService.Parameters(null,
                    ReportRequest.asOf(from, to, financialYear, calendarYear, asOf), List.of());
        } else {
            if ("cash-flow".equals(kind) && (accountIds == null || accountIds.isEmpty())) {
                throw ApiException.badRequest("INVALID_REQUEST", "cash-flow needs accountIds.");
            }
            parameters = new ReportService.Parameters(
                    ReportRequest.range(from, to, financialYear, calendarYear, asOf), null,
                    accountIds == null ? List.of() : accountIds);
        }
        return reports.compute(member, kind, parameters);
    }
}
