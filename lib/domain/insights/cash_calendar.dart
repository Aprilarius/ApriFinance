import '../models.dart';
import '../schedule_math.dart';
import 'analysis_facts.dart';
import 'insight.dart';

class CashDay {
  CashDay(this.date, this.balanceMinor, Map<String, int> accounts)
    : accounts = Map.unmodifiable(accounts);
  final DateTime date;
  final int balanceMinor;
  final Map<String, int> accounts;
}

class CashCalendar {
  CashCalendar({
    required this.days,
    required this.evidence,
    required this.hasEvents,
    required this.hasExpectedIncome,
    required this.unassignedIncome,
    required this.unassignedExpense,
    required this.overdueExpense,
    required this.debitAccounts,
    required this.expenses,
  });
  final List<CashDay> days;
  final List<InsightEvidence> evidence;
  final bool hasEvents, hasExpectedIncome;
  final int unassignedIncome, unassignedExpense, overdueExpense;
  final Set<String> debitAccounts;
  final List<CashExpense> expenses;
  CashDay at(int offset) => days[offset];
  CashDay? get firstNegative =>
      days.where((d) => d.balanceMinor < 0).firstOrNull;
  int get minimum =>
      days.map((d) => d.balanceMinor).reduce((a, b) => a < b ? a : b);
}

class CashExpense {
  const CashExpense(this.date, this.category, this.amountMinor);
  final DateTime date;
  final String category;
  final int amountMinor;
}

class _Event {
  const _Event(this.date, this.delta, this.accountId);
  final DateTime date;
  final int delta;
  final String? accountId;
}

CashCalendar cashCalendar(
  AnalysisFacts f, {
  int incomeDelayDays = 0,
  Set<String> pausedPlanIds = const {},
}) {
  if (!f.current || incomeDelayDays < 0 || incomeDelayDays > 90) {
    throw const DomainError(
      'Календарный сценарий доступен для текущего месяца',
    );
  }
  final s = f.snapshot,
      today = f.today,
      end = DateTime(f.today.year, f.today.month, f.today.day + 90);
  final events = <_Event>[],
      evidence = <InsightEvidence>{
        for (final a in s.accounts) InsightEvidence(EvidenceKind.account, a.id),
      };
  final debitAccounts = <String>{};
  final expenses = <CashExpense>[];
  var hasExpectedIncome = false;
  var unassignedIncome = BigInt.zero,
      unassignedExpense = BigInt.zero,
      overdue = BigInt.zero;
  void add(DateTime date, int delta, String? account) {
    events.add(_Event(date, delta, account));
    if (delta < 0 && account != null) debitAccounts.add(account);
    if (account == null || !f.balances.containsKey(account)) {
      if (delta < 0) {
        unassignedExpense -= BigInt.from(delta);
      } else {
        unassignedIncome += BigInt.from(delta);
      }
    }
  }

  for (final e in s.entries.where(
    (e) => e.date.isAfter(today) && !e.date.isAfter(end),
  )) {
    evidence.add(InsightEvidence(EvidenceKind.entry, e.id));
    if (e.kind == EntryKind.expense || e.kind == EntryKind.refund) {
      expenses.add(
        CashExpense(
          e.date,
          e.category,
          e.kind == EntryKind.expense ? e.amountMinor : -e.amountMinor,
        ),
      );
    }
    add(
      e.date,
      e.kind == EntryKind.expense || e.kind == EntryKind.transfer
          ? -e.amountMinor
          : e.amountMinor,
      e.accountId,
    );
    if (e.kind == EntryKind.transfer) {
      add(e.date, e.amountMinor, e.targetAccountId);
    }
  }
  final entryIds = s.entries.map((e) => e.id).toSet();
  final settled = s.settlements
      .where(
        (p) => p.skipped || (p.entryId != null && entryIds.contains(p.entryId)),
      )
      .map((p) => '${p.obligationId}:${p.periodIndex}')
      .toSet();
  for (final due in plannedBetween(s, DateTime(2000), end)) {
    if (settled.contains(due.key) ||
        pausedPlanIds.contains(due.obligation.id)) {
      continue;
    }
    final income = due.obligation.kind == EntryKind.income;
    if (income && due.date.isBefore(today)) continue;
    final date = income
        ? DateTime(
            due.date.year,
            due.date.month,
            due.date.day + incomeDelayDays,
          )
        : (due.date.isBefore(today) ? today : due.date);
    if (date.isAfter(end)) continue;
    hasExpectedIncome |= income;
    if (!income && due.date.isBefore(today)) {
      overdue += BigInt.from(due.obligation.amountMinor);
    }
    evidence.add(InsightEvidence(EvidenceKind.obligation, due.obligation.id));
    if (!income) {
      expenses.add(
        CashExpense(date, due.obligation.category, due.obligation.amountMinor),
      );
    }
    add(
      date,
      income ? due.obligation.amountMinor : -due.obligation.amountMinor,
      due.obligation.accountId,
    );
  }
  final byDate = <String, List<_Event>>{};
  for (final e in events) {
    byDate.putIfAbsent(calendarDate(e.date), () => []).add(e);
  }
  var balance = BigInt.from(sumMinor(f.balances.values));
  final accounts = {
    for (final a in f.balances.entries) a.key: BigInt.from(a.value),
  };
  final days = <CashDay>[];
  for (var n = 0; n <= 90; n++) {
    final day = DateTime(today.year, today.month, today.day + n);
    // End-of-day sums avoid inventing an order of debits and credits on one day.
    for (final event in byDate[calendarDate(day)] ?? <_Event>[]) {
      balance += BigInt.from(event.delta);
      if (accounts.containsKey(event.accountId)) {
        accounts[event.accountId!] =
            accounts[event.accountId!]! + BigInt.from(event.delta);
      }
    }
    days.add(
      CashDay(day, checked(balance), {
        for (final a in accounts.entries) a.key: checked(a.value),
      }),
    );
  }
  return CashCalendar(
    days: List.unmodifiable(days),
    evidence: List.unmodifiable(evidence),
    hasEvents: events.isNotEmpty,
    hasExpectedIncome: hasExpectedIncome,
    unassignedIncome: checked(unassignedIncome),
    unassignedExpense: checked(unassignedExpense),
    overdueExpense: checked(overdue),
    debitAccounts: Set.unmodifiable(debitAccounts),
    expenses: List.unmodifiable(expenses),
  );
}
