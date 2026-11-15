import 'ledger_math.dart';
import 'money.dart';
import 'models.dart';

class BudgetProgress {
  const BudgetProgress(this.budget, this.spentMinor);
  final CategoryBudget budget;
  final int spentMinor;
  int get remainingMinor => checkedMoneyTotal(
    BigInt.from(budget.limitMinor) - BigInt.from(spentMinor),
  );
  bool get exceeded => spentMinor > budget.limitMinor;
  bool get nearLimit =>
      !exceeded &&
      BigInt.from(spentMinor) * BigInt.from(100) >=
          BigInt.from(budget.limitMinor) * BigInt.from(80);
  double get fraction => (spentMinor / budget.limitMinor).clamp(0.0, 1.0);
}

List<BudgetProgress> budgetProgress(
  LedgerSnapshot snapshot,
  DateTime month, {
  DateTime? through,
  String Function(String)? canonical,
}) {
  final totals = monthTotals(snapshot.entries, month, through: through);
  String category(String value) =>
      canonical?.call(value) ?? value.trim().toLowerCase();
  final key = calendarDate(DateTime(month.year, month.month)).substring(0, 7);
  return snapshot.budgets.where((b) => b.month == key).map((b) {
    final spent = totals.byCategory.entries.where(
      (e) => category(e.key) == category(b.category),
    );
    final amount = sumMoneyTotals(spent.map((e) => e.value));
    return BudgetProgress(b, amount);
  }).toList();
}
