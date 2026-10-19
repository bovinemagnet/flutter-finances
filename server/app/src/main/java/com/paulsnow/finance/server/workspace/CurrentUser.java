package com.paulsnow.finance.server.workspace;

import java.util.UUID;

/**
 * The authenticated caller. Controllers declare it as a parameter.
 *
 * @param id      internal user identifier
 * @param subject OIDC subject claim
 * @author Paul Snow
 * @since 0.0.0
 */
public record CurrentUser(UUID id, String subject) {
}
