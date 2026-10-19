import 'dart:io';
import 'dart:typed_data';

import 'package:finance_app/data/workspace_gate.dart';
import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:flutter_test/flutter_test.dart';

const _fastKdf = Argon2idParameters(
  memoryKiB: 64,
  iterations: 1,
  parallelism: 1,
);

class _NoKeyStore implements SecureKeyStore {
  @override
  Future<bool> isAvailable() async => false;
  @override
  Future<Uint8List?> read(String name) async => null;
  @override
  Future<void> write(String name, Uint8List material) async {}
  @override
  Future<void> delete(String name) async {}
}

void main() {
  test(
    'a backup restores on a fresh device after verification (A16)',
    () async {
      final root = await Directory.systemTemp.createTemp('restore_test');
      addTearDown(() => root.delete(recursive: true));
      final original = WorkspaceGate(
        Directory('${root.path}/a'),
        _NoKeyStore(),
        kdf: _fastKdf,
      );
      final store = await original.create(
        password: 'device-password',
        timezone: 'Australia/Brisbane',
        locale: 'en_AU',
        syncMode: SyncMode.local,
      );
      await store.createAccount(
        const Account(
          id: 'bank',
          name: 'Everyday',
          type: AccountType.transaction,
        ),
      );
      await store.postTransaction(
        TransactionDraft(
          type: TransactionType.openingBalance,
          accountId: 'bank',
          amount: Money(123456, Currency.aud),
          effectiveDate: LocalDate(2026, 10, 1),
        ),
      );
      await store.vault.saveAsset(
        ownerType: 'receipt',
        ownerId: 'r1',
        kind: VaultAssetKind.source,
        contentType: 'image/png',
        bytes: [1, 2, 3],
      );
      final archive = File('${root.path}/backup.fsbackup');
      await exportBackup(
        store,
        archive,
        recoverySecret: 'recovery-secret',
        kdf: _fastKdf,
      );
      await store.close();

      final fresh = WorkspaceGate(
        Directory('${root.path}/b'),
        _NoKeyStore(),
        kdf: _fastKdf,
      );
      expect(fresh.inspect(), WorkspaceStatus.none);
      final staged = await fresh.stageBackup(
        archive,
        recoverySecret: 'recovery-secret',
        password: 'new-password',
      );
      expect(staged.preview.canActivate, isTrue);
      expect(staged.preview.checksumFailures, isEmpty);
      final restored = await staged.activate();
      expect(restored.displayBalance('bank'), Money(123456, Currency.aud));
      for (final journal in restored.projection().journals) {
        expect(validatePostings(journal.postings), isEmpty);
      }
      await restored.close();
      expect(fresh.inspect(), WorkspaceStatus.locked);
    },
  );
}
