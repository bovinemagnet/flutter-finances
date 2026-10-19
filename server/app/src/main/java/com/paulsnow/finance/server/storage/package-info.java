/**
 * Private S3-compatible object storage: presigned upload and download URLs,
 * reads for verification and archive writes. Callers build workspace-scoped
 * object keys; this module never decides who may access an object.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@org.springframework.modulith.ApplicationModule(displayName = "Object storage")
package com.paulsnow.finance.server.storage;
