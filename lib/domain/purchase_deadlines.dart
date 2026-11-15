import 'purchases.dart';

enum PurchaseDeadlineKind { returnLimit, warranty }

extension PurchaseDeadlineLabel on PurchaseDeadlineKind {
  String get label => switch (this) {
    PurchaseDeadlineKind.returnLimit => 'Срок возврата',
    PurchaseDeadlineKind.warranty => 'Окончание гарантии',
  };
}

class PurchaseDeadline {
  const PurchaseDeadline(this.purchase, this.date, this.kind);
  final Purchase purchase;
  final DateTime date;
  final PurchaseDeadlineKind kind;
}

List<PurchaseDeadline> purchaseDeadlines(
  Iterable<Purchase> purchases,
  DateTime month,
) {
  final result = <PurchaseDeadline>[];
  for (final p in purchases.where((p) => !p.archived)) {
    for (final (date, kind) in [
      (p.returnBy, PurchaseDeadlineKind.returnLimit),
      (p.warrantyUntil, PurchaseDeadlineKind.warranty),
    ]) {
      if (date != null &&
          date.year == month.year &&
          date.month == month.month) {
        result.add(PurchaseDeadline(p, date, kind));
      }
    }
  }
  result.sort((a, b) {
    final byDate = a.date.compareTo(b.date);
    if (byDate != 0) return byDate;
    final byKind = a.kind.index.compareTo(b.kind.index);
    if (byKind != 0) return byKind;
    return a.purchase.id.compareTo(b.purchase.id);
  });
  return List.unmodifiable(result);
}
