package com.paulsnow.finance.server.jobs;

/**
 * A failure that retrying cannot fix. The message is a stable code shown in
 * job status, so it must not contain user data.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public class PermanentJobFailure extends RuntimeException {

    private static final long serialVersionUID = 1L;

    public PermanentJobFailure(String code) {
        super(code);
    }
}
