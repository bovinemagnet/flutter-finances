import 'dart:typed_data';

import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../data/import_service.dart';
import '../../format/formatters.dart';

const _flagText = {
  PreviewFlag.possibleTransfer: 'Looks like a transfer between your accounts; it will not count as spending if treated as a transfer',
  PreviewFlag.possibleCardRepayment:
      'Looks like a card repayment; the purchases were already counted',
  PreviewFlag.receiptEntry: 'Already entered from a receipt; matching it adds the bank record as evidence',
};

const _statusText = {
  PreviewRowStatus.newEntry: 'New',
  PreviewRowStatus.duplicate: 'Already imported',
  PreviewRowStatus.ambiguous: 'Check: possible duplicate',
  PreviewRowStatus.existingMatch: 'Matches an existing entry',
};

/// Bank statement (CSV) import with a mapping, guided preview and an
/// explicit commit (IMP 01 to IMP 03).
class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key, required this.bytes, this.fileName});
  final Uint8List bytes;
  final String? fileName;

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  late final StatementFormat _format = detectStatementFormat(
    widget.bytes,
    widget.fileName,
  );
  bool get _isCsv => _format == StatementFormat.csv;
  late final List<String> _headers;
  late TextEncoding _encoding = detectEncoding(widget.bytes);
  String? _accountId;
  String? _dateColumn;
  String? _descriptionColumn;
  String? _amountColumn;
  String? _debitColumn;
  String? _creditColumn;
  var _splitColumns = false;
  var _dateFormat = 'dd/MM/yyyy';
  var _debitSign = DebitSign.negative;
  var _decimalSeparator = '.';
  var _delimiter = ',';
  ImportPreview? _preview;
  final _decisions = <int, RowDecision>{};
  var _busy = false;

  @override
  void initState() {
    super.initState();
    final text = decodeText(widget.bytes, _encoding);
    _delimiter =
        text.split('\n').first.contains(';') &&
            !text.split('\n').first.contains(',')
        ? ';'
        : ',';
    final records = readCsv(text, delimiter: _delimiter).records;
    _headers = records.isEmpty ? const [] : records.first.fields;
    String? guess(List<String> words) => _headers
        .where((h) => words.any((w) => h.toLowerCase().contains(w)))
        .firstOrNull;
    _dateColumn = guess(['date']);
    _descriptionColumn = guess(['desc', 'narrative', 'details', 'payee']);
    _amountColumn = guess(['amount', 'value']);
    _debitColumn = guess(['debit', 'withdrawal']);
    _creditColumn = guess(['credit', 'deposit']);
    _splitColumns =
        _amountColumn == null && _debitColumn != null && _creditColumn != null;
  }

  CsvMapping? get _mapping {
    if (_accountId == null ||
        _dateColumn == null ||
        _descriptionColumn == null) {
      return null;
    }
    if (_splitColumns
        ? (_debitColumn == null || _creditColumn == null)
        : _amountColumn == null) {
      return null;
    }
    return CsvMapping(
      id: newId(),
      name: widget.fileName ?? 'Statement',
      accountId: _accountId!,
      dateColumn: CsvColumn.header(_dateColumn!),
      descriptionColumn: CsvColumn.header(_descriptionColumn!),
      amountColumn: _splitColumns ? null : CsvColumn.header(_amountColumn!),
      debitColumn: _splitColumns ? CsvColumn.header(_debitColumn!) : null,
      creditColumn: _splitColumns ? CsvColumn.header(_creditColumn!) : null,
      dateFormat: _dateFormat,
      debitSign: _debitSign,
      delimiter: _delimiter,
      encoding: _encoding,
      decimalSeparator: _decimalSeparator,
    );
  }

  Widget _column(
    String label,
    String? value,
    ValueChanged<String?> onChanged,
  ) => DropdownButtonFormField<String>(
    initialValue: value,
    decoration: InputDecoration(labelText: label),
    items: [
      for (final h in _headers) DropdownMenuItem(value: h, child: Text(h)),
    ],
    onChanged: (v) => setState(() {
      onChanged(v);
      _preview = null;
    }),
  );

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final imports = ImportService(state);
    final mapping = _mapping;
    final preview = _preview;
    return Scaffold(
      appBar: AppBar(title: Text('Import ${widget.fileName ?? 'statement'}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DropdownButtonFormField<String>(
            initialValue: _accountId,
            decoration: const InputDecoration(
              labelText: 'Statement for account',
            ),
            items: [
              for (final a in state.chart.accounts.where((a) => !a.archived))
                DropdownMenuItem(value: a.id, child: Text(a.name)),
            ],
            onChanged: (v) => setState(() {
              _accountId = v;
              _preview = null;
            }),
          ),
          if (_isCsv) ...[
            const SizedBox(height: 8),
            _column('Date column', _dateColumn, (v) => _dateColumn = v),
            const SizedBox(height: 8),
            _column(
              'Description column',
              _descriptionColumn,
              (v) => _descriptionColumn = v,
            ),
            SwitchListTile(
              value: _splitColumns,
              title: const Text('Separate debit and credit columns'),
              onChanged: (v) => setState(() {
                _splitColumns = v;
                _preview = null;
              }),
            ),
            if (_splitColumns) ...[
              _column('Debit column', _debitColumn, (v) => _debitColumn = v),
              const SizedBox(height: 8),
              _column('Credit column', _creditColumn, (v) => _creditColumn = v),
            ] else ...[
              _column('Amount column', _amountColumn, (v) => _amountColumn = v),
              DropdownButtonFormField<DebitSign>(
                initialValue: _debitSign,
                decoration: const InputDecoration(
                  labelText: 'Money going out is shown as',
                ),
                items: const [
                  DropdownMenuItem(
                    value: DebitSign.negative,
                    child: Text('Negative (-12.50)'),
                  ),
                  DropdownMenuItem(
                    value: DebitSign.positive,
                    child: Text('Positive (12.50)'),
                  ),
                ],
                onChanged: (v) => setState(() {
                  _debitSign = v!;
                  _preview = null;
                }),
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                DropdownMenu<String>(
                  initialSelection: _dateFormat,
                  label: const Text('Date format'),
                  dropdownMenuEntries: const [
                    DropdownMenuEntry(value: 'dd/MM/yyyy', label: '31/12/2026'),
                    DropdownMenuEntry(value: 'd/M/yyyy', label: '1/2/2026'),
                    DropdownMenuEntry(value: 'yyyy-MM-dd', label: '2026-12-31'),
                    DropdownMenuEntry(
                      value: 'dd MMM yyyy',
                      label: '31 Dec 2026',
                    ),
                    DropdownMenuEntry(value: 'MM/dd/yyyy', label: '12/31/2026'),
                  ],
                  onSelected: (v) => setState(() {
                    _dateFormat = v ?? _dateFormat;
                    _preview = null;
                  }),
                ),
                DropdownMenu<String>(
                  initialSelection: _decimalSeparator,
                  label: const Text('Decimal mark'),
                  dropdownMenuEntries: const [
                    DropdownMenuEntry(value: '.', label: '12.50'),
                    DropdownMenuEntry(value: ',', label: '12,50'),
                  ],
                  onSelected: (v) => setState(() {
                    _decimalSeparator = v ?? _decimalSeparator;
                    _preview = null;
                  }),
                ),
                DropdownMenu<TextEncoding>(
                  initialSelection: _encoding,
                  label: const Text('Text encoding'),
                  dropdownMenuEntries: const [
                    DropdownMenuEntry(value: TextEncoding.utf8, label: 'UTF-8'),
                    DropdownMenuEntry(
                      value: TextEncoding.windows1252,
                      label: 'Windows-1252',
                    ),
                    DropdownMenuEntry(
                      value: TextEncoding.latin1,
                      label: 'Latin-1',
                    ),
                  ],
                  onSelected: (v) => setState(() {
                    _encoding = v ?? _encoding;
                    _preview = null;
                  }),
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          FilledButton.tonal(
            onPressed: (_isCsv ? mapping == null : _accountId == null)
                ? null
                : () => setState(
                    () => _preview = _isCsv
                        ? imports.preview(widget.bytes, mapping!)
                        : imports.previewStatement(
                            widget.bytes,
                            _format,
                            accountId: _accountId!,
                          ),
                  ),
            child: const Text('Preview'),
          ),
          if (preview != null) ..._previewWidgets(state.chart, preview),
          if (preview != null && (mapping != null || !_isCsv))
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: FilledButton(
                onPressed: _busy
                    ? null
                    : () async {
                        setState(() => _busy = true);
                        final messenger = ScaffoldMessenger.of(context);
                        final navigator = Navigator.of(context);
                        final ImportOutcome outcome;
                        if (_isCsv) {
                          await imports.saveMapping(mapping!);
                          outcome = await imports.commit(
                            preview,
                            mapping,
                            decisions: _decisions,
                            fileName: widget.fileName,
                          );
                        } else {
                          outcome = await imports.commitStatement(
                            preview,
                            accountId: _accountId!,
                            decisions: _decisions,
                            fileName: widget.fileName,
                          );
                        }
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(
                              outcome.alreadyCommitted
                                  ? 'This statement was already imported; nothing was added'
                                  : 'Imported ${outcome.posted} entries',
                            ),
                          ),
                        );
                        navigator.pop();
                      },
                child: const Text('Import'),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _previewWidgets(Chart chart, ImportPreview preview) {
    final totals = preview.totals;
    final otherAccounts = chart.accounts
        .where((a) => a.id != _accountId)
        .toList();
    return [
      const SizedBox(height: 16),
      if (preview.alreadyImportedBatch != null)
        const Card(
          child: ListTile(
            leading: Icon(Icons.info_outline),
            title: Text(
              'This exact file was imported before; importing again adds nothing.',
            ),
          ),
        ),
      Text(
        '${totals.count} rows · money in ${formatMoney(totals.credits)} · '
        'money out ${formatMoney(totals.debits)}',
      ),
      for (final gap in preview.dateGaps)
        Text(
          'No entries between ${formatDate(gap.from)} and ${formatDate(gap.to)}; '
          'part of the statement may be missing.',
        ),
      for (final error in preview.errors)
        Text(
          'Row ${error.row}: ${error.message}',
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      const Divider(),
      for (final (index, row) in preview.rows.indexed)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${formatDate(row.row.date)} · ${row.row.description}',
                      ),
                    ),
                    Text(formatMoney(row.row.amount)),
                  ],
                ),
                Text(_statusText[row.status]!),
                for (final flag in row.flags) Text(_flagText[flag]!),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('Skip'),
                      selected: _decisions[index] is SkipRow,
                      onSelected: (v) => setState(
                        () => v
                            ? _decisions[index] = const SkipRow()
                            : _decisions.remove(index),
                      ),
                    ),
                    if (row.flags.contains(PreviewFlag.possibleTransfer) ||
                        row.flags.contains(PreviewFlag.possibleCardRepayment))
                      for (final account in otherAccounts)
                        ChoiceChip(
                          label: Text('Transfer with ${account.name}'),
                          selected: switch (_decisions[index]) {
                            CreateTransfer(:final counterAccountId) =>
                              counterAccountId == account.id,
                            _ => false,
                          },
                          onSelected: (v) => setState(
                            () => v
                                ? _decisions[index] = CreateTransfer(account.id)
                                : _decisions.remove(index),
                          ),
                        ),
                    for (final proposal in row.proposals.take(2))
                      ChoiceChip(
                        label: Text(
                          'Match ${proposal.journal.payee ?? 'entry'} '
                          '${formatDate(proposal.journal.effectiveDate)}',
                        ),
                        selected: switch (_decisions[index]) {
                          MatchExisting(:final journalId) =>
                            journalId == proposal.journal.id,
                          _ => false,
                        },
                        onSelected: (v) => setState(
                          () => v
                              ? _decisions[index] = MatchExisting(
                                  proposal.journal.id,
                                )
                              : _decisions.remove(index),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
    ];
  }
}
