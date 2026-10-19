package com.paulsnow.finance.core.fixtures;

import tools.jackson.databind.JsonNode;

/**
 * Checks one fixture case and throws an assertion error on mismatch.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@FunctionalInterface
interface FixtureOp {

    void check(JsonNode input, JsonNode expected) throws Exception;
}
