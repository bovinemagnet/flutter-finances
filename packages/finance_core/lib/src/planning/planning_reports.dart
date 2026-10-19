import 'budget_evaluation.dart';
import 'date_range.dart';
import 'goals.dart';
import 'report.dart';

/// Budget versus actual for one evaluated period, including unbudgeted
/// spending. [labels] maps target ids to display names.
Report budgetVsActual(
  BudgetPeriodEvaluation evaluation, {
  Map<String, String> labels = const {},
  bool includesUnsyncedChanges = false,
}) => Report(
  title: 'Budget and actual',
  keyLabel: 'Budget',
  range: DateRange(evaluation.period.start, evaluation.period.end),
  includesUnsyncedChanges: includesUnsyncedChanges,
  columns: const [
    ReportColumn('planned', 'Planned'),
    ReportColumn('rollover', 'Rollover'),
    ReportColumn('adjustments', 'Adjustments'),
    ReportColumn('actual', 'Actual'),
    ReportColumn('pending', 'Pending'),
    ReportColumn('remaining', 'Remaining'),
  ],
  rows: [
    for (final line in [...evaluation.lines, ...evaluation.unbudgeted])
      ReportRow(
        key: line.targetId,
        label: labels[line.targetId] ?? line.targetId,
        amounts: {
          'planned': line.planned,
          'rollover': line.openingRollover,
          'adjustments': line.adjustments,
          'actual': line.postedNet,
          'pending': line.pending,
          'remaining': line.remaining,
        },
        journalIds: line.journalIds,
      ),
  ],
);

/// Progress toward each goal.
Report goalProgressReport(
  List<GoalProgress> goals, {
  bool includesUnsyncedChanges = false,
}) => Report(
  title: 'Goals',
  keyLabel: 'Goal',
  includesUnsyncedChanges: includesUnsyncedChanges,
  columns: const [
    ReportColumn('target', 'Target'),
    ReportColumn('allocated', 'Allocated'),
    ReportColumn('moved', 'Moved'),
    ReportColumn('reserved', 'Reserved'),
    ReportColumn('fundingGap', 'Funding gap'),
  ],
  rows: [
    for (final progress in goals)
      ReportRow(
        key: progress.goal.id,
        label: progress.goal.name,
        amounts: {
          'target': progress.goal.target,
          'allocated': progress.allocated,
          'moved': progress.moved,
          'reserved': progress.reserved,
          'fundingGap': progress.fundingGap,
        },
        journalIds: progress.journalIds,
      ),
  ],
);
