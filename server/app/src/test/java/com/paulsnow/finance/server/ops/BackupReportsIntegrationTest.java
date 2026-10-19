package com.paulsnow.finance.server.ops;

import static org.assertj.core.api.Assertions.assertThat;
import static org.hamcrest.Matchers.containsString;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.time.Duration;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.LinkedHashMap;
import java.util.Map;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.MediaType;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.test.web.servlet.ResultActions;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

import com.paulsnow.finance.server.support.IntegrationTestSupport;

import io.micrometer.core.instrument.MeterRegistry;

/**
 * Backup reporting for operations (NFR 08): the backup and restore-drill
 * jobs report each run, and the last success, recovery point and failures
 * are exposed as metrics for alerting.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
class BackupReportsIntegrationTest extends IntegrationTestSupport {

    @Autowired
    MeterRegistry meters;

    private static RequestPostProcessor operator() {
        return jwt().jwt(token -> token.subject("backup-agent"))
                .authorities(new SimpleGrantedAuthority("SCOPE_finance.ops"));
    }

    @Test
    void aSuccessfulBackupSetsTheLastSuccessAndRecoveryPoint() throws Exception {
        Instant completed = now().minus(Duration.ofMinutes(1));
        Instant recoveryPoint = completed.minus(Duration.ofMinutes(2));
        report(operator(), "database", "success", completed, recoveryPoint).andExpect(status().isOk())
                .andExpect(jsonPath("$.kind").value("database"))
                .andExpect(jsonPath("$.lastSuccessAt").value(completed.toString()))
                .andExpect(jsonPath("$.recoveryPointAt").value(recoveryPoint.toString()));

        assertThat(gauge("finance.backup.last.success", "database")).isEqualTo(completed.getEpochSecond());
        assertThat(gauge("finance.backup.recovery.point", "database")).isEqualTo(recoveryPoint.getEpochSecond());

        // A late report of an older run never moves the figures back.
        report(operator(), "database", "success", completed.minus(Duration.ofHours(1)), null)
                .andExpect(status().isOk());
        assertThat(gauge("finance.backup.last.success", "database")).isEqualTo(completed.getEpochSecond());
        assertThat(gauge("finance.backup.recovery.point", "database")).isEqualTo(recoveryPoint.getEpochSecond());

        mvc.perform(get("/actuator/prometheus")).andExpect(status().isOk())
                .andExpect(content().string(containsString("finance_backup_last_success_seconds{")))
                .andExpect(content().string(containsString("finance_backup_recovery_point_seconds{")))
                .andExpect(content().string(containsString("finance_backup_failures_total{")));
    }

    @Test
    void aSuccessWithoutARecoveryPointRecoversToItsCompletion() throws Exception {
        Instant completed = now().plus(Duration.ofDays(1));
        clock.advance(Duration.ofDays(1).plusMinutes(1));
        report(operator(), "objects", "success", completed, null).andExpect(status().isOk());
        assertThat(gauge("finance.backup.recovery.point", "objects")).isEqualTo(completed.getEpochSecond());
    }

    @Test
    void aFailureIsCountedAndLeavesTheLastSuccessAlone() throws Exception {
        double before = gauge("finance.backup.last.success", "restore-drill");
        double failures = meters.get("finance.backup.failures").tag("kind", "restore-drill").counter().count();

        Instant failedAt = now();
        report(operator(), "restore-drill", "failure", failedAt, null).andExpect(status().isOk())
                .andExpect(jsonPath("$.lastFailureAt").value(failedAt.toString()));

        assertThat(meters.get("finance.backup.failures").tag("kind", "restore-drill").counter().count())
                .isEqualTo(failures + 1);
        assertThat(gauge("finance.backup.last.success", "restore-drill")).isEqualTo(before);
    }

    @Test
    void onlyTheOperationsScopeMayReport() throws Exception {
        report(user(newSubject()), "database", "success", now(), null)
                .andExpect(status().isForbidden()).andExpect(jsonPath("$.error").value("FORBIDDEN"));
        mvc.perform(post("/v1/ops/backups").contentType(MediaType.APPLICATION_JSON).content("{}"))
                .andExpect(status().isUnauthorized());
    }

    @Test
    void rejectsMalformedReports() throws Exception {
        Instant now = now();
        report(operator(), "snapshots", "success", now, null).andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error").value("INVALID_REQUEST"));
        report(operator(), "database", "partial", now, null).andExpect(status().isBadRequest());
        report(operator(), "database", "success", null, null).andExpect(status().isBadRequest());
        report(operator(), "database", "success", now, now.plusSeconds(1)).andExpect(status().isBadRequest());
        report(operator(), "database", "success", now.plus(Duration.ofHours(1)), null)
                .andExpect(status().isBadRequest());
    }

    private ResultActions report(RequestPostProcessor caller, String kind, String outcome, Instant completedAt,
            Instant recoveryPointAt) throws Exception {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("kind", kind);
        body.put("outcome", outcome);
        if (completedAt != null) {
            body.put("completedAt", completedAt.toString());
        }
        if (recoveryPointAt != null) {
            body.put("recoveryPointAt", recoveryPointAt.toString());
        }
        return mvc.perform(post("/v1/ops/backups").with(caller).contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsString(body)));
    }

    /** The test clock to whole seconds, as stored and reported. */
    private Instant now() {
        return clock.instant().truncatedTo(ChronoUnit.SECONDS);
    }

    private double gauge(String name, String kind) {
        return meters.get(name).tag("kind", kind).gauge().value();
    }
}
