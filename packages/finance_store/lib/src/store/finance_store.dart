import 'dart:convert';
import 'dart:io';

import 'package:finance_core/finance_core.dart';
import 'package:meta/meta.dart';
import 'package:sqlite3/sqlite3.dart' show Row;

import '../crypto/key_protection.dart';
import '../db/database.dart';
import '../db/migrations.dart';
import '../db/schema.dart';
import '../db/search_index.dart';
import '../vault/receipt_vault.dart';
import 'command_effects.dart';
import 'entity_ref.dart';
import 'ledger_queries.dart';
import 'outbox.dart';
import 'review.dart';
import 'store_context.dart';
import 'workspace.dart';

class ImmutableJournalException implements Exception {
  ImmutableJournalException(this.journalId, this.status);
  final String journalId;
  final JournalStatus status;

  @override
  String toString() =>
      'Journal $journalId is ${status.name}; correct it with a reversal '
      'and replacement instead';
}

class LedgerValidationException implements Exception {
  LedgerValidationException(this.errors);
  final List<LedgerError> errors;

  @override
  String toString() =>
      'Journal rejected: ${errors.map((e) => e.code).join(', ')}';
}

class EntityNotFoundException implements Exception {
  EntityNotFoundException(this.entity);
  final EntityRef entity;

  @override
  String toString() => 'No live entity $entity';
}

/// The most recent local action, while it can still be undone (UX 02).
@immutable
class UndoableAction {
  const UndoableAction({
    required this.commandId,
    required this.type,
    required this.entity,
    required this.createdAt,
    this.description,
  });

  final String commandId;
  final CommandType type;
  final EntityRef entity;
  final DateTime createdAt;
  final String? description;
}

@immutable
class SearchHit {
  const SearchHit(this.ref, this.rank);
  final EntityRef ref;

  /// FTS5 bm25 rank; lower is better.
  final double rank;
}

/// An encrypted local finance workspace.
///
/// Every mutation validates, writes the new local state and appends an
/// outbox command in one SQLite transaction, and completes only after the
/// commit is durable (SYNC 01, NFR 01). The same happens in local-only
/// mode: the outbox is kept, so enabling sync later uploads the complete
/// history in order, and the unsynced indicator simply stays on.
///
/// Mutations return futures; reads are synchronous and run on the calling
/// isolate. Host the store on a background isolate in a UI application.
class FinanceStore {
  FinanceStore._(this._ctx)
    : _ledger = LedgerQueries(_ctx.db, _ctx.settings.currency);

  final StoreContext _ctx;
  final LedgerQueries _ledger;

  static const databaseFileName = 'finance.db';

  /// Internal state shared with the vault, sync client and backups.
  @internal
  StoreContext get context => _ctx;

  /// Creates a new workspace in [directory], which must not already hold
  /// one. A random data key is generated and protected by [keyProtection].
  static Future<FinanceStore> create(
    Directory directory, {
    required KeyProtection keyProtection,
    Currency currency = Currency.aud,
    String timezone = 'Australia/Sydney',
    String locale = 'en_AU',
    SyncMode syncMode = SyncMode.local,
    String? workspaceId,
    String? deviceId,
    Map<String, EntityValidator> validators = const {},
    Map<String, SearchExtractor> searchExtractors = const {},
    DateTime Function() clock = DateTime.now,
    @internal String state = 'active',
  }) async {
    if (File(WorkspaceDescriptor.pathIn(directory)).existsSync()) {
      throw WorkspaceExistsException(directory.path);
    }
    directory.createSync(recursive: true);
    final dbPath = '${directory.path}/$databaseFileName';
    // A database without a descriptor is an interrupted creation.
    for (final suffix in ['', '-wal', '-shm']) {
      final f = File('$dbPath$suffix');
      if (f.existsSync()) f.deleteSync();
    }
    final protected = await keyProtection.create();
    final db = openEncryptedDatabase(dbPath, protected.key.databaseKeyHex);
    try {
      migrate(db, financeMigrations);
      transaction(db, () {
        WorkspaceSettings(
          workspaceId: workspaceId ?? newId(),
          deviceId: deviceId ?? newId(),
          currency: currency,
          timezone: timezone,
          locale: locale,
          syncMode: syncMode,
          createdAt: clock().toUtc(),
        ).insert(db);
      });
    } catch (_) {
      db.close();
      rethrow;
    }
    final descriptor = WorkspaceDescriptor(
      key: protected.descriptor,
      state: state,
    )..write(directory);
    return FinanceStore._(
      StoreContext(
        directory: directory,
        db: db,
        dataKey: protected.key,
        descriptor: descriptor,
        validators: validators,
        extractors: searchExtractors,
        now: clock,
      ),
    ).._afterOpen();
  }

  /// Opens an existing, activated workspace.
  ///
  /// Pending migrations run first; an existing database is copied to
  /// `finance.db.pre-v<n>` before it is upgraded.
  static Future<FinanceStore> open(
    Directory directory, {
    required KeyProtection keyProtection,
    Map<String, EntityValidator> validators = const {},
    Map<String, SearchExtractor> searchExtractors = const {},
    DateTime Function() clock = DateTime.now,
    @internal bool allowStaged = false,
  }) async {
    final descriptor = WorkspaceDescriptor.read(directory);
    if (descriptor.state != 'active' && !allowStaged) {
      throw WorkspaceNotActiveException(descriptor.state);
    }
    final key = await keyProtection.unlock(descriptor.key);
    final dbPath = '${directory.path}/$databaseFileName';
    final db = openEncryptedDatabase(dbPath, key.databaseKeyHex);
    try {
      migrate(
        db,
        financeMigrations,
        beforeUpgrade: (from) {
          db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
          File(dbPath).copySync('$dbPath.pre-v$from');
        },
      );
    } catch (_) {
      db.close();
      rethrow;
    }
    return FinanceStore._(
      StoreContext(
        directory: directory,
        db: db,
        dataKey: key,
        descriptor: descriptor,
        validators: validators,
        extractors: searchExtractors,
        now: clock,
      ),
    ).._afterOpen();
  }

  /// Rewraps a password-protected workspace key under [newPassword].
  static Future<void> changeWorkspacePassword(
    Directory directory,
    String oldPassword,
    String newPassword,
  ) async {
    final descriptor = WorkspaceDescriptor.read(directory);
    descriptor.key = await changePassword(
      descriptor.key,
      oldPassword,
      newPassword,
    );
    descriptor.write(directory);
  }

  void _afterOpen() => vault.removeOrphans();

  /// Encrypted receipt files of this workspace.
  late final ReceiptVault vault = ReceiptVault(_ctx);

  WorkspaceSettings get settings => _ctx.settings;

  Future<void> close() async => _ctx.db.close();

  // Accounts and categories ----------------------------------------------

  Future<Account> createAccount(Account account) async {
    _create(
      EntityRef(EntityTypes.account, account.id),
      accountToJson(account),
      'Create account',
    );
    return account;
  }

  /// Saves the changed fields of [account] as a metadata merge.
  Future<Account> updateAccount(Account account) async {
    _update(
      EntityRef(EntityTypes.account, account.id),
      accountToJson(account),
      'Update account',
    );
    return account;
  }

  Future<Category> createCategory(Category category) async {
    _create(
      EntityRef(EntityTypes.category, category.id),
      categoryToJson(category),
      'Create category',
    );
    return category;
  }

  Future<Category> updateCategory(Category category) async {
    _update(
      EntityRef(EntityTypes.category, category.id),
      categoryToJson(category),
      'Update category',
    );
    return category;
  }

  List<Account> accounts({bool includeArchived = true}) => _ctx.db
      .select(
        'SELECT * FROM accounts WHERE deleted = 0'
        '${includeArchived ? '' : ' AND archived = 0'} ORDER BY name',
      )
      .map(_ctx.state.accountFromRow)
      .toList();

  Account? account(String id) {
    final rows = _ctx.db.select(
      'SELECT * FROM accounts WHERE id = ? AND deleted = 0',
      [id],
    );
    return rows.isEmpty ? null : _ctx.state.accountFromRow(rows.first);
  }

  List<Category> categories({bool includeArchived = true}) => _ctx.db
      .select(
        'SELECT * FROM categories WHERE deleted = 0'
        '${includeArchived ? '' : ' AND archived = 0'} ORDER BY name',
      )
      .map(_ctx.state.categoryFromRow)
      .toList();

  Category? category(String id) {
    final rows = _ctx.db.select(
      'SELECT * FROM categories WHERE id = ? AND deleted = 0',
      [id],
    );
    return rows.isEmpty ? null : _ctx.state.categoryFromRow(rows.first);
  }

  // Transactions -----------------------------------------------------------

  /// Builds a balanced journal from [draft] and saves it with a
  /// `journal.post` command. Giving the id of an existing draft or pending
  /// journal replaces it; posted journals need [correctTransaction].
  Future<Journal> postTransaction(TransactionDraft draft) async {
    final journal = JournalFactory(_ctx.chart()).build(draft);
    return _ctx.write(() {
      _postJournal(journal);
      return journal;
    });
  }

  void _postJournal(Journal journal, {String? description}) {
    final ref = EntityRef(EntityTypes.journal, journal.id);
    final existing = _ctx.state.snapshot(ref);
    if (existing != null && !existing.deleted) {
      final status = JournalStatus.values.byName(
        existing.json['status'] as String,
      );
      if (status.inPostedLedger) {
        throw ImmutableJournalException(journal.id, status);
      }
    }
    _validate(journal);
    _ctx.record(
      _ctx.newCommand(
        type: CommandType.journalPost,
        entity: ref,
        payload: {'journal': journalToJson(journal)},
      ),
      description: description ?? 'Save ${journal.type.name}',
    );
  }

  void _validate(Journal journal) {
    final errors = validatePostings(journal.postings);
    if (errors.isNotEmpty) throw LedgerValidationException(errors);
  }

  /// Corrects a posted journal as a reversal plus an optional replacement
  /// (FIN 07). A null [replacement] voids the journal.
  Future<CorrectionResult> correctTransaction(
    String journalId,
    TransactionDraft? replacement,
  ) async {
    final original = _rawJournal(journalId);
    if (original == null) {
      throw EntityNotFoundException(EntityRef(EntityTypes.journal, journalId));
    }
    if (!original.status.inPostedLedger) {
      throw StateError(
        'Journal $journalId is ${original.status.name}; '
        'edit it with postTransaction',
      );
    }
    final built = replacement == null
        ? null
        : JournalFactory(_ctx.chart()).build(
            TransactionDraft(
              type: replacement.type,
              accountId: replacement.accountId,
              amount: replacement.amount,
              effectiveDate: replacement.effectiveDate,
              counterAccountId: replacement.counterAccountId,
              splits: replacement.splits,
              status: replacement.status,
              payee: replacement.payee,
              notes: replacement.notes,
              tags: replacement.tags,
              refundOf: replacement.refundOf,
              enteredAt: replacement.enteredAt,
            ),
          );
    return _ctx.write(() => _correct(original, built));
  }

  CorrectionResult _correct(Journal original, Journal? replacement) {
    final result = correctJournal(original, replacement);
    _validate(result.reversal);
    if (result.replacement case final r?) _validate(r);
    _ctx.record(
      _ctx.newCommand(
        type: CommandType.journalCorrect,
        entity: EntityRef(EntityTypes.journal, original.id),
        payload: {
          'originalId': original.id,
          'reversal': journalToJson(result.reversal),
          'replacement': result.replacement == null
              ? null
              : journalToJson(result.replacement!),
        },
      ),
      description: replacement == null ? 'Void entry' : 'Correct entry',
    );
    return result;
  }

  /// Deletes a draft or pending journal. Posted journals are immutable.
  Future<void> deleteDraft(String journalId) async {
    final journal = _rawJournal(journalId);
    final ref = EntityRef(EntityTypes.journal, journalId);
    if (journal == null) throw EntityNotFoundException(ref);
    if (journal.status.inPostedLedger) {
      throw ImmutableJournalException(journalId, journal.status);
    }
    _ctx.write(
      () => _ctx.record(
        _ctx.newCommand(
          type: CommandType.entityDelete,
          entity: ref,
          payload: const {},
        ),
        description: 'Delete draft',
      ),
    );
  }

  /// Changes payee, notes or tags of any journal without touching its
  /// postings, through a mergeable `journalAnnotation` entity.
  Future<void> annotateTransaction(
    String journalId, {
    String? payee,
    String? notes,
    Set<String>? tags,
  }) async {
    if (_rawJournal(journalId) == null) {
      throw EntityNotFoundException(EntityRef(EntityTypes.journal, journalId));
    }
    final ref = EntityRef(journalAnnotationType, journalId);
    final current = _ctx.state.json(ref) ?? {'journalId': journalId};
    _ctx.write(
      () => _update(
        ref,
        {
          ...current,
          'payee': ?payee,
          'notes': ?notes,
          if (tags != null) 'tags': tags.toList()..sort(),
        },
        'Annotate entry',
        allowCreate: true,
      ),
    );
  }

  Journal? _rawJournal(String id) {
    final rows = _ctx.db.select(
      'SELECT * FROM journals WHERE id = ? AND deleted = 0',
      [id],
    );
    if (rows.isEmpty) return null;
    return _ctx.state.journalFromRow(
      rows.first,
      _ctx.state.postingsFor([id])[id] ?? const [],
    );
  }

  /// A journal with its annotation applied, or null.
  Journal? journal(String id) {
    final raw = _rawJournal(id);
    return raw == null ? null : _annotate([raw]).single;
  }

  List<Journal> _annotate(List<Journal> journals) {
    if (journals.isEmpty) return journals;
    final annotations = <String, Map<String, Object?>>{};
    final ids = journals.map((j) => j.id).toList();
    for (var i = 0; i < ids.length; i += 500) {
      final part = ids.sublist(i, i + 500 > ids.length ? ids.length : i + 500);
      final rows = _ctx.db.select(
        'SELECT id, json FROM entities WHERE entity_type = ? AND deleted = 0 '
        'AND id IN (${List.filled(part.length, '?').join(',')})',
        [journalAnnotationType, ...part],
      );
      for (final r in rows) {
        annotations[r['id'] as String] =
            (jsonDecode(r['json'] as String) as Map).cast<String, Object?>();
      }
    }
    return [
      for (final j in journals)
        if (annotations[j.id] case final a?)
          j.copyWith(
            payee: a['payee'] as String?,
            notes: a['notes'] as String?,
            tags: (a['tags'] as List?)?.cast<String>().toSet(),
          )
        else
          j,
    ];
  }

  /// Journals newest first, filtered and paged (NFR 09).
  List<Journal> journals({
    LocalDate? from,
    LocalDate? to,
    String? accountId,
    Set<JournalStatus>? statuses,
    int limit = 100,
    int offset = 0,
  }) {
    final where = <String>['deleted = 0'];
    final args = <Object?>[];
    if (from != null) {
      where.add('effective_date >= ?');
      args.add(from.toString());
    }
    if (to != null) {
      where.add('effective_date <= ?');
      args.add(to.toString());
    }
    if (accountId != null) {
      where.add('id IN (SELECT journal_id FROM postings WHERE account_id = ?)');
      args.add(accountId);
    }
    if (statuses != null) {
      where.add('status IN (${List.filled(statuses.length, '?').join(',')})');
      args.addAll(statuses.map((s) => s.name));
    }
    final rows = _ctx.db.select(
      'SELECT * FROM journals WHERE ${where.join(' AND ')} '
      'ORDER BY effective_date DESC, entered_at DESC, id DESC '
      'LIMIT ? OFFSET ?',
      [...args, limit, offset],
    );
    return _journalsFromRows(rows.toList());
  }

  List<Journal> _journalsFromRows(List<Row> rows) {
    final postings = _ctx.state.postingsFor(rows.map((r) => r['id'] as String));
    return _annotate([
      for (final r in rows)
        _ctx.state.journalFromRow(r, postings[r['id']] ?? const []),
    ]);
  }

  /// All live journals as a [LedgerProjection], for code written against
  /// finance_core. Prefer the SQL aggregates for large workspaces.
  LedgerProjection projection() {
    final rows = _ctx.db.select('SELECT * FROM journals WHERE deleted = 0');
    final postings = _ctx.state.postingsFor(rows.map((r) => r['id'] as String));
    return LedgerProjection(_ctx.chart(), [
      for (final r in rows)
        _ctx.state.journalFromRow(r, postings[r['id']] ?? const []),
    ]);
  }

  // SQL aggregates -----------------------------------------------------------

  Money ledgerBalance(
    String ledgerAccountId, {
    LocalDate? asOf,
    bool includePending = false,
  }) => _ledger.ledgerBalance(
    ledgerAccountId,
    asOf: asOf,
    includePending: includePending,
  );

  /// Money held, or money owed for cards and loans.
  Money displayBalance(
    String accountId, {
    LocalDate? asOf,
    bool includePending = false,
  }) {
    final balance = ledgerBalance(
      accountId,
      asOf: asOf,
      includePending: includePending,
    );
    return _ctx.chart().account(accountId).type.isLiability
        ? -balance
        : balance;
  }

  /// Display balances of every live account.
  Map<String, Money> displayBalances({
    LocalDate? asOf,
    bool includePending = false,
  }) {
    final ledger = _ledger.ledgerBalances(
      asOf: asOf,
      includePending: includePending,
    );
    final zero = Money.zero(settings.currency);
    return {
      for (final a in _ctx.chart().accounts)
        a.id: a.type.isLiability
            ? -(ledger[a.id] ?? zero)
            : (ledger[a.id] ?? zero),
    };
  }

  Money expenses(LocalDate from, LocalDate to) => _ledger.expenses(from, to);

  Money income(LocalDate from, LocalDate to) => _ledger.income(from, to);

  Money pendingExpenses(LocalDate from, LocalDate to) =>
      _ledger.pendingExpenses(from, to);

  Money categoryNet(
    String categoryId,
    LocalDate from,
    LocalDate to, {
    bool pending = false,
  }) => _ledger.categoryNet(
    categoryId,
    from,
    to,
    pending: pending,
    isIncome: _ctx.chart().category(categoryId).kind == CategoryKind.income,
  );

  Map<String, Money> categoryTotals(LocalDate from, LocalDate to) =>
      _ledger.categoryTotals(from, to);

  /// Assets less liabilities for accounts included in net worth, plus the
  /// reimbursement receivable.
  Money netWorth({LocalDate? asOf}) {
    final ledger = _ledger.ledgerBalances(asOf: asOf);
    var total =
        ledger[SystemAccounts.reimbursementReceivable] ??
        Money.zero(settings.currency);
    for (final a in _ctx.chart().accounts) {
      if (a.includeInNetWorth && ledger[a.id] != null) total += ledger[a.id]!;
    }
    return total;
  }

  // Generic entities ---------------------------------------------------------

  /// Saves any metadata entity type as JSON (budgets, goals, schedules,
  /// receipts and so on). Only the changed fields are sent: [changedFields]
  /// when given, otherwise the difference from the stored JSON, with
  /// removed keys sent as null.
  Future<EntityRecord> upsertEntity(
    String type,
    String id,
    Map<String, Object?> json, {
    Set<String>? changedFields,
  }) async {
    if (type == EntityTypes.journal) {
      throw ArgumentError('Use postTransaction for journals');
    }
    final ref = EntityRef(type, id);
    _ctx.write(() {
      final current = _ctx.state.snapshot(ref);
      if (current != null && current.deleted) {
        throw StateError('$ref is deleted');
      }
      if (changedFields != null) {
        _ctx.validators[type]?.call({...?current?.json, ...json});
        _record(ref, CommandType.entityUpsert, {
          'fields': {for (final f in changedFields) f: json[f]},
        }, 'Save $type');
      } else {
        _update(ref, json, 'Save $type', allowCreate: true);
      }
    });
    return entity(type, id) ??
        EntityRecord(
          ref: ref,
          json: json,
          revision: 0,
          deleted: false,
          updatedAt: _ctx.now(),
        );
  }

  /// Writes a tombstone for any non-journal entity.
  Future<void> deleteEntity(String type, String id) async {
    if (type == EntityTypes.journal) {
      throw ArgumentError('Use deleteDraft or correctTransaction for journals');
    }
    final ref = EntityRef(type, id);
    if (_ctx.state.json(ref) == null) throw EntityNotFoundException(ref);
    _ctx.write(
      () => _record(ref, CommandType.entityDelete, const {}, 'Delete $type'),
    );
  }

  /// A generic entity, or null when absent or deleted.
  EntityRecord? entity(String type, String id) {
    final rows = _ctx.db.select(
      'SELECT * FROM entities WHERE entity_type = ? AND id = ? AND deleted = 0',
      [type, id],
    );
    return rows.isEmpty ? null : _ctx.state.recordFromRow(rows.first);
  }

  List<EntityRecord> entities(String type, {bool includeDeleted = false}) =>
      _ctx.db
          .select(
            'SELECT * FROM entities WHERE entity_type = ?'
            '${includeDeleted ? '' : ' AND deleted = 0'} ORDER BY id',
            [type],
          )
          .map(_ctx.state.recordFromRow)
          .toList();

  void _create(EntityRef ref, Map<String, Object?> json, String description) {
    _ctx.write(() {
      if (_ctx.state.snapshot(ref) != null) {
        throw StateError('$ref already exists');
      }
      _record(ref, CommandType.entityUpsert, {'fields': json}, description);
    });
  }

  void _update(
    EntityRef ref,
    Map<String, Object?> json,
    String description, {
    bool allowCreate = false,
  }) {
    final current = _ctx.state.json(ref);
    if (current == null && !allowCreate) throw EntityNotFoundException(ref);
    _ctx.validators[ref.type]?.call(json);
    final fields = changedFields(current ?? const {}, json);
    if (fields.isEmpty) return;
    _ctx.write(
      () => _record(ref, CommandType.entityUpsert, {
        'fields': fields,
      }, description),
    );
  }

  void _record(
    EntityRef ref,
    CommandType type,
    Map<String, Object?> payload,
    String description,
  ) => _ctx.record(
    _ctx.newCommand(type: type, entity: ref, payload: payload),
    description: description,
  );

  // Search -------------------------------------------------------------------

  /// Full-text search over payees, notes, tags and receipt text (REC 07).
  List<SearchHit> search(
    String text, {
    Set<String>? entityTypes,
    int limit = 50,
  }) {
    final query = ftsQuery(text);
    if (query == null) return const [];
    final types = entityTypes?.toList();
    final rows = _ctx.db.select(
      'SELECT d.entity_type, d.entity_id, bm25(search_index) AS rank '
      'FROM search_index JOIN search_docs d ON d.doc_id = search_index.rowid '
      'WHERE search_index MATCH ?'
      '${types == null ? '' : ' AND d.entity_type IN (${List.filled(types.length, '?').join(',')})'}'
      ' ORDER BY rank LIMIT ?',
      [query, ...?types, limit],
    );
    return [
      for (final r in rows)
        SearchHit(
          EntityRef(r['entity_type'] as String, r['entity_id'] as String),
          (r['rank'] as num).toDouble(),
        ),
    ];
  }

  /// Transactions matching text, an exact amount or an effective date.
  List<Journal> searchTransactions(String text, {int limit = 50}) {
    final ids = <String>{};
    final trimmed = text.trim();
    int? minor;
    try {
      minor = parseMinor(trimmed, settings.currency.exponent).abs();
    } on FormatException {
      minor = null;
    } on MoneyRangeException {
      minor = null;
    }
    if (minor != null && minor > 0) {
      ids.addAll(
        _ctx.db
            .select(
              'SELECT id FROM journals WHERE deleted = 0 AND amount_minor = ? '
              'ORDER BY effective_date DESC LIMIT ?',
              [minor, limit],
            )
            .map((r) => r['id'] as String),
      );
    }
    if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(trimmed)) {
      ids.addAll(
        _ctx.db
            .select(
              'SELECT id FROM journals WHERE deleted = 0 '
              'AND effective_date = ? LIMIT ?',
              [trimmed, limit],
            )
            .map((r) => r['id'] as String),
      );
    } else {
      ids.addAll(
        search(
          text,
          entityTypes: {EntityTypes.journal},
          limit: limit,
        ).map((h) => h.ref.id),
      );
    }
    final ordered = ids.take(limit).toList();
    final byId = {for (final j in _byIds(ordered)) j.id: j};
    return [for (final id in ordered) ?byId[id]];
  }

  List<Journal> _byIds(List<String> ids) {
    if (ids.isEmpty) return const [];
    final rows = _ctx.db.select(
      'SELECT * FROM journals WHERE id IN '
      '(${List.filled(ids.length, '?').join(',')})',
      ids,
    );
    return _journalsFromRows(rows.toList());
  }

  // Sync status --------------------------------------------------------------

  /// Whether [type]/[id] has local changes the server has not accepted.
  bool isUnsynced(String type, String id) =>
      _ctx.outbox.touchesPending(EntityRef(type, id));

  Set<EntityRef> unsyncedEntities() => _ctx.outbox.pendingKeys();

  int get pendingCommandCount => _ctx.outbox.pendingCount;

  List<OutboxEntry> pendingCommands() => _ctx.outbox.pending();

  // Review of conflicts and rejected commands --------------------------------

  List<ReviewItem> openReviewItems() => _ctx.reviews.open();

  bool hasOpenReview(String type, String id) =>
      _ctx.reviews.hasOpen(EntityRef(type, id));

  /// Keeps the server state and drops the local proposal.
  Future<void> dismissReview(String reviewId) async => _ctx.write(
    () => _ctx.reviews.close(reviewId, ReviewStatus.dismissed, null),
  );

  /// Reapplies the local proposal as a fresh, validated command on top of
  /// the current server state. Entities deleted remotely are recreated
  /// under a new id, never resurrected.
  Future<void> resolveKeepLocal(String reviewId) async {
    final item = _reviewOrThrow(reviewId);
    final commands = item.localCommands;
    final ref = item.entity;
    final deleted = item.kind == ReviewKind.deletedRemotely;
    String? resolution;
    _ctx.write(() {
      final last = commands.last;
      switch (last.type) {
        case CommandType.entityUpsert:
          final proposal = {...?item.localState};
          if (deleted) {
            final newRef = EntityRef(ref.type, newId());
            _record(newRef, CommandType.entityUpsert, {
              'fields': {
                ...proposal,
                if (proposal.containsKey('id')) 'id': newRef.id,
              },
            }, 'Recreate ${ref.type}');
          } else {
            _update(ref, {...?_ctx.state.json(ref), ...proposal}, 'Resolve');
          }
        case CommandType.entityDelete:
          if (!deleted && _ctx.state.json(ref) != null) {
            _record(ref, CommandType.entityDelete, const {}, 'Resolve');
          }
        case CommandType.journalPost:
          final local = journalFromJson(
            postedJournalJson(last.payload),
            settings.currency,
          );
          _postJournal(
            deleted ? _withNewId(local) : local,
            description: 'Resolve',
          );
        case CommandType.journalCorrect:
          final replacement = last.payload['replacement'] as Map?;
          final head = _correctionHead(last.entityId);
          if (head == null) {
            throw StateError('The entry was voided on another device');
          }
          _correct(
            head,
            replacement == null
                ? null
                : _withNewId(
                    journalFromJson(
                      replacement.cast<String, Object?>(),
                      settings.currency,
                    ),
                  ),
          );
      }
      resolution = _ctx.outbox.latestPending()?.command.commandId;
      _ctx.reviews.close(reviewId, ReviewStatus.resolved, resolution);
    });
  }

  /// Resolves a journal review with a replacement the user combined from
  /// both versions. It corrects the current server version of the entry.
  Future<CorrectionResult?> resolveWithTransaction(
    String reviewId,
    TransactionDraft replacement,
  ) async {
    final item = _reviewOrThrow(reviewId);
    if (item.entity.type != EntityTypes.journal) {
      throw ArgumentError('Review $reviewId is not about a journal');
    }
    final head = _correctionHead(item.entity.id);
    if (head == null || !head.status.inPostedLedger) {
      await postTransaction(replacement);
      _ctx.write(
        () => _ctx.reviews.close(
          reviewId,
          ReviewStatus.resolved,
          _ctx.outbox.latestPending()?.command.commandId,
        ),
      );
      return null;
    }
    final result = await correctTransaction(head.id, replacement);
    _ctx.write(
      () => _ctx.reviews.close(
        reviewId,
        ReviewStatus.resolved,
        _ctx.outbox.latestPending()?.command.commandId,
      ),
    );
    return result;
  }

  /// Resolves a metadata review with fields the user chose from both sides.
  Future<void> resolveWithFields(
    String reviewId,
    Map<String, Object?> fields,
  ) async {
    final item = _reviewOrThrow(reviewId);
    _ctx.write(() {
      _update(item.entity, {
        ...?_ctx.state.json(item.entity),
        ...fields,
      }, 'Resolve');
      _ctx.reviews.close(
        reviewId,
        ReviewStatus.resolved,
        _ctx.outbox.latestPending()?.command.commandId,
      );
    });
  }

  ReviewItem _reviewOrThrow(String id) {
    final item = _ctx.reviews.byId(id);
    if (item == null || item.status != ReviewStatus.open) {
      throw StateError('No open review $id');
    }
    return item;
  }

  Journal _withNewId(Journal j) => Journal(
    id: newId(),
    type: j.type,
    status: j.status,
    effectiveDate: j.effectiveDate,
    enteredAt: j.enteredAt,
    postings: j.postings,
    accountId: j.accountId,
    counterAccountId: j.counterAccountId,
    amount: j.amount,
    payee: j.payee,
    notes: j.notes,
    tags: j.tags,
    refundOf: j.refundOf,
  );

  /// Follows replacements from [journalId] to the version currently in
  /// force; null when the chain ends in a void.
  Journal? _correctionHead(String journalId) {
    var current = _rawJournal(journalId);
    while (current != null && current.status == JournalStatus.reversed) {
      final next = _ctx.db.select(
        'SELECT id FROM journals WHERE replaces = ? AND deleted = 0 LIMIT 1',
        [current.id],
      );
      current = next.isEmpty ? null : _rawJournal(next.first['id'] as String);
    }
    return current;
  }

  // Undo ---------------------------------------------------------------------

  /// The latest action when it has never been sent and can be undone.
  UndoableAction? get lastUndoableAction {
    final rows = _ctx.db.select(
      'SELECT seq FROM outbox ORDER BY seq DESC LIMIT 1',
    );
    if (rows.isEmpty) return null;
    final entry = _ctx.outbox.bySeq(rows.first['seq'] as int)!;
    if (entry.status != OutboxStatus.pending ||
        entry.attempts > 0 ||
        !entry.undoable) {
      return null;
    }
    return UndoableAction(
      commandId: entry.command.commandId,
      type: entry.command.type,
      entity: entry.primary,
      createdAt: entry.createdAt,
      description: entry.description,
    );
  }

  /// Restores the state before the latest action and forgets its command.
  /// Returns false when nothing can be undone.
  Future<bool> undoLastAction() async {
    final action = lastUndoableAction;
    if (action == null) return false;
    _ctx.write(() {
      final entry = _ctx.outbox.byCommandId(action.commandId)!;
      for (final e in entry.before.entries.toList().reversed) {
        _ctx.state.restore(e.key, e.value);
      }
      _ctx.outbox.delete(entry.seq);
    });
    return true;
  }
}

/// Fields of [after] that differ from [before]; removed keys map to null.
Map<String, Object?> changedFields(
  Map<String, Object?> before,
  Map<String, Object?> after,
) => {
  for (final e in after.entries)
    if (!before.containsKey(e.key) ||
        jsonEncode(before[e.key]) != jsonEncode(e.value))
      e.key: e.value,
  for (final k in before.keys)
    if (!after.containsKey(k)) k: null,
};
