import 'package:finance_app/features/onboarding/onboarding_flow.dart';
import 'package:finance_app/features/onboarding/onboarding_model.dart';
import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() => initializeDateFormatting('en_AU'));

  testWidgets('completes setup with an account and a budget', (tester) async {
    tester.view.physicalSize = const Size(600, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final results = <OnboardingResult>[];
    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingFlow(
          model: OnboardingModel(today: LocalDate(2026, 10, 19)),
          onFinish: (r) async => results.add(r),
        ),
      ),
    );
    await tester.tap(find.text('Continue').hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('Only on this device'), findsOneWidget);
    await tester.tap(find.text('Continue').hitTestable());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add account'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Account name'),
      'Everyday',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Opening balance'),
      '1500',
    );
    await tester.tap(find.text('Save account'));
    await tester.pumpAndSettle();
    expect(find.text('Everyday'), findsOneWidget);
    await tester.tap(find.text('Continue').hitTestable());
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Take-home pay'),
      '3123.45',
    );
    await tester.pump();
    await tester.tap(find.text('Continue').hitTestable());
    await tester.pumpAndSettle();
    expect(
      find.textContaining(r'Fortnightly budget from $3,123.45'),
      findsOneWidget,
    );
    await tester.tap(find.text('Finish').hitTestable());
    await tester.pumpAndSettle();

    final result = results.single;
    expect(result.accounts.single.openingBalance, Money(150000, Currency.aud));
    expect(result.plan!.versions.single.income, Money(312345, Currency.aud));
  });
}
