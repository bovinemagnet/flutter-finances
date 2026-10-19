import 'dart:convert';

import 'package:finance_core/finance_core.dart' show nameBasedId;
import 'package:meta/meta.dart';
import 'package:sqlite3/sqlite3.dart';

/// Text indexed for one entity in the FTS5 search index (NFR 03, REC 07).
@immutable
class SearchDocument {
  const SearchDocument({
    this.payee = '',
    this.notes = '',
    this.tags = '',
    this.body = '',
  });

  final String payee;
  final String notes;
  final String tags;

  /// Longer text such as receipt OCR output.
  final String body;

  bool get isEmpty =>
      payee.isEmpty && notes.isEmpty && tags.isEmpty && body.isEmpty;
}

/// Builds the search text for an entity of one type from its JSON.
typedef SearchExtractor = SearchDocument? Function(Map<String, Object?> json);

const _payeeKeys = ['payee', 'merchant', 'merchantName', 'name', 'title'];
const _notesKeys = ['notes', 'note', 'description', 'memo'];
const _bodyKeys = ['text', 'extractedText', 'ocrText', 'rawText', 'body'];

/// Indexes well-known keys of any metadata entity, so receipts and other
/// entity types defined elsewhere are searchable without registration.
SearchDocument defaultSearchDocument(Map<String, Object?> json) {
  String pick(List<String> keys) => [
    for (final k in keys)
      if (json[k] is String) json[k] as String,
  ].join(' ');
  final tags = json['tags'];
  return SearchDocument(
    payee: pick(_payeeKeys),
    notes: pick(_notesKeys),
    tags: tags is List ? tags.whereType<String>().join(' ') : '',
    body: pick(_bodyKeys),
  );
}

/// Replaces the indexed text of one entity; a null or empty [document]
/// removes it. Rows are addressed by rowid through `search_docs`, so an
/// update never scans the index.
void putSearchDocument(
  Database db,
  String entityType,
  String entityId,
  SearchDocument? document,
) {
  final existing = db.select(
    'SELECT doc_id FROM search_docs WHERE entity_type = ? AND entity_id = ?',
    [entityType, entityId],
  );
  int? docId = existing.isEmpty ? null : existing.first['doc_id'] as int;
  if (docId != null) {
    db.execute('DELETE FROM search_index WHERE rowid = ?', [docId]);
  }
  if (document == null || document.isEmpty) {
    if (docId != null) {
      db.execute('DELETE FROM search_docs WHERE doc_id = ?', [docId]);
    }
    return;
  }
  if (docId == null) {
    db.execute(
      'INSERT INTO search_docs (entity_type, entity_id) VALUES (?, ?)',
      [entityType, entityId],
    );
    docId = db.lastInsertRowId;
  }
  db.execute(
    'INSERT INTO search_index (rowid, payee, notes, tags, body) '
    'VALUES (?, ?, ?, ?, ?)',
    [docId, document.payee, document.notes, document.tags, document.body],
  );
}

/// Search text of a journal row, with an optional annotation overlay.
SearchDocument journalSearchDocument({
  String? payee,
  String? notes,
  required List<String> tags,
}) => SearchDocument(
  payee: payee ?? '',
  notes: notes ?? '',
  tags: tags.join(' '),
);

/// Entity type holding user annotations of a journal (payee, notes, tags).
const journalAnnotationType = 'journalAnnotation';

const _journalAnnotationNamespace = '1babbe32-2e00-4fe3-9244-01533ea53450';

/// The id of [journalId]'s annotation entity. Entity ids are unique across
/// entity types in a workspace, so the annotation cannot reuse the
/// journal's id; every device derives the same one, so concurrent
/// annotations of a journal merge field by field (SYNC 03). Its JSON names
/// the journal in `journalId`.
String journalAnnotationId(String journalId) =>
    nameBasedId(_journalAnnotationNamespace, journalId);

/// The id of the single [entityType] entity that belongs to [ownerId], such
/// as an entry's review state. Entity ids are unique across entity types,
/// so such an entity never reuses its owner's id; every device derives the
/// same one offline, so concurrent edits merge field by field.
String ownedEntityId(String entityType, String ownerId) =>
    nameBasedId(_journalAnnotationNamespace, '$entityType:$ownerId');

/// Recomputes the indexed text of a journal, overlaying its annotation.
void reindexJournal(Database db, String journalId) {
  final rows = db.select(
    'SELECT payee, notes, tags_json, deleted FROM journals WHERE id = ?',
    [journalId],
  );
  if (rows.isEmpty || rows.first['deleted'] == 1) {
    putSearchDocument(db, 'journal', journalId, null);
    return;
  }
  var payee = rows.first['payee'] as String?;
  var notes = rows.first['notes'] as String?;
  var tags = decodeTags(rows.first['tags_json']);
  final annotation = db.select(
    'SELECT json FROM entities WHERE entity_type = ? AND id = ? '
    'AND deleted = 0',
    [journalAnnotationType, journalAnnotationId(journalId)],
  );
  if (annotation.isNotEmpty) {
    final a = jsonDecode(annotation.first['json'] as String) as Map;
    if (a.containsKey('payee')) payee = a['payee'] as String?;
    if (a.containsKey('notes')) notes = a['notes'] as String?;
    if (a['tags'] is List) tags = (a['tags'] as List).cast<String>();
  }
  putSearchDocument(
    db,
    'journal',
    journalId,
    journalSearchDocument(payee: payee, notes: notes, tags: tags),
  );
}

List<String> decodeTags(Object? tagsJson) => tagsJson == null
    ? const []
    : (jsonDecode(tagsJson as String) as List).cast<String>();

/// Converts user text into a safe FTS5 query: every word becomes a quoted
/// prefix term, so punctuation cannot inject query syntax.
String? ftsQuery(String text) {
  final words = RegExp(
    r'[\p{L}\p{N}]+',
    unicode: true,
  ).allMatches(text).map((m) => m[0]!).toList();
  if (words.isEmpty) return null;
  return words.map((w) => '"$w"*').join(' ');
}
