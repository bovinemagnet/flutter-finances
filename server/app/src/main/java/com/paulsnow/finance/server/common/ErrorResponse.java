package com.paulsnow.finance.server.common;

import com.fasterxml.jackson.annotation.JsonInclude;

/**
 * The error body every endpoint returns, for example
 * {@code {"error": "CURSOR_EXPIRED", "message": "...", "correlationId": "..."}}.
 *
 * @param error         stable machine-readable code
 * @param message       human-readable explanation without sensitive data
 * @param correlationId opaque identifier to quote to support
 * @author Paul Snow
 * @since 0.0.0
 */
@JsonInclude(JsonInclude.Include.NON_NULL)
public record ErrorResponse(String error, String message, String correlationId) {

    /**
     * Creates a response carrying the current correlation identifier.
     *
     * @param error   code
     * @param message explanation
     * @return the response
     */
    public static ErrorResponse of(String error, String message) {
        return new ErrorResponse(error, message, CorrelationIds.current());
    }
}
