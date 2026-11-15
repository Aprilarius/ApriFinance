import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/domain/insights/analysis_facts.dart';
import 'package:personal_finance/domain/insights/analysis_profile.dart';
import 'package:personal_finance/domain/insights/insight.dart';
import 'package:personal_finance/domain/insights/insight_engine.dart';
import 'package:personal_finance/domain/insights/series_review.dart';
import 'package:personal_finance/domain/insights/series_plan_link.dart';
import 'package:personal_finance/domain/models.dart';
import 'package:personal_finance/domain/purchases.dart';

import 'insights_test.dart' as core;
import 'descriptive_insights_test.dart' as descriptive;
import 'pattern_insights_test.dart' as patterns;
import 'confirmed_series_test.dart' as confirmed;
import 'series_plan_link_test.dart' as linking;
import 'cash_calendar_test.dart' as calendar;

const finalRuleIds = {
  'A6',
  'C4',
  'C6',
  'D4',
  'E4',
  'I4',
  'I6',
  'J3',
  'J4',
  'J5',
  'J6',
  'K2',
  'K3',
  'K4',
  'K5',
  'K6',
  'L5',
  'L6',
  'M4',
  'M5',
  'M6',
  'N3',
  'N4',
  'N5',
  'O4',
  'O5',
  'O6',
};
LedgerSnapshot completeSnapshot({bool reverse = false}) {
  final entries = <LedgerEntry>[];
  for (
    var d = DateTime(2024, 11);
    !d.isAfter(DateTime(2026, 11, 14));
    d = DateTime(d.year, d.month, d.day + 1)
  ) {
    final amount = (d.weekday >= 6 ? 300 : 100) * (d.month == 12 ? 4 : 1);
    entries.add(
      LedgerEntry(
        id: 'day-${calendarDate(d)}',
        kind: EntryKind.expense,
        amountMinor: amount,
        date: d,
        accountId: 'a',
        category: 'Еда',
        note: 'Покупка',
      ),
    );
    if (d.day == 1) {
      entries.add(
        LedgerEntry(
          id: 'salary-${monthKey(d)}',
          kind: EntryKind.income,
          amountMinor: 500000,
          date: d,
          accountId: 'a',
          category: 'Доход',
          note: 'Работа',
        ),
      );
      entries.add(
        LedgerEntry(
          id: 'side-${monthKey(d)}',
          kind: EntryKind.income,
          amountMinor: 100000,
          date: d,
          accountId: 'a',
          category: 'Доход',
          note: 'Подработка',
        ),
      );
    }
  }
  for (var year = 2023; year <= 2025; year++) {
    entries.add(
      LedgerEntry(
        id: 'annual-$year',
        kind: EntryKind.expense,
        amountMinor: 1000000,
        date: DateTime(year, 12, 20),
        accountId: 'a',
        category: 'Годовые',
        note: 'Налог',
      ),
    );
  }
  for (var m = 9; m <= 11; m++) {
    entries.add(
      LedgerEntry(
        id: 'fixed-$m',
        kind: EntryKind.expense,
        amountMinor: 1000,
        date: DateTime(2026, m, 10),
        accountId: 'a',
        category: 'Сервис',
        note: 'Связь',
      ),
    );
  }
  for (final (id, day, amount, category) in [
    ('purchase-refund', 1, 20000, 'Покупки'),
    ('purchase-candidate', 10, 10000, 'Покупки'),
    ('typo-1', 5, 500, 'Продукты'),
    ('typo-2', 6, 500, 'Продуктыы'),
  ]) {
    entries.add(
      LedgerEntry(
        id: id,
        kind: EntryKind.expense,
        amountMinor: amount,
        date: DateTime(2026, 6, day),
        accountId: 'a',
        category: category,
        note: 'Пример',
      ),
    );
  }
  final plans = [
    Obligation(
      id: 'fixed-plan',
      name: 'Связь',
      kind: EntryKind.expense,
      amountMinor: 1000,
      category: 'Сервис',
      anchor: DateTime(2026, 9, 10),
      repeat: RepeatRule.monthly,
      accountId: 'a',
      nextIndex: 3,
    ),
  ];
  return LedgerSnapshot(
    currency: 'AZN',
    accounts: const [
      Account(
        id: 'a',
        name: 'Основная карта',
        kind: 'Карта',
        openingMinor: 5000000,
      ),
    ],
    entries: reverse ? entries.reversed : entries,
    obligations: plans,
    budgets: [
      CategoryBudget(
        id: 'food',
        month: '2026-11',
        category: 'Еда',
        limitMinor: 4000,
      ),
    ],
    settlements: [
      for (var n = 0; n < 3; n++)
        Settlement(
          id: 'settled-$n',
          obligationId: 'fixed-plan',
          periodIndex: n,
          dueDate: DateTime(2026, 9 + n, 10),
          entryId: 'fixed-${9 + n}',
          skipped: false,
          version: 1,
        ),
    ],
    purchases: [
      Purchase(
        id: 'refund-purchase',
        name: 'Возвращаемая покупка',
        date: DateTime(2026, 6, 1),
        amountMinor: 20000,
        entryId: 'purchase-refund',
      ),
      Purchase(
        id: 'candidate-purchase',
        name: 'Покупка без связи',
        date: DateTime(2026, 6, 10),
        amountMinor: 10000,
        store: 'Пример',
      ),
    ],
  );
}

AnalysisPolicy completePolicy(LedgerSnapshot s) {
  final tags = <String, EntryAnnotation>{};
  for (final e in s.entries) {
    tags[e.id] = EntryAnnotation(
      entryId: e.id,
      sourceHash: annotationHash(e),
      reviewedOn: e.date,
      role: e.kind == EntryKind.income
          ? ExpenseRole.unspecified
          : e.id.startsWith('day-') && e.date.day.isEven
          ? ExpenseRole.flexible
          : ExpenseRole.mandatory,
      counterparty: e.kind == EntryKind.income
          ? e.note == 'Работа'
                ? 'Главная работа'
                : 'Подработка'
          : e.category == 'Еда'
          ? 'Магазин'
          : 'Сервис',
    );
  }
  SeriesReview review(
    Iterable<String> ids,
    SeriesCadence cadence,
    DateTime date, {
    Obligation? plan,
  }) {
    final rows = s.entries.where((e) => ids.contains(e.id)).toList();
    return SeriesReview(
      proposal: SeriesProposal(
        key: seriesKey('AZN', rows.first),
        cadence: cadence,
        sourceHash: seriesSourceHash('AZN', rows),
        sourceIds: rows.map((e) => e.id),
      ),
      decision: SeriesDecision.accepted,
      reviewedOn: date,
      planLink: plan == null
          ? null
          : SeriesPlanLink(
              planId: plan.id,
              planHash: planLinkHash(plan),
              linkedOn: date,
            ),
    );
  }

  final reviews = [
    review(
      [for (var y = 2023; y <= 2025; y++) 'annual-$y'],
      SeriesCadence.yearly,
      DateTime(2025, 12, 21),
    ),
    review(
      [
        for (var m = 7; m <= 9; m++)
          'salary-2025-${m.toString().padLeft(2, '0')}',
      ],
      SeriesCadence.monthly,
      DateTime(2025, 9, 2),
    ),
    review(
      ['fixed-9', 'fixed-10', 'fixed-11'],
      SeriesCadence.monthly,
      DateTime(2026, 11, 11),
      plan: s.obligations.single,
    ),
  ];
  final profile = AnalysisProfile(
    trackingStart: DateTime(2024, 11),
    touched: true,
    lastBackupOn: DateTime(2026, 9, 1),
    annotations: tags,
    reserves: {'a': 300000},
    goals: [
      SavingsGoal(
        id: 'trip',
        name: 'Поездка',
        accountId: 'a',
        targetMinor: 500000,
        allocatedMinor: 100000,
        start: DateTime(2026, 1, 1),
        deadline: DateTime(2026, 12, 31),
        monthlyMinor: 50000,
      ),
    ],
    debts: [
      DebtPlan(
        id: 'loan',
        name: 'Тестовый долг',
        principalMinor: 100000,
        annualRateBp: 1200,
        monthlyPaymentMinor: 10000,
        monthlyFeeMinor: 100,
        firstDue: DateTime(2026, 12, 1),
      ),
    ],
    refunds: [
      ExpectedRefund(
        id: 'return',
        purchaseId: 'refund-purchase',
        purchaseHash: seriesDigest(s.purchases.first.toJson()),
        expectedMinor: 10000,
        baselineRefundMinor: 0,
        due: DateTime(2026, 11, 1),
      ),
    ],
    categoryAliases: {'еда': 'питание'},
    counterpartyAliases: {'главная работа': 'работодатель'},
    flexibleCaps: {'питание': 500},
    smallSkipCount: 2,
    scenarioCategories: {'питание'},
    pausePlanIds: {'fixed-plan'},
    ruleMinimums: {'B1': 100},
    categoryMinimums: {'питание': 50},
    priorities: {'M6': 31},
  );
  final baseEnd = DateTime(2026, 9, 0),
      baseStart = DateTime(2026, 8),
      facts = AnalysisFacts(
        s,
        baseStart,
        DateTime(2026, 11, 14),
        profile: profile,
      ),
      baseline = facts.categories['питание']!;
  final tracked = TrackedAdvice(
    id: 'food-target',
    category: 'питание',
    baselineMonth: baseStart,
    baselineMinor: baseline,
    targetMinor: baseline * 9 ~/ 10,
    baselineHash: coverageHash(s, baseEnd),
  );
  final dates = [
    for (
      var m = DateTime(2024, 11);
      m.isBefore(DateTime(2026, 11));
      m = DateTime(m.year, m.month + 1)
    )
      DateTime(m.year, m.month + 1, 0),
    DateTime(2026, 11, 14),
  ];
  return AnalysisPolicy(
    profile: profile.patch({
      'tracked': [tracked.toJson()],
    }),
    seriesReviews: {for (final r in reviews) r.proposal.key: r},
    verifiedThrough: {for (final d in dates) monthKey(d): calendarDate(d)},
    verifiedHashes: {for (final d in dates) monthKey(d): coverageHash(s, d)},
  );
}

List<Insight> completeScan(
  LedgerSnapshot s,
  AnalysisPolicy p, {
  int month = 11,
}) => InsightEngine().analyze(
  s,
  DateTime(2026, month),
  DateTime(2026, 11, 14),
  p,
);
void main() {
  test('all final 27 rules produce genuine configured outcomes', () {
    final s = completeSnapshot(), p = completePolicy(s);
    final all = [
      ...completeScan(s, p),
      ...completeScan(s, p, month: 10),
      ...completeScan(
        s,
        p.copyWith(profile: p.profile.patch({'trackingStart': null})),
      ),
    ];
    final positive = all
        .where((i) => i.kind != InsightKind.insufficient)
        .map((i) => i.rule)
        .toSet();
    expect(
      positive,
      containsAll(finalRuleIds),
      reason: 'Missing ${finalRuleIds.difference(positive)}',
    );
    expect(all.where((i) => i.rule == 'I4').first.timeline, hasLength(91));
    expect(all.where((i) => i.rule == 'K3').first.amounts['Назначено'], 100000);
  });
  test('90 rule catalogue has a positive fixture for every rule', () {
    final registered = {
      for (var letter = 65; letter <= 79; letter++)
        for (var n = 1; n <= 6; n++) '${String.fromCharCode(letter)}$n',
    };
    expect(insightRules.keys.toSet(), registered);
    final engine = InsightEngine(),
        s = completeSnapshot(),
        p = completePolicy(s);
    List<Insight> run(
      LedgerSnapshot snapshot,
      AnalysisPolicy policy, {
      int month = 11,
    }) => engine.analyze(
      snapshot,
      DateTime(2026, month),
      DateTime(2026, month, 14),
      policy,
    );
    final old = core.fixture(),
        d = descriptive.historyFixture(),
        pattern = patterns.patternFixture(),
        income = confirmed.seriesFixture(kind: EntryKind.income);
    final proposal = run(
      income,
      AnalysisPolicy(),
    ).singleWhere((i) => i.rule == 'E3').seriesProposal!;
    final all = [
      ...run(old, core.verifiedPolicy(old)),
      ...run(d, descriptive.covered(d)),
      ...engine.analyze(
        d,
        DateTime(2026, 10),
        DateTime(2026, 11, 14),
        descriptive.covered(d),
      ),
      ...run(pattern, patterns.patternPolicy(pattern)),
      ...engine.analyze(
        pattern,
        DateTime(2026, 10),
        DateTime(2026, 11, 14),
        patterns.patternPolicy(pattern),
      ),
      ...run(
        confirmed.seriesFixture(nextAmount: 100000),
        confirmed.acceptedPolicy(),
        month: 12,
      ),
      ...run(
        confirmed.seriesFixture(kind: EntryKind.income, nextAmount: 10000),
        confirmed.acceptedPolicy(proposal: proposal),
        month: 12,
      ),
      ...run(linking.linkedFixture(), confirmed.acceptedPolicy()),
      ...run(calendar.calendarFixture(), AnalysisPolicy()),
      ...completeScan(s, p),
      ...completeScan(s, p, month: 10),
      ...completeScan(
        s,
        p.copyWith(profile: p.profile.patch({'trackingStart': null})),
      ),
    ];
    final covered = all
        .where((i) => i.rule == 'M1' || i.kind != InsightKind.insufficient)
        .map((i) => i.rule)
        .toSet();
    expect(
      covered,
      containsAll(registered),
      reason: 'No positive evidence for ${registered.difference(covered)}',
    );
  });
  test(
    'all 90 can be disabled and results remain deterministic under reorder',
    () {
      final s = completeSnapshot(),
          p = completePolicy(s),
          reversed = completeSnapshot(reverse: true);
      expect(
        completeScan(s, p.copyWith(disabled: insightRules.keys.toSet())),
        isEmpty,
      );
      final a = completeScan(s, p), b = completeScan(reversed, p);
      expect(a.map((i) => i.key), b.map((i) => i.key));
      for (var n = 0; n < a.length; n++) {
        expect(a[n].amounts, b[n].amounts);
        expect(a[n].evidence, b[n].evidence);
      }
    },
  );
}
