import 'package:finance_core/finance_core.dart';

import 'entity_ref.dart';
import 'local_state.dart';

/// The journal carried by a `journal.post` payload.
///
/// The client sends `{"journal": Journal}`; a bare journal object is also
/// accepted when reading, because the protocol text does not fix the shape.
Map<String, Object?> postedJournalJson(Map<String, Object?> payload) =>
    ((payload['journal'] as Map?) ?? payload).cast<String, Object?>();

Map<String, Object?>? _journalField(Map<String, Object?> payload, String key) =>
    (payload[key] as Map?)?.cast<String, Object?>();

/// Every entity a command writes, primary entity first.
List<EntityRef> commandKeys(SyncCommand command) {
  final primary = EntityRef(command.entityType, command.entityId);
  if (command.type != CommandType.journalCorrect) return [primary];
  return [
    primary,
    for (final key in ['reversal', 'replacement'])
      if (_journalField(command.payload, key) case final j?)
        EntityRef(EntityTypes.journal, j['id'] as String),
  ];
}

/// Applies a command's effect to local state and returns the state of each
/// affected entity beforehand.
///
/// The same function serves a fresh user action, and re-applying pending
/// commands as overlays on top of newly pulled server state (SYNC 04).
Map<EntityRef, EntitySnapshot?> applyCommand(
  LocalState state,
  SyncCommand command,
) {
  final before = {for (final k in commandKeys(command)) k: state.snapshot(k)};
  final primary = EntityRef(command.entityType, command.entityId);
  switch (command.type) {
    case CommandType.journalPost:
      state.put(primary, postedJournalJson(command.payload));
    case CommandType.journalCorrect:
      final original = state.json(primary);
      if (original != null) {
        state.put(primary, {...original, 'status': 'reversed'});
      }
      for (final key in ['reversal', 'replacement']) {
        final journal = _journalField(command.payload, key);
        if (journal != null) {
          state.put(
            EntityRef(EntityTypes.journal, journal['id'] as String),
            journal,
          );
        }
      }
    case CommandType.entityUpsert:
      final fields = (command.payload['fields'] as Map).cast<String, Object?>();
      state.put(primary, {...?state.json(primary), ...fields});
    case CommandType.entityDelete:
      state.markDeleted(primary);
  }
  return before;
}
