# Email Receipt Forwarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Forward an email to a private address, and have its image and PDF attachments arrive on the user's device as receipts waiting for review.

**Architecture:** A new `inboundmail` Spring Modulith module verifies provider deliveries, validates attachments in a background job and holds them in private storage. The client collects waiting documents after each sync through a new `InboundMailClient`, saves them through the existing receipt capture path, then acknowledges so the server deletes its copy. The server never creates a receipt or sends a sync command.

**Tech Stack:** Java 25, Spring Boot 4.1, Spring Modulith, PostgreSQL with Liquibase, S3-compatible storage, Dart, Flutter.

**Spec:** `docs/superpowers/specs/2026-11-04-email-receipt-forwarding-design.md`

## Global Constraints

- A forwarded email may only create a receipt for review. It never posts a transaction or changes a balance.
- Email content (sender, subject, file name, body, bytes) never appears in logs, notifications, analytics, error reports or audit details. The body is never stored.
- Accept JPEG, PNG, HEIC and PDF, identified from the bytes, never from the declared type or extension.
- Limits, as configuration: 20 MB per attachment, 10 attachments per message, 50 messages per address per day. Ignore inline images under 20 KB.
- Uncollected documents and all message records are deleted after 30 days. Collected documents are deleted on acknowledgement.
- Another member's or workspace's document gives the same `404` as a missing one (A17). Viewers get `403 READ_ONLY`.
- The token has at least 128 bits of randomness in lower-case base32.
- A failure while collecting never fails or blocks a sync.
- Build with `gradle25w`, never `./gradlew`. Java classes carry `@author Paul Snow` and `@since 0.0.0`. British spelling throughout. Run every package's tests after changing `finance_core` or `finance_store`, writing `flutter test` output to a file and checking the exit code.
- Edit `.adoc` files through the `asciidoc-antora-writer` agent, and check them with `gradle25w antora`.

## Decisions This Plan Adds To The Spec

- **Type detection:** the server has no byte sniffing, because `StructuralDocumentScanner` only checks the type it is told. Task 2 adds `DocumentScanner.detectContentType`.
- **Raw delivery storage:** the webhook stores the raw body under `inbound-mail/raw/<uuid>` with `Retention.STAGING` and enqueues a job, so a slow scan cannot hold the webhook open. Deliveries over `max-delivery-bytes` (default 64 MiB) get `413`, which a provider reports back to the sender.
- **Document storage:** documents go under `inbound-mail/<workspaceId>/<documentId>` with **no** retention tag. `STAGING` objects expire far sooner than 30 days. The purge job removes them.
- **Permanent failures:** a message row starts as outcome `processing`, and the scheduled purge turns rows still `processing` after one hour into `failed`.
- **Idempotent capture:** `capture` makes new page ids on each call, so a retry would duplicate pages. Task 6 adds a `receiptId` parameter that also makes page ids deterministic.
- **Membership changes:** nothing announces them today. Task 4 publishes a `MembershipChanged` event from `WorkspaceDirectory`.
- **Notices on the Receipts page:** the page has no sync controller, so outcomes reach it through `AppState`.

## Review Focus

Each line is pinned by a test in the owning task.

1. **The same document collected twice** (a crash between save and acknowledge, or a retry after a failed acknowledge): one receipt with one set of pages. Two devices racing can at worst raise a reviewable conflict, never lose data (Task 6).
2. **A hostile attachment name or subject** (`../../evil.pdf`, control characters, 1,000 characters): stored bounded and sanitised, and shown only as plain text (Task 2).
3. **A mixed email** (11 attachments, inline logos, one disguised executable): valid ones arrive, and the user is told about the rest (Task 2 and Task 7).
4. **The network failing partway through collection, or an older server without these endpoints:** the sync still succeeds, nothing is acknowledged, and the next sync tries again (Task 6).
5. **A member who loses access with documents waiting:** the address stops working and the documents are removed (Task 4).

---

### Task 1: Module, schema and the forwarding address API

**Files:**
- Create: `server/app/src/main/java/com/paulsnow/finance/server/inboundmail/{package-info,InboundMailProperties,InboundMailConfiguration,InboundAddressStore,InboundAddressService,InboundMailController,InboundMailViews}.java`
- Create: `server/app/src/main/resources/db/changelog/inboundmail.sql`
- Move: `server/.../bankfeeds/TokenCipher.java` and its test to `server/.../common/`, public
- Modify: `db.changelog-master.yaml`, `application.yml`, `application-e2e.yml`, `ModularityTest.java`
- Test: `server/app/src/test/java/com/paulsnow/finance/server/inboundmail/InboundMailIntegrationTest.java`

**Interfaces:**
- Produces: `record InboundMailProperties(String tokenKey, String domain, Map<String,String> webhookSecrets, Duration webhookTolerance, long maxDeliveryBytes, long maxAttachmentBytes, int maxAttachmentsPerMessage, int maxMessagesPerDay, long ignoreInlineBelowBytes, Duration retention)` on `finance.inbound-mail`, with defaults 5m, 64 MiB, 20971520, 10, 50, 20480, 30d.
- Produces: `InboundAddressStore.findActiveByToken(String token) -> Optional<Address>`, where `record Address(UUID id, UUID workspaceId, UUID userId)`.
- Produces: `boolean InboundAddressService.available()`, true when a provider bean exists and both `tokenKey` and `domain` are set.

- [x] **Step 1: Write the failing tests** in `InboundMailIntegrationTest extends IntegrationTestSupport`, with the properties `finance.inbound-mail.sandbox.enabled=true`, a token key, `domain=receipts.test` and a webhook secret:

  - `statusIsAvailableWithAProviderAndKey`: `GET /v1/inbound-mail/status` returns `{"available": true}`. A separate test class with no provider enabled returns `{"available": false}`.
  - `putCreatesAnAddressAndGetShowsItAgain`: `PUT` returns `{"address": "<token>@receipts.test", "createdAt"}` where the local part matches `^[a-z2-7]{26}$`, and `GET` returns the same address.
  - `putReplacesTheAddress`: a second `PUT` returns a different address, and `findActiveByToken` on the old token is empty.
  - `deleteRevokes`: `DELETE` returns 204, then `GET` returns 404.
  - `eachMemberHasTheirOwn`: two members of one workspace get different addresses.
  - `viewerCannotCreate`: `PUT` gives `403` with code `READ_ONLY`.
  - `tokenIsNotStoredInTheClear`: the `inbound_address` row's columns do not contain the token.

- [x] **Step 2: Run them to see them fail**

  Run: `gradle25w :server:app:test --tests '*InboundMailIntegrationTest*'`
  Expected: FAIL, because the endpoints do not exist.

- [x] **Step 3: Implement.** Move `TokenCipher` to `common` and make it public, with `BankFeedsConfiguration` importing it. Write `inboundmail.sql` with these tables, each changeset authored `"Paul Snow"`:

  - `inbound_address (id uuid pk, workspace_id, user_id, token_sha256 char(64) unique, token_encrypted, created_at, revoked_at)` with a partial unique index on `(workspace_id, user_id) where revoked_at is null`.
  - `inbound_message (id uuid pk, workspace_id, user_id, provider varchar(32), provider_message_id varchar(200), sender varchar(320), subject varchar(200), received_at, outcome varchar(16) check in ('processing','documents','no_attachment','rejected','rate_limited','failed'), expires_at)` with unique `(provider, provider_message_id)`.
  - `inbound_document (id uuid pk, message_id references inbound_message on delete cascade, attachment_index int, object_key, content_type, size_bytes bigint, sha256 char(64), file_name varchar(255), state varchar(16) check in ('waiting','collected','rejected'), rejection_code varchar(32), rejection_detail varchar(200))` with unique `(message_id, attachment_index)`.

  Add endpoints as the spec's table gives them, using `CurrentMember`. Add an `InboundAddressService` audit event `inbound_mail.address_changed` with no address in the detail. Add `"inboundmail"` to `ModularityTest`. Add `finance.inbound-mail` to `application.yml` (`token-key: ${FINANCE_INBOUND_MAIL_TOKEN_KEY:}`, `domain: ${FINANCE_INBOUND_MAIL_DOMAIN:}`, `sandbox.enabled: false`) and to `application-e2e.yml` (sandbox enabled, generated key, `domain: receipts.test`, secret from `FINANCE_INBOUND_MAIL_WEBHOOK_SECRET`).

- [x] **Step 4: Run the tests and the module check**

  Run: `gradle25w :server:app:test --tests '*InboundMailIntegrationTest*' --tests '*ModularityTest*' --tests '*BankFeeds*' --tests '*TokenCipherTest*'`
  Expected: PASS.

- [x] **Step 5: Commit** `Add the inbound mail module and forwarding addresses`

### Task 2: Receiving and validating deliveries

**Files:**
- Create: `inboundmail/{InboundMailProvider,InboundDelivery,InboundMessage,SandboxInboundMailProvider,InboundDeliveryReceiver,InboundProcessJobHandler,InboundMessageStore}.java`
- Modify: `common/SecurityConfiguration.java`, `receipts/DocumentScanner.java`, `InboundMailController.java`, `InboundMailConfiguration.java`
- Test: `InboundMailIntegrationTest.java`, `receipts/DocumentScannerTest.java`

**Interfaces:**
- Consumes: `InboundAddressStore.findActiveByToken`, `InboundMailProperties`.
- Produces: `public static Optional<String> DocumentScanner.detectContentType(byte[] bytes)`, using `FF D8 FF` for JPEG, `89 50 4E 47 0D 0A 1A 0A` for PNG, `%PDF-` for PDF, and `ftyp` at offset 4 with brand `heic`, `heix`, `hevc`, `heim`, `heis` or `mif1` for HEIC.
- Produces: `interface InboundMailProvider { String id(); boolean verify(InboundDelivery d); InboundMessage parse(byte[] rawBody); }`
- Produces: `record InboundDelivery(String id, String timestamp, String signature, byte[] body)` and `record InboundMessage(String messageId, String recipient, String sender, String subject, List<Attachment> attachments)` with `record Attachment(String fileName, byte[] bytes, boolean inline)`.
- Sandbox JSON: `{"messageId","to","from","subject","attachments":[{"fileName","contentBase64","inline"}]}`, signed with the `v1=` HMAC-SHA256 of `"<id>.<timestamp>.<raw body>"` as `bankfeeds/WebhookReceiver` does.

- [x] **Step 1: Write the failing tests.** A helper `deliver(json)` signs and posts to `/v1/inbound-mail/webhooks/sandbox`, then runs the job synchronously with the existing test support.

  - `DocumentScannerTest.detectsTypesFromBytes`: each magic number maps to its type. An MZ executable named `receipt.pdf` and an empty array give `Optional.empty()`.
  - `invalidSignatureIsRefused` and `staleTimestampIsRefused`: 401, nothing stored.
  - `unknownProviderIsRefused`: 401, the same as a bad signature.
  - `oversizedDeliveryIsRefused`: 413 above `max-delivery-bytes`.
  - `pdfAttachmentBecomesAWaitingDocument`: outcome `documents`, one `waiting` row, object present with content type `application/pdf`, raw object deleted.
  - `repeatedDeliveryIsHandledOnce`: the same `messageId` twice gives one message and one document.
  - `unknownAndRevokedAddressesLookAccepted`: both return the same 202 body as a valid one, store nothing and raise an audit event `inbound_mail.dropped` whose detail excludes sender and subject.
  - `disguisedFileIsRejected`: an executable declared as `.pdf` gives state `rejected`, code `UNSUPPORTED_TYPE`, no object, outcome `rejected`.
  - `activePdfIsRejected`: a PDF containing `/JavaScript` gives code `ACTIVE_CONTENT`.
  - `noAttachmentIsReported`: outcome `no_attachment`, and no `body` column exists.
  - `mixedMessage`: 11 attachments made of 1 inline 10 KB PNG (ignored, no row), 1 inline 30 KB PNG (kept), 1 disguised file and 8 PDFs. Ten are considered, the eleventh is rejected `TOO_MANY`, outcome `documents`.
  - `tooLargeAttachmentIsRejected`: above `max-attachment-bytes`, code `TOO_LARGE`.
  - `rateLimitApplies`: with the limit set to 2 by test property, the third message in 24 hours has outcome `rate_limited` and no documents.
  - `hostileTextIsBounded`: file name `../../evil\u0000.pdf` is stored as `evil.pdf`, a 1,000-character subject is stored at 200, and neither appears in captured logs.

- [x] **Step 2: Run them to see them fail**

  Run: `gradle25w :server:app:test --tests '*InboundMailIntegrationTest*' --tests '*DocumentScannerTest*'`
  Expected: FAIL.

- [x] **Step 3: Implement.** Permit `POST /v1/inbound-mail/webhooks/**` in `SecurityConfiguration` beside the bank feed rule. The receiver checks size, verifies the signature, stores the raw body and enqueues `inbound_mail.process` with `{"provider","rawKey"}` and no workspace, then returns 202 `{"status":"accepted"}`. The handler parses, resolves the address from the lower-cased local part of the recipient, and inserts the message as `processing`, ignoring a repeat. Then it handles attachments in order, using `(message_id, attachment_index)` so a retried job does not repeat work, sets the final outcome and deletes the raw object. A malformed payload throws `PermanentJobFailure`. Sanitise file names to their base name without control characters, at most 255 characters, and truncate sender and subject to their columns. Register the sandbox bean under `@ConditionalOnProperty("finance.inbound-mail.sandbox.enabled")`.

- [x] **Step 4: Run the tests**

  Run: `gradle25w :server:app:test --tests '*InboundMailIntegrationTest*' --tests '*DocumentScannerTest*'`
  Expected: PASS.

- [x] **Step 5: Commit** `Receive and validate forwarded email deliveries`

### Task 3: Collecting documents

**Files:**
- Create: `inboundmail/InboundDocumentService.java`
- Modify: `InboundMailController.java`, `InboundMailViews.java`, `InboundMessageStore.java`
- Test: `InboundMailIntegrationTest.java`

**Interfaces:**
- Produces, under `/v1/workspaces/{workspaceId}/inbound-documents`:
  - `GET` returns `{"documents":[{"id","fileName","contentType","sizeBytes","sha256","receivedAt"}],"notices":[{"messageId","sender","receivedAt","outcome","rejections":[{"fileName","code","detail"}]}]}`. `notices` holds messages with outcome `no_attachment`, `rejected`, `rate_limited` or `failed`, and those with any rejected document.
  - `GET /{id}/download` returns the same presigned request shape as `/v1/receipts/{id}/assets/{assetId}/download`.
  - `POST /{id}/acknowledge` returns 204, and repeating it also returns 204.
  - `POST /{id}/reject` takes `{"code","detail"}` with `detail` bounded to 200 characters, and returns 204.

- [x] **Step 1: Write the failing tests**

  - `listShowsOnlyTheCallersDocuments`: a second member of the workspace sees none of the first member's.
  - `anotherMemberOrWorkspaceGets404` (A17): download, acknowledge and reject each return the same 404 body as a random id.
  - `acknowledgeDeletesTheObjectAndIsIdempotent`: the object is gone, state is `collected`, the document leaves the list, and a repeat returns 204.
  - `downloadAfterAcknowledgeIs404`.
  - `rejectRecordsTheReasonAndDeletes`: the object is gone, it no longer appears under `documents`, and it does appear under `notices`.
  - `viewerCannotCollect`: `403 READ_ONLY` on all four.
  - `auditHasNoEmailContent`: events for acknowledge and reject contain none of the sender, subject or file name.

- [x] **Step 2: Run them to see them fail**

  Run: `gradle25w :server:app:test --tests '*InboundMailIntegrationTest*'`
  Expected: FAIL.

- [x] **Step 3: Implement** `InboundDocumentService`, finding documents by `(id, workspace_id, user_id)` and throwing `ApiException.notFound("NOT_FOUND", "Not found.")` otherwise.

- [x] **Step 4: Run the tests**

  Run: `gradle25w :server:app:test --tests '*InboundMailIntegrationTest*'`
  Expected: PASS.

- [x] **Step 5: Commit** `Let members collect their forwarded documents`

### Task 4: Retention, workspace deletion and membership changes

**Files:**
- Create: `inboundmail/{InboundMailMaintenance,InboundMailPurger,InboundMailMembershipListener}.java`
- Create: `workspace/MembershipChanged.java`
- Modify: `workspace/WorkspaceDirectory.java`
- Test: `InboundMailIntegrationTest.java`

**Interfaces:**
- Produces: `public record MembershipChanged(UUID workspaceId, UUID userId, String newRole)` with `newRole` null on removal, published inside the transaction from `changeRole` and `removeMember`.
- Produces: `InboundMailPurger implements WorkspaceDataPurger` with step `inboundmail`.

- [x] **Step 1: Write the failing tests**

  - `expiredMessagesAreRemoved`: with the clock moved past 30 days, the sweep removes messages, documents and objects. A 29-day-old message stays.
  - `stuckProcessingBecomesFailed`: a `processing` row older than 1 hour becomes `failed` and appears under `notices`.
  - `removingAMemberRevokesAndDeletes`: the address is revoked, and waiting documents and objects are gone.
  - `demotingToViewerRevokesAndDeletes`: the same.
  - `promotingAViewerChangesNothing`, and `changingOwnerToMemberKeepsTheAddress`.
  - `deletingAWorkspacePurgesEverything`: no rows or objects remain.
  - `revokingKeepsWaitingDocuments`: after `DELETE` on the address, already waiting documents can still be collected.

- [x] **Step 2: Run them to see them fail**

  Run: `gradle25w :server:app:test --tests '*InboundMailIntegrationTest*'`
  Expected: FAIL.

- [x] **Step 3: Implement.** Schedule the sweep with `@Scheduled(cron = "${finance.inbound-mail.purge-cron:0 17 * * * *}", zone = "UTC")`, deleting objects before rows. The listener uses `@EventListener`, so that it commits with the membership change, and acts when `newRole` is null or `viewer`.

- [x] **Step 4: Run the whole server suite**

  Run: `gradle25w :server:app:test`
  Expected: PASS.

- [x] **Step 5: Commit** `Purge forwarded mail and revoke addresses when access is lost`

### Task 5: The Dart client

**Files:**
- Create: `packages/finance_store/lib/src/sync/inbound_mail_client.dart`
- Modify: `packages/finance_store/lib/finance_store.dart`, `packages/finance_store/test/support/fake_server.dart`, `packages/finance_core/lib/src/documents/receipts/receipt.dart`
- Test: `packages/finance_store/test/inbound_mail_client_test.dart`

**Interfaces:**
- Produces: `class InboundMailClient { factory InboundMailClient.of(SyncClient client); Future<bool> available(); Future<InboundAddress?> address(String workspaceId); Future<InboundAddress> createOrReplaceAddress(String workspaceId); Future<void> revokeAddress(String workspaceId); Future<InboundInbox> inbox(String workspaceId); Future<Uint8List> download(String workspaceId, InboundDocument document); Future<void> acknowledge(String workspaceId, String documentId); Future<void> reject(String workspaceId, String documentId, {required String code, String? detail}); }`
- Produces: immutable `InboundAddress(address, createdAt)`, `InboundDocument(id, fileName, contentType, sizeBytes, sha256, receivedAt)`, `InboundNotice(messageId, sender, receivedAt, outcome, rejections)`, `InboundRejection(fileName, code, detail)` and `InboundInbox(documents, notices)`.
- Produces: `class InboundDocumentGoneException implements Exception`, thrown by `download` on 404, and `class InboundDocumentCorruptException implements Exception`, thrown when the downloaded bytes do not match `sha256`.
- Produces: `CaptureSource.email`, added last in the enum so that existing values are unaffected.

- [x] **Step 1: Write the failing tests**, following `bank_feed_client_test.dart` for decoding, and using `FakeSyncServer` with new helpers `deliverInbound(user, {fileName, bytes})` and `addInboundNotice(user, outcome)`:

  - `available` is true on 200 `{"available":true}`, and false on 404 from an older server.
  - `address` returns null on 404. `createOrReplaceAddress` replaces. `revokeAddress` calls DELETE.
  - `inbox` decodes documents and notices, including a notice with rejections.
  - `download` returns the bytes and follows the presigned request.
  - `download` throws `InboundDocumentCorruptException` on a hash mismatch, and `InboundDocumentGoneException` on 404.
  - `acknowledge` and `reject` send the right requests, and `reject` includes `code` and `detail`.
  - In `finance_core`, a receipt with `CaptureSource.email` survives the JSON round trip.

- [x] **Step 2: Run them to see them fail**

  Run: `cd packages/finance_store && dart test test/inbound_mail_client_test.dart`
  Expected: FAIL.

- [x] **Step 3: Implement**, following `BankFeedClient`'s use of `transport.send`. Add the endpoints to `FakeSyncServer`, with an empty inbox by default so that existing sync tests are unaffected.

- [x] **Step 4: Run the package suites**

  Run: `cd packages/finance_core && dart test` then `cd ../finance_store && dart test`
  Expected: PASS.

- [x] **Step 5: Commit** `Add the inbound mail client`

### Task 6: Collecting after each sync

**Files:**
- Create: `apps/finance_app/lib/data/inbound_mail_service.dart`
- Modify: `apps/finance_app/lib/data/receipt_service.dart`, `apps/finance_app/lib/data/sync_controller.dart`, `apps/finance_app/lib/data/app_state.dart`, `apps/finance_app/lib/main.dart`
- Test: `apps/finance_app/test/unit/inbound_mail_service_test.dart`, `apps/finance_app/test/unit/receipt_service_test.dart`

**Interfaces:**
- Consumes: `InboundMailClient`, `CaptureSource.email`.
- Produces: `ReceiptService.capture(List<CapturedFile> files, {String? receiptId})`. With a `receiptId`, it returns the existing receipt if one is live, and otherwise derives page ids with `nameBasedId(receiptId, '<sourceIndex>-<pageIndex>')`.
- Produces: `class InboundMailService { InboundMailService({required AppState state, required InboundMailClient client, required String workspaceId, TextRecogniser? recogniser}); Future<void> collect(); }`. It is single-flight, so a call during a running collection returns at once.
- Produces: `AppState.inboundNotices -> List<InboundNotice>`, and `AppState.setInboundNotices(List<InboundNotice>)`, held in memory, excluding dismissed ones. `AppState.dismissInboundNotice(String messageId)` is stored in preferences under `dismissedInboundNotices`.
- Produces: `SyncController({..., TextRecogniser? recogniser})`, and `InboundMailClient get inboundMail`.

- [x] **Step 1: Write the failing tests** against `FakeSyncServer`:

  - `receipt_service_test`: `captureWithSameIdMakesOneReceipt`: capturing twice with one `receiptId` gives one receipt and one set of pages, and `partialCaptureRetryDoesNotDuplicatePages`: pages written with no receipt entity, then a retry, gives each page once.
  - `collectSavesThenAcknowledges`: one receipt with `CaptureSource.email`, id `nameBasedId('inbound-receipt', documentId)`, and the server's document is acknowledged.
  - `collectCreatesNoFinancialData`: journal count and every balance are unchanged (spec anti-goal).
  - `crashBeforeAcknowledgeMakesOneReceipt`: with `acknowledge` failing once, a second `collect` gives one receipt and then acknowledges.
  - `refusedDocumentIsRejectedAndNotRetried`: a 11-page PDF makes `reject` run with code `REJECTED_ON_DEVICE` and the message as detail, and a second `collect` does nothing.
  - `corruptDownloadIsNotSaved`: no receipt and no acknowledge, and it is retried on the next collect.
  - `goneDocumentIsSkipped`: a 404 on download leaves no receipt and no error, and other documents still arrive.
  - `networkFailureDoesNotThrow`: `collect` completes when the inbox request fails, with nothing acknowledged.
  - `olderServerIsTolerated`: a 404 on the inbox does not throw.
  - `imagesAreReadAndPdfsAreNot`: `recogniser.recognise` runs for an image and is not called for a PDF, and a recognition failure keeps the receipt.
  - `noticesReachAppState`, and `dismissedNoticesStayHidden`.
  - `syncCollectsAfterSucceeding`, and `syncStaysIdleWhileCollecting`: `phase` is `idle` before collection ends. A throwing collection leaves `phase` idle with no `lastError`. A failed sync does not collect.
  - `localWorkspacesNeverCollect`: no inbox request when not synced.

- [x] **Step 2: Run them to see them fail**

  Run: `cd apps/finance_app && flutter test test/unit/inbound_mail_service_test.dart test/unit/receipt_service_test.dart > /tmp/out.txt 2>&1; echo $?`
  Expected: non-zero.

- [x] **Step 3: Implement.** Call `unawaited(_inboundService.collect())` at the end of a successful `syncNow`, after `phase` is `idle`, with `collect` catching everything. Handle documents one at a time, so one failure does not stop the rest. Treat `ReceiptRejectedException` as the only refusal; other errors leave the document waiting. In `main.dart`, pass `services.textRecogniser` to `SyncController`.

- [x] **Step 4: Run all app tests**

  Run: `cd apps/finance_app && flutter test > /tmp/out.txt 2>&1; echo $?; tail -1 /tmp/out.txt`
  Expected: 0, all pass.

- [x] **Step 5: Commit** `Collect forwarded receipts after each sync`

### Task 7: The address screen and notices

**Files:**
- Create: `apps/finance_app/lib/features/sync/forwarding_address_screen.dart`
- Modify: `apps/finance_app/lib/features/sync/sync_section.dart`, `apps/finance_app/lib/features/receipts/receipts_page.dart`
- Test: `apps/finance_app/test/widget/forwarding_address_screen_test.dart`, `apps/finance_app/test/widget/inbound_notices_test.dart`

**Interfaces:**
- Consumes: `SyncController.inboundMail`, `AppState.inboundNotices`, `AppState.dismissInboundNotice`.
- Produces: `class ForwardingAddressScreen extends StatefulWidget { const ForwardingAddressScreen({super.key, required this.controller}); }`

- [x] **Step 1: Write the failing tests**, following `bank_feeds_screen_test.dart`:

  - `explainsBeforeTurningOn`: the text covers the outside service, the sync server, the discarded body, and that collected receipts are shared with the workspace.
  - `turningOnShowsTheAddressWithCopy`: the address appears, and copy places it on the clipboard.
  - `replacingWarnsTheOldAddressStops`: a confirmation names that mail to the old address is dropped, and Cancel changes nothing.
  - `turningOffKeepsWaitingDocumentsAndSaysSo`.
  - `explainsExpiry`: the screen says documents not collected within 30 days expire.
  - `viewerSeesWhyNot`: on `403 READ_ONLY`, a message appears and no address.
  - `tileHiddenWhenUnavailable`: `SyncSection` shows "Forward receipts by email" only when synced and `available()` is true, and an error from `available()` hides it without an exception.
  - `noticesExplainWhatHappened`: on the Receipts page, `no_attachment` shows "Email from shop@example.com had no attachment", and `rejected`, `rate_limited` and `failed` each show their own message, with rejection file names as plain text.
  - `noticeCanBeDismissed`: Dismiss removes it and calls `dismissInboundNotice`.
  - The new screen passes `labeledTapTargetGuideline` and `androidTapTargetGuideline`.

- [x] **Step 2: Run them to see them fail**

  Run: `cd apps/finance_app && flutter test test/widget/forwarding_address_screen_test.dart test/widget/inbound_notices_test.dart > /tmp/out.txt 2>&1; echo $?`
  Expected: non-zero.

- [x] **Step 3: Implement**, using only `FinancePalette` colours, and following `bank_feeds_screen.dart` for loading and error states.

- [x] **Step 4: Run all app tests and the analyser**

  Run: `cd apps/finance_app && flutter test > /tmp/out.txt 2>&1; echo $?; flutter analyze`
  Expected: 0, and "No issues found!".

- [x] **Step 5: Commit** `Add the forwarding address screen and receipt notices`

### Task 8: End to end and documentation

**Files:**
- Modify: `packages/finance_store/test/e2e/sync_e2e_test.dart`, `tool/e2e/run.sh`, `spec/sync/protocol.md`, `CLAUDE.md`
- Modify through the `asciidoc-antora-writer` agent: the receipt capture page under `src/docs/modules/platform/pages/`, adding the flow and limits

- [x] **Step 1: Write the e2e test** `email forwarding: a sandbox delivery becomes a document that is collected once`: a signed delivery of a PDF to the sandbox webhook, then listing, downloading and acknowledging it, confirming the same bytes arrive, and that a second listing is empty and a journal count taken from the server is unchanged. Have `tool/e2e/run.sh` generate `FINANCE_INBOUND_MAIL_TOKEN_KEY` and `FINANCE_INBOUND_MAIL_WEBHOOK_SECRET`.

- [x] **Step 2: Run it**

  Run: `FINANCE_E2E_SKIP_BUILD= tool/e2e/run.sh`
  Expected: PASS. Containers run through Podman; set `CONTAINER_ENGINE=docker` if Podman is unavailable.

- [x] **Step 3: Update the docs.** Add the endpoints, outcomes and rejection codes to `spec/sync/protocol.md`. Add `inboundmail` to the P1 server modules line of `CLAUDE.md`, stating that only the `sandbox` provider exists until an inbound email service is chosen, and add `InboundMailClient` to the client list. Run `gradle25w antora`.

- [x] **Step 4: Run every suite**

  Run: `gradle25w build`, `cd packages/finance_core && dart test`, `cd packages/finance_store && dart test`, `cd apps/finance_app && flutter test`, `flutter analyze`
  Expected: all pass.

- [x] **Step 5: Commit** `Test email forwarding end to end and document it`
