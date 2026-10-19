import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';

import '../../app/app_scope.dart';
import '../../data/receipt_service.dart';
import '../../format/formatters.dart';
import '../../platform/services.dart';
import 'receipt_capture.dart';
import 'receipt_review_screen.dart';

const extractionLabels = {
  ExtractionState.captured: 'Saved, waiting to be read',
  ExtractionState.extractionQueued: 'Waiting to be read',
  ExtractionState.extracting: 'Reading',
  ExtractionState.needsReview: 'Needs review',
  ExtractionState.reviewed: 'Reviewed',
  ExtractionState.extractionFailed: 'Could not be read',
};

/// Receipt inbox, distinct from the transaction review queue (section 9).
/// Desktop widths accept dropped and pasted files (REC 01).
class ReceiptsPage extends StatefulWidget {
  const ReceiptsPage({super.key});

  @override
  State<ReceiptsPage> createState() => _ReceiptsPageState();
}

class _ReceiptsPageState extends State<ReceiptsPage> {
  var _query = '';
  var _unmatchedOnly = false;
  var _failedOnly = false;
  var _dragging = false;

  Future<void> _addFiles(List<CapturedFile> files) =>
      saveCapturedReceipt(context, files);

  Future<void> _paste() async {
    final image = await Pasteboard.image;
    if (image != null) {
      await _addFiles([
        CapturedFile(
          image,
          fileName: 'pasted.png',
          source: CaptureSource.paste,
        ),
      ]);
      return;
    }
    final paths = await Pasteboard.files();
    final files = <CapturedFile>[];
    for (final path in paths) {
      files.add(
        CapturedFile(
          await File(path).readAsBytes(),
          fileName: path.split('/').last,
          source: CaptureSource.paste,
        ),
      );
    }
    if (files.isNotEmpty) await _addFiles(files);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final services = AppScope.servicesOf(context);
    final service = state.receipts;
    final receipts = service.search(
      ReceiptQuery(
        text: _query.isEmpty ? null : _query,
        unmatchedOnly: _unmatchedOnly,
        extractionFailedOnly: _failedOnly,
      ),
    );
    final linked = {for (final l in service.links) l.receiptId};
    final list = Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Semantics(
            label: 'Search receipts',
            textField: true,
            child: SearchBar(
              hintText: 'Search merchant, amount, notes or receipt text',
              leading: const Icon(Icons.search),
              onChanged: (q) => setState(() => _query = q.trim()),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Wrap(
            spacing: 8,
            children: [
              FilterChip(
                label: const Text('Not matched'),
                selected: _unmatchedOnly,
                onSelected: (v) => setState(() => _unmatchedOnly = v),
              ),
              FilterChip(
                label: const Text('Could not be read'),
                selected: _failedOnly,
                onSelected: (v) => setState(() => _failedOnly = v),
              ),
              ActionChip(
                avatar: const Icon(Icons.upload_file),
                label: const Text('Import file'),
                onPressed: () async =>
                    _addFiles(await services.fileImporter.pickReceipts()),
              ),
              if (services.capabilities.paste)
                ActionChip(
                  avatar: const Icon(Icons.content_paste),
                  label: const Text('Paste'),
                  onPressed: _paste,
                ),
            ],
          ),
        ),
        Expanded(
          child: receipts.isEmpty
              ? Center(
                  child: Text(
                    services.capabilities.dragAndDrop
                        ? 'No receipts. Drop images or PDFs here, paste, or import a file.'
                        : 'No receipts yet. Use Scan receipt to capture one.',
                  ),
                )
              : ListView.builder(
                  itemCount: receipts.length,
                  itemBuilder: (context, index) {
                    final r = receipts[index];
                    final extraction = service.extractionFor(r);
                    final fields =
                        extraction?.suggested.merge(r.confirmed) ?? r.confirmed;
                    return ListTile(
                      leading: const Icon(Icons.receipt_long_outlined),
                      title: Text(fields.merchant ?? 'Receipt'),
                      subtitle: Text(
                        [
                          if (fields.date != null) formatDate(fields.date!),
                          extractionLabels[r.extractionState]!,
                          linked.contains(r.id) ? 'Matched' : 'Not matched',
                          if (state.isUnsynced(
                            ReceiptEntityTypes.receipt,
                            r.id,
                          ))
                            'Saved on this device only',
                        ].join(' · '),
                      ),
                      trailing: Text(
                        fields.total == null ? '' : formatMoney(fields.total!),
                      ),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ReceiptReviewScreen(receiptId: r.id),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
    final body = Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.keyV, control: true): _PasteIntent(),
      },
      child: Actions(
        actions: {
          _PasteIntent: CallbackAction<_PasteIntent>(onInvoke: (_) => _paste()),
        },
        child: Focus(autofocus: true, child: list),
      ),
    );
    if (!services.capabilities.dragAndDrop) return body;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) async {
        setState(() => _dragging = false);
        final files = <CapturedFile>[];
        for (final file in details.files) {
          files.add(
            CapturedFile(
              await file.readAsBytes(),
              fileName: file.name,
              source: CaptureSource.dragAndDrop,
            ),
          );
        }
        await _addFiles(files);
      },
      child: Stack(
        children: [
          body,
          if (_dragging)
            Positioned.fill(
              child: ColoredBox(
                color: Theme.of(context).colorScheme.primary
                    .withValues(alpha: 0.12),
                child: const Center(child: Text('Drop to save as a receipt')),
              ),
            ),
        ],
      ),
    );
  }
}

class _PasteIntent extends Intent {
  const _PasteIntent();
}
