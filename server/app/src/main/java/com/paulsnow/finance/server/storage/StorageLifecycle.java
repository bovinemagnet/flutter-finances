package com.paulsnow.finance.server.storage;

import java.time.Duration;
import java.util.ArrayList;
import java.util.List;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.AbortIncompleteMultipartUpload;
import software.amazon.awssdk.services.s3.model.BucketLifecycleConfiguration;
import software.amazon.awssdk.services.s3.model.ExpirationStatus;
import software.amazon.awssdk.services.s3.model.LifecycleExpiration;
import software.amazon.awssdk.services.s3.model.LifecycleRule;
import software.amazon.awssdk.services.s3.model.LifecycleRuleAndOperator;
import software.amazon.awssdk.services.s3.model.LifecycleRuleFilter;
import software.amazon.awssdk.services.s3.model.S3Exception;
import software.amazon.awssdk.services.s3.model.Tag;

/**
 * The bucket lifecycle rules the service owns (SEC 06):
 * <ul>
 * <li>{@value #ABORT_RULE}: abort incomplete multipart uploads one day
 * after they start, where the store supports that action (MinIO does not,
 * and removes stale multipart uploads itself);</li>
 * <li>{@value #STAGING_RULE}: expire staging uploads
 * ({@code workspaces/{id}/uploads/}, tagged {@link Retention#STAGING}) one
 * day after they were written;</li>
 * <li>{@value #EXPORT_RULE}: expire export archives
 * ({@code workspaces/{id}/exports/}, tagged {@link Retention#EXPORT}) after
 * {@link StorageProperties#exportRetention()}, rounded up to whole
 * days.</li>
 * </ul>
 * Applying replaces the rules whose identifier starts with
 * {@value #RULE_PREFIX} and keeps every other rule, so it is idempotent and
 * leaves operators' own rules alone.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
class StorageLifecycle {

    static final String RULE_PREFIX = "finance-";
    static final String ABORT_RULE = "finance-abort-incomplete-uploads";
    static final String STAGING_RULE = "finance-expire-staging-uploads";
    static final String EXPORT_RULE = "finance-expire-exports";

    private static final Logger LOG = LoggerFactory.getLogger(StorageLifecycle.class);
    private static final String WORKSPACES = "workspaces/";

    private final S3Client client;
    private final StorageProperties properties;

    StorageLifecycle(S3Client client, StorageProperties properties) {
        this.client = client;
        this.properties = properties;
    }

    /** Puts the service's rules on the bucket, keeping rules it does not own. */
    void apply() {
        List<LifecycleRule> rules = new ArrayList<>();
        for (LifecycleRule rule : existingRules()) {
            if (rule.id() == null || !rule.id().startsWith(RULE_PREFIX)) {
                rules.add(rule);
            }
        }
        rules.add(expire(STAGING_RULE, Retention.STAGING, 1));
        int exportDays = wholeDays(properties.exportRetention());
        rules.add(expire(EXPORT_RULE, Retention.EXPORT, exportDays));
        List<LifecycleRule> withAbort = new ArrayList<>(rules);
        withAbort.add(LifecycleRule.builder().id(ABORT_RULE).status(ExpirationStatus.ENABLED)
                .filter(LifecycleRuleFilter.builder().prefix("").build())
                .abortIncompleteMultipartUpload(AbortIncompleteMultipartUpload.builder().daysAfterInitiation(1)
                        .build())
                .build());
        try {
            put(withAbort);
        } catch (S3Exception e) {
            if (e.statusCode() != 400 && e.statusCode() != 501) {
                throw e;
            }
            // MinIO has no AbortIncompleteMultipartUpload action and rejects the
            // whole configuration; it removes stale multipart uploads itself
            // (after 24 hours by default).
            LOG.warn("Bucket {} rejected the rule aborting incomplete multipart uploads ({}); applying the "
                    + "expiry rules without it", properties.bucket(), e.awsErrorDetails().errorCode());
            put(rules);
        }
        LOG.info("Applied lifecycle rules to bucket {}: staging uploads expire after 1 day, exports after {} days",
                properties.bucket(), exportDays);
    }

    private void put(List<LifecycleRule> rules) {
        client.putBucketLifecycleConfiguration(r -> r.bucket(properties.bucket())
                .lifecycleConfiguration(BucketLifecycleConfiguration.builder().rules(rules).build()));
    }

    private List<LifecycleRule> existingRules() {
        try {
            return client.getBucketLifecycleConfiguration(r -> r.bucket(properties.bucket())).rules();
        } catch (S3Exception e) {
            if (e.statusCode() == 404) {
                // NoSuchLifecycleConfiguration: the bucket has no rules yet.
                return List.of();
            }
            throw e;
        }
    }

    private static LifecycleRule expire(String id, Retention retention, int days) {
        return LifecycleRule.builder().id(id).status(ExpirationStatus.ENABLED)
                .filter(LifecycleRuleFilter.builder().and(LifecycleRuleAndOperator.builder().prefix(WORKSPACES)
                        .tags(Tag.builder().key(Retention.TAG_KEY).value(retention.tagValue()).build()).build())
                        .build())
                .expiration(LifecycleExpiration.builder().days(days).build())
                .build();
    }

    private static int wholeDays(Duration duration) {
        long days = duration.toDays();
        if (duration.compareTo(Duration.ofDays(days)) > 0) {
            days++;
        }
        return (int) Math.max(1, Math.min(days, Integer.MAX_VALUE));
    }
}
