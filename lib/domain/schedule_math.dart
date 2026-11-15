import 'models.dart';
import 'money.dart';

DateTime dayOnly(DateTime date) => DateTime(date.year, date.month, date.day);

DateTime periodDate(Obligation o, int index) {
  if (index < 0) throw const DomainError('Неверный период');
  final a = o.anchor;
  switch (o.repeat) {
    case RepeatRule.once:
      return dayOnly(a);
    case RepeatRule.weekly:
      return DateTime(a.year, a.month, a.day + index * 7);
    case RepeatRule.monthly:
      final first = DateTime(a.year, a.month + index);
      final lastDay = DateTime(first.year, first.month + 1, 0).day;
      return DateTime(
        first.year,
        first.month,
        a.day > lastDay ? lastDay : a.day,
      );
    case RepeatRule.yearly:
      final year = a.year + index;
      final lastDay = DateTime(year, a.month + 1, 0).day;
      return DateTime(year, a.month, a.day > lastDay ? lastDay : a.day);
  }
}

void validateObligation(Obligation o) {
  if (o.id.isEmpty ||
      o.id.length > 80 ||
      o.name.trim().isEmpty ||
      o.name.length > 100 ||
      o.category.trim().isEmpty ||
      o.category.length > 60 ||
      ![EntryKind.income, EntryKind.expense].contains(o.kind) ||
      o.amountMinor <= 0 ||
      o.amountMinor > maxMoneyMinor ||
      o.anchor.year < 2000 ||
      o.anchor.year > 2100 ||
      o.nextIndex < 0 ||
      o.nextIndex > 6000 ||
      o.version < 1 ||
      (o.repeat == RepeatRule.once && o.nextIndex > 1) ||
      ![0, 1, 3, 7].contains(o.reminderDays)) {
    throw const DomainError(
      'Проверьте название, сумму, категорию и даты платежа',
    );
  }
  if (o.trialEnd != null &&
      (o.trialEnd!.year < 2000 || o.trialEnd!.year > 2100)) {
    throw const DomainError('Недопустимая дата пробного периода');
  }
  if (o.manageUrl.length > 500 ||
      (o.manageUrl.isNotEmpty &&
          (Uri.tryParse(o.manageUrl)?.scheme != 'https' ||
              Uri.tryParse(o.manageUrl)?.host.isEmpty != false))) {
    throw const DomainError(
      'Ссылка должна начинаться с https:// и содержать адрес сайта',
    );
  }
}

class PlannedOccurrence {
  const PlannedOccurrence(this.obligation, this.index, this.date);
  final Obligation obligation;
  final int index;
  final DateTime date;
  String get key => '${obligation.id}:$index';
}

List<PlannedOccurrence> occurrences(
  Obligation o,
  DateTime from,
  DateTime through,
) {
  if (!o.active) return [];
  final result = <PlannedOccurrence>[];
  for (var i = o.nextIndex; i <= 6000; i++) {
    if (o.repeat == RepeatRule.once && i > 0) break;
    final due = periodDate(o, i);
    if (due.isAfter(through)) break;
    if (!due.isBefore(from)) result.add(PlannedOccurrence(o, i, due));
  }
  return result;
}

List<PlannedOccurrence> plannedBetween(
  LedgerSnapshot snapshot,
  DateTime from,
  DateTime through,
) =>
    snapshot.obligations
        .expand((o) => occurrences(o, dayOnly(from), dayOnly(through)))
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));

class CashForecast {
  const CashForecast(this.income, this.expense, this.overdueExpense);
  final int income, expense, overdueExpense;
  int after(int actualBalance) => checkedMoneyTotal(
    BigInt.from(actualBalance) + BigInt.from(income) - BigInt.from(expense),
  );
}

CashForecast forecast30Days(LedgerSnapshot snapshot, DateTime now) {
  final today = dayOnly(now);
  final end = DateTime(today.year, today.month, today.day + 30);
  var income = BigInt.zero, expense = BigInt.zero, overdue = BigInt.zero;
  for (final entry in snapshot.entries.where(
    (e) => e.date.isAfter(today) && !e.date.isAfter(end),
  )) {
    if (entry.kind == EntryKind.income || entry.kind == EntryKind.refund) {
      income += BigInt.from(entry.amountMinor);
    }
    if (entry.kind == EntryKind.expense) {
      expense += BigInt.from(entry.amountMinor);
    }
  }
  final handled = snapshot.settlements
      .map((s) => '${s.obligationId}:${s.periodIndex}')
      .toSet();
  for (final due in plannedBetween(snapshot, DateTime(2000), end)) {
    if (handled.contains(due.key)) continue;
    if (due.obligation.kind == EntryKind.income) {
      // Past expected income is not assumed to have arrived.
      if (!due.date.isBefore(today)) {
        income += BigInt.from(due.obligation.amountMinor);
      }
    } else {
      expense += BigInt.from(due.obligation.amountMinor);
      if (due.date.isBefore(today)) {
        overdue += BigInt.from(due.obligation.amountMinor);
      }
    }
  }
  return CashForecast(
    checkedMoneyTotal(income),
    checkedMoneyTotal(expense),
    checkedMoneyTotal(overdue),
  );
}
