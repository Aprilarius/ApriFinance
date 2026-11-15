import 'models.dart';
import 'money.dart';

Map<String, int> accountBalances(LedgerSnapshot snapshot, {DateTime? through}) {
  final balances = {
    for (final a in snapshot.accounts) a.id: BigInt.from(a.openingMinor),
  };
  final cutoff = through == null
      ? null
      : DateTime(through.year, through.month, through.day);
  for (final e in snapshot.entries) {
    if (cutoff != null && e.date.isAfter(cutoff)) continue;
    final amount = BigInt.from(e.amountMinor);
    final delta = e.kind == EntryKind.expense || e.kind == EntryKind.transfer
        ? -amount
        : amount;
    balances.update(e.accountId, (v) => v + delta);
    if (e.kind == EntryKind.transfer) {
      balances.update(e.targetAccountId!, (v) => v + amount);
    }
  }
  return balances.map((id, value) => MapEntry(id, checkedMoneyTotal(value)));
}

class PeriodTotals {
  const PeriodTotals(this.income, this.expense, this.byCategory);
  final int income, expense;
  final Map<String, int> byCategory;
  int get net => checkedMoneyTotal(BigInt.from(income) - BigInt.from(expense));
}

PeriodTotals monthTotals(
  Iterable<LedgerEntry> entries,
  DateTime month, {
  DateTime? through,
}) {
  var income = BigInt.zero, expense = BigInt.zero;
  final categories = <String, BigInt>{};
  final cutoff = through == null
      ? null
      : DateTime(through.year, through.month, through.day);
  for (final e in entries) {
    if (e.date.year != month.year ||
        e.date.month != month.month ||
        (cutoff != null && e.date.isAfter(cutoff))) {
      continue;
    }
    if (e.kind == EntryKind.income) income += BigInt.from(e.amountMinor);
    if (e.kind == EntryKind.expense || e.kind == EntryKind.refund) {
      final amount = BigInt.from(
        e.kind == EntryKind.refund ? -e.amountMinor : e.amountMinor,
      );
      expense += amount;
      categories.update(e.category, (v) => v + amount, ifAbsent: () => amount);
    }
  }
  return PeriodTotals(
    checkedMoneyTotal(income),
    checkedMoneyTotal(expense),
    Map.unmodifiable(
      categories.map((key, value) => MapEntry(key, checkedMoneyTotal(value))),
    ),
  );
}
