package com.paulsnow.finance.server.jobs;

import java.time.Instant;
import java.util.UUID;

import com.fasterxml.jackson.annotation.JsonInclude;

import tools.jackson.databind.JsonNode;

/**
 * Job status for polling.
 *
 * @param id          stable identifier
 * @param type        job type
 * @param status      {@code queued}, {@code running}, {@code succeeded} or {@code failed}
 * @param attempts    attempts so far
 * @param result      handler result once succeeded
 * @param error       failure code once failed
 * @param createdAt   when queued
 * @param updatedAt   last change
 * @param completedAt when it finished
 * @author Paul Snow
 * @since 0.0.0
 */
@JsonInclude(JsonInclude.Include.NON_NULL)
public record JobView(UUID id, String type, String status, int attempts, JsonNode result, String error,
        Instant createdAt, Instant updatedAt, Instant completedAt) {
}
