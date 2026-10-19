import 'documents_ops.dart';
import 'ledger_ops.dart';
import 'planning_ops.dart';
import 'reports_ops.dart';

/// Checks one fixture case; throws a test failure on mismatch.
typedef FixtureOp = void Function(
  Map<String, dynamic> input,
  Map<String, dynamic> expected,
);

final Map<String, FixtureOp> fixtureOps = {
  ...ledgerOps,
  ...planningOps,
  ...documentsOps,
  ...reportsOps,
};
