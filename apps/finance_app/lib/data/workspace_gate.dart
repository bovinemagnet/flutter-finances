import 'dart:io';

import 'package:finance_store/finance_store.dart';

enum WorkspaceStatus { none, locked, platformProtected }

/// Finds, creates and unlocks the local workspace.
class WorkspaceGate {
  WorkspaceGate(
    this.directory,
    this.keyStore, {
    this.kdf = Argon2idParameters.standard,
  });

  final Directory directory;
  final SecureKeyStore keyStore;
  final Argon2idParameters kdf;

  WorkspaceStatus inspect() {
    try {
      final descriptor = WorkspaceDescriptor.read(directory);
      return descriptor.key['protection'] == 'password'
          ? WorkspaceStatus.locked
          : WorkspaceStatus.platformProtected;
    } on WorkspaceNotFoundException {
      return WorkspaceStatus.none;
    }
  }

  /// Whether a new workspace needs a password because no platform key store
  /// is usable (for example Linux without a Secret Service provider).
  Future<bool> newWorkspaceNeedsPassword() async =>
      !await keyStore.isAvailable();

  Future<FinanceStore> create({
    String? password,
    required String timezone,
    required String locale,
    required SyncMode syncMode,
  }) async {
    final protection = await KeyProtection.select(
      platformStore: keyStore,
      password: password,
      kdf: kdf,
    );
    return FinanceStore.create(
      directory,
      keyProtection: protection,
      timezone: timezone,
      locale: locale,
      syncMode: syncMode,
    );
  }

  Future<FinanceStore> open({String? password}) {
    final protection = password == null
        ? KeyProtection.platform(keyStore)
        : KeyProtection.password(password, kdf: kdf);
    return FinanceStore.open(directory, keyProtection: protection);
  }

  /// Stages a backup into this (empty) workspace location for verification
  /// before it becomes active (DATA 03, A16).
  Future<StagedRestore> stageBackup(
    File archive, {
    required String recoverySecret,
    String? password,
  }) async {
    final protection = await KeyProtection.select(
      platformStore: keyStore,
      password: password,
      kdf: kdf,
    );
    return stageRestore(
      archive,
      recoverySecret: recoverySecret,
      target: directory,
      keyProtection: protection,
    );
  }
}
