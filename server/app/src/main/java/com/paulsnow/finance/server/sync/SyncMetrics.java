package com.paulsnow.finance.server.sync;

import java.sql.Timestamp;
import java.time.Clock;
import java.util.List;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Component;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.Gauge;
import io.micrometer.core.instrument.MeterRegistry;

/**
 * Sync metrics: commands by status (the conflict rate is
 * {@code conflict / total}) and the sync backlog age, the age of the oldest
 * change an active device has not yet pulled.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Component
class SyncMetrics {

    private static final List<String> STATUSES = List.of(CommandResult.APPLIED, CommandResult.PREVIOUSLY_APPLIED,
            CommandResult.CONFLICT, CommandResult.VALIDATION_FAILED, CommandResult.PERMISSION_DENIED);

    private final MeterRegistry meters;

    SyncMetrics(MeterRegistry meters, JdbcClient jdbc, Clock clock, SyncProperties properties) {
        this.meters = meters;
        STATUSES.forEach(this::counter);
        Gauge.builder("finance.sync.backlog.age", () -> backlogAgeSeconds(jdbc, clock, properties))
                .description("Age of the oldest change not yet pulled by an active device")
                .baseUnit("seconds")
                .register(meters);
    }

    void recordCommand(String status) {
        counter(status).increment();
    }

    private Counter counter(String status) {
        return Counter.builder("finance.sync.commands").description("Sync commands processed, by result status")
                .tag("status", status).register(meters);
    }

    private static double backlogAgeSeconds(JdbcClient jdbc, Clock clock, SyncProperties properties) {
        try {
            Timestamp now = Timestamp.from(clock.instant());
            Timestamp active = Timestamp.from(clock.instant().minus(properties.tombstoneHorizon()));
            Double age = jdbc.sql("select max(extract(epoch from (?::timestamptz - c.created_at))) "
                            + "from sync_device_cursor d cross join lateral (select created_at from sync_change c "
                            + "where c.workspace_id = d.workspace_id and c.sequence > d.last_sequence "
                            + "order by c.sequence limit 1) c where d.pulled_at > ?")
                    .params(now, active).query(Double.class).optional().orElse(null);
            return age == null ? 0 : age;
        } catch (RuntimeException e) {
            return Double.NaN;
        }
    }
}
