/**
 * Shared households (P1, SEC 05): single-use workspace invitations with an
 * expiry that another signed-in user accepts, the owner, member and viewer
 * roles, and member removal, which revokes the member's devices at once.
 * What each member may see is decided by the sync module's visibility
 * rules ({@code spec/sync/protocol.md}, "Households").
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@org.springframework.modulith.ApplicationModule(displayName = "Households")
package com.paulsnow.finance.server.households;
