/// Encrypted local persistence, receipt vault, backup and sync client for
/// the personal finance application.
library;

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
    show SearchDocument, SearchExtractor, defaultSearchDocument;
