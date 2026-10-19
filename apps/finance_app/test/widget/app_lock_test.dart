import 'package:finance_app/app/app_lock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAuthenticator implements DeviceAuthenticator {
  var calls = 0;
  var succeed = true;
  @override
  Future<bool> isSupported() async => true;
  @override
  Future<bool> authenticate(String reason) async {
    calls++;
    return succeed;
  }
}

void main() {
  testWidgets('locks on launch and after time in the background', (
    tester,
  ) async {
    final auth = _FakeAuthenticator()..succeed = false;
    var now = DateTime(2026, 10, 19, 9);
    await tester.pumpWidget(
      MaterialApp(
        home: AppLockGate(
          enabled: true,
          authenticator: auth,
          clock: () => now,
          child: const Text('finances'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('finances'), findsNothing);
    expect(find.text('Unlock'), findsOneWidget);

    auth.succeed = true;
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(find.text('finances'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    now = now.add(const Duration(seconds: 30));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(
      find.text('finances'),
      findsOneWidget,
      reason: 'short absences do not lock',
    );

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    now = now.add(const Duration(minutes: 6));
    auth.succeed = false;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('finances'), findsNothing);
  });

  testWidgets('passes straight through when the lock is off', (tester) async {
    final auth = _FakeAuthenticator();
    await tester.pumpWidget(
      MaterialApp(
        home: AppLockGate(
          enabled: false,
          authenticator: auth,
          child: const Text('finances'),
        ),
      ),
    );
    expect(find.text('finances'), findsOneWidget);
    expect(auth.calls, 0);
  });
}
