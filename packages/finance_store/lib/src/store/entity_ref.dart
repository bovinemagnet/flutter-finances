import 'package:meta/meta.dart';

/// Entity types with typed tables; every other type is stored generically.
abstract final class EntityTypes {
  static const journal = 'journal';
  static const account = 'account';
  static const category = 'category';
}

/// Identifies one synchronised entity.
@immutable
class EntityRef {
  const EntityRef(this.type, this.id);

  factory EntityRef.parse(String key) {
    final colon = key.indexOf(':');
    return EntityRef(key.substring(0, colon), key.substring(colon + 1));
  }

  final String type;
  final String id;

  String get key => '$type:$id';

  @override
  bool operator ==(Object other) =>
      other is EntityRef && other.type == type && other.id == id;

  @override
  int get hashCode => Object.hash(type, id);

  @override
  String toString() => key;
}

/// A stored metadata entity of any type.
@immutable
class EntityRecord {
  const EntityRecord({
    required this.ref,
    required this.json,
    required this.revision,
    required this.deleted,
    required this.updatedAt,
    this.fieldRevisions = const {},
  });

  final EntityRef ref;
  final Map<String, Object?> json;

  /// Last revision accepted by the server; 0 when never synchronised.
  final int revision;
  final bool deleted;
  final DateTime updatedAt;

  /// Server revision at which each field last changed, as observed.
  final Map<String, int> fieldRevisions;

  String get type => ref.type;
  String get id => ref.id;
}
