import 'dart:io';

import 'package:cunning_document_scanner/cunning_document_scanner.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../capabilities.dart';
import '../services.dart';

/// VisionKit on iOS and the ML Kit document scanner on Android, through one
/// plugin. Edge detection, perspective correction and multi-page capture are
/// provided by the native scanner.
class NativeDocumentScanner implements ReceiptScanner {
  NativeDocumentScanner(this.capabilities);
  final PlatformCapabilities capabilities;

  @override
  Future<bool> isAvailable() async => capabilities.documentScanner;

  @override
  Future<List<CapturedFile>> capture() async {
    try {
      final paths = await CunningDocumentScanner.getPictures(noOfPages: 10);
      if (paths == null || paths.isEmpty) {
        throw CaptureException(CaptureFailure.cancelled);
      }
      return [
        for (final path in paths)
          CapturedFile(
            await File(path).readAsBytes(),
            fileName: path.split('/').last,
            source: CaptureSource.documentScanner,
          ),
      ];
    } on CunningDocumentScannerException catch (e) {
      throw CaptureException(
        e.code == 'permission_denied'
            ? CaptureFailure.permissionDenied
            : CaptureFailure.unavailable,
        e.message,
      );
    } on PlatformException catch (e) {
      // Missing scanner modules or Play services: let the fallback run.
      throw CaptureException(CaptureFailure.unavailable, e.message);
    } on MissingPluginException catch (e) {
      throw CaptureException(CaptureFailure.unavailable, e.message);
    }
  }
}

/// Basic camera or photo capture with manual crop afterwards; needs no
/// downloaded resources, so it works on first launch in flight mode.
class BasicCameraScanner implements ReceiptScanner {
  BasicCameraScanner(this.capabilities, {this.fromLibrary = false});
  final PlatformCapabilities capabilities;
  final bool fromLibrary;
  final _picker = ImagePicker();

  @override
  Future<bool> isAvailable() async => fromLibrary || capabilities.cameraCapture;

  @override
  Future<List<CapturedFile>> capture() async {
    try {
      final files = fromLibrary
          ? await _picker.pickMultiImage(requestFullMetadata: false)
          : [
              ?await _picker.pickImage(
                source: ImageSource.camera,
                requestFullMetadata: false,
              ),
            ];
      if (files.isEmpty) throw CaptureException(CaptureFailure.cancelled);
      return [
        for (final file in files)
          CapturedFile(
            await file.readAsBytes(),
            fileName: file.name,
            source: fromLibrary
                ? CaptureSource.photoLibrary
                : CaptureSource.camera,
          ),
      ];
    } on PlatformException catch (e) {
      throw CaptureException(
        e.code.contains('denied')
            ? CaptureFailure.permissionDenied
            : CaptureFailure.failed,
        e.message,
      );
    }
  }
}
