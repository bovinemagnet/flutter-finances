# Email Receipt Forwarding Design

Status: approved. Requirement: PRD section 3, P1 receipts, "email forwarding". The PRD excludes "unrestricted mailbox access".

## Why

Many receipts now arrive by email. Today they reach the app only if someone saves the attachment and imports it. Forwarding should be as easy as sending the email to a private address and finding the receipt in the app, ready to review.

## Goals

- Each member of a workspace can turn on a private forwarding address, and can replace or turn off that address at any time.
- A forwarded email's image or PDF attachments become ordinary receipts on the user's device, waiting for review. Images are read by the existing recognition step. PDFs cannot be read today, so their details are entered by hand until PDF reading is added as a separate follow-up.
- A real inbound email service can be added later without changing the rest of the system. Until then, a sandbox provider makes the whole flow testable.

## Non-goals

- Reading anyone's mailbox. The app only sees what is deliberately sent to the address.
- Direct merchant integrations (P2).
- Choosing or paying for a real inbound email service. This design leaves that decision open.
- Reading text from PDFs, a follow-up that would help every PDF receipt and not only emailed ones.
- Capturing emails with no attachment. Their body is never stored, and rendering untrusted HTML on the server is a real security and operational cost, so the user is told instead.
- Keeping a collected receipt private from other workspace members.

## Anti-goals

These would make the feature a failure even if it worked:

- A forwarded email posts a transaction or changes a balance. It may only create a receipt for review.
- Email content appears in logs, notifications, analytics or error reports.
- Someone who guesses or learns another workspace's identifiers can read its documents.
- An email sent to an active address is lost without the user being able to tell what happened to it. Two losses are accepted and explained on the address screen: mail to a replaced or revoked address is dropped, and documents not collected within 30 days expire. Since collection happens on every sync, the second needs a device left unused for a month.

## How it works

1. In Settings, under Sync, the user turns on "Forward receipts by email". The screen explains that the email passes through an outside service and the sync server, that the body is discarded, and that once collected a receipt is shared with the workspace like any other. The app then shows an address such as `k7f2m9q4x1@receipts.example.com`, with a copy action.
2. The user forwards an email to that address. The inbound provider posts it to the server.
3. The server verifies the delivery, finds the address, validates each attachment and stores the accepted ones in private object storage, in a staging area.
4. During its next sync, the app lists waiting documents, downloads each through a short-lived link, and saves it as a receipt on the device.
5. Once the receipt is durably saved locally, the app acknowledges the document and the server deletes its copy.
6. The receipt follows the existing path: text recognition for images, then review, with PDF details entered by hand. It shows "Not matched" until the user acts.

The server never creates a receipt entity or sends a sync command. It holds documents only until the client collects them, which is why no server-originated financial or entity data is needed.

## Server: new `inboundmail` Spring Modulith module

It follows the structure of `bankfeeds`, and reuses `receipts/ContentTypes`, `receipts/DocumentScanner`, `storage/ObjectStorage`, `common/AuditEvent` and `bankfeeds/TokenCipher` (moved to `common` if the module rules require it).

### Provider boundary

```java
public interface InboundMailProvider {
    String id();
    boolean verify(InboundDelivery delivery);       // signature and timestamp, on the raw body
    InboundMessage parse(InboundDelivery delivery); // never trusts declared content types
}
```

`InboundMessage` holds the provider's message id, the recipient address, the sender, the subject and the attachments (name, bytes). Adapters are beans. `SandboxInboundMailProvider` exists only when `finance.inbound-mail.sandbox.enabled` is true, and uses the same `v1=` HMAC-SHA256 signature scheme as `bankfeeds/WebhookReceiver`. A real provider is a new adapter and configuration only.

When no provider is enabled, `GET /v1/inbound-mail/status` returns `{"available": false}` and the app hides the feature.

### Data (`inboundmail.sql` changelog)

- `inbound_address`: `id`, `workspace_id`, `user_id`, `token_sha256` (unique, used for lookup), `token_encrypted` (so the address can be shown again), `created_at`, `revoked_at`. At most one active address per member of a workspace.
- `inbound_message`: `id`, `workspace_id`, `user_id`, `provider`, `provider_message_id`, `sender`, `subject`, `received_at`, `outcome`, `expires_at`. Unique on `(provider, provider_message_id)`, so a repeated delivery is handled once.
- `inbound_document`: `id`, `message_id`, `object_key`, `content_type`, `size_bytes`, `sha256`, `file_name`, `state` (`waiting`, `collected`, `rejected`), `rejection_code`.

The token has at least 128 bits of randomness, encoded in lower-case base32. The body is never stored.

### Endpoints

| Method and path | Purpose | Who |
| --- | --- | --- |
| `POST /v1/inbound-mail/webhooks/{provider}` | Receive a delivery. Permitted without a user token; requires a valid signature | Provider |
| `GET /v1/inbound-mail/status` | Whether the feature is available | Signed-in user |
| `GET`, `PUT`, `DELETE /v1/workspaces/{workspaceId}/inbound-address` | Show, create or replace, and revoke the caller's own address | Owner or member; viewers get `403 READ_ONLY` |
| `GET /v1/workspaces/{workspaceId}/inbound-documents` | The caller's waiting documents and recent outcomes | Owner or member |
| `GET .../inbound-documents/{id}/download` | A short-lived presigned link | Owner of that document |
| `POST .../inbound-documents/{id}/acknowledge` | Mark collected and delete the object. Idempotent | Owner of that document |
| `POST .../inbound-documents/{id}/reject` | The device refused the document (for example an encrypted PDF or too many pages, which the server scan does not check). Records the reason and deletes the object, so it is not retried at every sync | Owner of that document |

An address belongs to one member, and until collection only that member can see what it receives. A collected receipt follows the normal rules in `spec/sync/protocol.md`: it syncs to the workspace unless it links to something hidden from a member. Access to another member's or workspace's document gives the same `404` as a missing one (A17).

### Handling a delivery

The webhook verifies first and rejects an invalid signature with `401`. It then returns `200` for every verified delivery, including an unknown or revoked address, so that the response reveals nothing about which addresses exist; those messages are dropped and audited.

Processing runs as a job through the existing `jobs` module, so a slow scan cannot hold the webhook open:

- Accept JPEG, PNG, HEIC and PDF, identified from the bytes rather than the declared type or extension (SEC 04, REC 05). The server scans each document as it does receipt uploads.
- Limits: 20 MB per attachment (REC 05), 10 attachments per message, and 50 messages per address per day. These are configuration values.
- Ignore inline images under 20 KB, which are almost always logos and signatures.
- Record an outcome for every message: `documents`, `no_attachment`, `rejected`, `rate_limited` or `failed` (a job that fails permanently).

### Retention

- Collected documents are deleted from storage on acknowledgement.
- Uncollected documents, and all message records including sender and subject, are deleted after 30 days by a purger like `BankFeedsPurger`.
- Audit events record the action, workspace and outcome, never the sender, subject or file name.
- Revoking an address stops new deliveries. Documents already waiting can still be collected until they expire.
- Removing a member, or changing their role to viewer, revokes their address and deletes their waiting documents.

## Client

- `finance_store`: `InboundMailClient` beside `BankFeedClient` and `ExtractionClient`, and `.of(client)` access from `SyncController`.
- `apps/finance_app`:
  - After each successful `SyncController.syncNow`, collect waiting documents when an address is active. A failure here never fails or blocks the sync.
  - Save through `state.receipts.capture` with a new `CaptureSource.email`, then acknowledge only after the save succeeds (REC 03). If `capture` refuses the document, call `reject` and show the reason. `receiptFromJson` throws on an unknown source, so a device on an older build would fail reading such a receipt; this is accepted because nothing is released (version `0.0.0+1`, no tags). If the app stops between the two, the next collection must not create a second receipt: the receipt id is derived from the document id with `nameBasedId`.
  - Text recognition starts as for any capture, without blocking collection.
  - A new `ForwardingAddressScreen` reached from `SyncSection`: the explanation, turning on, the address with a copy action, replacing and turning off, and the list of recent outcomes.
  - The Receipts page says when a message arrived with nothing usable, for example "Email from shop@example.com had no attachment". This is how the "never silently lost" anti-goal is met.
- The feature appears only when sync is turned on and the server reports it available.

## Testing

- Java: unit tests for signature checks and limits. `InboundMailIntegrationTest` with Testcontainers covers repeat delivery, unknown address, wrong member and workspace access (A17), a disguised executable, rate limit, acknowledgement deleting the object, and purging.
- Dart: `InboundMailClient` against the shared `FakeSyncServer`, including a crash between save and acknowledgement producing one receipt.
- Flutter: widget tests for the screen, including viewer role and unavailable states, and proof that no journal is created by collection.
- End to end (`tool/e2e/run.sh`): the sandbox provider delivers a PDF, the client collects it, and a receipt appears with no change to any balance.

Documentation: `spec/sync/protocol.md` gains the endpoints, and the Antora receipt pages gain the flow.

## Decisions

Made by the product owner:

- A collected receipt is shared with the workspace, as a scanned one is, and the turn-on screen says so.
- PDF details are entered by hand for now, with PDF reading as a separate follow-up.
- An email with no attachment is reported as having none, and its body is not stored.

Made by the designer, open to change:

- Addresses belong to a member rather than a workspace, and hold documents privately only until collection.
- Limits of 20 MB per attachment, 10 attachments per message and 50 messages per address per day, and ignoring inline images under 20 KB.
- 30-day retention for uncollected documents and for message records, which is an accepted loss when a device goes unused for a month.
- Mail to a replaced or revoked address is dropped without notice to the sender, and the address screen warns of this when replacing.
- `reject` endpoint for documents a device refuses, and a `failed` outcome for permanent job failures.
- Removing a member or making them a viewer revokes their address and deletes their waiting documents.
- A new `CaptureSource.email` without a tolerant decoder, because nothing is released.

## Left to the builder

Package layout within the module, class names beyond those given, job retry settings, screen layout within the app's existing patterns, and the exact wording of messages.
