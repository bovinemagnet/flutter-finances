package com.paulsnow.finance.server.sync;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.time.Duration;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.test.web.servlet.MvcResult;

import com.paulsnow.finance.server.support.IntegrationTestSupport;

import tools.jackson.databind.JsonNode;

/**
 * The long-polled change feed (NFR 05): a pull with {@code wait} is held
 * open until another device commits, the wait ends, or at once when changes
 * already exist.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
class LongPollIntegrationTest extends IntegrationTestSupport {

    @Autowired
    TombstonePurger purger;

    /** A held-open pull and when it finished, measured with the wall clock. */
    private record Timed(MvcResult result, long finishedNanos) {
    }

    private CompletableFuture<Timed> waitingPull(ExecutorService executor, Actor actor, String cursor, int wait) {
        return CompletableFuture.supplyAsync(() -> {
            try {
                MvcResult result = mvc.perform(get("/v1/sync/changes").with(user(actor.subject()))
                                .header("X-Device-Id", actor.deviceId().toString())
                                .param("cursor", cursor == null ? "" : cursor).param("wait", String.valueOf(wait)))
                        .andReturn();
                return new Timed(result, System.nanoTime());
            } catch (Exception e) {
                throw new IllegalStateException(e);
            }
        }, executor);
    }

    private static long millisBetween(long fromNanos, long toNanos) {
        return Duration.ofNanos(toNanos - fromNanos).toMillis();
    }

    @Test
    void returnsSoonAfterAnotherDeviceCommits() throws Exception {
        Actor phone = newActor();
        Actor tablet = secondDevice(phone);
        String cursor = changes(tablet, null).path("cursor").asString();
        try (ExecutorService executor = Executors.newVirtualThreadPerTaskExecutor()) {
            CompletableFuture<Timed> pull = waitingPull(executor, tablet, cursor, 10);
            Thread.sleep(300);
            createAccount(phone, "transaction");
            long committed = System.nanoTime();

            Timed timed = pull.get();
            JsonNode page = json.readTree(timed.result().getResponse().getContentAsString());
            assertThat(timed.result().getResponse().getStatus()).isEqualTo(200);
            assertThat(page.path("changes")).hasSize(1);
            assertThat(page.path("waited").asBoolean()).isTrue();
            assertThat(millisBetween(committed, timed.finishedNanos())).isLessThan(2000);
        }
    }

    @Test
    void returnsAnEmptyPageWhenTheWaitEnds() throws Exception {
        Actor phone = newActor();
        Actor tablet = secondDevice(phone);
        String cursor = changes(tablet, null).path("cursor").asString();
        try (ExecutorService executor = Executors.newVirtualThreadPerTaskExecutor()) {
            long started = System.nanoTime();
            Timed timed = waitingPull(executor, tablet, cursor, 1).get();
            JsonNode page = json.readTree(timed.result().getResponse().getContentAsString());
            assertThat(page.path("changes")).isEmpty();
            assertThat(page.path("hasMore").asBoolean()).isFalse();
            assertThat(page.path("waited").asBoolean()).isTrue();
            assertThat(millisBetween(started, timed.finishedNanos())).isBetween(900L, 3000L);
        }
    }

    @Test
    void answersAtOnceWhenChangesAlreadyExist() throws Exception {
        Actor phone = newActor();
        Actor tablet = secondDevice(phone);
        createAccount(phone, "transaction");
        try (ExecutorService executor = Executors.newVirtualThreadPerTaskExecutor()) {
            long started = System.nanoTime();
            Timed timed = waitingPull(executor, tablet, null, 10).get();
            JsonNode page = json.readTree(timed.result().getResponse().getContentAsString());
            assertThat(page.path("changes")).hasSize(1);
            assertThat(page.path("waited").asBoolean()).isTrue();
            assertThat(millisBetween(started, timed.finishedNanos())).isLessThan(1000);
        }
    }

    @Test
    void expiredCursorGets410WithoutWaiting() throws Exception {
        Actor oldDevice = newActor();
        Actor activeDevice = secondDevice(oldDevice);
        createAccount(oldDevice, "transaction");
        String doomed = createAccount(oldDevice, "savings");
        String staleCursor = changes(oldDevice, null).path("cursor").asString();
        submitOne(activeDevice, command(activeDevice, "entity.delete", "account", doomed, 1,
                json.createObjectNode()));
        clock.advance(Duration.ofDays(91));
        purger.purgeExpiredTombstones();

        long started = System.nanoTime();
        mvc.perform(get("/v1/sync/changes").with(user(oldDevice.subject()))
                        .header("X-Device-Id", oldDevice.deviceId().toString())
                        .param("cursor", staleCursor).param("wait", "10"))
                .andExpect(status().isGone())
                .andExpect(jsonPath("$.error").value("CURSOR_EXPIRED"));
        assertThat(millisBetween(started, System.nanoTime())).isLessThan(1000);
    }

    @Test
    void withoutWaitTheResponseHasNoWaitedField() throws Exception {
        Actor phone = newActor();
        Actor tablet = secondDevice(phone);
        createAccount(phone, "transaction");
        assertThat(changes(tablet, null).path("waited").isMissingNode()).isTrue();
    }

    @Test
    void waitIgnoresPurgedRecordsBeyondTheLastChange() throws Exception {
        Actor phone = newActor();
        createAccount(phone, "transaction");
        String doomed = createAccount(phone, "savings");
        submitOne(phone, command(phone, "entity.delete", "account", doomed, 1, json.createObjectNode()));
        clock.advance(Duration.ofDays(91));
        purger.purgeExpiredTombstones();

        Actor fresh = secondDevice(phone);
        String cursor = changes(fresh, null).path("cursor").asString();
        try (ExecutorService executor = Executors.newVirtualThreadPerTaskExecutor()) {
            long started = System.nanoTime();
            Timed timed = waitingPull(executor, fresh, cursor, 1).get();
            JsonNode page = json.readTree(timed.result().getResponse().getContentAsString());
            assertThat(page.path("changes")).isEmpty();
            assertThat(millisBetween(started, timed.finishedNanos())).isGreaterThanOrEqualTo(900L);
        }
    }
}
