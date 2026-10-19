import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:test/test.dart';

import 'support/devices.dart';
import 'support/fake_server.dart';
import 'support/memory_key_store.dart';
import 'support/store_fixtures.dart';

Uint8List jpeg(int size, {int seed = 1}) => Uint8List.fromList([
  0xff,
  0xd8,
  0xff,
  for (var i = 0; i < size - 3; i++) (i * seed + 3) & 0xff,
]);

const secret = 'correct horse battery staple';

void main() {
  late TempDir temp;
  late FinanceStore source;
  late File archive;
  late String sourceId;
  late String derivativeId;

  setUp(() async {
    temp = TempDir();
    source = await newStore(temp.sub('source'));
    await seedChart(source);
    await source.postTransaction(
      TransactionDraft(
        type: TransactionType.openingBalance,
        accountId: 'bank',
        amount: m('500.00'),
        effectiveDate: d('2026-06-30'),
      ),
    );
    final lunch = await source.postTransaction(formulaLunch());
    final original = await source.postTransaction(
      expense('100.00', payee: 'Grocer'),
    );
    await source.correctTransaction(original.id, expense('90.00'));
    await source.postTransaction(
      expense('7.00', status: JournalStatus.pending, payee: 'Cafe'),
    );
    await source.postTransaction(
      expense('3.00', status: JournalStatus.draft, payee: 'Draft'),
    );
    await source.annotateTransaction(lunch.id, notes: 'team lunch');
    await source.upsertEntity('budgetPlan', 'july', {
      'id': 'july',
      'plannedMinor': 50000,
    });
    await source.upsertEntity('receipt', 'r1', {
      'id': 'r1',
      'merchant': 'Grocer',
      'extractedText': 'TOTAL 90.00',
    });
    sourceId = (await source.vault.saveAsset(
      ownerType: 'receipt',
      ownerId: 'r1',
      kind: VaultAssetKind.source,
      contentType: 'image/jpeg',
      bytes: jpeg(30000),
    )).id;
    derivativeId = (await source.vault.saveAsset(
      ownerType: 'receipt',
      ownerId: 'r1',
      kind: VaultAssetKind.derivative,
      contentType: 'image/jpeg',
      bytes: jpeg(9000, seed: 5),
    )).id;
    await source.vault.saveAsset(
      ownerType: 'receipt',
      ownerId: 'r1',
      kind: VaultAssetKind.preview,
      contentType: 'image/jpeg',
      bytes: jpeg(500, seed: 7),
    );
    archive = File('${temp.dir.path}/backup.fsbk');
  });

  tearDown(() async {
    await source.close();
    temp.dispose();
  });

  Future<BackupSummary> export({bool csv = true}) => exportBackup(
    source,
    archive,
    recoverySecret: secret,
    kdf: testKdf,
    includeCsv: csv,
  );

  group('export (DATA 01)', () {
    test('the archive is encrypted and versioned', () async {
      final summary = await export();
      expect(summary.journals, 7);
      expect(summary.assetFiles, 3);
      final bytes = archive.readAsBytesSync();
      expect(ascii.decode(bytes.sublist(0, 8)), 'FSBACKUP');
      final text = latin1.decode(bytes);
      expect(text.contains('Grocer'), isFalse);
      expect(text.contains('plannedMinor'), isFalse);
    });

    test('the manifest lists hashes, counts and relationships', () async {
      await export();
      final entries = await readBackupEntries(archive, secret);
      final manifest =
          jsonDecode(utf8.decode(entries['manifest.json']!)) as Map;
      expect(manifest['formatVersion'], 1);
      expect(manifest['schemaVersion'], syncSchemaVersion);
      expect((manifest['counts'] as Map)['journals'], 7);
      final files = (manifest['files'] as Map).cast<String, Object?>();
      expect(files.keys, contains('files/$sourceId'));
      expect(files.keys, contains('csv/transactions.csv'));
      final relationships = (manifest['relationships'] as List)
          .cast<Map<String, Object?>>();
      expect(
        relationships.map((r) => r['type']).toSet(),
        containsAll(['reversalOf', 'replaces', 'ownedBy', 'annotates']),
      );
      expect(
        (manifest['pendingLocalChanges'] as Map)['count'],
        source.pendingCommandCount,
      );
      expect((manifest['ledger'] as Map)['unbalancedJournals'], isEmpty);
    });

    test('CSV views neutralise spreadsheet formulas', () async {
      await export();
      final entries = await readBackupEntries(archive, secret);
      final csv = utf8.decode(entries['csv/transactions.csv']!);
      expect(csv, contains("'=cmd|calc"));
      expect(csv.split('\n').first, startsWith('id,effectiveDate'));
    });

    test('a wrong recovery secret cannot read the archive', () async {
      await export();
      await expectLater(
        readBackupEntries(archive, 'guess'),
        throwsA(isA<BackupDecryptionException>()),
      );
    });

    test('tampering and truncation are detected', () async {
      await export();
      final bytes = archive.readAsBytesSync();
      final tampered = Uint8List.fromList(bytes)..[bytes.length - 40] ^= 1;
      final t = File('${temp.dir.path}/tampered.fsbk')
        ..writeAsBytesSync(tampered);
      await expectLater(
        readBackupEntries(t, secret),
        throwsA(isA<BackupDecryptionException>()),
      );
      final cut = File('${temp.dir.path}/cut.fsbk')
        ..writeAsBytesSync(bytes.sublist(0, bytes.length - 100));
      await expectLater(
        readBackupEntries(cut, secret),
        throwsA(isA<BackupFormatException>()),
      );
    });
  });

  group('restore (DATA 02, DATA 03, A16)', () {
    test('a fresh device restores, verifies and activates', () async {
      await export();
      final fresh = TempDir();
      addTearDown(fresh.dispose);
      final keys = MemoryKeyStore();
      final target = fresh.sub('restored');
      final staged = await stageRestore(
        archive,
        recoverySecret: secret,
        target: target,
        keyProtection: KeyProtection.platform(keys),
      );
      final preview = staged.preview;
      expect(preview.schemaCompatible, isTrue);
      expect(preview.checksumFailures, isEmpty);
      expect(preview.missingAssets, isEmpty);
      expect(preview.unbalancedJournals, isEmpty);
      expect(preview.countsMatch, isTrue);
      expect(preview.restoredCounts['journals'], 7);
      expect(preview.sourceWorkspaceId, source.settings.workspaceId);
      expect(
        preview.pendingLocalChanges,
        hasLength(source.pendingCommandCount),
      );
      expect(preview.canActivate, isTrue);
      expect(target.existsSync(), isFalse);
      await expectLater(
        FinanceStore.open(
          staged.stagingDirectory,
          keyProtection: KeyProtection.platform(keys),
        ),
        throwsA(isA<WorkspaceNotActiveException>()),
      );

      final restored = await staged.activate();
      addTearDown(restored.close);
      expect(restored.settings.workspaceId, isNot(source.settings.workspaceId));
      expect(restored.settings.syncMode, SyncMode.local);
      expect(restored.settings.currency, source.settings.currency);

      // Journals balance and balances reconcile with the source.
      for (final j in restored.projection().journals) {
        expect(validatePostings(j.postings), isEmpty);
      }
      expect(restored.journals(), hasLength(7));
      for (final id in ['bank', 'card']) {
        expect(
          restored.displayBalance(id, includePending: true),
          source.displayBalance(id, includePending: true),
        );
      }
      expect(restored.netWorth(), source.netWorth());
      expect(restored.searchTransactions('lunch').map((j) => j.notes), [
        'team lunch',
      ]);
      expect(
        restored.entity('budgetPlan', 'july')!.json['plannedMinor'],
        50000,
      );

      // Receipts open and hashes match.
      expect(await restored.vault.readAsset(sourceId), jpeg(30000));
      expect(await restored.vault.readAsset(derivativeId), jpeg(9000, seed: 5));
      expect(
        restored.vault.asset(sourceId)!.sha256,
        source.vault.asset(sourceId)!.sha256,
      );
      expect(restored.vault.assetsFor('receipt', 'r1'), hasLength(2));
    });

    test(
      'a restored workspace can later enable sync and upload everything',
      () async {
        await export();
        final fresh = TempDir();
        addTearDown(fresh.dispose);
        final staged = await stageRestore(
          archive,
          recoverySecret: secret,
          target: fresh.sub('restored'),
          keyProtection: KeyProtection.platform(MemoryKeyStore()),
        );
        final restored = await staged.activate();
        final server = FakeSyncServer(workspaceId: 'ws-new');
        final device = Device.wrap('restored', restored, server);
        addTearDown(device.close);
        final preview = await device.client.previewBootstrap(
          remoteWorkspaceId: 'ws-new',
        );
        expect(preview.action, BootstrapAction.uploadLocal);
        await device.client.enableSync(preview);
        final report = await device.sync();
        expect(report.push.conflicts, 0);
        expect(report.push.rejected, 0);
        expect(server.live('journal'), hasLength(7));
        expect(report.uploads!.uploaded, hasLength(2));
      },
    );

    test('missing files and bad checksums block activation', () async {
      await export();
      final entries = await readBackupEntries(archive, secret);
      entries.remove('files/$sourceId');
      entries['files/$derivativeId'] = Uint8List.fromList([1, 2, 3]);
      final broken = File('${temp.dir.path}/broken.fsbk');
      await writeBackupEntries(broken, entries, secret, kdf: testKdf);
      final staged = await stageRestore(
        broken,
        recoverySecret: secret,
        target: temp.sub('restored'),
        keyProtection: KeyProtection.platform(MemoryKeyStore()),
      );
      expect(staged.preview.missingAssets, contains(sourceId));
      expect(staged.preview.checksumFailures, contains('files/$derivativeId'));
      expect(staged.preview.canActivate, isFalse);
      await expectLater(
        staged.activate(),
        throwsA(isA<RestoreVerificationException>()),
      );
      await staged.discard();
      expect(staged.stagingDirectory.existsSync(), isFalse);
      expect(temp.sub('restored').existsSync(), isFalse);
    });

    test('an archive from a newer format is refused', () async {
      await export();
      final entries = await readBackupEntries(archive, secret);
      final manifest = jsonDecode(
        utf8.decode(entries['manifest.json']!),
      ) as Map<String, Object?>;
      entries['manifest.json'] = utf8.encode(
        jsonEncode({...manifest, 'schemaVersion': syncSchemaVersion + 1}),
      );
      final newer = File('${temp.dir.path}/newer.fsbk');
      await writeBackupEntries(newer, entries, secret, kdf: testKdf);
      final staged = await stageRestore(
        newer,
        recoverySecret: secret,
        target: temp.sub('restored'),
        keyProtection: KeyProtection.platform(MemoryKeyStore()),
      );
      expect(staged.preview.schemaCompatible, isFalse);
      expect(staged.preview.canActivate, isFalse);
      await staged.discard();
    });
  });
}

/// A lunch whose payee looks like a spreadsheet formula.
TransactionDraft formulaLunch() => TransactionDraft(
  type: TransactionType.expense,
  accountId: 'bank',
  amount: m('12.50'),
  effectiveDate: d('2026-07-02'),
  splits: [Split('dining', m('12.50'))],
  payee: '=cmd|calc',
);
