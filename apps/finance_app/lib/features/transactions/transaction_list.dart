import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/breakpoints.dart';
import '../../app/theme.dart';
import '../../format/formatters.dart';

/// A journal plus the labels and states the list needs.
class TransactionListItem {
  const TransactionListItem({
    required this.journal,
    required this.accountName,
    required this.categoryLabel,
    required this.reviewed,
    required this.hasReceipt,
    required this.unsynced,
  });

  final Journal journal;
  final String accountName;
  final String categoryLabel;
  final bool reviewed;
  final bool hasReceipt;
  final bool unsynced;

  /// Signed from the account's point of view: spending is negative.
  Money get signedAmount {
    final amount =
        journal.amount ?? Money.zero(journal.postings.first.amount.currency);
    return switch (journal.type) {
      TransactionType.expense || TransactionType.reimbursableExpense => -amount,
      TransactionType.transfer => -amount,
      TransactionType.openingBalance || TransactionType.adjustment => amount,
      _ => amount,
    };
  }

  bool matches(String query) {
    if (query.isEmpty) return true;
    final q = query.toLowerCase();
    return [
      journal.payee,
      journal.notes,
      categoryLabel,
      accountName,
      journal.amount?.toDecimalString(),
      ...journal.tags,
    ].whereType<String>().any((v) => v.toLowerCase().contains(q));
  }
}

const transactionTypeLabels = {
  TransactionType.expense: 'Expense',
  TransactionType.income: 'Income',
  TransactionType.transfer: 'Transfer',
  TransactionType.refund: 'Refund',
  TransactionType.adjustment: 'Balance adjustment',
  TransactionType.openingBalance: 'Opening balance',
  TransactionType.reimbursableExpense: 'Paid for someone',
  TransactionType.reimbursement: 'Reimbursement',
  TransactionType.reversal: 'Correction',
};

/// Transaction history and review queue (Journeys C and D).
///
/// Every action has a visible control; the phone layout adds optional swipe
/// shortcuts. Desktop widths get a dense table with multi-selection
/// (shift-click selects a range) and bulk actions.
class TransactionList extends StatefulWidget {
  const TransactionList({
    super.key,
    required this.items,
    required this.categories,
    required this.onOpen,
    required this.onMarkReviewed,
    required this.onCategorise,
    this.emptyMessage = 'No transactions yet',
  });

  final List<TransactionListItem> items;
  final List<Category> categories;
  final ValueChanged<Journal> onOpen;
  final ValueChanged<List<String>> onMarkReviewed;
  final void Function(List<String> journalIds, String categoryId) onCategorise;
  final String emptyMessage;

  @override
  State<TransactionList> createState() => _TransactionListState();
}

class _TransactionListState extends State<TransactionList> {
  final _selected = <String>{};
  int? _anchor;
  var _query = '';

  List<TransactionListItem> get _visible =>
      widget.items.where((i) => i.matches(_query)).toList();

  void _toggle(int index, List<TransactionListItem> visible) {
    final shift = HardwareKeyboard.instance.isShiftPressed;
    setState(() {
      if (shift && _anchor != null) {
        final from = _anchor! < index ? _anchor! : index;
        final to = _anchor! < index ? index : _anchor!;
        for (var i = from; i <= to; i++) {
          _selected.add(visible[i].journal.id);
        }
      } else {
        final id = visible[index].journal.id;
        _selected.contains(id) ? _selected.remove(id) : _selected.add(id);
        _anchor = index;
      }
    });
  }

  Future<void> _categoriseSelected() async {
    final category = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Categorise ${_selected.length} transactions'),
        children: [
          for (final c in widget.categories.where((c) => !c.archived))
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(c.id),
              child: Text(c.name),
            ),
        ],
      ),
    );
    if (category == null) return;
    widget.onCategorise(_selected.toList(), category);
    setState(_selected.clear);
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    final wide =
        windowClassFor(MediaQuery.sizeOf(context).width) ==
        WindowClass.expanded;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Semantics(
            label: 'Search transactions',
            textField: true,
            child: SearchBar(
              hintText: 'Search payee, notes, amount or tag',
              leading: const Icon(Icons.search),
              onChanged: (q) => setState(() => _query = q.trim()),
            ),
          ),
        ),
        if (_selected.isNotEmpty)
          Material(
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [
                  Text('${_selected.length} selected'),
                  TextButton.icon(
                    icon: const Icon(Icons.category_outlined),
                    label: const Text('Categorise'),
                    onPressed: _categoriseSelected,
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.done_all),
                    label: const Text('Mark reviewed'),
                    onPressed: () {
                      widget.onMarkReviewed(_selected.toList());
                      setState(_selected.clear);
                    },
                  ),
                  IconButton(
                    tooltip: 'Clear selection',
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(_selected.clear),
                  ),
                ],
              ),
            ),
          ),
        Expanded(
          child: visible.isEmpty
              ? Center(child: Text(widget.emptyMessage))
              : wide
              ? _table(visible)
              : _list(visible),
        ),
      ],
    );
  }

  Widget _statusChips(TransactionListItem item) {
    final journal = item.journal;
    return Wrap(
      spacing: 4,
      children: [
        if (journal.status == JournalStatus.pending)
          const _Tag('Pending', attention: true),
        if (journal.status == JournalStatus.draft) const _Tag('Draft'),
        if (journal.status == JournalStatus.reversed) const _Tag('Corrected'),
        if (!item.reviewed) const _Tag('To review', attention: true),
        if (item.unsynced) const _Tag('Not synced'),
      ],
    );
  }

  Widget _amount(TransactionListItem item) {
    final amount = item.signedAmount;
    final palette = FinancePalette.of(context);
    return Text(
      formatMoney(amount),
      style: palette.figure(
        size: 14,
        weight: FontWeight.w600,
        color: amount.isNegative ? null : palette.accentText,
      ),
    );
  }

  Widget _list(List<TransactionListItem> visible) {
    return ListView.builder(
      itemCount: visible.length,
      itemBuilder: (context, index) {
        final item = visible[index];
        final journal = item.journal;
        final tile = ListTile(
          onTap: () => widget.onOpen(journal),
          onLongPress: () => _toggle(index, visible),
          selected: _selected.contains(journal.id),
          title: Text(journal.payee ?? item.categoryLabel),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${formatDate(journal.effectiveDate)} · ${item.accountName}'
                '${journal.payee == null ? '' : ' · ${item.categoryLabel}'}',
              ),
              _statusChips(item),
            ],
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (item.hasReceipt)
                const Tooltip(
                  message: 'Receipt attached',
                  child: Icon(Icons.receipt_outlined, size: 20),
                ),
              _amount(item),
              if (!item.reviewed)
                IconButton(
                  tooltip: 'Mark reviewed',
                  icon: const Icon(Icons.check_circle_outline),
                  onPressed: () => widget.onMarkReviewed([journal.id]),
                ),
            ],
          ),
        );
        if (item.reviewed) return tile;
        return Dismissible(
          key: ValueKey(journal.id),
          direction: DismissDirection.startToEnd,
          confirmDismiss: (_) async {
            widget.onMarkReviewed([journal.id]);
            return false;
          },
          background: Container(
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.only(left: 16),
            color: Theme.of(context).colorScheme.primaryContainer,
            child: const Text('Mark reviewed'),
          ),
          child: tile,
        );
      },
    );
  }

  Widget _table(List<TransactionListItem> visible) {
    final allSelected =
        visible.isNotEmpty &&
        visible.every((i) => _selected.contains(i.journal.id));
    return SingleChildScrollView(
      child: SizedBox(
        width: double.infinity,
        child: DataTable(
          dataRowMinHeight: 36,
          dataRowMaxHeight: 52,
          headingRowHeight: 40,
          onSelectAll: (value) => setState(() {
            if (value ?? !allSelected) {
              _selected.addAll(visible.map((i) => i.journal.id));
            } else {
              _selected.clear();
            }
          }),
          columns: const [
            DataColumn(label: Text('Date')),
            DataColumn(label: Text('Payee')),
            DataColumn(label: Text('Category')),
            DataColumn(label: Text('Account')),
            DataColumn(label: Text('Status')),
            DataColumn(label: Text('Amount'), numeric: true),
          ],
          rows: [
            for (final (index, item) in visible.indexed)
              DataRow(
                selected: _selected.contains(item.journal.id),
                onSelectChanged: (_) => _toggle(index, visible),
                cells: [
                  DataCell(Text(formatShortDate(item.journal.effectiveDate))),
                  DataCell(
                    Row(
                      children: [
                        Flexible(child: Text(item.journal.payee ?? '–')),
                        if (item.hasReceipt)
                          const Tooltip(
                            message: 'Receipt attached',
                            child: Icon(Icons.receipt_outlined, size: 18),
                          ),
                      ],
                    ),
                    onTap: () => widget.onOpen(item.journal),
                  ),
                  DataCell(Text(item.categoryLabel)),
                  DataCell(Text(item.accountName)),
                  DataCell(_statusChips(item)),
                  DataCell(_amount(item)),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text, {this.attention = false});
  final String text;

  /// Pending and unreviewed entries are outlined in amber.
  final bool attention;

  @override
  Widget build(BuildContext context) {
    final palette = FinancePalette.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      decoration: BoxDecoration(
        color: attention ? palette.warningSoft : palette.cardMuted,
        border: Border.all(
          color: attention ? palette.warning : Colors.transparent,
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        style: palette.figure(
          size: 11,
          weight: FontWeight.w500,
          color: attention ? palette.onWarningSoft : palette.text,
        ),
      ),
    );
  }
}
