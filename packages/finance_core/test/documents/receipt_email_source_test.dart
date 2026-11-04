import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

void main() {
  test('a receipt captured from email survives the JSON round trip', () {
    final receipt = Receipt(
      id: 'r1',
      capturedAt: DateTime.utc(2026, 11, 4),
      source: CaptureSource.email,
    );
    expect(receiptFromJson(receiptToJson(receipt)).source, CaptureSource.email);
  });

  test('existing capture sources keep their positions', () {
    expect(CaptureSource.values.indexOf(CaptureSource.dragAndDrop), 6);
    expect(CaptureSource.values.last, CaptureSource.email);
  });
}
