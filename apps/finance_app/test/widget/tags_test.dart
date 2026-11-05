import 'dart:io';

import 'package:finance_app/app/app_scope.dart';
import 'package:finance_app/data/app_state.dart';
import 'package:finance_app/features/reports/report_view.dart';
import 'package:finance_app/features/settings/tags_screen.dart';
import 'package:finance_app/features/transactions/transaction_form.dart';
import 'package:finance_app/features/transactions/transaction_form_model.dart';
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
const _aud = Currency.aud;

void main() {
  setUpAll(() => initializeDateFormatting('en_AU'));
  late Directory dir;
  late AppState state;
  final today = LocalDate(2026, 7, 15);

  setUp(() async => dir = await Directory.systemTemp.createTemp('tags'));
  tearDown(() async {
    await state.store.close();
    await dir.delete(recursive: true);
  });

  Future<Journal> spend(int minor, Set<String> tags) => state.post(
    TransactionDraft(
      type: TransactionType.expense,
      accountId: 'bank',
      amount: Money(minor, _aud),
      effectiveDate: LocalDate(2026, 7, 10),
      splits: [Split('food', Money(minor, _aud))],
      tags: tags,
    ),
  );

  Future<void> start(WidgetTester tester) => tester.runAsync(() async {
    final store = await FinanceStore.create(
      dir,
      keyProtection: KeyProtection.password('secret', kdf: _fastKdf),
    );
    await store.createAccount(
      const Account(id: 'bank', name: 'Bank', type: AccountType.transaction),
    );
    await store.createCategory(
      const Category(id: 'food', name: 'Food', kind: CategoryKind.expense),
    );
    state = AppState(store, today: () => today);
  });

  Future<void> pumpPage(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      AppScope(
        state: state,
        services: testServices(),
        child: MaterialApp(home: Scaffold(body: page)),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('known tags', () {
    testWidgets('are listed most used first', (tester) async {
      await start(tester);
      await tester.runAsync(() async {
        await spend(100, {'kids'});
        await spend(100, {'holiday'});
        await spend(100, {'holiday'});
      });
      expect(state.knownTags, ['holiday', 'kids']);
      expect(state.tagCounts, {'holiday': 2, 'kids': 1});
    });

    testWidgets('leave out corrected entries', (tester) async {
      await start(tester);
      await tester.runAsync(() async {
        final entry = await spend(100, {'holiday'});
        await state.correct(
          entry.id,
          TransactionDraft(
            type: TransactionType.expense,
            accountId: 'bank',
            amount: Money(200, _aud),
            effectiveDate: LocalDate(2026, 7, 10),
            splits: [Split('food', Money(200, _aud))],
            tags: const {'work'},
          ),
        );
      });
      expect(state.tagCounts, {'work': 1});
    });
  });

  group('the entry form', () {
    TransactionForm form(
      TransactionFormModel model,
      List<String> suggestions, {
      Future<void> Function(TransactionDraft)? onSave,
    }) => TransactionForm(
      model: model,
      tagSuggestions: suggestions,
      onSave: onSave ?? (_) async {},
    );

    TransactionFormModel model() => TransactionFormModel(
      Chart(
        currency: _aud,
        accounts: const [
          Account(id: 'bank', name: 'Bank', type: AccountType.transaction),
        ],
        categories: const [
          Category(id: 'food', name: 'Food', kind: CategoryKind.expense),
        ],
      ),
      today: today,
    );

    Future<void> showForm(WidgetTester tester, Widget widget) async {
      tester.view.physicalSize = const Size(600, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: widget)));
      await tester.pumpAndSettle();
    }

    testWidgets('offers existing tags, and tapping one adds it', (
      tester,
    ) async {
      final m = model();
      await showForm(tester, form(m, ['holiday', 'kids']));
      await tester.tap(find.widgetWithText(ActionChip, 'holiday'));
      await tester.pump();
      expect(m.tags, {'holiday'});
      expect(find.widgetWithText(ActionChip, 'holiday'), findsNothing);
      expect(find.widgetWithText(InputChip, 'holiday'), findsOneWidget);
    });

    testWidgets('narrows the suggestions while typing', (tester) async {
      await showForm(tester, form(model(), ['holiday', 'kids']));
      await tester.enterText(find.widgetWithText(TextField, 'Add tag'), 'HOL');
      await tester.pump();
      expect(find.widgetWithText(ActionChip, 'holiday'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, 'kids'), findsNothing);
    });

    testWidgets('does not lose a tag typed but not yet added', (tester) async {
      TransactionDraft? saved;
      final m = model()
        ..accountId = 'bank'
        ..categoryId = 'food'
        ..amountText = '12.50';
      await showForm(tester, form(m, const [], onSave: (d) async => saved = d));
      await tester.enterText(
        find.widgetWithText(TextField, 'Add tag'),
        ' Holiday ',
      );
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(saved!.tags, {'holiday'});
    });
  });

  group('renaming a tag', () {
    testWidgets('changes every entry, and no money', (tester) async {
      await start(tester);
      await tester.runAsync(() async {
        await spend(100, {'holidy', 'kids'});
        await spend(200, {'holidy'});
        await spend(400, {'kids'});
      });
      final balance = state.ledger.displayBalance('bank');
      final count = state.ledger.journals.length;
      await tester.runAsync(() => state.renameTag('holidy', 'holiday'));
      expect(state.tagCounts, {'holiday': 2, 'kids': 2});
      expect(state.ledger.displayBalance('bank'), balance);
      expect(state.ledger.journals, hasLength(count));
      expect(
        state.ledger.journals.every((j) => j.status != JournalStatus.reversed),
        isTrue,
      );
    });

    testWidgets('into an existing tag merges them', (tester) async {
      await start(tester);
      await tester.runAsync(() async {
        await spend(100, {'holidays'});
        await spend(200, {'holiday'});
        await spend(400, {'holidays', 'holiday'});
      });
      await tester.runAsync(() => state.renameTag('holidays', 'holiday'));
      expect(state.tagCounts, {'holiday': 3});
    });

    testWidgets('tidies the new name, and ignores no change', (tester) async {
      await start(tester);
      await tester.runAsync(() async {
        await spend(100, {'holiday'});
      });
      final pending = state.unsyncedCount;
      await tester.runAsync(() => state.renameTag('holiday', '  HOLIDAY '));
      await tester.runAsync(() => state.renameTag('holiday', '   '));
      expect(state.unsyncedCount, pending);
      expect(state.tagCounts, {'holiday': 1});
    });

    testWidgets('shows in the report afterwards', (tester) async {
      await start(tester);
      await tester.runAsync(() async {
        await spend(100, {'holidy'});
        await state.renameTag('holidy', 'holiday');
      });
      final report = spendingByTag(
        state.ledger,
        DateRange(LocalDate(2026, 7, 1), LocalDate(2026, 7, 31)),
      );
      expect(report.row('holiday')!.amount('spending'), Money(100, _aud));
      expect(report.row('holidy'), isNull);
    });
  });

  group('the tags screen', () {
    testWidgets('says what to do when there are none', (tester) async {
      await start(tester);
      await pumpPage(tester, const TagsScreen());
      expect(find.textContaining('No tags yet'), findsOneWidget);
    });

    testWidgets('lists tags with how many entries use them', (tester) async {
      await start(tester);
      await tester.runAsync(() async {
        await spend(100, {'holiday'});
        await spend(100, {'holiday'});
        await spend(100, {'kids'});
      });
      await pumpPage(tester, const TagsScreen());
      expect(find.text('holiday'), findsOneWidget);
      expect(find.text('2 entries'), findsOneWidget);
      expect(find.text('1 entry'), findsOneWidget);
    });

    Future<void> rename(WidgetTester tester, String from, String to) async {
      await tester.tap(find.text(from));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, to);
      await tester.pumpAndSettle();
    }

    Future<void> confirm(WidgetTester tester, String button) async {
      await tester.tap(find.widgetWithText(FilledButton, button));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('renames a tag', (tester) async {
      await start(tester);
      await tester.runAsync(() async {
        await spend(100, {'holidy'});
      });
      await pumpPage(tester, const TagsScreen());
      await rename(tester, 'holidy', 'holiday');
      await confirm(tester, 'Rename');
      expect(state.tagCounts, {'holiday': 1});
      expect(find.text('holiday'), findsOneWidget);
    });

    testWidgets('warns before merging into an existing tag', (tester) async {
      await start(tester);
      await tester.runAsync(() async {
        await spend(100, {'holidays'});
        await spend(100, {'holiday'});
      });
      await pumpPage(tester, const TagsScreen());
      await rename(tester, 'holidays', 'holiday');
      expect(find.textContaining('already exists'), findsOneWidget);
      await confirm(tester, 'Merge');
      expect(state.tagCounts, {'holiday': 2});
    });
  });

  testWidgets('a report shows its note beside the figures', (tester) async {
    await start(tester);
    await tester.runAsync(() async {
      await spend(100, {'holiday'});
    });
    final report = spendingByTag(
      state.ledger,
      DateRange(LocalDate(2026, 7, 1), LocalDate(2026, 7, 31)),
    );
    await pumpPage(tester, ReportView(report: report, onDrillThrough: (_) {}));
    expect(find.textContaining('more than one tag'), findsOneWidget);
  });
}
