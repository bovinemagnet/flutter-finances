import 'dart:io';
import 'dart:typed_data';

import 'package:finance_app/app/app_scope.dart';
import 'package:finance_app/data/app_state.dart';
import 'package:finance_app/features/receipts/receipt_review_screen.dart';
import 'package:finance_app/features/transactions/transaction_form.dart';
import 'package:finance_app/features/transactions/transaction_form_model.dart';
import 'package:finance_app/features/transactions/transaction_list.dart';
import 'package:finance_app/platform/capabilities.dart';
import 'package:finance_app/platform/services.dart';
import 'package:finance_app/platform/text_recognition.dart';
import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:flutter/material.dart' hide Split;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:intl/date_symbol_data_local.dart';

const _fastKdf = Argon2idParameters(
  memoryKiB: 64,
  iterations: 1,
  parallelism: 1,
);

class _NoFiles implements FileImporter {
  @override
  Future<List<CapturedFile>> pickReceipts() async => const [];
  @override
  Future<CapturedFile?> pickStatement() async => null;
  @override
  Future<String?> pickBackupPath() async => null;
  @override
  Future<String?> chooseDirectory() async => null;
  @override
  Future<String?> chooseSaveLocation(String suggestedName) async => null;
}

class _NoScanner implements ReceiptScanner {
  @override
  Future<bool> isAvailable() async => false;
  @override
  Future<List<CapturedFile>> capture() async => const [];
}

class _NoNotifications implements Notifications {
  @override
  Future<void> cancel(int id) async {}
  @override
  Future<void> cancelAll() async {}
  @override
  Future<void> initialise() async {}
  @override
  Future<void> schedule(Reminder reminder, {required bool showDetails}) async {}
}

/// A18: screen reader labels and 200% text on a tablet, with no clipped
/// controls (Flutter reports any layout overflow as a test failure).
void main() {
  setUpAll(() => initializeDateFormatting('en_AU'));
  const tablet = Size(834, 1194);

  Future<void> pumpAt200(
    WidgetTester tester,
    AppState state,
    Widget child,
  ) async {
    tester.view.physicalSize = tablet;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      AppScope(
        state: state,
        services: AppServices(
          capabilities: PlatformCapabilities.forPlatform(
            TargetPlatform.android,
          ),
          scanner: _NoScanner(),
          fileImporter: _NoFiles(),
          shareInbox: EmptyShareInboxForTests(),
          notifications: _NoNotifications(),
          textRecogniser: UnavailableTextRecogniser(),
          workspaceDirectory: Directory.systemTemp,
        ),
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: child,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  late Directory dir;
  late AppState state;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('a18');
  });

  tearDown(() async {
    await state.store.close();
    await dir.delete(recursive: true);
  });

  Future<void> openStore(WidgetTester tester) => tester.runAsync(() async {
    final store = await FinanceStore.create(
      dir,
      keyProtection: KeyProtection.password('secret', kdf: _fastKdf),
    );
    await store.createAccount(
      const Account(
        id: 'bank',
        name: 'Everyday account',
        type: AccountType.transaction,
      ),
    );
    await store.createCategory(
      const Category(
        id: 'groceries',
        name: 'Groceries',
        kind: CategoryKind.expense,
      ),
    );
    state = AppState(store, today: () => LocalDate(2026, 10, 19));
  });

  testWidgets('entry form at 200% text', (tester) async {
    await openStore(tester);
    final handle = tester.ensureSemantics();
    final model = TransactionFormModel(state.chart, today: state.today());
    await pumpAt200(
      tester,
      state,
      Scaffold(
        body: TransactionForm(model: model, onSave: (_) async {}),
      ),
    );
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    expect(find.bySemanticsLabel(RegExp('Amount')), findsWidgets);
    handle.dispose();
  });

  testWidgets('review queue at 200% text keeps every action visible', (
    tester,
  ) async {
    await openStore(tester);
    late Journal journal;
    await tester.runAsync(() async {
      journal = await state.post(
        TransactionDraft(
          type: TransactionType.expense,
          accountId: 'bank',
          amount: Money(6325, Currency.aud),
          effectiveDate: LocalDate(2026, 10, 19),
          payee: 'Fresh Grocer',
          splits: [Split('groceries', Money(6325, Currency.aud))],
        ),
      );
    });
    final handle = tester.ensureSemantics();
    await pumpAt200(
      tester,
      state,
      Scaffold(
        body: TransactionList(
          items: [
            TransactionListItem(
              journal: journal,
              accountName: 'Everyday account',
              categoryLabel: 'Groceries',
              reviewed: false,
              hasReceipt: false,
              unsynced: true,
            ),
          ],
          categories: state.chart.categories.toList(),
          onOpen: (_) {},
          onMarkReviewed: (_) {},
          onCategorise: (_, _) {},
        ),
      ),
    );
    expect(find.byTooltip('Mark reviewed'), findsOneWidget);
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    handle.dispose();
  });

  testWidgets('receipt review and linking at 200% text', (tester) async {
    await openStore(tester);
    late String receiptId;
    await tester.runAsync(() async {
      await state.post(
        TransactionDraft(
          type: TransactionType.expense,
          accountId: 'bank',
          amount: Money(1350, Currency.aud),
          effectiveDate: LocalDate(2026, 10, 19),
          payee: 'Fresh Grocer',
          splits: [Split('groceries', Money(1350, Currency.aud))],
        ),
      );
      final receipt = await state.receipts.capture([
        CapturedFile(
          Uint8List.fromList(img.encodePng(img.Image(width: 4, height: 4))),
          source: CaptureSource.camera,
        ),
      ]);
      receiptId = receipt.id;
    });
    final handle = tester.ensureSemantics();
    await pumpAt200(tester, state, ReceiptReviewScreen(receiptId: receiptId));
    await tester.dragUntilVisible(
      find.widgetWithText(TextField, 'Total paid'),
      find.byType(ListView).last,
      const Offset(0, -200),
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Total paid'),
      '13.50',
    );
    await tester.pumpAndSettle();
    expect(find.text('Attach'), findsOneWidget);
    await tester.dragUntilVisible(
      find.text('Confirm'),
      find.byType(ListView).last,
      const Offset(0, -200),
    );
    expect(find.text('Confirm'), findsOneWidget);
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    handle.dispose();
  });
}

class EmptyShareInboxForTests implements ShareInbox {
  @override
  Stream<List<CapturedFile>> get incoming => const Stream.empty();
  @override
  Future<List<CapturedFile>> takePending() async => const [];
}
