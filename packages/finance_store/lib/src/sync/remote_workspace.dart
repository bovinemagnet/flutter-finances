import 'package:meta/meta.dart';

/// A workspace on the sync server that the signed-in user belongs to.
@immutable
class RemoteWorkspace {
  const RemoteWorkspace({
    required this.id,
    required this.name,
    required this.currencyCode,
    required this.timezone,
  });

  /// Reads `GET /v1/workspaces` and `POST /v1/workspaces` answers.
  factory RemoteWorkspace.fromJson(Map<String, Object?> json) =>
      RemoteWorkspace(
        id: json['id'] as String,
        name: json['name'] as String,
        currencyCode: json['currency'] as String,
        timezone: json['timezone'] as String,
      );

  final String id;
  final String name;

  /// ISO 4217 code of the single workspace currency.
  final String currencyCode;

  /// IANA timezone deciding local effective dates.
  final String timezone;

  @override
  bool operator ==(Object other) =>
      other is RemoteWorkspace &&
      other.id == id &&
      other.name == name &&
      other.currencyCode == currencyCode &&
      other.timezone == timezone;

  @override
  int get hashCode => Object.hash(id, name, currencyCode, timezone);

  @override
  String toString() => 'RemoteWorkspace($id, $name, $currencyCode, $timezone)';
}
