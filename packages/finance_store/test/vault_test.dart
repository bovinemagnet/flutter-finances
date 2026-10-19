import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:finance_store/finance_store.dart';
import 'package:test/test.dart';

import 'support/memory_key_store.dart';
import 'support/store_fixtures.dart';

Uint8List jpeg(int size, {int seed = 1}) => Uint8List.fromList([
  0xff,
  0xd8,
  0xff,
  for (var i = 0; i < size - 3; i++) (i * seed) & 0xff,
]);

void main() {
  late TempDir temp;
  late MemoryKeyStore keys;
  late FinanceStore store;
  late ReceiptVault vault;

  setUp(() async {
    temp = TempDir();
    keys = MemoryKeyStore();
    store = await newStore(temp.sub('ws'), keys: keys);
    vault = store.vault;
  });

  tearDown(() async {
    await store.close();
    temp.dispose();
  });

  Future<AssetRecord> saveSource({int size = 2000, int seed = 1}) =>
      vault.saveAsset(
        ownerType: 'receipt',
        ownerId: 'r1',
        kind: VaultAssetKind.source,
        contentType: 'image/jpeg',
        bytes: jpeg(size, seed: seed),
      );

  Future<void> reopen() async {
    await store.close();
    store = await FinanceStore.open(
      temp.sub('ws'),
      keyProtection: KeyProtection.platform(keys),
    );
    vault = store.vault;
  }

  test('saves encrypted bytes and reads them back (REC 03)', () async {
    final bytes = jpeg(5000);
    final record = await saveSource(size: 5000);
    expect(record.sha256, sha256.convert(bytes).toString());
    expect(record.sizeBytes, 5000);
    expect(record.localState, AssetLocalState.present);
    expect(record.uploadState, AssetUploadState.pending);
    final file = vault.fileFor(record);
    expect(file.existsSync(), isTrue);
    final stored = file.readAsBytesSync();
    expect(stored.length, greaterThan(5000));
    expect(
      latin1.decode(stored).contains(latin1.decode(bytes.sublist(100, 200))),
      isFalse,
    );
    expect(await vault.readAsset(record.id), bytes);
    expect(store.isUnsynced(documentAssetType, record.id), isTrue);
    expect(store.pendingCommands().last.command.entityType, documentAssetType);
  });

  test('a saved receipt survives reopening', () async {
    final record = await saveSource();
    await reopen();
    expect(vault.asset(record.id)!.sha256, record.sha256);
    expect(await vault.readAsset(record.id), jpeg(2000));
  });

  test('tampered files are detected', () async {
    final record = await saveSource();
    final file = vault.fileFor(record);
    final bytes = file.readAsBytesSync();
    bytes[bytes.length - 20] ^= 0xff;
    file.writeAsBytesSync(bytes);
    expect(
      () => vault.readAsset(record.id),
      throwsA(isA<AssetCorruptException>()),
    );
  });

  test('previews are stored separately and never uploaded', () async {
    final preview = await vault.saveAsset(
      ownerType: 'receipt',
      ownerId: 'r1',
      kind: VaultAssetKind.preview,
      contentType: 'image/jpeg',
      bytes: jpeg(300),
    );
    expect(vault.fileFor(preview).parent.path, endsWith('previews'));
    expect(preview.uploadState, AssetUploadState.notRequired);
    expect(store.isUnsynced(documentAssetType, preview.id), isFalse);
    expect(vault.assetsFor('receipt', 'r1'), isEmpty);
    expect(
      vault.assetsFor('receipt', 'r1', includePreviews: true),
      hasLength(1),
    );
  });

  test('a low storage error is explicit and records nothing', () async {
    vault.debugBeforeWrite = (_) => throw const FileSystemException(
      'write failed',
      'x',
      OSError('No space left on device', 28),
    );
    final before = store.pendingCommandCount;
    await expectLater(
      saveSource(),
      throwsA(
        isA<StorageWriteException>().having(
          (e) => e.lowStorage,
          'lowStorage',
          isTrue,
        ),
      ),
    );
    expect(vault.assetsFor('receipt', 'r1'), isEmpty);
    expect(store.pendingCommandCount, before);
    expect(vault.storageReport().assetCount, 0);
  });

  test('a failed metadata commit leaves no file behind', () async {
    vault.debugBeforeCommit = () => throw StateError('crash');
    await expectLater(saveSource(), throwsA(isA<StateError>()));
    expect(vault.assetsFor('receipt', 'r1'), isEmpty);
    final files = Directory('${temp.sub('ws').path}/vault')
        .listSync(recursive: true)
        .whereType<File>();
    expect(files, isEmpty);
  });

  test('orphans from a crash before commit are removed on open', () async {
    final kept = await saveSource();
    final assets = Directory('${temp.sub('ws').path}/vault/assets');
    File('${assets.path}/orphan.bin').writeAsBytesSync([1, 2, 3]);
    File('${temp.sub('ws').path}/vault/tmp/half.part')
      ..createSync(recursive: true)
      ..writeAsBytesSync([4]);
    await reopen();
    expect(File('${assets.path}/orphan.bin').existsSync(), isFalse);
    expect(
      File('${temp.sub('ws').path}/vault/tmp/half.part').existsSync(),
      isFalse,
    );
    expect(vault.fileFor(kept).existsSync(), isTrue);
  });

  group('eviction (REC 08, NFR 10)', () {
    test('unsynced originals are never evicted', () async {
      final record = await saveSource();
      await expectLater(
        vault.evictAsset(record.id),
        throwsA(isA<EvictionRefusedException>()),
      );
      final result = await vault.evictToFree(1 << 30);
      expect(result.evictedCount, 0);
      expect(vault.fileFor(record).existsSync(), isTrue);
      expect(await vault.readAsset(record.id), jpeg(2000));
    });

    test('only confirmed cloud copies are evicted', () async {
      final synced = await saveSource(seed: 1);
      final uploadedOnly = await saveSource(seed: 2);
      final unsynced = await saveSource(seed: 3);
      vault.markUploaded(synced.id, cloudConfirmed: true);
      vault.markUploaded(uploadedOnly.id, cloudConfirmed: false);
      final report = vault.storageReport();
      expect(report.evictableBytes, synced.storedBytes);
      expect(
        report.unsyncedBytes,
        uploadedOnly.storedBytes + unsynced.storedBytes,
      );
      final result = await vault.evictToFree(1 << 30);
      expect(result.evictedCount, 1);
      expect(vault.asset(synced.id)!.localState, AssetLocalState.evicted);
      expect(vault.asset(synced.id)!.imagePending, isTrue);
      expect(vault.fileFor(synced).existsSync(), isFalse);
      expect(vault.fileFor(uploadedOnly).existsSync(), isTrue);
      expect(vault.fileFor(unsynced).existsSync(), isTrue);
      await expectLater(
        vault.readAsset(synced.id),
        throwsA(isA<AssetNotLocalException>()),
      );
      await vault.storeDownloaded(synced.id, jpeg(2000, seed: 1));
      expect(await vault.readAsset(synced.id), jpeg(2000, seed: 1));
    });

    test('downloads with the wrong checksum are refused', () async {
      final synced = await saveSource();
      vault.markUploaded(synced.id, cloudConfirmed: true);
      await vault.evictAsset(synced.id);
      await expectLater(
        vault.storeDownloaded(synced.id, jpeg(2000, seed: 9)),
        throwsA(isA<AssetCorruptException>()),
      );
      expect(vault.asset(synced.id)!.localState, AssetLocalState.evicted);
    });
  });

  test('storage report totals by kind', () async {
    await saveSource(size: 1000);
    await vault.saveAsset(
      ownerType: 'receipt',
      ownerId: 'r1',
      kind: VaultAssetKind.derivative,
      contentType: 'image/jpeg',
      bytes: jpeg(500),
    );
    final report = vault.storageReport();
    expect(report.assetCount, 2);
    expect(report.originalBytes, greaterThan(1000));
    expect(report.derivativeBytes, greaterThan(500));
    expect(report.pendingUploadCount, 2);
    expect(report.databaseBytes, greaterThan(0));
    expect(report.totalBytes, greaterThan(1500));
  });

  test(
    'deleting a document removes its file and records a tombstone',
    () async {
      final record = await saveSource();
      await vault.deleteAsset(record.id);
      expect(vault.asset(record.id), isNull);
      expect(vault.fileFor(record).existsSync(), isFalse);
      expect(store.pendingCommands().last.command.type.wire, 'entity.delete');
    },
  );
}
