import 'package:file_selector/file_selector.dart';

import '../services.dart';

const _receiptTypes = XTypeGroup(
  label: 'Receipts',
  extensions: ['jpg', 'jpeg', 'png', 'heic', 'heif', 'pdf'],
  mimeTypes: ['image/jpeg', 'image/png', 'image/heic', 'application/pdf'],
  uniformTypeIdentifiers: [
    'public.jpeg',
    'public.png',
    'public.heic',
    'com.adobe.pdf',
  ],
);

const _statementTypes = XTypeGroup(
  label: 'Bank statements',
  extensions: ['csv', 'txt'],
  mimeTypes: ['text/csv', 'text/plain'],
  uniformTypeIdentifiers: [
    'public.comma-separated-values-text',
    'public.plain-text',
  ],
);

/// Platform file pickers. User-selected files remain importable when camera
/// or photo library access is denied (UX 04).
class PlatformFileImporter implements FileImporter {
  @override
  Future<List<CapturedFile>> pickReceipts() async {
    final files = await openFiles(acceptedTypeGroups: [_receiptTypes]);
    return [
      for (final file in files)
        CapturedFile(await file.readAsBytes(), fileName: file.name),
    ];
  }

  @override
  Future<CapturedFile?> pickStatement() async {
    final file = await openFile(acceptedTypeGroups: [_statementTypes]);
    if (file == null) return null;
    return CapturedFile(await file.readAsBytes(), fileName: file.name);
  }

  @override
  Future<String?> pickBackupPath() async => (await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'Finance backups', extensions: ['fsbackup']),
    ],
  ))?.path;

  @override
  Future<String?> chooseDirectory() => getDirectoryPath();

  @override
  Future<String?> chooseSaveLocation(String suggestedName) async =>
      (await getSaveLocation(suggestedName: suggestedName))?.path;
}
