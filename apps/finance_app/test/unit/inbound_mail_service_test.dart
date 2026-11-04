import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:finance_app/data/app_state.dart';
import 'package:finance_app/data/entity_types.dart';
import 'package:finance_app/data/inbound_mail_service.dart';
import 'package:finance_app/data/oidc.dart';
import 'package:finance_app/data/receipt_service.dart';
import 'package:finance_app/data/sync_controller.dart';
import 'package:finance_app/platform/services.dart';
import 'package:finance_app/platform/text_recognition.dart';
import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import '../../../../packages/finance_store/test/support/fake_server.dart';

const _fastKdf = Argon2idParameters(
  memoryKiB: 64,
  iterations: 1,
  parallelism: 1,
);
const _user = FakeSyncServer.defaultUser;

class _Recogniser implements TextRecogniser {
  _Recogniser({this.fails = false, this.hold});
  final bool fails;

  /// When set, recognition waits for it.
  final Completer<void>? hold;
  var calls = 0;

  @override
  String get unavailableMessage => 'unavailable';
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<OcrResult> recognise(List<Uint8List> images) async {
    calls++;
    await hold?.future;
    if (fails) throw const TextRecognitionException('could not read');
    return OcrResult.fromText(
      'TOTAL 13.50',
      engine: 'fake',
      engineVersion: '1',
    );
  }
}

/// Holds inbox requests until [gate] completes.
class _GatedClient extends http.BaseClient {
  _GatedClient(this.inner);
  final http.Client inner;
  Completer<void>? gate;
  var inboxRequests = 0;
  String? lastInboxHost;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path.endsWith('/inbound-documents')) {
      inboxRequests++;
      lastInboxHost = request.url.host;
      await gate?.future;
    }
    return inner.send(request);
  }
}

Uint8List _photo() =>
    Uint8List.fromList(img.encodePng(img.Image(width: 400, height: 600)));

Uint8List _pdf({int pages = 1}) => Uint8List.fromList(
  utf8.encode(
    '%PDF-1.7\n'
    '2 0 obj\n<< /Type /Pages /Count $pages >>\nendobj\n'
    '${'3 0 obj\n<< /Type /Page >>\nendobj\n' * pages}'
    'trailer\n<< /Root 1 0 R >>\nstartxref\n0\n%%EOF\n',
  ),
);

/// A JPEG that passes validation but stops the decoder.
Uint8List _corruptJpeg() {
  final good = Uint8List.fromList(
    img.encodeJpg(img.Image(width: 400, height: 600)),
  );
  var start = 2;
  while (!(good[start] == 0xFF && good[start + 1] == 0xC0)) {
    start++;
  }
  return Uint8List.fromList(good)..[start + 11] = 0;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late FakeSyncServer server;
  late _GatedClient http_;
  late AppState state;
  late SyncController controller;
  late _Recogniser recogniser;
  late InboundMailService service;

  Future<void> start({_Recogniser? using, bool connect = true}) async {
    recogniser = using ?? _Recogniser();
    final store = await FinanceStore.create(
      root,
      keyProtection: KeyProtection.password('secret', kdf: _fastKdf),
    );
    state = AppState(store, today: () => LocalDate(2026, 11, 4));
    http_ = _GatedClient(server.client);
    controller = SyncController(
      state,
      tokens: MemoryTokenStore(),
      settingsStore: MemorySyncSettingsStore(),
      redirectUri: 'test:/oauth',
      browserSignIn: (_) async {},
      httpClient: http_,
      accessToken: () async => _user,
      platform: 'test',
      retry: const RetryPolicy(maxAttempts: 1),
      recogniser: recogniser,
    );
    await controller.saveSettings(
      SyncSettings(
        serverUrl: FakeSyncServer.base.toString(),
        issuer: 'https://id.test',
        clientId: 'app',
      ),
    );
    if (connect) {
      final remote = (await controller.remoteWorkspaces()).single;
      await controller.enable(await controller.prepare(existing: remote));
      service = InboundMailService(
        state: state,
        client: controller.inboundMail,
        recogniser: recogniser,
      );
      // Turning sync on starts a collection of its own; let that one finish.
      while (http_.inboxRequests == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('inbound');
    server = FakeSyncServer(workspaceId: 'ws-cloud');
  });

  tearDown(() async {
    controller.dispose();
    await state.store.close();
    await root.delete(recursive: true);
  });

  String deliver({Uint8List? bytes, String contentType = 'application/pdf'}) =>
      server.deliverInbound(
        _user,
        fileName: 'receipt.pdf',
        bytes: bytes ?? _pdf(),
        contentType: contentType,
      );

  Future<void> eventually(bool Function() done) async {
    final end = DateTime.now().add(const Duration(seconds: 3));
    while (!done()) {
      if (DateTime.now().isAfter(end)) fail('not met in time');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('collecting saves a receipt, then acknowledges', () async {
    await start();
    final id = deliver();
    await service.collect();
    final receipt = state.receipts.receipts().single;
    expect(receipt.source, CaptureSource.email);
    expect(receipt.id, nameBasedId(id, 'inbound-receipt'));
    expect(state.receipts.pagesFor(receipt.id), hasLength(1));
    expect(server.inboundAcknowledged, [id]);
  });

  test('collecting creates no financial data', () async {
    await start();
    deliver();
    await service.collect();
    expect(state.ledger.journals, isEmpty);
  });

  test('a failed acknowledge leaves one receipt, and is tried again', () async {
    await start();
    final id = deliver();
    server
      ..failRequests = 1
      ..failPath = 'acknowledge';
    await service.collect();
    expect(state.receipts.receipts(), hasLength(1));
    expect(server.inboundAcknowledged, isEmpty);

    await service.collect();
    final receipt = state.receipts.receipts().single;
    expect(state.receipts.pagesFor(receipt.id), hasLength(1));
    expect(server.inboundAcknowledged, [id]);
  });

  test('a document the device refuses is rejected, not retried', () async {
    await start();
    final id = deliver(bytes: _pdf(pages: 11));
    await service.collect();
    expect(state.receipts.receipts(), isEmpty);
    final notice = state.inboundNotices.single;
    expect(notice.rejections.single.code, 'REJECTED_ON_DEVICE');
    expect(notice.rejections.single.detail, contains('11 pages'));

    final downloads = server.inboundDownloads.length;
    await service.collect();
    expect(server.inboundDownloads, hasLength(downloads));
    expect(server.inboundAcknowledged, isNot(contains(id)));
  });

  test('a corrupt download is not saved, and is tried again', () async {
    await start();
    final id = deliver();
    server.corruptInbound(id);
    await service.collect();
    expect(state.receipts.receipts(), isEmpty);
    expect(server.inboundAcknowledged, isEmpty);
    await service.collect();
    expect(server.inboundDownloads, [id, id]);
  });

  test('a corrupt download stops being repeated on this run', () async {
    await start();
    final id = deliver();
    server.corruptInbound(id);
    for (var i = 0; i < 6; i++) {
      await service.collect();
    }
    expect(server.inboundDownloads, [
      for (var i = 0; i < InboundMailService.maxCaptureAttempts; i++) id,
    ]);
  });

  test('a dropped connection does not use up the attempts', () async {
    await start();
    final id = deliver();
    server
      ..failRequests = InboundMailService.maxCaptureAttempts + 1
      ..failPath = 'download';
    for (var i = 0; i < InboundMailService.maxCaptureAttempts + 1; i++) {
      await service.collect();
    }
    await service.collect();
    expect(server.inboundAcknowledged, [id]);
  });

  test('a document already saved is acknowledged, not downloaded again', () async {
    await start();
    final id = deliver();
    server
      ..failRequests = 1
      ..failPath = 'acknowledge';
    await service.collect();
    expect(server.inboundDownloads, [id]);

    await service.collect();
    expect(server.inboundDownloads, [id]);
    expect(server.inboundAcknowledged, [id]);
  });

  test('a receipt saved before the app stopped is still read', () async {
    await start();
    final id = deliver(bytes: _photo(), contentType: 'image/png');
    // The app stopped after saving, before acknowledging or reading.
    await state.receipts.capture(
      [CapturedFile(_photo(), source: CaptureSource.email)],
      receiptId: nameBasedId(id, 'inbound-receipt'),
    );
    await service.collect();
    await eventually(() => recogniser.calls == 1);
    expect(server.inboundAcknowledged, [id]);
  });

  test('a receipt that came from another device is not read here', () async {
    await start();
    final id = deliver(bytes: _photo(), contentType: 'image/png');
    final receiptId = nameBasedId(id, 'inbound-receipt');
    // The other device saved it but its acknowledge failed; only the record
    // reached this one, without the document.
    await state.store.upsertEntity(
      ReceiptEntityTypes.receipt,
      receiptId,
      receiptToJson(
        Receipt(
          id: receiptId,
          capturedAt: DateTime.utc(2026, 11, 4),
          source: CaptureSource.email,
        ),
      ),
    );
    await service.collect();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(recogniser.calls, 0);
    expect(server.inboundDownloads, isEmpty);
    expect(server.inboundAcknowledged, [id]);
    expect(
      state.receipts.receipt(receiptId)!.extractionState,
      ExtractionState.captured,
    );
  });

  test('a receipt arriving from elsewhere during a download is left alone', () async {
    await start();
    final id = deliver(bytes: _photo(), contentType: 'image/png');
    final receiptId = nameBasedId(id, 'inbound-receipt');
    final service = InboundMailService(
      state: state,
      client: controller.inboundMail,
      recogniser: recogniser,
      capture: (files, {receiptId, capturedAt}) async {
        // Only the record has arrived; the document is on the other device.
        final arrived = Receipt(
          id: receiptId!,
          capturedAt: DateTime.utc(2026, 11, 4),
          source: CaptureSource.email,
        );
        await state.store.upsertEntity(
          ReceiptEntityTypes.receipt,
          arrived.id,
          receiptToJson(arrived),
        );
        return arrived;
      },
    );
    await service.collect();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(
      state.receipts.receipt(receiptId)!.extractionState,
      ExtractionState.captured,
    );
  });

  test('a forwarded image syncs without needing a decision', () async {
    await start();
    deliver(bytes: _photo(), contentType: 'image/png');
    await service.collect();
    await eventually(() => recogniser.calls == 1);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await controller.syncNow();
    await controller.syncNow();
    expect(
      [for (final r in state.store.openReviewItems()) r.entity.type],
      isEmpty,
    );
    expect(state.unsyncedCount, 0);
  });

  test('one bad document does not stop the others', () async {
    await start();
    final bad = deliver();
    server.corruptInbound(bad);
    final good = deliver();
    await service.collect();
    expect(state.receipts.receipts(), hasLength(1));
    expect(server.inboundAcknowledged, [good]);
  });

  test('a document collected elsewhere first is skipped quietly', () async {
    await start();
    final id = deliver();
    final inbox = await controller.inboundMail.inbox(
      state.settings.workspaceId,
    );
    await controller.inboundMail.acknowledge(
      state.settings.workspaceId,
      inbox.documents.single.id,
    );
    await service.collect();
    expect(state.receipts.receipts(), isEmpty);
    expect(server.inboundAcknowledged, [id]);
  });

  test('a network failure does not throw, and acknowledges nothing', () async {
    await start();
    deliver();
    server.offline = true;
    await service.collect();
    expect(state.receipts.receipts(), isEmpty);
    server.offline = false;
    expect(server.inboundAcknowledged, isEmpty);
  });

  test('an older server is tolerated', () async {
    await start();
    server.inboundSupported = false;
    await service.collect();
    expect(state.inboundNotices, isEmpty);
  });

  Future<void> eventuallyHost(bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('images are read', () async {
    await start();
    deliver(bytes: _photo(), contentType: 'image/png');
    await service.collect();
    await eventually(() => recogniser.calls == 1);
  });

  test('a forwarded PDF is marked for entering by hand', () async {
    await start();
    deliver();
    await service.collect();
    final receipt = state.receipts.receipts().single;
    await eventually(
      () =>
          state.receipts.receipt(receipt.id)!.extractionState ==
          ExtractionState.extractionFailed,
    );
    expect(recogniser.calls, 0);
  });

  test('a recognition failure keeps the receipt', () async {
    await start(using: _Recogniser(fails: true));
    final id = deliver(bytes: _photo(), contentType: 'image/png');
    await service.collect();
    await eventually(() => recogniser.calls == 1);
    expect(state.receipts.receipts(), hasLength(1));
    expect(server.inboundAcknowledged, [id]);
  });

  test('a repeat collection does not read the receipt again', () async {
    await start();
    deliver(bytes: _photo(), contentType: 'image/png');
    server
      ..failRequests = 1
      ..failPath = 'acknowledge';
    await service.collect();
    await service.collect();
    await eventually(() => recogniser.calls > 0);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(recogniser.calls, 1);
  });

  test('slow recognition does not hold up collection', () async {
    final hold = Completer<void>();
    await start(using: _Recogniser(hold: hold));
    deliver(bytes: _photo(), contentType: 'image/png');
    await service.collect().timeout(const Duration(seconds: 2));
    final second = deliver();
    await service.collect().timeout(const Duration(seconds: 2));
    expect(server.inboundAcknowledged, contains(second));
    hold.complete();
  });

  group('an image the decoder cannot read', () {
    test('arrives as a receipt and is acknowledged', () async {
      await start();
      final id = deliver(bytes: _corruptJpeg(), contentType: 'image/jpeg');
      await service.collect();
      expect(state.receipts.receipts(), hasLength(1));
      expect(server.inboundAcknowledged, [id]);
    });

    test('is not downloaded and saved over and over', () async {
      await start();
      final id = deliver(bytes: _corruptJpeg(), contentType: 'image/jpeg');
      await service.collect();
      // Recognition runs alongside and saves its own result; let it finish.
      await eventually(() => recogniser.calls == 1);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final pending = state.unsyncedCount;
      for (var i = 0; i < 3; i++) {
        await service.collect();
      }
      expect(server.inboundDownloads, [id]);
      expect(state.unsyncedCount, pending);
    });
  });

  group('a capture that keeps failing', () {
    late int attempts;

    InboundMailService failing() => InboundMailService(
      state: state,
      client: controller.inboundMail,
      recogniser: recogniser,
      capture: (files, {receiptId, capturedAt}) async {
        attempts++;
        throw const FileSystemException('disk full');
      },
    );

    setUp(() => attempts = 0);

    test('stops being retried on this run, and is never rejected', () async {
      await start();
      final id = deliver();
      final service = failing();
      for (var i = 0; i < 6; i++) {
        await service.collect();
      }
      expect(attempts, InboundMailService.maxCaptureAttempts);
      expect(server.inboundDownloads, hasLength(attempts));
      expect(server.inboundAcknowledged, isNot(contains(id)));
      expect(state.inboundNotices, isEmpty);
      // The document is still waiting, for the next run of the app.
      final inbox = await controller.inboundMail.inbox(
        state.settings.workspaceId,
      );
      expect(inbox.documents.single.id, id);
    });

    test('adds nothing to the changes waiting to upload', () async {
      await start();
      deliver();
      final pending = state.unsyncedCount;
      await failing().collect();
      expect(state.unsyncedCount, pending);
    });
  });

  group('a document that cannot reach this device', () {
    String oldDocument() {
      final id = server.deliverInbound(
        _user,
        fileName: 'old.pdf',
        bytes: _pdf(),
        receivedAt: DateTime.now().toUtc().subtract(const Duration(days: 8)),
      );
      server.corruptInbound(id);
      return id;
    }

    test('is reported after a week, before it expires', () async {
      await start();
      final id = oldDocument();
      await service.collect();
      final notice = state.inboundNotices.single;
      expect(notice.messageId, id);
      expect(notice.outcome, 'not_collected');
      expect(notice.rejections.single.fileName, 'old.pdf');
    });

    test('is not reported while it is recent', () async {
      await start();
      final id = deliver();
      server.corruptInbound(id);
      await service.collect();
      expect(state.inboundNotices, isEmpty);
    });

    test('is not reported once it arrives', () async {
      await start();
      final id = server.deliverInbound(
        _user,
        fileName: 'old.pdf',
        bytes: _pdf(),
        receivedAt: DateTime.now().toUtc().subtract(const Duration(days: 8)),
      );
      await service.collect();
      expect(server.inboundAcknowledged, [id]);
      expect(state.inboundNotices, isEmpty);
    });
  });

  test(
    'after the service address changes, collecting uses the new one',
    () async {
      await start();
      await controller.saveSettings(
        const SyncSettings(
          serverUrl: 'https://second.test',
          issuer: 'https://id.test',
          clientId: 'app',
        ),
      );
      await controller.syncNow();
      await eventuallyHost(() => http_.lastInboxHost == 'second.test');
      expect(http_.lastInboxHost, 'second.test');
    },
  );

  group('notices', () {
    test('reach the app state', () async {
      await start();
      server.addInboundNotice(_user, outcome: 'no_attachment');
      var notified = 0;
      state.addListener(() => notified++);
      await service.collect();
      expect(state.inboundNotices.single.outcome, 'no_attachment');
      expect(notified, greaterThan(0));
    });

    test('every dismissal is remembered, whichever is on offer', () async {
      await start();
      final first = server.addInboundNotice(_user, outcome: 'no_attachment');
      await service.collect();
      await state.dismissInboundNotice(first);
      final second = server.addInboundNotice(_user, outcome: 'failed');
      await service.collect();
      await state.dismissInboundNotice(second);
      await service.collect();
      expect(state.inboundNotices, isEmpty);
    });

    test('a dismissal does not touch the shared preferences', () async {
      await start();
      await state.setMinimumBuffer(Money(1000, Currency.aud));
      final id = server.addInboundNotice(_user, outcome: 'no_attachment');
      await service.collect();
      await state.dismissInboundNotice(id);
      expect(
        state.store
            .entity(
              AppEntityTypes.appPreferences,
              AppEntityTypes.appPreferencesId,
            )!
            .json
            .containsKey('dismissedInboundNotices'),
        isFalse,
      );
    });

    test('stay hidden once dismissed', () async {
      await start();
      final id = server.addInboundNotice(_user, outcome: 'no_attachment');
      await service.collect();
      await state.dismissInboundNotice(id);
      expect(state.inboundNotices, isEmpty);
      await service.collect();
      expect(state.inboundNotices, isEmpty);
    });
  });

  group('two devices that both save and read one document', () {
    late AppState otherState;
    late SyncController other;
    late Directory otherRoot;

    Future<void> startOther() async {
      otherRoot = await Directory.systemTemp.createTemp('inbound-other');
      final store = await FinanceStore.create(
        otherRoot,
        keyProtection: KeyProtection.password('secret', kdf: _fastKdf),
      );
      otherState = AppState(store, today: () => LocalDate(2026, 11, 4));
      other = SyncController(
        otherState,
        tokens: MemoryTokenStore(),
        settingsStore: MemorySyncSettingsStore(),
        redirectUri: 'test:/oauth',
        browserSignIn: (_) async {},
        httpClient: server.client,
        accessToken: () async => _user,
        platform: 'test',
        retry: const RetryPolicy(maxAttempts: 1),
        recogniser: _Recogniser(),
      );
      await other.saveSettings(
        SyncSettings(
          serverUrl: FakeSyncServer.base.toString(),
          issuer: 'https://id.test',
          clientId: 'app',
        ),
      );
      final remote = (await other.remoteWorkspaces()).single;
      await other.enable(await other.prepare(existing: remote));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    tearDown(() async {
      other.dispose();
      await otherState.store.close();
      await otherRoot.delete(recursive: true);
    });

    /// This device saved and read the document, but lost its connection before
    /// acknowledging it or sending anything. [other] then collected it too.
    Future<String> bothRead() async {
      await start();
      await startOther();
      final id = deliver(bytes: _photo(), contentType: 'image/png');
      final receiptId = nameBasedId(id, 'inbound-receipt');
      final inbox = await controller.inboundMail.inbox(
        state.settings.workspaceId,
      );
      await state.receipts.capture(
        [
          CapturedFile(
            _photo(),
            fileName: 'receipt.png',
            source: CaptureSource.email,
          ),
        ],
        receiptId: receiptId,
        capturedAt: inbox.documents.single.receivedAt,
      );
      await state.receipts.extract(receiptId, recogniser);
      await other.syncNow();
      await eventually(
        () =>
            otherState.receipts.receipt(receiptId)?.extractionState ==
            ExtractionState.needsReview,
      );
      await other.syncNow();
      return receiptId;
    }

    test('neither asks anyone to decide', () async {
      final receiptId = await bothRead();
      final otherReading = otherState.receipts
          .receipt(receiptId)!
          .latestExtractionId;
      await controller.syncNow();
      await controller.syncNow();
      expect(
        [for (final r in state.store.openReviewItems()) r.entity.type],
        isEmpty,
      );
      expect(state.unsyncedCount, 0);
      final receipt = state.receipts.receipt(receiptId)!;
      expect(receipt.extractionState, ExtractionState.needsReview);
      expect(receipt.latestExtractionId, otherReading);
    });

    test('a review on this device still goes to a person', () async {
      final receiptId = await bothRead();
      await state.receipts.review(
        receiptId,
        ReceiptFields(
          merchant: 'Fresh Grocer',
          total: Money(1350, Currency.aud),
          date: LocalDate(2026, 11, 4),
        ),
        const KeepDocumentOnly(),
      );
      await controller.syncNow();
      expect(
        [for (final r in state.store.openReviewItems()) r.entity.type],
        contains(ReceiptEntityTypes.receipt),
      );
    });
  });

  group('after a sync', () {
    Future<void> until(bool Function() done) async {
      final end = DateTime.now().add(const Duration(seconds: 3));
      while (!done()) {
        if (DateTime.now().isAfter(end)) fail('not met in time');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    test('a successful sync collects', () async {
      await start();
      final id = deliver();
      await controller.syncNow();
      await until(() => server.inboundAcknowledged.contains(id));
      expect(state.receipts.receipts(), hasLength(1));
    });

    test('sync is finished while collecting continues', () async {
      await start();
      http_.gate = Completer<void>();
      await controller.syncNow();
      expect(controller.phase, SyncPhase.idle);
      http_.gate!.complete();
    });

    test('a failing collection leaves sync healthy', () async {
      await start();
      server
        ..failRequests = 1
        ..failPath = 'inbound-documents';
      await controller.syncNow();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(controller.phase, SyncPhase.idle);
      expect(controller.lastError, isNull);
    });

    test('a failed sync does not collect', () async {
      await start();
      final before = http_.inboxRequests;
      server.offline = true;
      await controller.syncNow();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(controller.phase, SyncPhase.failed);
      expect(http_.inboxRequests, before);
      server.offline = false;
    });

    test('a local workspace never asks', () async {
      await start(connect: false);
      await controller.syncNow();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(http_.inboxRequests, 0);
    });
  });
}
