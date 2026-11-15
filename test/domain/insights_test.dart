import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/domain/insights/analysis_facts.dart';
import 'package:personal_finance/domain/insights/insight.dart';
import 'package:personal_finance/domain/insights/insight_engine.dart';
import 'package:personal_finance/domain/models.dart';
import 'package:personal_finance/domain/purchases.dart';

LedgerEntry entry(
  String id,
  EntryKind kind,
  int amount,
  int day, {
  int month = 11,
  String category = 'Еда',
  String? refundOf,
  String? target,
}) => LedgerEntry(
  id: id,
  kind: kind,
  amountMinor: amount,
  date: DateTime(2026, month, day),
  accountId: 'a',
  category: category,
  refundOf: refundOf,
  targetAccountId: target,
);
AnalysisPolicy verifiedPolicy([LedgerSnapshot? snapshot]) => AnalysisPolicy(
  verifiedThrough: {'2026-11': '2026-11-14', '2026-10': '2026-10-14'},
  verifiedHashes: {
    for (final d in [DateTime(2026, 11, 14), DateTime(2026, 10, 14)])
      monthKey(d): coverageHash(snapshot ?? fixture(), d),
  },
);
LedgerSnapshot fixture() => LedgerSnapshot(
  currency: 'AZN',
  accounts: const [
    Account(id: 'a', name: 'Карта', kind: 'Карта', openingMinor: 1000),
    Account(id: 'b', name: 'Наличные', kind: 'Наличные', openingMinor: -100),
  ],
  entries: [
    entry('old-income', EntryKind.income, 1000, 1, month: 10),
    entry('income', EntryKind.income, 2000, 1),
    entry('old-food', EntryKind.expense, 1000, 2, month: 10),
    entry('food', EntryKind.expense, 4000, 2),
    entry('food2', EntryKind.expense, 100, 3, category: 'еда'),
    entry('refund', EntryKind.refund, 500, 5, refundOf: 'food'),
    entry('home', EntryKind.expense, 12000, 6, category: 'Дом'),
    entry('settled', EntryKind.expense, 700, 8, category: 'Подписки'),
    entry('future', EntryKind.income, 900000, 15),
  ],
  budgets: [
    CategoryBudget(
      id: 'food-budget',
      month: '2026-11',
      category: 'Еда',
      limitMinor: 4000,
    ),
    CategoryBudget(
      id: 'home-budget',
      month: '2026-11',
      category: 'Дом',
      limitMinor: 10000,
    ),
  ],
  obligations: [
    for (var i = 0; i < 2; i++)
      Obligation(
        id: 'plan$i',
        name: 'Сервис $i',
        kind: EntryKind.expense,
        amountMinor: 1000,
        category: 'Подписки',
        anchor: DateTime(2026, 11, 16),
        repeat: RepeatRule.monthly,
        trialEnd: DateTime(2026, 11, 17),
      ),
    Obligation(
      id: 'late',
      name: 'Срок прошёл',
      kind: EntryKind.expense,
      amountMinor: 500,
      category: 'Дом',
      anchor: DateTime(2026, 11, 10),
      repeat: RepeatRule.once,
    ),
    Obligation(
      id: 'late-income',
      name: 'Поступление',
      kind: EntryKind.income,
      amountMinor: 500,
      category: 'Доход',
      anchor: DateTime(2026, 11, 10),
      repeat: RepeatRule.once,
    ),
    Obligation(
      id: 'paid',
      name: 'Оплаченный сервис',
      kind: EntryKind.expense,
      amountMinor: 1000,
      category: 'Подписки',
      anchor: DateTime(2026, 11, 8),
      nextIndex: 1,
      repeat: RepeatRule.monthly,
    ),
  ],
  settlements: [
    Settlement(
      id: 's',
      obligationId: 'paid',
      periodIndex: 0,
      dueDate: DateTime(2026, 11, 8),
      entryId: 'settled',
      skipped: false,
      version: 1,
    ),
  ],
  purchases: [
    Purchase(
      id: 'p',
      name: 'Покупка',
      date: DateTime(2026, 11, 2),
      amountMinor: 4000,
      entryId: 'food',
      returnBy: DateTime(2026, 11, 18),
      warrantyUntil: DateTime(2026, 11, 20),
    ),
  ],
);

List<Insight> analyze(
  LedgerSnapshot snapshot, {
  AnalysisPolicy? policy,
  DateTime? now,
  DateTime? month,
}) => InsightEngine().analyze(
  snapshot,
  month ?? DateTime(2026, 11),
  now ?? DateTime(2026, 11, 14),
  policy ?? verifiedPolicy(snapshot),
);

void main() {
  test(
    'comparison handles the signed 64-bit lower bound without abs overflow',
    () {
      final s = LedgerSnapshot(
        currency: 'AZN',
        accounts: [],
        entries: [
          entry(
            'extreme',
            EntryKind.expense,
            9223372036854775807,
            2,
            month: 10,
          ),
          entry('return', EntryKind.refund, 1, 2, refundOf: 'extreme'),
        ],
      );
      expect(
        analyze(s).singleWhere((i) => i.rule == 'B1').amounts['Изменение'],
        -9223372036854775808,
      );
    },
  );
  test('editing or restoring different entries invalidates coverage, reordering does not', () {
    final s = fixture(), p = verifiedPolicy();
    expect(p.covers(DateTime(2026, 11, 14), s), isTrue);
    final changed = LedgerSnapshot(
      currency: s.currency,
      accounts: s.accounts,
      entries: s.entries.where((e) => e.id != 'food'),
    );
    expect(p.covers(DateTime(2026, 11, 14), changed), isFalse);
    final reversed = LedgerSnapshot(
      currency: s.currency,
      accounts: s.accounts,
      entries: s.entries.reversed,
    );
    expect(p.covers(DateTime(2026, 11, 14), reversed), isTrue);
  });
  test('the first 26 rules remain available after extending the registry', () {
    final results = analyze(fixture());
    expect(
      {
        ...results.map((i) => i.rule),
        ...analyze(fixture(), policy: AnalysisPolicy()).map((i) => i.rule),
      },
      containsAll({
        'A1',
        'A3',
        'A5',
        'B1',
        'B2',
        'C1',
        'C2',
        'D1',
        'D2',
        'D3',
        'E1',
        'E2',
        'F1',
        'F2',
        'F3',
        'F4',
        'F5',
        'F6',
        'J1',
        'J2',
        'L1',
        'L2',
        'L4',
        'M1',
        'M2',
        'M3',
      }),
    );
    expect(results.map((i) => i.key).toSet().length, results.length);
    for (final rule in insightRules.keys) {
      expect(
        analyze(
          fixture(),
          policy: verifiedPolicy().copyWith(disabled: {rule}),
        ).where((i) => i.rule == rule),
        isEmpty,
        reason: rule,
      );
    }
  });
  test(
    'empty history emits no fabricated spending, limits, plans or savings',
    () {
      final results = analyze(
        LedgerSnapshot(currency: 'AZN', accounts: [], entries: []),
        policy: AnalysisPolicy(),
      );
      expect(results.map((e) => e.rule), ['M1']);
      expect(results.single.kind, InsightKind.insufficient);
      expect(results.single.amounts, isEmpty);
    },
  );
  test(
    'flow excludes future entries, transfers, opening balances and purchases',
    () {
      final snapshot = LedgerSnapshot(
        currency: 'AZN',
        accounts: fixture().accounts,
        entries: [
          entry('i', EntryKind.income, 10000, 1),
          entry('e', EntryKind.expense, 3000, 2),
          entry('r', EntryKind.refund, 500, 3, refundOf: 'e'),
          entry('t', EntryKind.transfer, 2000, 4, target: 'b'),
          entry('future', EntryKind.income, 100000, 15),
        ],
        purchases: fixture().purchases,
      );
      final flow = analyze(snapshot).singleWhere((i) => i.rule == 'A1');
      expect(flow.amounts, {
        'Доходы': 10000,
        'Расходы до возвратов': 3000,
        'Возвраты': 500,
        'Чистые расходы': 2500,
        'Разница': 7500,
      });
      final facts = AnalysisFacts(
        snapshot,
        DateTime(2026, 11),
        DateTime(2026, 11, 14),
      );
      expect(facts.balances, {'a': 6500, 'b': 1900});
    },
  );
  test(
    'late refund belongs to cash-flow date and purchase lifetime separately',
    () {
      final snapshot = LedgerSnapshot(
        currency: 'AZN',
        accounts: fixture().accounts,
        entries: [
          entry('e', EntryKind.expense, 5000, 2, month: 10),
          entry('r', EntryKind.refund, 5000, 2, refundOf: 'e'),
        ],
        purchases: [
          Purchase(
            id: 'p',
            name: 'Товар',
            date: DateTime(2026, 10, 2),
            amountMinor: 5000,
            entryId: 'e',
          ),
        ],
      );
      final results = analyze(snapshot);
      expect(
        results.singleWhere((i) => i.rule == 'A1').amounts['Чистые расходы'],
        -5000,
      );
      expect(
        results
            .singleWhere((i) => i.rule == 'L4')
            .amounts['Стоимость после возвратов'],
        0,
      );
      expect(results.where((i) => i.rule == 'A5'), isEmpty);
      expect(results.where((i) => i.rule == 'J1'), isEmpty);
    },
  );
  test(
    'comparison needs explicit coverage and both significant thresholds',
    () {
      expect(
        analyze(
          fixture(),
          policy: AnalysisPolicy(),
        ).where((i) => ['B1', 'B2', 'E1'].contains(i.rule)),
        isEmpty,
      );
      expect(analyze(fixture()).where((i) => i.rule == 'B1'), isNotEmpty);
      expect(
        analyze(
          fixture(),
          policy: verifiedPolicy().copyWith(minimumChangeMinor: 900000),
        ).where((i) => ['B1', 'B2', 'E1'].contains(i.rule)),
        isEmpty,
      );
      expect(
        analyze(
          fixture(),
          policy: verifiedPolicy().copyWith(changePercent: 1000),
        ).where((i) => i.rule == 'E1'),
        isEmpty,
      );
    },
  );
  test('zero comparison base is absolute, never an invented percentage', () {
    final s = LedgerSnapshot(
      currency: 'AZN',
      accounts: fixture().accounts,
      entries: [entry('e', EntryKind.expense, 2000, 2)],
    );
    final b = analyze(s).singleWhere((i) => i.rule == 'B1');
    expect(b.explanation, contains('Процент не рассчитывается'));
    expect(b.amounts['Предыдущий период'], 0);
  });
  test('March versus February compares 28 days on both sides', () {
    final f = AnalysisFacts(
      LedgerSnapshot(currency: 'AZN', accounts: [], entries: []),
      DateTime(2026, 3),
      DateTime(2026, 3, 31),
    );
    expect(f.comparableEnd, DateTime(2026, 3, 28));
    expect(f.comparisonEnd, DateTime(2026, 2, 28));
    final leap = AnalysisFacts(
      LedgerSnapshot(currency: 'AZN', accounts: [], entries: []),
      DateTime(2024, 3),
      DateTime(2024, 3, 31),
    );
    expect(leap.comparisonEnd, DateTime(2024, 2, 29));
  });
  test(
    'budget canonicalization, mutually exclusive alerts and daily floor',
    () {
      final results = analyze(fixture());
      expect(
        results.singleWhere((i) => i.rule == 'D1').amounts['Чистые расходы'],
        3600,
      );
      expect(
        results.singleWhere((i) => i.rule == 'D2').amounts['Превышение'],
        2000,
      );
      final daily = results.singleWhere(
        (i) => i.rule == 'D3' && i.entity == 'food-budget',
      );
      expect(daily.amounts['В среднем на день'], 400 ~/ 17);
      expect(
        results.where((i) => i.rule == 'D1' && i.entity == 'home-budget'),
        isEmpty,
      );
    },
  );
  test(
    'annual recurring costs count calendar occurrences, not 4 weeks per month',
    () {
      final s = LedgerSnapshot(
        currency: 'AZN',
        accounts: [],
        entries: [],
        obligations: [
          Obligation(
            id: 'weekly',
            name: 'Раз в неделю',
            kind: EntryKind.expense,
            amountMinor: 100,
            category: 'Дом',
            anchor: DateTime(2026, 11, 14),
            repeat: RepeatRule.weekly,
          ),
        ],
      );
      final annual = analyze(s).singleWhere((i) => i.rule == 'F4');
      expect(annual.amounts['Запланировано'], 5300);
      expect(
        analyze(s)
            .singleWhere((i) => i.rule == 'J2')
            .amounts['Сумма этих списаний'],
        5300,
      );
    },
  );
  test('inactive and completed plans do not create upcoming alerts', () {
    final o = Obligation(
      id: 'x',
      name: 'Пауза',
      kind: EntryKind.expense,
      amountMinor: 100,
      category: 'Дом',
      anchor: DateTime(2026, 11, 14),
      repeat: RepeatRule.monthly,
      paused: true,
    );
    final results = analyze(
      LedgerSnapshot(
        currency: 'AZN',
        accounts: [],
        entries: [],
        obligations: [o],
      ),
    );
    expect(
      results.where((i) => i.group == InsightGroup.payments || i.rule == 'J2'),
      isEmpty,
    );
  });
  test('past slice ignores future cash and current actionable schedules', () {
    final results = analyze(fixture(), month: DateTime(2026, 10));
    expect(
      results.where(
        (i) => [
          'F1',
          'F2',
          'F3',
          'F4',
          'F5',
          'E2',
          'J2',
          'L1',
          'L2',
          'M3',
        ].contains(i.rule),
      ),
      isEmpty,
    );
    expect(results.singleWhere((i) => i.rule == 'A1').amounts['Доходы'], 1000);
    expect(results.where((i) => i.rule == 'L4'), isEmpty);
  });
  test('future month has only a clear insufficient-data result', () {
    expect(analyze(fixture(), month: DateTime(2027, 1)).map((i) => i.rule), [
      'M1',
    ]);
  });
  test('rounding uses integer arithmetic and overflow is explicit', () {
    expect(percentMinor(105, 10), 11);
    expect(sumMinor([900000000000000, 900000000000000]), 1800000000000000);
    expect(
      () => sumMinor([9223372036854775807, 1]),
      throwsA(isA<DomainError>()),
    );
    expect(
      () => sumMinor([-9223372036854775807, -2]),
      throwsA(isA<DomainError>()),
    );
  });
  test('reordering records does not change cards, amounts or order', () {
    final s = fixture();
    final reversed = LedgerSnapshot(
      currency: s.currency,
      accounts: s.accounts.reversed,
      entries: s.entries.reversed,
      budgets: s.budgets.reversed,
      obligations: s.obligations.reversed,
      settlements: s.settlements,
      purchases: s.purchases,
    );
    final a = analyze(s), b = analyze(reversed);
    expect(a.map((i) => i.key).toList(), b.map((i) => i.key).toList());
    for (var n = 0; n < a.length; n++) {
      expect(a[n].amounts, b[n].amounts);
      expect(a[n].explanation, b[n].explanation);
    }
  });
  test('hidden period stays hidden next day and snooze expires', () {
    final i = analyze(fixture()).firstWhere((i) => i.rule == 'C2');
    final hidden = verifiedPolicy().copyWith(hidden: {i.key});
    expect(
      analyze(
        fixture(),
        policy: hidden,
        now: DateTime(2026, 11, 15),
      ).where((x) => x.key == i.key),
      isEmpty,
    );
    final snoozed = verifiedPolicy().copyWith(snoozed: {i.key: '2026-11-21'});
    expect(
      analyze(fixture(), policy: snoozed).where((x) => x.key == i.key),
      isEmpty,
    );
    expect(
      analyze(
        fixture(),
        policy: snoozed,
        now: DateTime(2026, 11, 21),
      ).where((x) => x.key == i.key),
      isNotEmpty,
    );
  });
  test('policy roundtrip validates versions, dates and ranges', () {
    final p = verifiedPolicy().copyWith(
      disabled: {'A1'},
      hidden: {'card'},
      snoozed: {'card': '2026-11-21'},
    );
    expect(AnalysisPolicy.fromJson(p.toJson()).toJson(), p.toJson());
    expect(
      () => AnalysisPolicy.fromJson({...p.toJson(), 'version': 99}),
      throwsFormatException,
    );
    expect(() => AnalysisPolicy(scenarioPercent: 0), throwsFormatException);
    expect(
      () => AnalysisPolicy.fromJson({
        ...p.toJson(),
        'verifiedThrough': {'2026-11': '2026-10-01'},
      }),
      throwsFormatException,
    );
  });
}
