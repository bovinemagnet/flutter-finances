import 'dart:convert';
import 'dart:typed_data';

import 'package:finance_store/finance_store.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support/devices.dart';
import 'support/fake_server.dart';
import 'support/store_fixtures.dart';

void main() {
  late TempDir temp;
  late FakeSyncServer server;
  late Device device;
  late InboundMailClient client;
  late String workspaceId;
  final bytes = Uint8List.fromList(utf8.encode('%PDF-1.7\nreceipt\n%%EOF\n'));

  setUp(() async {
    temp = TempDir();
    server = FakeSyncServer(workspaceId: 'ws-cloud');
    device = await Device.create(temp, 'a', server);
    await device.enableSync(server);
    client = InboundMailClient.of(device.client);
    workspaceId = server.workspaceId;
  });

  tearDown(() async {
    await device.close();
    temp.dispose();
  });

  String deliver({Uint8List? content, String fileName = 'receipt.pdf'}) =>
      server.deliverInbound(
        FakeSyncServer.defaultUser,
        fileName: fileName,
        bytes: content ?? bytes,
      );

  group('availability', () {
    test('reports what the server says', () async {
      expect(await client.available(), isTrue);
      server.inboundAvailable = false;
      expect(await client.available(), isFalse);
    });

    test('an older server without these endpoints is unavailable', () async {
      server.inboundSupported = false;
      expect(await client.available(), isFalse);
    });
  });

  group('address', () {
    test('is null until turned on', () async {
      expect(await client.address(workspaceId), isNull);
    });

    test('can be created, shown, replaced and turned off', () async {
      final created = await client.createOrReplaceAddress(workspaceId);
      expect(created.address, endsWith('@receipts.test'));
      expect((await client.address(workspaceId))!.address, created.address);

      final replaced = await client.createOrReplaceAddress(workspaceId);
      expect(replaced.address, isNot(created.address));

      await client.revokeAddress(workspaceId);
      expect(await client.address(workspaceId), isNull);
    });
  });

  group('inbox', () {
    test('describes documents', () async {
      final id = deliver();
      final inbox = await client.inbox(workspaceId);
      final document = inbox.documents.single;
      expect(document.id, id);
      expect(document.fileName, 'receipt.pdf');
      expect(document.contentType, 'application/pdf');
      expect(document.sizeBytes, bytes.length);
      expect(document.sha256, hasLength(64));
      expect(document.receivedAt.isUtc, isTrue);
      expect(inbox.notices, isEmpty);
    });

    test('describes notices with their rejections', () async {
      server.addInboundNotice(
        FakeSyncServer.defaultUser,
        outcome: 'rejected',
        rejections: const [
          {'fileName': 'evil.pdf', 'code': 'UNSUPPORTED_TYPE', 'detail': null},
        ],
      );
      final notice = (await client.inbox(workspaceId)).notices.single;
      expect(notice.outcome, 'rejected');
      expect(notice.sender, 'shop@example.com');
      expect(notice.rejections.single.fileName, 'evil.pdf');
      expect(notice.rejections.single.code, 'UNSUPPORTED_TYPE');
      expect(notice.rejections.single.detail, isNull);
    });

    test('lists recent emails, newest first', () async {
      deliver();
      server.addInboundNotice(FakeSyncServer.defaultUser, outcome: 'failed');
      final recent = (await client.inbox(workspaceId)).recent;
      expect(recent.map((r) => r.outcome), ['failed', 'documents']);
    });

    test('a server without the recent list gives an empty one', () async {
      server.inboundSendsRecent = false;
      expect((await client.inbox(workspaceId)).recent, isEmpty);
    });

    test('an older server gives an empty inbox', () async {
      server.inboundSupported = false;
      final inbox = await client.inbox(workspaceId);
      expect(inbox.documents, isEmpty);
      expect(inbox.notices, isEmpty);
    });
  });

  group('download', () {
    test('returns the bytes', () async {
      deliver();
      final document = (await client.inbox(workspaceId)).documents.single;
      expect(await client.download(workspaceId, document), bytes);
    });

    test('a large download gets longer than an ordinary request', () async {
      deliver();
      final document = (await client.inbox(workspaceId)).documents.single;
      final slow = _SlowObjects(server.client);
      final patient = InboundMailClient(
        SyncTransport(
          client: slow,
          baseUri: FakeSyncServer.base,
          accessToken: () async => FakeSyncServer.defaultUser,
          retry: const RetryPolicy(maxAttempts: 1),
          timeout: const Duration(milliseconds: 100),
        ),
      );
      expect(await patient.download(workspaceId, document), bytes);
    });

    test('never sends the access token to object storage', () async {
      deliver();
      final document = (await client.inbox(workspaceId)).documents.single;
      await client.download(workspaceId, document);
      final object = server.received.lastWhere(
        (r) => r.url.host == 'objects.test',
      );
      expect(object.headers.containsKey('authorization'), isFalse);
    });

    test('refuses bytes that do not match the hash', () async {
      deliver();
      final document = (await client.inbox(workspaceId)).documents.single;
      server.corruptInbound(document.id);
      await expectLater(
        client.download(workspaceId, document),
        throwsA(isA<InboundDocumentCorruptException>()),
      );
    });

    test('says when the document has gone', () async {
      deliver();
      final document = (await client.inbox(workspaceId)).documents.single;
      await client.acknowledge(workspaceId, document.id);
      await expectLater(
        client.download(workspaceId, document),
        throwsA(isA<InboundDocumentGoneException>()),
      );
    });
  });

  group('finishing with a document', () {
    test('acknowledge removes it, and repeating it is harmless', () async {
      final id = deliver();
      await client.acknowledge(workspaceId, id);
      await client.acknowledge(workspaceId, id);
      expect((await client.inbox(workspaceId)).documents, isEmpty);
      expect(server.inboundAcknowledged, [id, id]);
    });

    test('reject sends the reason', () async {
      final id = deliver();
      await client.reject(
        workspaceId,
        id,
        code: 'REJECTED_ON_DEVICE',
        detail: 'Too many pages',
      );
      final inbox = await client.inbox(workspaceId);
      expect(inbox.documents, isEmpty);
      final rejection = inbox.notices.single.rejections.single;
      expect(rejection.code, 'REJECTED_ON_DEVICE');
      expect(rejection.detail, 'Too many pages');
    });
  });
}

/// Delays object storage responses past an ordinary request's timeout.
class _SlowObjects extends http.BaseClient {
  _SlowObjects(this.inner);
  final http.Client inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.host == 'objects.test') {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return inner.send(request);
  }
}
