/**
 * Identity and tenancy: users keyed by their OIDC subject, workspaces with
 * a currency and timezone, memberships and devices. Every request resolves
 * the caller's workspace here; possession of an identifier is never
 * permission.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@org.springframework.modulith.ApplicationModule(displayName = "Workspace")
package com.paulsnow.finance.server.workspace;
