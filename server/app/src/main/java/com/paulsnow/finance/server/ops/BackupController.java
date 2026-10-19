package com.paulsnow.finance.server.ops;

import java.time.Instant;

import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.tags.Tag;

/**
 * Backup reporting for operations tooling. Only tokens with the
 * {@code finance.ops} scope reach it ({@code SCOPE_finance.ops}); end users
 * never do.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@RestController
@Tag(name = "Operations")
class BackupController {

    /** One backup or restore-drill run. */
    record BackupReport(String kind, String outcome, Instant completedAt, Instant recoveryPointAt) {
    }

    private final BackupReports backups;

    BackupController(BackupReports backups) {
        this.backups = backups;
    }

    @PostMapping("/v1/ops/backups")
    @Operation(summary = "Report a database backup, object storage backup or restore drill (finance.ops scope)")
    BackupReports.BackupStatus report(@RequestBody BackupReport report) {
        return backups.record(report.kind(), report.outcome(), report.completedAt(), report.recoveryPointAt());
    }
}
