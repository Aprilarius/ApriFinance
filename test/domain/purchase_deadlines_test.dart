import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/domain/purchases.dart';
import 'package:personal_finance/domain/purchase_deadlines.dart';

void main() {
  Purchase purchase(
    String id, {
    DateTime? returns,
    DateTime? warranty,
    bool archived = false,
  }) => Purchase(
    id: id,
    name: id,
    date: DateTime(2026, 1, 1),
    amountMinor: 100,
    returnBy: returns,
    warrantyUntil: warranty,
    archived: archived,
  );
  test(
    'calendar uses month and year, excludes archive, keeps both deadline types',
    () {
      final result = purchaseDeadlines([
        purchase('outside', returns: DateTime(2027, 11, 1)),
        purchase('archived', returns: DateTime(2026, 11, 1), archived: true),
        purchase('no-dates'),
        purchase(
          'same-day',
          returns: DateTime(2026, 11, 30),
          warranty: DateTime(2026, 11, 30),
        ),
        purchase('earlier', warranty: DateTime(2026, 11, 1)),
      ], DateTime(2026, 11));
      expect(result.map((d) => d.purchase.id), [
        'earlier',
        'same-day',
        'same-day',
      ]);
      expect(result.map((d) => d.kind), [
        PurchaseDeadlineKind.warranty,
        PurchaseDeadlineKind.returnLimit,
        PurchaseDeadlineKind.warranty,
      ]);
    },
  );
  test('December and January deadlines stay in separate months', () {
    final values = [
      purchase(
        'boundary',
        returns: DateTime(2026, 12, 31),
        warranty: DateTime(2027, 1, 1),
      ),
    ];
    expect(
      purchaseDeadlines(values, DateTime(2026, 12)).single.kind,
      PurchaseDeadlineKind.returnLimit,
    );
    expect(
      purchaseDeadlines(values, DateTime(2027, 1)).single.kind,
      PurchaseDeadlineKind.warranty,
    );
    expect(purchaseDeadlines(values, DateTime(2026, 1)), isEmpty);
  });
}
