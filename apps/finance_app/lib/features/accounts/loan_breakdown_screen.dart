import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/theme.dart';
import '../../format/formatters.dart';
import '../../screens/pages/reports_page.dart' show RangeChoice;

/// A loan's principal repaid, interest and fees shown apart (BUD 06).
/// Principal reduces what is owed and is not spending; interest and fees
/// are. The user chooses which categories hold the loan's interest and fees.
class LoanBreakdownScreen extends StatefulWidget {
  const LoanBreakdownScreen({super.key, required this.accountId});

  final String accountId;

  @override
  State<LoanBreakdownScreen> createState() => _LoanBreakdownScreenState();
}

class _LoanBreakdownScreenState extends State<LoanBreakdownScreen> {
  RangeChoice _range = RangeChoice.thisFinancialYear;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final account = state.chart.account(widget.accountId);
    final today = state.today();
    final period = _range.dateRange(today);
    // A period that runs past today shows what is owed today.
    final end = period.end > today ? today : period.end;
    final summary = state.loanSummary(
      widget.accountId,
      DateRange(period.start, end),
    );
    final chosen = state.loanCategories(widget.accountId);
    final interestId = chosen.interest.firstOrNull;
    final feesId = chosen.fees.firstOrNull;

    Widget figure(String label, Money amount, {String? note}) => ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      subtitle: note == null ? null : Text(note),
      trailing: Text(
        formatMoney(amount),
        style: FinancePalette.of(context).figure(size: 16),
      ),
    );

    Widget categoryField(
      String label,
      String? selected,
      String? excluded,
      void Function(String?) onChanged,
    ) => DropdownButtonFormField<String>(
      initialValue: selected,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        const DropdownMenuItem(child: Text('None')),
        for (final c in state.chart.categories)
          if (c.kind == CategoryKind.expense &&
              c.id != excluded &&
              (!c.archived || c.id == selected))
            DropdownMenuItem(
              value: c.id,
              child: Text(c.name, overflow: TextOverflow.ellipsis),
            ),
      ],
      onChanged: onChanged,
    );

    return Scaffold(
      appBar: AppBar(title: Text(account.name)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Repayments reduce what you owe and are not spending. '
            'Interest and fees are spending.',
          ),
          const SizedBox(height: 16),
          DropdownMenu<RangeChoice>(
            initialSelection: _range,
            label: const Text('Period'),
            dropdownMenuEntries: [
              for (final r in RangeChoice.values)
                DropdownMenuEntry(value: r, label: r.label),
            ],
            onSelected: (r) => setState(() => _range = r ?? _range),
          ),
          const SizedBox(height: 8),
          figure('Owed on ${formatDate(end)}', summary.outstanding),
          figure('Principal repaid', summary.principalRepaid),
          figure('Interest', summary.interest),
          figure('Fees', summary.fees),
          if (!summary.otherCharges.isZero)
            figure(
              'Other charges',
              summary.otherCharges,
              note:
                  'Charged to this loan in other categories. Choose the '
                  'categories for interest and fees below to sort them.',
            ),
          const SizedBox(height: 16),
          categoryField(
            'Interest category',
            interestId,
            feesId,
            (id) => state.saveLoanCategories(
              widget.accountId,
              interest: {?id},
              fees: chosen.fees,
            ),
          ),
          const SizedBox(height: 16),
          categoryField(
            'Fees category',
            feesId,
            interestId,
            (id) => state.saveLoanCategories(
              widget.accountId,
              interest: chosen.interest,
              fees: {?id},
            ),
          ),
        ],
      ),
    );
  }
}
