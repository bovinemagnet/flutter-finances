package com.paulsnow.finance.server.sync;

import java.time.Duration;
import java.util.UUID;

import org.springframework.stereotype.Component;

/**
 * Holds a long-polled change feed request open until something changes in
 * its workspace (NFR 05). Committing a change calls {@link #changed}; waiters
 * also re-check the database every {@code waitRecheck}, so a wake-up that
 * never arrives (another server instance, a missed signal) only delays the
 * answer.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Component
class ChangeWaiter {

    private final EntityStore store;
    private final SyncProperties properties;
    private final Object monitor = new Object();
    private long generation;

    ChangeWaiter(EntityStore store, SyncProperties properties) {
        this.store = store;
        this.properties = properties;
    }

    /** The wait to honour: none unless a positive number of seconds was asked for, never above {@code max}. */
    static Duration effectiveWait(Integer requestedSeconds, Duration max) {
        if (requestedSeconds == null || requestedSeconds <= 0) {
            return Duration.ZERO;
        }
        Duration requested = Duration.ofSeconds(requestedSeconds);
        return requested.compareTo(max) < 0 ? requested : max;
    }

    /** Wakes every waiter; each re-reads its own workspace's position. */
    void changed(UUID workspaceId) {
        synchronized (monitor) {
            generation++;
            monitor.notifyAll();
        }
    }

    /**
     * Returns when the workspace has a change after {@code sequence}, when
     * {@code wait} has elapsed, or when the thread is interrupted. Time is
     * measured with {@link System#nanoTime()} rather than the injectable clock.
     */
    void awaitChangeAfter(UUID workspaceId, long sequence, Duration wait) {
        long deadline = System.nanoTime() + wait.toNanos();
        long recheckNanos = Math.max(1, properties.waitRecheck().toNanos());
        try {
            while (true) {
                long seen;
                synchronized (monitor) {
                    seen = generation;
                }
                // Registered (generation read) before the query, so a commit
                // between the two makes the wait below return at once.
                if (store.latestChangeSequence(workspaceId) > sequence) {
                    return;
                }
                long remaining = deadline - System.nanoTime();
                if (remaining <= 0) {
                    return;
                }
                long pauseNanos = Math.min(remaining, recheckNanos);
                synchronized (monitor) {
                    if (generation == seen) {
                        monitor.wait(pauseNanos / 1_000_000, (int) (pauseNanos % 1_000_000));
                    }
                }
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}
