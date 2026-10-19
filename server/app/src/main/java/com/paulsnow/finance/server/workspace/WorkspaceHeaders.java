package com.paulsnow.finance.server.workspace;

/**
 * Request headers that select the workspace and device.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public final class WorkspaceHeaders {

    /** Workspace the caller acts on. */
    public static final String WORKSPACE = "X-Workspace-Id";

    /** Registered device the caller acts through. */
    public static final String DEVICE = "X-Device-Id";

    private WorkspaceHeaders() {
    }
}
