package com.paulsnow.finance.server.storage;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.List;
import java.util.Map;
import java.util.function.Consumer;
import java.util.stream.Collectors;

import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.ApplicationRunner;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;

import com.paulsnow.finance.core.ids.Ids;
import com.paulsnow.finance.server.support.IntegrationTestSupport;

import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.BucketLifecycleConfiguration;
import software.amazon.awssdk.services.s3.model.ExpirationStatus;
import software.amazon.awssdk.services.s3.model.GetBucketLifecycleConfigurationResponse;
import software.amazon.awssdk.services.s3.model.LifecycleExpiration;
import software.amazon.awssdk.services.s3.model.LifecycleRule;
import software.amazon.awssdk.services.s3.model.LifecycleRuleFilter;
import software.amazon.awssdk.services.s3.model.PutBucketLifecycleConfigurationRequest;
import software.amazon.awssdk.services.s3.model.Tag;

/**
 * Object storage lifecycle rules (SEC 06) applied by the worker at
 * start-up, checked against MinIO: staging uploads expire after a day,
 * export archives after the configured retention, incomplete multipart
 * uploads are aborted where the store supports it, and rules the service
 * does not own are kept.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
class StorageLifecycleIntegrationTest extends IntegrationTestSupport {

    private final HttpClient http = HttpClient.newHttpClient();

    @Autowired
    S3Client s3;

    @Autowired
    StorageProperties properties;

    @Autowired
    ObjectStorage storage;

    @Test
    void appliesTheServiceRulesOnceAndKeepsOtherRules() {
        s3.putBucketLifecycleConfiguration(r -> r.bucket(properties.bucket())
                .lifecycleConfiguration(BucketLifecycleConfiguration.builder().rules(LifecycleRule.builder()
                        .id("operator-logs").status(ExpirationStatus.ENABLED)
                        .filter(LifecycleRuleFilter.builder().prefix("logs/").build())
                        .expiration(LifecycleExpiration.builder().days(30).build()).build()).build()));

        StorageLifecycle lifecycle = new StorageLifecycle(s3, properties);
        lifecycle.apply();
        lifecycle.apply();

        // MinIO has no AbortIncompleteMultipartUpload action, so only the expiry
        // rules are applied there (see abortsIncompleteUploadsWhereTheStoreSupportsIt).
        Map<String, LifecycleRule> rules = rules();
        assertThat(rules).containsOnlyKeys("operator-logs", "finance-expire-staging-uploads",
                "finance-expire-exports");
        LifecycleRule staging = rules.get("finance-expire-staging-uploads");
        assertThat(staging.expiration().days()).isEqualTo(1);
        assertThat(tags(staging)).containsExactly(Tag.builder().key("finance-retention").value("staging").build());
        LifecycleRule exports = rules.get("finance-expire-exports");
        assertThat(exports.expiration().days()).isEqualTo(7);
        assertThat(tags(exports)).containsExactly(Tag.builder().key("finance-retention").value("export").build());
        assertThat(rules.values()).allMatch(r -> r.status() == ExpirationStatus.ENABLED);
    }

    @Test
    void abortsIncompleteUploadsWhereTheStoreSupportsIt() {
        S3Client store = mock(S3Client.class);
        when(store.getBucketLifecycleConfiguration(any(Consumer.class))).thenReturn(
                GetBucketLifecycleConfigurationResponse.builder().build());
        new StorageLifecycle(store, properties).apply();

        ArgumentCaptor<Consumer<PutBucketLifecycleConfigurationRequest.Builder>> sent =
                ArgumentCaptor.captor();
        verify(store).putBucketLifecycleConfiguration(sent.capture());
        PutBucketLifecycleConfigurationRequest.Builder request = PutBucketLifecycleConfigurationRequest.builder();
        sent.getValue().accept(request);
        LifecycleRule abort = request.build().lifecycleConfiguration().rules().stream()
                .filter(rule -> "finance-abort-incomplete-uploads".equals(rule.id())).findFirst().orElseThrow();
        assertThat(abort.abortIncompleteMultipartUpload().daysAfterInitiation()).isEqualTo(1);
        assertThat(abort.filter().prefix()).isEmpty();
    }

    @Test
    void exportRetentionIsConfigurableInWholeDays() {
        new StorageLifecycle(s3, withExportRetention(Duration.ofHours(30 * 24 - 1))).apply();
        assertThat(rules().get("finance-expire-exports").expiration().days()).isEqualTo(30);
    }

    @Test
    void stagingUploadsAndExportArchivesCarryTheirRetentionTag() throws Exception {
        String staging = "workspaces/" + Ids.newId() + "/uploads/" + Ids.newId();
        PresignedRequest put = storage.presignPut(staging, "image/png", Retention.STAGING);
        assertThat(put.headers()).containsEntry("x-amz-tagging", "finance-retention=staging");
        HttpRequest.Builder request = HttpRequest.newBuilder(URI.create(put.url()))
                .PUT(HttpRequest.BodyPublishers.ofByteArray(new byte[] { 1, 2, 3 }));
        put.headers().forEach(request::header);
        HttpResponse<String> response = http.send(request.build(), HttpResponse.BodyHandlers.ofString());
        assertThat(response.statusCode()).as(response.body()).isEqualTo(200);
        assertThat(objectTags(staging)).containsEntry("finance-retention", "staging");

        String archive = "workspaces/" + Ids.newId() + "/exports/" + Ids.newId() + ".zip";
        Path file = Files.createTempFile("archive", ".zip");
        try {
            storage.put(archive, file, "application/zip", Retention.EXPORT);
        } finally {
            Files.delete(file);
        }
        assertThat(objectTags(archive)).containsEntry("finance-retention", "export");
    }

    @Test
    void onlyTheWorkerWorkloadAppliesRulesAndOperatorsCanTurnItOff() {
        // Mocks: closing the test context must not close the shared client.
        ApplicationContextRunner runner = new ApplicationContextRunner()
                .withBean(S3Client.class, () -> mock(S3Client.class))
                .withBean(StorageProperties.class, () -> properties)
                .withUserConfiguration(StorageLifecycleConfiguration.class);
        runner.run(context -> assertThat(context).doesNotHaveBean(ApplicationRunner.class));
        runner.withPropertyValues("finance.worker.enabled=true")
                .run(context -> assertThat(context).hasSingleBean(ApplicationRunner.class));
        runner.withPropertyValues("finance.worker.enabled=true", "finance.storage.manage-lifecycle=false")
                .run(context -> assertThat(context).doesNotHaveBean(ApplicationRunner.class));
    }

    private StorageProperties withExportRetention(Duration retention) {
        StorageProperties p = properties;
        return new StorageProperties(p.endpoint(), p.presignEndpoint(), p.region(), p.bucket(), p.accessKey(),
                p.secretKey(), p.pathStyleAccess(), p.createBucket(), p.uploadUrlTtl(), p.downloadUrlTtl(),
                retention);
    }

    private Map<String, LifecycleRule> rules() {
        return s3.getBucketLifecycleConfiguration(r -> r.bucket(properties.bucket())).rules().stream()
                .collect(Collectors.toMap(LifecycleRule::id, r -> r));
    }

    private static List<Tag> tags(LifecycleRule rule) {
        LifecycleRuleFilter filter = rule.filter();
        if (filter.tag() != null) {
            return List.of(filter.tag());
        }
        return filter.and().tags();
    }

    private Map<String, String> objectTags(String key) {
        return s3.getObjectTagging(r -> r.bucket(properties.bucket()).key(key)).tagSet().stream()
                .collect(Collectors.toMap(Tag::key, Tag::value));
    }
}
