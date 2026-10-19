/// Encrypted local persistence, receipt vault, backup and sync client for
/// the personal finance application.
library;

export 'src/backup/archive_container.dart'
    show
        BackupDecryptionException,
        BackupFormatException,
        readBackupEntries,
        writeBackupEntries;
export 'src/backup/backup_export.dart'
    show BackupSummary, backupFormatVersion, csvCell, exportBackup;
export 'src/backup/backup_restore.dart';
export 'src/crypto/aead.dart';
export 'src/crypto/data_key.dart';
export 'src/crypto/hkdf.dart';
export 'src/crypto/kdf.dart';
export 'src/crypto/key_protection.dart';
export 'src/db/database.dart'
    show
        EncryptionUnavailableException,
        WrongDatabaseKeyException,
        openEncryptedDatabase;
export 'src/db/migrations.dart';
export 'src/db/schema.dart' show financeMigrations, latestSchemaVersion;
export 'src/db/search_index.dart'
    show
        SearchDocument,
        SearchExtractor,
        defaultSearchDocument,
        journalAnnotationId,
        journalAnnotationType,
        ownedEntityId;
export 'src/store/entity_ref.dart';
export 'src/store/finance_store.dart' hide changedFields;
export 'src/store/local_state.dart' show EntitySnapshot;
export 'src/store/outbox.dart' show OutboxEntry, OutboxStatus;
export 'src/store/review.dart' show ReviewItem, ReviewKind, ReviewStatus;
export 'src/store/store_context.dart' show EntityValidator;
export 'src/store/workspace.dart'
    show
        WorkspaceDescriptor,
        SyncMode,
        WorkspaceExistsException,
        WorkspaceNotActiveException,
        WorkspaceNotFoundException,
        WorkspaceSettings;
export 'src/vault/asset_record.dart' hide uploadStateFromWire, uploadStateWire;
export 'src/vault/receipt_vault.dart';
export 'src/sync/asset_sync.dart'
    show
        AssetNotYetAvailableException,
        UploadPhase,
        UploadProgress,
        UploadSummary;
export 'src/sync/sync_client.dart';
export 'src/sync/transport.dart'
    show
        AccessTokenProvider,
        AuthenticationRequiredException,
        RetryPolicy,
        Sleep,
        SyncHttpException,
        SyncNetworkException;
