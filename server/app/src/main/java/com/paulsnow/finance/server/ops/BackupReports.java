package com.paulsnow.finance.server.ops;

import java.sql.Timestamp;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.List;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import com.paulsnow.finance.server.common.ApiException;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.Gauge;
import io.micrometer.core.instrument.MeterRegistry;

/**
 * Records backup and restore-drill outcomes reported by the operations
 * tooling (NFR 08) and exposes them as metrics:
 * <ul>
 * <li>{@code finance.backup.last.success{kind}}: epoch seconds of the latest
 * successful run, 0 when none was ever reported;</li>
 * <li>{@code finance.backup.recovery.point{kind}} (database and objects):
 * epoch seconds of the latest point a successful backup can restore to;</li>
 * <li>{@code finance.backup.failures{kind}}: failed runs reported to this
 * instance.</li>
 * </ul>
 * The last success and recovery point are stored, so every instance
 * reports the same values and they survive restarts; a report of an older
 * run never moves them back.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Service
class BackupReports {

    /** Backup kinds. */
    static final List<String> KINDS = List.of("database", "objects", "restore-drill");

    /** Kinds whose runs restore to a point in time. */
    static final List<String> RECOVERABLE = List.of("database", "objects");

    /** How far {@code completedAt} may be ahead of the server clock. */
    static final Duration CLOCK_SKEW = Duration.ofMinutes(5);

    /** The stored outcome of one kind. */
    record BackupStatus(String kind, Instant lastSuccessAt, Instant recoveryPointAt, Instant lastFailureAt) {
    }

    private static final Logger LOG = LoggerFactory.getLogger(BackupReports.class);

    private final JdbcClient jdbc;
    private final Clock clock;
    private final MeterRegistry meters;

    BackupReports(JdbcClient jdbc, Clock clock, MeterRegistry meters) {
        this.jdbc = jdbc;
        this.clock = clock;
        this.meters = meters;
        for (String kind : KINDS) {
            Gauge.builder("finance.backup.last.success", () -> epochSeconds("last_success_at", kind))
                    .description("Completion of the latest successful backup or restore drill, in epoch seconds")
                    .baseUnit("seconds").tag("kind", kind).register(meters);
            failures(kind);
        }
        for (String kind : RECOVERABLE) {
            Gauge.builder("finance.backup.recovery.point", () -> epochSeconds("recovery_point_at", kind))
                    .description("Latest point a successful backup restores to, in epoch seconds")
                    .baseUnit("seconds").tag("kind", kind).register(meters);
        }
    }

    /**
     * Records one run.
     *
     * @param kind            {@code database}, {@code objects} or {@code restore-drill}
     * @param outcome         {@code success} or {@code failure}
     * @param completedAt     when the run finished
     * @param recoveryPointAt for a successful backup, the point it restores to; defaults to {@code completedAt}
     * @return the stored status of the kind
     * @throws ApiException 400 {@code INVALID_REQUEST} for an invalid report
     */
    @Transactional
    BackupStatus record(String kind, String outcome, Instant completedAt, Instant recoveryPointAt) {
        if (!KINDS.contains(kind)) {
            throw invalid("kind is one of " + String.join(", ", KINDS) + ".");
        }
        boolean success = "success".equals(outcome);
        if (!success && !"failure".equals(outcome)) {
            throw invalid("outcome is success or failure.");
        }
        if (completedAt == null) {
            throw invalid("completedAt is required.");
        }
        Instant now = clock.instant();
        if (completedAt.isAfter(now.plus(CLOCK_SKEW))) {
            throw invalid("completedAt is in the future.");
        }
        if (recoveryPointAt != null && recoveryPointAt.isAfter(completedAt)) {
            throw invalid("recoveryPointAt is after completedAt.");
        }
        if (success) {
            Instant recoveryPoint = !RECOVERABLE.contains(kind) ? null
                    : recoveryPointAt == null ? completedAt : recoveryPointAt;
            jdbc.sql("insert into ops_backup_status (kind, last_success_at, recovery_point_at, updated_at) "
                            + "values (?, ?, ?, ?) on conflict (kind) do update set "
                            + "last_success_at = greatest(ops_backup_status.last_success_at, excluded.last_success_at), "
                            + "recovery_point_at = greatest(ops_backup_status.recovery_point_at, "
                            + "excluded.recovery_point_at), updated_at = excluded.updated_at")
                    .params(kind, Timestamp.from(completedAt), timestamp(recoveryPoint), Timestamp.from(now))
                    .update();
        } else {
            failures(kind).increment();
            jdbc.sql("insert into ops_backup_status (kind, last_failure_at, updated_at) values (?, ?, ?) "
                            + "on conflict (kind) do update set last_failure_at = "
                            + "greatest(ops_backup_status.last_failure_at, excluded.last_failure_at), "
                            + "updated_at = excluded.updated_at")
                    .params(kind, Timestamp.from(completedAt), Timestamp.from(now)).update();
        }
        LOG.info("Backup {} reported {} at {}", kind, outcome, completedAt);
        return jdbc.sql("select * from ops_backup_status where kind = ?").param(kind)
                .query((rs, row) -> new BackupStatus(kind, instant(rs.getTimestamp("last_success_at")),
                        instant(rs.getTimestamp("recovery_point_at")), instant(rs.getTimestamp("last_failure_at"))))
                .single();
    }

    private Counter failures(String kind) {
        return Counter.builder("finance.backup.failures").description("Failed backups and restore drills reported")
                .tag("kind", kind).register(meters);
    }

    private double epochSeconds(String column, String kind) {
        try {
            Double value = jdbc.sql("select extract(epoch from " + column + ")::float8 from ops_backup_status "
                            + "where kind = ?")
                    .param(kind).query(Double.class).optional().orElse(null);
            return value == null ? 0 : Math.floor(value);
        } catch (RuntimeException e) {
            return Double.NaN;
        }
    }

    private static ApiException invalid(String message) {
        return ApiException.badRequest("INVALID_REQUEST", message);
    }

    private static Timestamp timestamp(Instant instant) {
        return instant == null ? null : Timestamp.from(instant);
    }

    private static Instant instant(Timestamp timestamp) {
        return timestamp == null ? null : timestamp.toInstant();
    }
}
