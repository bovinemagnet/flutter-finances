import 'package:meta/meta.dart';

import '../money/money.dart';
import '../time/local_date.dart';
import 'schedules.dart';

/// A what-if applied to a forecast (PLAN 03). Scenarios only change the
/// projection; they never create journals or edit schedules.
@immutable
class Scenario {
  Scenario({
    required this.id,
    required this.name,
    required List<ScenarioChange> changes,
  }) : changes = List.unmodifiable(changes);

  final String id;
  final String name;
  final List<ScenarioChange> changes;
}

/// One hypothetical change. Every forecast line it produces or alters is
/// tagged hypothetical.
@immutable
sealed class ScenarioChange {
  const ScenarioChange(this.id);
  final String id;
}

/// A single hypothetical cash movement; [amount] is signed (negative for
/// money leaving [accountId]).
final class OneOffChange extends ScenarioChange {
  const OneOffChange({
    required String id,
    required this.date,
    required this.accountId,
    required this.amount,
    this.description,
  }) : super(id);

  final LocalDate date;
  final String accountId;
  final Money amount;
  final String? description;
}

/// Projects a schedule's occurrences at a different amount.
final class ScheduleAmountChange extends ScenarioChange {
  const ScheduleAmountChange({
    required String id,
    required this.scheduleId,
    required this.amount,
  }) : super(id);

  final String scheduleId;
  final Money amount;
}

/// Leaves a schedule out of the projection.
final class RemoveScheduleChange extends ScenarioChange {
  const RemoveScheduleChange({required String id, required this.scheduleId})
    : super(id);

  final String scheduleId;
}

/// Projects an additional schedule.
final class AddScheduleChange extends ScenarioChange {
  const AddScheduleChange({required String id, required this.schedule})
    : super(id);

  final RecurringSchedule schedule;
}
