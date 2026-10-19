import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as hash;
import 'package:finance_core/finance_core.dart';
import 'package:meta/meta.dart';

import '../crypto/kdf.dart';
import '../db/schema.dart';
import '../db/search_index.dart';
import '../store/finance_store.dart';
import '../store/store_context.dart';
import '../sync/sync_engine.dart';
import '../vault/asset_record.dart';
import 'archive_container.dart';

/// Version of the archive's manifest and entry layout.
const backupFormatVersion = 1;

@immutable
class BackupSummary {
  const BackupSummary({
    required this.accounts,
    required this.categories,
    required this.journals,
    required this.entities,
    required this.assetFiles,
    required this.unavailableAssets,
    required this.pendingLocalChanges,
    required this.sizeBytes,
  });

  final int accounts;
  final int categories;
  final int journals;
  final int entities;
  final int assetFiles;

  /// Assets whose bytes were not on the device (evicted or never
  /// downloaded) and so are not in the archive.
  final int unavailableAssets;
  final int pendingLocalChanges;
  final int sizeBytes;
}

/// Exports the whole workspace as an encrypted, versioned archive
/// (DATA 01): JSON for accounts, categories, every journal and every
/// metadata entity, receipt files, pending local commands recorded
/// separately from the accepted state, optional CSV views, and a manifest
/// with SHA-256 hashes, counts and relationships. CSV alone is not a
/// backup.
///
/// Entries, in order: `data/workspace.json`, `data/accounts.json`,
/// `data/categories.json`, `data/journals.json`, `data/entities.json`,
/// `data/assets.json`, `pending_commands.json`, `files/<assetId>`,
/// `csv/transactions.csv`, `csv/accounts.csv`, and `manifest.json` last.
Future<BackupSummary> exportBackup(
  FinanceStore store,
  File target, {
  required String recoverySecret,
  Argon2idParameters kdf = Argon2idParameters.standard,
  bool includeCsv = true,
}) async {
  final ctx = store.context;
  final writer = await ArchiveWriter.create(target, recoverySecret, kdf: kdf);
  try {
    final files = <String, Map<String, Object?>>{};
    void add(String name, List<int> bytes) {
      writer.add(name, bytes);
      files[name] = {
        'sha256': hash.sha256.convert(bytes).toString(),
        'size': bytes.length,
      };
    }

    List<int> json(Object value) => utf8.encode(jsonEncode(value));
    final settings = store.settings;
    add('data/workspace.json', json(_settingsJson(store)));

    final accounts = [
      for (final r in ctx.db.select('SELECT * FROM accounts WHERE deleted = 0'))
        {
          ...accountToJson(ctx.state.accountFromRow(r)),
          'revision': r['revision'],
        },
    ];
    add('data/accounts.json', json(accounts));
    final categories = [
      for (final r in ctx.db.select(
        'SELECT * FROM categories WHERE deleted = 0',
      ))
        {
          ...categoryToJson(ctx.state.categoryFromRow(r)),
          'revision': r['revision'],
        },
    ];
    add('data/categories.json', json(categories));

    final journalRows = ctx.db.select(
      'SELECT * FROM journals WHERE deleted = 0 ORDER BY entered_at, id',
    );
    final postings = ctx.state.postingsFor(
      journalRows.map((r) => r['id'] as String),
    );
    final journals = <Journal>[];
    final journalJson = <Map<String, Object?>>[];
    for (final r in journalRows) {
      final j = ctx.state.journalFromRow(r, postings[r['id']] ?? const []);
      journals.add(j);
      journalJson.add({...journalToJson(j), 'revision': r['revision']});
    }
    add('data/journals.json', json(journalJson));

    final entityRows = ctx.db.select(
      'SELECT * FROM entities WHERE deleted = 0 ORDER BY entity_type, id',
    );
    final entities = [
      for (final r in entityRows)
        {
          'entityType': r['entity_type'],
          'id': r['id'],
          'json': jsonDecode(r['json'] as String),
          'revision': r['revision'],
        },
    ];
    add('data/entities.json', json(entities));

    final assets = store.vault.allAssets();
    final assetJson = [
      for (final a in assets)
        {
          ...a.toEntityJson(),
          'file': a.localState == AssetLocalState.present
              ? 'files/${a.id}'
              : null,
          'localState': a.localState.name,
        },
    ];
    add('data/assets.json', json(assetJson));

    final pending = ctx.outbox.pending();
    add(
      'pending_commands.json',
      json([for (final e in pending) e.command.toJson()]),
    );

    var assetFiles = 0;
    for (final a in assets) {
      if (a.localState != AssetLocalState.present) continue;
      add('files/${a.id}', await store.vault.readAsset(a.id));
      assetFiles++;
    }

    if (includeCsv) {
      add('csv/transactions.csv', utf8.encode(_transactionsCsv(ctx, journals)));
      add('csv/accounts.csv', utf8.encode(_accountsCsv(store)));
    }

    final entityCounts = <String, int>{};
    for (final e in entities) {
      entityCounts.update(
        e['entityType'] as String,
        (n) => n + 1,
        ifAbsent: () => 1,
      );
    }
    final unbalanced = [
      for (final j in journals)
        if (validatePostings(j.postings).isNotEmpty) j.id,
    ];
    final manifest = {
      'format': BackupContainer.format,
      'formatVersion': backupFormatVersion,
      'schemaVersion': syncSchemaVersion,
      'databaseSchemaVersion': latestSchemaVersion,
      'createdAt': ctx.now().toUtc().toIso8601String(),
      'workspace': _settingsJson(store),
      'acceptedState': {
        'cursor': ctx.syncValue(SyncKeys.cursor),
        'lastPullAt': ctx.syncValue(SyncKeys.lastPullAt),
        'acceptedEntities': _acceptedCount(ctx),
        'note':
            'Each record carries the last revision the server accepted; '
            '0 means never synchronised.',
      },
      'pendingLocalChanges': {
        'file': 'pending_commands.json',
        'count': pending.length,
      },
      'counts': {
        'accounts': accounts.length,
        'categories': categories.length,
        'journals': journals.length,
        'postings': journals.fold<int>(0, (n, j) => n + j.postings.length),
        'entities': entityCounts,
        'assets': assets.length,
        'assetFiles': assetFiles,
      },
      'files': files,
      'relationships': _relationships(journals, assets, entities),
      'ledger': {
        'unbalancedJournals': unbalanced,
        'currency': settings.currency.code,
        'exponent': settings.currency.exponent,
      },
    };
    writer.add('manifest.json', json(manifest));
    await writer.close();
    return BackupSummary(
      accounts: accounts.length,
      categories: categories.length,
      journals: journals.length,
      entities: entities.length,
      assetFiles: assetFiles,
      unavailableAssets: assets.length - assetFiles,
      pendingLocalChanges: pending.length,
      sizeBytes: target.lengthSync(),
    );
  } catch (_) {
    writer.abort();
    rethrow;
  }
}

Map<String, Object?> _settingsJson(FinanceStore store) {
  final s = store.settings;
  return {
    'workspaceId': s.workspaceId,
    'currency': s.currency.code,
    'exponent': s.currency.exponent,
    'timezone': s.timezone,
    'locale': s.locale,
    'syncMode': s.syncMode.name,
    'createdAt': s.createdAt.toUtc().toIso8601String(),
  };
}

int _acceptedCount(StoreContext ctx) {
  var n = 0;
  for (final table in ['accounts', 'categories', 'journals', 'entities']) {
    n +=
        ctx.db
                .select('SELECT count(*) FROM $table WHERE revision > 0')
                .first
                .values
                .first
            as int;
  }
  return n;
}

List<Map<String, Object?>> _relationships(
  List<Journal> journals,
  List<AssetRecord> assets,
  List<Map<String, Object?>> entities,
) => [
  for (final j in journals) ...[
    if (j.reversalOf != null)
      {
        'from': 'journal:${j.id}',
        'to': 'journal:${j.reversalOf}',
        'type': 'reversalOf',
      },
    if (j.replaces != null)
      {
        'from': 'journal:${j.id}',
        'to': 'journal:${j.replaces}',
        'type': 'replaces',
      },
    if (j.refundOf != null)
      {
        'from': 'journal:${j.id}',
        'to': 'journal:${j.refundOf}',
        'type': 'refundOf',
      },
  ],
  for (final a in assets)
    {
      'from': '$documentAssetType:${a.id}',
      'to': '${a.ownerType}:${a.ownerId}',
      'type': 'ownedBy',
    },
  for (final e in entities)
    if (e['entityType'] == journalAnnotationType)
      {
        'from': '$journalAnnotationType:${e['id']}',
        'to': 'journal:${(e['json'] as Map)['journalId']}',
        'type': 'annotates',
      },
];

/// Neutralises spreadsheet formula prefixes in user text (EXP 01) and
/// quotes the cell when needed.
String csvCell(String? value) {
  var text = value ?? '';
  if (text.isNotEmpty && '=+-@\t\r'.contains(text[0])) text = "'$text";
  if (text.contains(RegExp('[",\n\r]'))) {
    text = '"${text.replaceAll('"', '""')}"';
  }
  return text;
}

String _transactionsCsv(StoreContext ctx, List<Journal> journals) {
  final exponent = ctx.currency.exponent;
  final categories = {
    for (final r in ctx.db.select('SELECT id FROM categories')) r['id'],
  };
  final out = StringBuffer(
    'id,effectiveDate,status,type,account,amount,payee,notes,tags,categories\n',
  );
  for (final j in journals) {
    final split = [
      for (final p in j.postings)
        if (categories.contains(p.ledgerAccountId))
          '${p.ledgerAccountId}=${formatMinor(p.amount.minor, exponent)}',
    ].join(';');
    out.writeln(
      [
        j.id,
        j.effectiveDate.toString(),
        j.status.name,
        j.type.name,
        csvCell(j.accountId),
        j.amount == null ? '' : formatMinor(j.amount!.minor, exponent),
        csvCell(j.payee),
        csvCell(j.notes),
        csvCell((j.tags.toList()..sort()).join(' ')),
        csvCell(split),
      ].join(','),
    );
  }
  return out.toString();
}

String _accountsCsv(FinanceStore store) {
  final balances = store.displayBalances();
  final exponent = store.settings.currency.exponent;
  final out = StringBuffer('id,name,type,archived,balance\n');
  for (final a in store.accounts()) {
    out.writeln(
      [
        a.id,
        csvCell(a.name),
        a.type.name,
        a.archived,
        formatMinor(balances[a.id]?.minor ?? 0, exponent),
      ].join(','),
    );
  }
  return out.toString();
}
