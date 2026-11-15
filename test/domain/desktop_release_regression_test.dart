import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/data/finance_repository.dart';
import 'package:personal_finance/data/ledger_database.dart';
import 'package:personal_finance/data/insights_preferences_repository.dart';
import 'package:personal_finance/domain/models.dart';
import 'package:personal_finance/domain/ledger_math.dart';
import 'package:personal_finance/domain/budget_math.dart';
import 'package:personal_finance/domain/money.dart';
import 'package:personal_finance/domain/schedule_math.dart';
import 'package:personal_finance/domain/insights/analysis_profile.dart';
import 'package:personal_finance/domain/insights/insight.dart';
import 'package:personal_finance/domain/insights/analysis_facts.dart';
import 'package:personal_finance/domain/insights/cash_calendar.dart';
import 'package:personal_finance/ui/finance_view_model.dart';

final today = DateTime(2026, 11, 15);

class SnapshotRepository extends FinanceRepository {
  SnapshotRepository(super.db, this.fixture) : super(clock: () => today);
  final LedgerSnapshot fixture;
  @override
  Future<LedgerSnapshot> load() async => fixture;
}

LedgerEntry entry(
  String id,
  EntryKind kind,
  int amount,
  DateTime date, {
  String category = 'Продукты',
  String? refundOf,
}) => LedgerEntry(
  id: id,
  kind: kind,
  amountMinor: amount,
  date: date,
  accountId: 'a',
  category: category,
  refundOf: refundOf,
);
LedgerSnapshot fixture({
  List<LedgerEntry> entries = const [],
  List<Obligation> plans = const [],
  List<CategoryBudget> budgets = const [],
}) => LedgerSnapshot(
  currency: 'AZN',
  accounts: const [
    Account(
      id: 'a',
      name: 'Тестовая карта',
      kind: 'Карта',
      openingMinor: 100000,
    ),
  ],
  entries: entries,
  obligations: plans,
  budgets: budgets,
);
void main() {
  test('unrepresentable loaded totals produce a readable error before UI receives the snapshot', () async {
    final db = LedgerDatabase(NativeDatabase.memory());
    final s = fixture(
      entries: [
        for (var n = 0; n < 11000; n++)
          entry('e$n', EntryKind.income, maxMoneyMinor, today),
      ],
    );
    final vm = FinanceViewModel(SnapshotRepository(db, s));
    try {
      await vm.refresh();
      expect(vm.snapshot, isNull);
      expect(vm.error, contains('слишком велик'));
      expect(vm.loading, isFalse);
    } finally {
      vm.dispose();
      await db.close();
    }
  });

  test('overview receives analysis configuration changes and balances refresh by snapshot identity', () async {
    final db = LedgerDatabase(NativeDatabase.memory());
    final s = fixture();
    final vm = FinanceViewModel(SnapshotRepository(db, s));
    try {
      await vm.refresh();
      var notifications = 0;
      vm.addListener(() => notifications++);
      expect(
        await vm.insights.updateProfile({
          'categoryAliases': {'еда': 'продукты'},
        }),
        isTrue,
      );
      expect(notifications, greaterThan(0));
      expect(identical(vm.balances, vm.balances), isTrue);
      vm.snapshot = fixture(
        entries: [entry('e', EntryKind.expense, 200, today)],
      );
      expect(vm.totalBalance, 99800);
      expect(() => vm.balances['a'] = 0, throwsUnsupportedError);
    } finally {
      vm.dispose();
      await db.close();
    }
  });

  test('overview today balance excludes future ledger records and forecast applies each once', () async {
    final s = fixture(
      entries: [
        entry('past', EntryKind.expense, 10000, DateTime(2026, 11, 2)),
        entry('future', EntryKind.expense, 20000, DateTime(2026, 11, 20)),
        entry('salary', EntryKind.income, 50000, DateTime(2026, 11, 25)),
        entry(
          'refund',
          EntryKind.refund,
          5000,
          DateTime(2026, 11, 21),
          refundOf: 'past',
        ),
      ],
    );
    final db = LedgerDatabase(NativeDatabase.memory());
    final vm = FinanceViewModel(SnapshotRepository(db, s))
      ..month = DateTime(2026, 11);
    try {
      await vm.refresh();
      expect(vm.totalBalance, 90000);
      expect(vm.forecast.after(vm.totalBalance), 125000);
      expect(
        vm.forecast.after(vm.totalBalance),
        cashCalendar(AnalysisFacts(s, DateTime(2026, 11), today))
            .at(30)
            .balanceMinor,
      );
      expect(vm.totals.expense, 10000);
      expect(vm.totals.income, 0);
      expect(accountBalances(s)['a'], 125000);
    } finally {
      vm.dispose();
      await db.close();
    }
  });
  test(
    'future ledger outside 30 day horizon does not affect overview forecast',
    () {
      final s = fixture(
        entries: [entry('late', EntryKind.income, 50000, DateTime(2027, 1, 1))],
      );
      final forecast = forecast30Days(s, today);
      expect(forecast.income, 0);
      expect(forecast.expense, 0);
    },
  );
  test('overview budgets use confirmed aliases and today cutoff', () async {
    final s = fixture(
      entries: [
        entry(
          'past',
          EntryKind.expense,
          8000,
          DateTime(2026, 11, 2),
          category: 'Еда',
        ),
        entry(
          'future',
          EntryKind.expense,
          1000,
          DateTime(2026, 11, 20),
          category: 'Продукты',
        ),
      ],
      budgets: const [
        CategoryBudget(
          id: 'b',
          month: '2026-11',
          category: 'Продукты',
          limitMinor: 10000,
        ),
      ],
    );
    final db = LedgerDatabase(NativeDatabase.memory());
    final prefs = MemoryInsightsPreferences()
      ..value = AnalysisPolicy(
        profile: AnalysisProfile(categoryAliases: {'еда': 'продукты'}),
      );
    final vm = FinanceViewModel(
      SnapshotRepository(db, s),
      insightsPreferences: prefs,
    )..month = DateTime(2026, 11);
    try {
      await vm.refresh();
      expect(vm.budgets.single.spentMinor, 8000);
      expect(vm.budgets.single.nearLimit, isTrue);
    } finally {
      vm.dispose();
      await db.close();
    }
  });
  test('near limit comparison cannot wrap at 64 bit boundary', () {
    const b = CategoryBudget(
      id: 'b',
      month: '2026-11',
      category: 'Тест',
      limitMinor: 900000000000000000,
    );
    expect(BudgetProgress(b, 800000000000000000).nearLimit, isTrue);
  });
  test(
    'aggregate exceeding signed 64 bit raises instead of silently wrapping',
    () {
      final s = fixture(
        entries: [
          for (var n = 0; n < 11000; n++)
            entry('e$n', EntryKind.income, maxMoneyMinor, today),
        ],
      );
      expect(() => accountBalances(s), throwsA(isA<DomainError>()));
      expect(() => monthTotals(s.entries, today), throwsA(isA<DomainError>()));
    },
  );
  test(
    'offsetting large entries are order independent without intermediate wrap',
    () {
      final rows = [
        for (var n = 0; n < 11000; n++)
          entry('i$n', EntryKind.income, maxMoneyMinor, today),
        for (var n = 0; n < 11000; n++)
          entry('e$n', EntryKind.expense, maxMoneyMinor, today),
      ];
      expect(accountBalances(fixture(entries: rows))['a'], 100000);
      expect(
        accountBalances(fixture(entries: rows.reversed.toList()))['a'],
        100000,
      );
    },
  );
}
