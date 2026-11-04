import 'dart:io';

import 'package:finance_app/app/app_scope.dart';
import 'package:finance_app/data/app_state.dart';
import 'package:finance_app/features/receipts/receipts_page.dart';
import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:flutter/material.dart' hide Split;
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../support/test_services.dart';

const _fastKdf = Argon2idParameters(
  memoryKiB: 64,
  iterations: 1,
  parallelism: 1,
);

void main() {
  setUpAll(() => initializeDateFormatting('en_AU'));
  late Directory dir;
  late AppState state;

  setUp(() async => dir = await Directory.systemTemp.createTemp('notices'));
  tearDown(() async {
    await state.store.close();
    await dir.delete(recursive: true);
  });

  InboundNotice notice(
    String id,
    String outcome, {
    String sender = 'shop@example.com',
    List<InboundRejection> rejections = const [],
  }) => InboundNotice(
    messageId: id,
    sender: sender,
    receivedAt: DateTime.utc(2026, 11, 4),
    outcome: outcome,
    rejections: rejections,
  );

  Future<void> pump(WidgetTester tester, List<InboundNotice> notices) async {
    await tester.runAsync(() async {
      final store = await FinanceStore.create(
        dir,
        keyProtection: KeyProtection.password('secret', kdf: _fastKdf),
      );
      state = AppState(store, today: () => LocalDate(2026, 11, 4));
    });
    state.setInboundNotices(notices);
    tester.view.physicalSize = const Size(411, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      AppScope(
        state: state,
        services: testServices(),
        child: const MaterialApp(home: Scaffold(body: ReceiptsPage())),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('no notices, nothing shown', (tester) async {
    await pump(tester, const []);
    expect(find.textContaining('Email from'), findsNothing);
  });

  testWidgets('an email with no attachment is explained', (tester) async {
    await pump(tester, [notice('a', 'no_attachment')]);
    expect(
      find.text('Email from shop@example.com had no attachment'),
      findsOneWidget,
    );
  });

  testWidgets('a rate limit and a failure each say what happened', (
    tester,
  ) async {
    await pump(tester, [notice('a', 'rate_limited'), notice('b', 'failed')]);
    expect(find.textContaining('daily limit'), findsOneWidget);
    expect(find.textContaining('could not be processed'), findsOneWidget);
  });

  testWidgets('refused attachments are named, with the reason', (tester) async {
    await pump(tester, [
      notice(
        'a',
        'rejected',
        rejections: const [
          InboundRejection(fileName: 'evil.pdf', code: 'UNSUPPORTED_TYPE'),
          InboundRejection(fileName: 'huge.pdf', code: 'TOO_LARGE'),
          InboundRejection(fileName: 'more.pdf', code: 'TOO_MANY'),
        ],
      ),
      notice(
        'b',
        'rejected',
        rejections: const [
          InboundRejection(fileName: 'odd.pdf', code: 'ACTIVE_CONTENT'),
          InboundRejection(
            fileName: 'long.pdf',
            code: 'REJECTED_ON_DEVICE',
            detail: 'It has 11 pages.',
          ),
        ],
      ),
    ]);
    expect(
      find.textContaining('evil.pdf: not an image or PDF'),
      findsOneWidget,
    );
    expect(find.textContaining('huge.pdf: larger than 20 MB'), findsOneWidget);
    expect(
      find.textContaining('more.pdf: too many attachments'),
      findsOneWidget,
    );
    expect(
      find.textContaining('odd.pdf: failed the safety check'),
      findsOneWidget,
    );
    expect(find.textContaining('long.pdf: It has 11 pages.'), findsOneWidget);
  });

  testWidgets('some arrived and some did not is still explained', (
    tester,
  ) async {
    await pump(tester, [
      notice(
        'a',
        'documents',
        rejections: const [
          InboundRejection(fileName: 'evil.pdf', code: 'UNSUPPORTED_TYPE'),
        ],
      ),
    ]);
    expect(find.textContaining('Some attachments'), findsOneWidget);
  });

  testWidgets('a document that cannot reach this device is explained', (
    tester,
  ) async {
    await pump(tester, [
      notice(
        'a',
        'not_collected',
        sender: '',
        rejections: const [
          InboundRejection(fileName: 'old.pdf', code: 'NOT_COLLECTED'),
        ],
      ),
    ]);
    expect(find.textContaining('has not reached this device'), findsOneWidget);
    expect(
      find.textContaining('old.pdf: expires 30 days after it arrived'),
      findsOneWidget,
    );
  });

  testWidgets('a missing sender still reads properly', (tester) async {
    await pump(tester, [notice('a', 'no_attachment', sender: '')]);
    expect(find.text('An email had no attachment'), findsOneWidget);
  });

  testWidgets('hostile text is shown as plain text', (tester) async {
    await pump(tester, [notice('a', 'no_attachment', sender: '<b>x</b>')]);
    expect(find.textContaining('<b>x</b>'), findsOneWidget);
  });

  testWidgets('a notice can be dismissed', (tester) async {
    await pump(tester, [notice('a', 'no_attachment')]);
    await tester.tap(find.byTooltip('Dismiss'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(find.textContaining('Email from'), findsNothing);
    expect(state.inboundNotices, isEmpty);
  });

  testWidgets('at most three show, and the rest are counted', (tester) async {
    await pump(tester, [
      for (var i = 0; i < 6; i++) notice('$i', 'no_attachment'),
    ]);
    expect(find.byTooltip('Dismiss'), findsNWidgets(3));
    expect(find.text('3 more emails to look at'), findsOneWidget);

    await tester.tap(find.byTooltip('Dismiss').first);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(find.text('2 more emails to look at'), findsOneWidget);
  });

  testWidgets('one more email reads properly', (tester) async {
    await pump(tester, [
      for (var i = 0; i < 4; i++) notice('$i', 'no_attachment'),
    ]);
    expect(find.text('1 more email to look at'), findsOneWidget);
  });

  testWidgets('a notice with many refused files keeps the page usable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    addTearDown(tester.view.reset);
    await pump(tester, [
      notice(
        'a',
        'rejected',
        rejections: [
          for (var i = 0; i < 60; i++)
            InboundRejection(
              fileName: '${'long-name-' * 20}$i.pdf',
              code: 'TOO_MANY',
            ),
        ],
      ),
    ]);
    tester.view.physicalSize = const Size(360, 640);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('and 57 more'), findsOneWidget);
    expect(find.byTooltip('Dismiss').hitTestable(), findsOneWidget);
    expect(
      find
          .text('No receipts yet. Use Scan receipt to capture one.')
          .hitTestable(),
      findsOneWidget,
    );
  });

  testWidgets('three large notices still leave the receipts in view', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    addTearDown(tester.view.reset);
    await pump(tester, [
      for (var n = 0; n < 3; n++)
        notice(
          '$n',
          'rejected',
          rejections: [
            for (var i = 0; i < 10; i++)
              InboundRejection(fileName: 'file$i.pdf', code: 'TOO_MANY'),
          ],
        ),
    ]);
    tester.view.physicalSize = const Size(360, 640);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
