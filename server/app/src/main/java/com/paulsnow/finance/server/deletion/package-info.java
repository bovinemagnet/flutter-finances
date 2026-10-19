/**
 * Workspace deletion (SEC 05, SEC 06). A request revokes every device and
 * hides the workspace at once, records a deletion suppression entry, and
 * queues a tracked job that erases documents and every module's metadata
 * and indexes through {@link com.paulsnow.finance.server.deletion.WorkspaceDataPurger}
 * implementations.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@org.springframework.modulith.ApplicationModule(displayName = "Deletion")
package com.paulsnow.finance.server.deletion;
