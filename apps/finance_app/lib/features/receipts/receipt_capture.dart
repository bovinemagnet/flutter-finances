import 'package:finance_store/finance_store.dart';
import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../data/receipt_service.dart';
import '../../platform/services.dart';

/// Opens the scanner (or camera fallback) and saves the result (Journey B).
Future<void> scanReceipt(BuildContext context) async {
  final services = AppScope.servicesOf(context);
  final messenger = ScaffoldMessenger.of(context);
  if (!await services.scanner.isAvailable()) {
    final files = await services.fileImporter.pickReceipts();
    if (context.mounted && files.isNotEmpty) {
      await saveCapturedReceipt(context, files);
    }
    return;
  }
  try {
    final files = await services.scanner.capture();
    if (context.mounted) await saveCapturedReceipt(context, files);
  } on CaptureException catch (e) {
    switch (e.failure) {
      case CaptureFailure.cancelled:
        return;
      case CaptureFailure.permissionDenied:
        messenger.showSnackBar(
          SnackBar(
            content: const Text(
              'Camera access was not allowed. You can still import a photo or PDF.',
            ),
            action: SnackBarAction(
              label: 'Import',
              onPressed: () async {
                final files = await services.fileImporter.pickReceipts();
                if (context.mounted && files.isNotEmpty) {
                  await saveCapturedReceipt(context, files);
                }
              },
            ),
          ),
        );
      case CaptureFailure.unavailable:
      case CaptureFailure.failed:
        messenger.showSnackBar(
          SnackBar(
            content: Text('The camera could not be used: ${e.detail ?? ''}'),
          ),
        );
    }
  }
}

/// Saves captured files durably, confirms "Saved", then reads the text in
/// the background. The image is kept whatever happens to extraction.
Future<void> saveCapturedReceipt(
  BuildContext context,
  List<CapturedFile> files,
) async {
  if (files.isEmpty) return;
  final state = AppScope.of(context);
  final services = AppScope.servicesOf(context);
  final messenger = ScaffoldMessenger.of(context);
  try {
    final receipt = await state.receipts.capture(files);
    messenger.showSnackBar(
      const SnackBar(content: Text('Receipt saved on this device')),
    );
    if (await services.textRecogniser.isAvailable()) {
      final read = await state.receipts.extract(
        receipt.id,
        services.textRecogniser,
      );
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            read.latestExtractionId == null
                ? 'The receipt could not be read; enter the details when reviewing'
                : 'Receipt read; ready to review',
          ),
        ),
      );
    }
  } on StorageWriteException catch (e) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          e.lowStorage
              ? 'Not saved: this device is out of storage. Free some space and try again.'
              : 'Not saved: the receipt could not be written to storage.',
        ),
        duration: const Duration(seconds: 10),
      ),
    );
  } on ReceiptRejectedException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.messages.join('\n'))));
  } on Exception catch (e) {
    messenger.showSnackBar(
      SnackBar(
        content: Text('Not saved: $e'),
        duration: const Duration(seconds: 10),
      ),
    );
  }
}
