import 'dart:typed_data';

import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart' show AssetCorruptException;
import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/breakpoints.dart';
import '../../data/app_state.dart';
import '../../format/formatters.dart';
import '../../platform/image_tools.dart';
import 'image_edit_screen.dart';

const uncertaintyText = {
  UncertaintyReason.ambiguousDate: 'the date could be day/month or month/day',
  UncertaintyReason.futureDate: 'the date is in the future',
  UncertaintyReason.conflictingDates: 'more than one date was found',
  UncertaintyReason.multiplePlausibleTotals:
      'more than one amount could be the total',
  UncertaintyReason.totalInferred: 'the total was worked out, not printed',
  UncertaintyReason.arithmeticMismatch: 'the items do not add up to the total',
  UncertaintyReason.currencyNotExplicit: 'no currency was printed',
  UncertaintyReason.foreignCurrency: 'a different currency was printed',
  UncertaintyReason.conflictingCurrencies: 'several currencies were printed',
  UncertaintyReason.refundReceipt: 'this looks like a refund',
  UncertaintyReason.merchantGuessed: 'the merchant name is a guess',
  UncertaintyReason.taxImplausible: 'the GST amount looks wrong',
  UncertaintyReason.missingMerchant: 'no merchant was found',
  UncertaintyReason.missingDate: 'no date was found',
  UncertaintyReason.missingTotal: 'no total was found',
};

enum _Decision { attach, create, keep }

/// Review a receipt beside its fields and decide what it is (REC 06).
/// Nothing is posted until the user chooses "Create expense".
class ReceiptReviewScreen extends StatefulWidget {
  const ReceiptReviewScreen({super.key, required this.receiptId});
  final String receiptId;

  @override
  State<ReceiptReviewScreen> createState() => _ReceiptReviewScreenState();
}

class _ReceiptReviewScreenState extends State<ReceiptReviewScreen> {
  final _merchant = TextEditingController();
  final _total = TextEditingController();
  final _tax = TextEditingController();
  LocalDate? _date;
  var _refund = false;
  var _decision = _Decision.attach;
  Journal? _selected;
  String? _accountId;
  String? _categoryId;
  var _cashConfirmed = false;
  var _initialised = false;
  String? _error;
  Future<bool>? _recognitionAvailable;

  @override
  void dispose() {
    _merchant.dispose();
    _total.dispose();
    _tax.dispose();
    super.dispose();
  }

  void _initialise(ReceiptReview review) {
    if (_initialised) return;
    _initialised = true;
    _merchant.text = review.merchant.value ?? '';
    _total.text = review.total.value?.toDecimalString() ?? '';
    _tax.text = review.tax.value?.toDecimalString() ?? '';
    _date = review.date.value;
    _refund = review.reviewReasons.contains(UncertaintyReason.refundReceipt);
  }

  ReceiptFields? _fields(Currency currency) {
    try {
      return ReceiptFields(
        merchant: _merchant.text.trim().isEmpty ? null : _merchant.text.trim(),
        date: _date,
        total: _total.text.trim().isEmpty
            ? null
            : Money.parse(_total.text, currency),
        tax: _tax.text.trim().isEmpty ? null : Money.parse(_tax.text, currency),
        isRefund: _refund,
      );
    } on FormatException {
      return null;
    }
  }

  Future<void> _submit() async {
    final state = AppScope.of(context);
    final fields = _fields(state.currency);
    if (fields == null) {
      setState(() => _error = 'Amounts must look like 12.50');
      return;
    }
    final ReviewDecision decision;
    switch (_decision) {
      case _Decision.attach:
        if (_selected == null) {
          setState(
            () => _error = 'Choose the transaction this receipt belongs to',
          );
          return;
        }
        decision = AttachToTransaction(_selected!);
      case _Decision.create:
        if (_accountId == null) {
          setState(() => _error = 'Choose the account it was paid from');
          return;
        }
        final cash = state.chart.account(_accountId!).type == AccountType.cash;
        decision = CreateExpense(
          accountId: _accountId!,
          categoryId: _categoryId,
          paidInCash: cash,
          accountConfirmed: !cash || _cashConfirmed,
        );
      case _Decision.keep:
        decision = const KeepDocumentOnly();
    }
    try {
      await state.receipts.review(widget.receiptId, fields, decision);
      if (mounted) Navigator.of(context).pop();
    } on Exception catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final service = state.receipts;
    final receipt = service.receipt(widget.receiptId);
    if (receipt == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('Receipt deleted')),
      );
    }
    final extraction = service.extractionFor(receipt);
    final review = buildReceiptReview(receipt, extraction);
    _initialise(review);
    final wide =
        windowClassFor(MediaQuery.sizeOf(context).width) != WindowClass.compact;
    final pages = service.pagesFor(receipt.id);
    final links = service.linksFor(receipt.id);

    final recogniser = AppScope.servicesOf(context).textRecogniser;
    _recognitionAvailable ??= recogniser.isAvailable();

    // Editing works on images, so a PDF page has nothing to offer here.
    final imagePages = [
      for (final page in pages)
        if (state.store.vault.asset(page.sourceAssetId)?.contentType
            case final type? when type != 'application/pdf')
          page,
    ];
    final preview = _PagePreview(pages: pages, read: service.readPage);
    final form = ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // NFR 06: an unread receipt says why when no engine is installed.
        if (receipt.extractionState == ExtractionState.captured)
          FutureBuilder(
            future: _recognitionAvailable,
            builder: (context, available) => switch (available.data) {
              false => Card(
                child: ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: Text(recogniser.unavailableMessage),
                  subtitle: const Text('Enter the details by hand.'),
                ),
              ),
              true when service.canReadAgain(receipt) => _ReadAgainCard(
                title: 'This receipt was not finished being read',
                receiptId: receipt.id,
                onRead: () => setState(() => _initialised = false),
              ),
              _ => const SizedBox.shrink(),
            },
          ),
        if (receipt.extractionState == ExtractionState.extractionFailed ||
            (receipt.extractionState == ExtractionState.extracting &&
                service.canReadAgain(receipt)))
          _ReadAgainCard(
            title: receipt.extractionState == ExtractionState.extractionFailed
                ? 'This receipt could not be read'
                : 'This receipt was not finished being read',
            receiptId: receipt.id,
            onRead: () => setState(() => _initialised = false),
          ),
        FutureBuilder(
          future: service.warningsFor(receipt.id),
          builder: (context, snapshot) => Column(
            children: [
              for (final warning in snapshot.data ?? const [])
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.warning_amber_outlined),
                    title: Text(warning.message),
                  ),
                ),
            ],
          ),
        ),
        Wrap(
          spacing: 8,
          children: [
            if ((AppScope.syncOf(context)?.isSynced ?? false) &&
                service.canUseCloudText(receipt))
              OutlinedButton.icon(
                icon: const Icon(Icons.cloud_download_outlined),
                label: const Text('Use cloud text'),
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  try {
                    final text = await AppScope.syncOf(context)!.extraction
                        .extractedText(receipt.id);
                    if (text == null) {
                      messenger.showSnackBar(
                        const SnackBar(
                          content: Text(
                            'No cloud text for this receipt. It is read '
                            'after syncing when cloud recognition is allowed.',
                          ),
                        ),
                      );
                      return;
                    }
                    await service.extractFromText(receipt.id, text);
                    setState(() => _initialised = false);
                  } on Exception catch (e) {
                    messenger.showSnackBar(
                      SnackBar(content: Text('Could not fetch the text: $e')),
                    );
                  }
                },
              ),
            if (imagePages.isNotEmpty)
              OutlinedButton.icon(
                icon: const Icon(Icons.auto_fix_high_outlined),
                label: const Text('Improve readability'),
                onPressed: () async {
                  final page = imagePages.length == 1
                      ? imagePages.single
                      : await showDialog<ReceiptPage>(
                          context: context,
                          builder: (context) => SimpleDialog(
                            title: const Text('Which page?'),
                            children: [
                              for (final p in imagePages)
                                SimpleDialogOption(
                                  onPressed: () => Navigator.of(context).pop(p),
                                  child: Text('Page ${p.pageNumber}'),
                                ),
                            ],
                          ),
                        );
                  if (page == null || !context.mounted) return;
                  final bytes = await state.store.vault.readAsset(
                    page.sourceAssetId,
                  );
                  if (!context.mounted) return;
                  final edits = await Navigator.of(context).push<ImageEdits>(
                    MaterialPageRoute(
                      builder: (_) => ImageEditScreen(source: bytes),
                    ),
                  );
                  if (edits != null && !edits.isEmpty) {
                    await service.saveReadableCopy(page, edits);
                  }
                },
              ),
            if (pages.length > 1)
              OutlinedButton.icon(
                icon: const Icon(Icons.auto_awesome_outlined),
                label: const Text('Suggest how to split'),
                onPressed: () async {
                  final services = AppScope.servicesOf(context);
                  final recogniser = services.textRecogniser;
                  final pdfReader = services.pdfReader;
                  final messenger = ScaffoldMessenger.of(context);
                  if (!await service.canRead(
                    receipt.id,
                    recogniser,
                    pdfReader: pdfReader,
                  )) {
                    messenger.showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Reading text is not available on this device; '
                          'separate pages by hand',
                        ),
                      ),
                    );
                    return;
                  }
                  final proposal = await service.suggestSeparation(
                    receipt.id,
                    recogniser,
                    pdfReader: pdfReader,
                  );
                  if (!context.mounted) return;
                  if (proposal.isSingleReceipt) {
                    messenger.showSnackBar(
                      const SnackBar(
                        content: Text('This looks like a single receipt'),
                      ),
                    );
                    return;
                  }
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: Text(
                        'Split into ${proposal.groups.length} receipts?',
                      ),
                      content: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final group in proposal.groups)
                            Text(
                              'Pages ${group.pages.map((p) => p + 1).join(', ')}'
                              '${group.merchantHint == null ? '' : ' · ${group.merchantHint}'}'
                              ' · ${group.confidence.name} confidence'
                              '${group.needsManualSplit ? ' · a page holds more than one receipt' : ''}',
                            ),
                        ],
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: const Text('Keep together'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.of(context).pop(true),
                          child: const Text('Split'),
                        ),
                      ],
                    ),
                  );
                  if (confirmed == true) {
                    await service.applySeparation(receipt.id, proposal);
                  }
                },
              ),
            if (pages.length > 1)
              OutlinedButton.icon(
                icon: const Icon(Icons.call_split),
                label: const Text('Separate pages'),
                onPressed: () async {
                  final page = await showDialog<int>(
                    context: context,
                    builder: (context) => SimpleDialog(
                      title: const Text('Make a page its own receipt'),
                      children: [
                        for (final p in pages.skip(1))
                          SimpleDialogOption(
                            onPressed: () =>
                                Navigator.of(context).pop(p.pageNumber),
                            child: Text('Page ${p.pageNumber}'),
                          ),
                      ],
                    ),
                  );
                  if (page == null) return;
                  await service.splitPages(receipt.id, [
                    [
                      for (final p in pages)
                        if (p.pageNumber != page) p.pageNumber,
                    ],
                    [page],
                  ]);
                },
              ),
          ],
        ),
        _ReviewedField(
          label: 'Merchant',
          field: review.merchant,
          child: TextField(
            controller: _merchant,
            decoration: const InputDecoration(labelText: 'Merchant'),
          ),
        ),
        _ReviewedField(
          label: 'Date',
          field: review.date,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(_date == null ? 'No date' : formatDate(_date!)),
            trailing: TextButton(
              child: const Text('Change'),
              onPressed: () async {
                final initial = _date ?? state.today();
                final picked = await showDatePicker(
                  context: context,
                  initialDate: DateTime(
                    initial.year,
                    initial.month,
                    initial.day,
                  ),
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                );
                if (picked != null) {
                  setState(() => _date = LocalDate.fromDateTime(picked));
                }
              },
            ),
          ),
        ),
        _ReviewedField(
          label: 'Total',
          field: review.total,
          child: TextField(
            controller: _total,
            decoration: const InputDecoration(
              labelText: 'Total paid',
              prefixText: r'$ ',
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        _ReviewedField(
          label: 'GST',
          field: review.tax,
          child: TextField(
            controller: _tax,
            decoration: const InputDecoration(
              labelText: 'GST (if printed)',
              prefixText: r'$ ',
            ),
          ),
        ),
        SwitchListTile(
          value: _refund,
          title: const Text('This is a refund'),
          onChanged: (v) => setState(() => _refund = v),
        ),
        ..._itemsAndWarranties(context, state, receipt.id),
        if (links.isNotEmpty) ...[
          const Divider(),
          for (final link in links)
            ListTile(
              leading: const Icon(Icons.link),
              title: Text('Linked for ${formatMoney(link.allocated)}'),
              trailing: TextButton(
                onPressed: () => service.unlink(link),
                child: const Text('Remove link'),
              ),
            ),
        ],
        const Divider(),
        SegmentedButton<_Decision>(
          segments: const [
            ButtonSegment(value: _Decision.attach, label: Text('Attach')),
            ButtonSegment(
              value: _Decision.create,
              label: Text('Create expense'),
            ),
            ButtonSegment(value: _Decision.keep, label: Text('Keep only')),
          ],
          selected: {_decision},
          onSelectionChanged: (s) => setState(() => _decision = s.single),
        ),
        const SizedBox(height: 8),
        ..._decisionDetails(state),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        const SizedBox(height: 16),
        OverflowBar(
          alignment: MainAxisAlignment.spaceBetween,
          overflowAlignment: OverflowBarAlignment.end,
          children: [
            TextButton.icon(
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete document'),
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Delete this receipt?'),
                    content: const Text(
                      'The image is removed. Any linked transaction is kept.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        child: const Text('Keep'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.of(context).pop(true),
                        child: const Text('Delete'),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) {
                  await service.deleteDocument(receipt.id);
                  if (context.mounted) Navigator.of(context).pop();
                }
              },
            ),
            FilledButton(onPressed: _submit, child: const Text('Confirm')),
          ],
        ),
      ],
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Review receipt')),
      body: wide
          ? Row(
              children: [
                Expanded(child: preview),
                Expanded(child: form),
              ],
            )
          : Column(
              children: [
                SizedBox(height: 240, child: preview),
                Expanded(child: form),
              ],
            ),
    );
  }

  List<Widget> _decisionDetails(AppState state) {
    final fields = _fields(state.currency) ?? const ReceiptFields();
    switch (_decision) {
      case _Decision.attach:
        final candidates = state.receipts.candidates(fields).take(8).toList();
        if (candidates.isEmpty) {
          return [
            const Text(
              'No matching transactions yet. Create an expense or keep the document.',
            ),
          ];
        }
        return [
          RadioGroup<Journal>(
            groupValue: _selected,
            onChanged: (j) => setState(() => _selected = j),
            child: Column(
              children: [
                for (final c in candidates)
                  RadioListTile<Journal>(
                    value: c.journal,
                    enabled: c.linkable,
                    title: Text(
                      '${c.journal.payee ?? 'Transaction'} · '
                      '${c.journal.amount == null ? '' : formatMoney(c.journal.amount!)}',
                    ),
                    subtitle: Text(
                      [
                        formatDate(c.journal.effectiveDate),
                        ...c.reasons.map((r) => r.message),
                      ].join(' · '),
                    ),
                  ),
              ],
            ),
          ),
        ];
      case _Decision.create:
        final chart = state.chart;
        final cash =
            _accountId != null &&
            chart.account(_accountId!).type == AccountType.cash;
        return [
          DropdownButtonFormField<String>(
            initialValue: _accountId,
            decoration: const InputDecoration(labelText: 'Paid from'),
            items: [
              for (final a in chart.accounts.where((a) => !a.archived))
                DropdownMenuItem(value: a.id, child: Text(a.name)),
            ],
            onChanged: (id) => setState(() {
              _accountId = id;
              _cashConfirmed = false;
            }),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: _categoryId,
            decoration: const InputDecoration(labelText: 'Category'),
            items: [
              for (final c in chart.categories.where(
                (c) => c.kind == CategoryKind.expense && !c.archived,
              ))
                DropdownMenuItem(value: c.id, child: Text(c.name)),
            ],
            onChanged: (id) => setState(() => _categoryId = id),
          ),
          if (cash)
            CheckboxListTile(
              value: _cashConfirmed,
              title: const Text('I paid this in cash from this account'),
              onChanged: (v) => setState(() => _cashConfirmed = v ?? false),
            ),
        ];
      case _Decision.keep:
        return [
          const Text(
            'The receipt is kept for your records and not counted as spending.',
          ),
        ];
    }
  }
}

class _ReviewedField<T> extends StatelessWidget {
  const _ReviewedField({
    required this.label,
    required this.field,
    required this.child,
  });
  final String label;
  final ReviewField<T> field;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: field.highlight ? const EdgeInsets.all(8) : EdgeInsets.zero,
      decoration: field.highlight
          ? BoxDecoration(
              border: Border.all(color: scheme.tertiary, width: 2),
              borderRadius: BorderRadius.circular(8),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          child,
          if (field.highlight)
            Row(
              children: [
                Icon(Icons.help_outline, size: 16, color: scheme.tertiary),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    field.reasons.isEmpty
                        ? 'Check the $label'
                        : 'Check the $label: ${field.reasons.map((r) => uncertaintyText[r]).join(', ')}',
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Says a receipt has not been read, and offers reading it again.
class _ReadAgainCard extends StatelessWidget {
  const _ReadAgainCard({
    required this.title,
    required this.receiptId,
    required this.onRead,
  });

  final String title;
  final String receiptId;
  final VoidCallback onRead;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      leading: const Icon(Icons.error_outline),
      title: Text(title),
      subtitle: const Text(
        'The image is kept. Enter the details or try again.',
      ),
      trailing: TextButton(
        onPressed: () async {
          final services = AppScope.servicesOf(context);
          await AppScope.of(context).receipts.extract(
            receiptId,
            services.textRecogniser,
            pdfReader: services.pdfReader,
          );
          onRead();
        },
        child: const Text('Try again'),
      ),
    ),
  );
}

class _PagePreview extends StatelessWidget {
  const _PagePreview({required this.pages, required this.read});
  final List<ReceiptPage> pages;
  final Future<Uint8List> Function(ReceiptPage page) read;

  @override
  Widget build(BuildContext context) {
    if (pages.isEmpty) return const Center(child: Text('No image'));
    return PageView(
      children: [
        for (final page in pages)
          FutureBuilder<Uint8List>(
            future: read(page),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(
                  child: Text(
                    snapshot.error is AssetCorruptException
                        ? 'The copy of this image on this device is damaged'
                        : 'The image is not on this device yet',
                  ),
                );
              }
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final bytes = snapshot.data!;
              final isPdf =
                  bytes.length > 4 &&
                  String.fromCharCodes(bytes.sublist(0, 4)) == '%PDF';
              if (isPdf) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.picture_as_pdf_outlined, size: 64),
                      Text('PDF receipt, page ${page.pageNumber}'),
                    ],
                  ),
                );
              }
              return InteractiveViewer(
                maxScale: 6,
                child: Semantics(
                  label:
                      'Receipt image, page ${page.pageNumber}. The fields beside it can be edited.',
                  image: true,
                  child: Image.memory(
                    bytes,
                    fit: BoxFit.contain,
                    errorBuilder: (context, _, _) => const Center(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          'This image cannot be shown on this device. '
                          'Your original is still saved.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

const _reconciliationText = {
  ItemReconciliation.consistent: 'The items add up to the total',
  ItemReconciliation.inconsistent:
      'The items do not add up to the total; check them',
  ItemReconciliation.insufficient: 'Not enough was read to check the items',
};

List<Widget> _itemsAndWarranties(
  BuildContext context,
  AppState state,
  String receiptId,
) {
  final service = state.receipts;
  final items = service.itemsFor(receiptId);
  final warranties = service
      .warranties()
      .where((w) => w.receiptId == receiptId)
      .toList();
  return [
    if (items != null && items.items.isNotEmpty) ...[
      const Divider(),
      Text('Items', style: Theme.of(context).textTheme.titleSmall),
      for (final item in items.items)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(item.description),
          subtitle: item.discount.isZero
              ? null
              : Text('Discount ${formatMoney(item.discount)}'),
          trailing: Text(formatMoney(item.lineTotal)),
        ),
      Text(_reconciliationText[items.reconciliation]!),
    ],
    const Divider(),
    for (final w in warranties)
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.verified_user_outlined),
        title: Text('Warranty: ${w.description}'),
        subtitle: Text(
          'Ends ${formatDate(w.expiresOn)}; reminder a month before',
        ),
        trailing: IconButton(
          tooltip: 'Remove warranty',
          icon: const Icon(Icons.delete_outline),
          onPressed: () => service.deleteWarranty(w.id),
        ),
      ),
    Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        icon: const Icon(Icons.verified_user_outlined),
        label: const Text('Add warranty'),
        onPressed: () async {
          final description = TextEditingController(
            text: items?.items.firstOrNull?.description ?? '',
          );
          final months = TextEditingController(text: '12');
          final warranty = await showDialog<Warranty>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Warranty'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: description,
                    decoration: const InputDecoration(
                      labelText: 'What is covered',
                    ),
                  ),
                  TextField(
                    controller: months,
                    decoration: const InputDecoration(labelText: 'Months'),
                    keyboardType: TextInputType.number,
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    final count = int.tryParse(months.text.trim());
                    if (count == null || count <= 0) return;
                    Navigator.of(context).pop(
                      Warranty(
                        id: newId(),
                        receiptId: receiptId,
                        description: description.text.trim().isEmpty
                            ? 'Purchase'
                            : description.text.trim(),
                        startDate:
                            service.receipt(receiptId)?.confirmed.date ??
                            state.today(),
                        months: count,
                      ),
                    );
                  },
                  child: const Text('Save'),
                ),
              ],
            ),
          );
          if (warranty != null) await service.addWarranty(warranty);
        },
      ),
    ),
  ];
}
