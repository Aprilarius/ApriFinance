import '../models.dart';
import '../schedule_math.dart';
import 'insight.dart';
import 'analysis_profile.dart';

int checked(BigInt value) {
  if (value < BigInt.parse('-9223372036854775808') ||
      value > BigInt.parse('9223372036854775807')) {
    throw const DomainError('Итог слишком велик для безопасного анализа');
  }
  return value.toInt();
}

int sumMinor(Iterable<int> values) =>
    checked(values.fold(BigInt.zero, (a, b) => a + BigInt.from(b)));
int difference(int a, int b) => checked(BigInt.from(a) - BigInt.from(b));
int percentMinor(int value, int percent) => checked(
  (BigInt.from(value) * BigInt.from(percent) + BigInt.from(50)) ~/
      BigInt.from(100),
);

class AnalysisFacts {
  AnalysisFacts(
    this.snapshot,
    DateTime month,
    DateTime now, {
    AnalysisProfile? profile,
  }) : profile = profile ?? AnalysisProfile() {
    today = dayOnly(now);
    start = DateTime(month.year, month.month);
    final last = DateTime(month.year, month.month + 1, 0);
    end = last.isAfter(today) ? today : last;
    future = end.isBefore(start);
    final previousLast = DateTime(start.year, start.month, 0);
    final days = future ? 0 : end.day.clamp(1, previousLast.day);
    comparisonEnd = DateTime(
      previousLast.year,
      previousLast.month,
      days == 0 ? 1 : days,
    );
    comparisonStart = DateTime(previousLast.year, previousLast.month);
    // A shorter preceding month means both sides stop at the same day number.
    comparableEnd = DateTime(start.year, start.month, days == 0 ? 1 : days);
    entries =
        snapshot.entries
            .where((e) => !future && within(e.date, start, end))
            .toList()
          ..sort((a, b) => a.id.compareTo(b.id));
    for (final e in snapshot.entries) {
      entryById[e.id] = e;
      if (e.kind == EntryKind.refund && e.refundOf != null) {
        refunds.putIfAbsent(e.refundOf!, () => []).add(e);
      }
    }
    categories = categoryTotals(entries);
    income = total(entries, EntryKind.income);
    gross = total(entries, EntryKind.expense);
    returned = total(entries, EntryKind.refund);
    netExpense = difference(gross, returned);
    balances = {for (final a in snapshot.accounts) a.id: a.openingMinor};
    final changes = <String, List<int>>{
      for (final a in snapshot.accounts) a.id: [a.openingMinor],
    };
    for (final e in snapshot.entries.where((e) => !e.date.isAfter(end))) {
      accountEntries.putIfAbsent(e.accountId, () => []).add(e);
      if (e.targetAccountId != null) {
        accountEntries.putIfAbsent(e.targetAccountId!, () => []).add(e);
      }
      changes[e.accountId]?.add(
        e.kind == EntryKind.expense || e.kind == EntryKind.transfer
            ? -e.amountMinor
            : e.amountMinor,
      );
      if (e.kind == EntryKind.transfer) {
        changes[e.targetAccountId]?.add(e.amountMinor);
      }
    }
    for (final a in changes.entries) {
      balances[a.key] = sumMinor(a.value);
    }
  }
  final LedgerSnapshot snapshot;
  final AnalysisProfile profile;
  String canonicalCategory(String value) => profile.category(value);
  Map<String, int> categoryTotals(Iterable<LedgerEntry> rows) =>
      totalsByCategory(rows, canonical: canonicalCategory);
  late final Set<String> budgetAmbiguities = () {
    final counts = <String, int>{};
    for (final b in snapshot.budgets) {
      final key = '${b.month}:${canonicalCategory(b.category)}';
      counts[key] = (counts[key] ?? 0) + 1;
    }
    return counts.entries.where((e) => e.value > 1).map((e) => e.key).toSet();
  }();
  bool unambiguousBudget(CategoryBudget budget) => !budgetAmbiguities.contains(
    '${budget.month}:${canonicalCategory(budget.category)}',
  );
  late final DateTime today,
      start,
      end,
      comparisonStart,
      comparisonEnd,
      comparableEnd;
  late final bool future;
  late final List<LedgerEntry> entries;
  final entryById = <String, LedgerEntry>{};
  final refunds = <String, List<LedgerEntry>>{};
  final accountEntries = <String, List<LedgerEntry>>{};
  final _coverageHashes = <String, String>{};
  bool covered(AnalysisPolicy policy, DateTime date) {
    final through = policy.verifiedThrough[monthKey(date)];
    if (through == null || through.compareTo(calendarDate(date)) < 0) {
      return false;
    }
    final hash = _coverageHashes.putIfAbsent(
      through,
      () => coverageHash(snapshot, parseCalendarDate(through)),
    );
    return policy.verifiedHashes[monthKey(date)] == hash;
  }

  bool coveredRange(AnalysisPolicy policy, DateTime from, DateTime through) {
    if (through.isBefore(from) ||
        (profile.trackingStart != null &&
            profile.trackingStart!.isAfter(from))) {
      return false;
    }
    for (
      var m = DateTime(from.year, from.month);
      !m.isAfter(through);
      m = DateTime(m.year, m.month + 1)
    ) {
      final last = DateTime(m.year, m.month + 1, 0);
      if (!covered(policy, last.isAfter(through) ? through : last)) {
        return false;
      }
    }
    return true;
  }

  late final Map<String, int> categories, balances;
  late final int income, gross, returned, netExpense;
  bool get current => start.year == today.year && start.month == today.month;
  String get period => '${calendarDate(start)}/${calendarDate(end)}';
  static bool within(DateTime d, DateTime from, DateTime to) =>
      !d.isBefore(from) && !d.isAfter(to);
  static int total(Iterable<LedgerEntry> entries, EntryKind kind) =>
      sumMinor(entries.where((e) => e.kind == kind).map((e) => e.amountMinor));
  static Map<String, int> totalsByCategory(
    Iterable<LedgerEntry> entries, {
    String Function(String)? canonical,
  }) {
    final groups = <String, List<int>>{};
    for (final e in entries.where(
      (e) => e.kind == EntryKind.expense || e.kind == EntryKind.refund,
    )) {
      groups
          .putIfAbsent((canonical ?? categoryKey)(e.category), () => [])
          .add(e.kind == EntryKind.refund ? -e.amountMinor : e.amountMinor);
    }
    return groups.map((k, v) => MapEntry(k, sumMinor(v)));
  }
}
