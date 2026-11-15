import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/domain/insights/insight_engine.dart';
import 'package:personal_finance/domain/insights/analysis_facts.dart';
import 'package:personal_finance/domain/insights/analysis_profile.dart';
import 'package:personal_finance/domain/insights/debt_math.dart';
import 'package:personal_finance/domain/insights/insight.dart';
import 'package:personal_finance/domain/insights/profile_math.dart';
import 'package:personal_finance/domain/insights/scenario_math.dart';
import 'package:personal_finance/domain/insights/statistics/robust_stats.dart';
import 'package:personal_finance/domain/models.dart';

import 'complete_insights_test.dart';

void main() {
  final snapshot = completeSnapshot(),
      policy = completePolicy(snapshot),
      today = DateTime(2026, 11, 14);
  List<Insight> run(AnalysisPolicy p, {LedgerSnapshot? s, int month = 11}) =>
      completeScan(s ?? snapshot, p, month: month);
  test('profile JSON preserves typed goals debts annotations aliases and selection', () {
    final restored = AnalysisPolicy.fromJson(
      jsonDecode(jsonEncode(policy.toJson())) as Map<String, dynamic>,
    );
    expect(restored.toJson(), policy.toJson());
    expect(restored.profile.goals.single.targetMinor, 500000);
    expect(restored.profile.debts.single.annualRateBp, 1200);
    expect(() => restored.profile.reserves['a'] = 0, throwsUnsupportedError);
    expect(() => restored.profile.goals.clear(), throwsUnsupportedError);
    final old = policy.toJson()..remove('profile');
    expect(AnalysisPolicy.fromJson(old).profile.goals, isEmpty);
  });
  test(
    'aliases reject cycles normalized duplicates and conflicting category caps',
    () {
      final p = AnalysisProfile();
      expect(
        () => p.patch({
          'categoryAliases': {'а': 'б', 'б': 'а'},
        }),
        throwsFormatException,
      );
      expect(
        () => p.patch({
          'counterpartyAliases': {' Shop': 'one', 'shop': 'two'},
        }),
        throwsFormatException,
      );
      expect(
        () => p.patch({
          'categoryAliases': {'еда': 'питание'},
          'flexibleCaps': {'еда': 100, 'питание': 200},
        }),
        throwsFormatException,
      );
    },
  );
  test('invalid monetary and rule inputs are rejected before persistence', () {
    for (final change in <Map<String, Object?>>[
      {
        'ruleMinimums': {'B1': 0},
      },
      {
        'priorities': {'Z1': 20},
      },
      {
        'priorities': {'A1': 101},
      },
      {'backupEveryDays': 0},
      {'smallSkipCount': 101},
      {
        'reserves': {'a': -1},
      },
    ]) {
      expect(() => AnalysisProfile().patch(change), throwsFormatException);
    }
    final duplicate = policy.profile.goals.single.toJson();
    expect(
      () => AnalysisProfile().patch({
        'goals': [duplicate, duplicate],
      }),
      throwsFormatException,
    );
    expect(
      () => AnalysisProfile().patch({
        'debts': [
          {...policy.profile.debts.single.toJson(), 'principalMinor': 0},
        ],
      }),
      throwsFormatException,
    );
  });
  test('confirmed aliases group existing transactions without modifying their labels', () {
    final facts = AnalysisFacts(
      snapshot,
      DateTime(2026, 11),
      today,
      profile: policy.profile,
    );
    expect(facts.categories.containsKey('питание'), isTrue);
    expect(facts.categories.containsKey('еда'), isFalse);
    expect(snapshot.entries.where((e) => e.category == 'Еда'), isNotEmpty);
    final seller = run(policy).singleWhere((i) => i.rule == 'C6');
    expect(seller.amounts.keys, contains('магазин'));
  });
  test('changed source invalidates annotation instead of guessing its role or seller', () {
    final source = snapshot.entries.firstWhere(
      (e) =>
          e.kind == EntryKind.expense &&
          e.date.year == 2026 &&
          e.date.month == 11,
    );
    final edited = LedgerEntry.fromJson({
      ...source.toJson(),
      'amountMinor': source.amountMinor + 1,
    });
    expect(policy.profile.annotation(edited), isNull);
    final small = LedgerSnapshot(
      currency: 'AZN',
      accounts: snapshot.accounts,
      entries: [edited],
    );
    final cards = run(policy, s: small);
    expect(
      cards.singleWhere((i) => i.rule == 'C4').amounts['Не помечены'],
      edited.amountMinor,
    );
    expect(cards.where((i) => i.rule == 'C6'), isEmpty);
    expect(
      cards.singleWhere((i) => i.rule == 'M4').explanation,
      contains('Недействительных меток'),
    );
  });
  test(
    'same funds cannot cover two goals plus a reserve and protection is capped',
    () {
      final s = LedgerSnapshot(
        currency: 'AZN',
        accounts: const [
          Account(id: 'a', name: 'Карта', kind: 'Карта', openingMinor: 1000),
        ],
        entries: [],
      );
      final p = AnalysisProfile(
        reserves: {'a': 800},
        goals: [
          SavingsGoal(
            id: 'g',
            name: 'Цель',
            accountId: 'a',
            targetMinor: 2000,
            allocatedMinor: 500,
            start: DateTime(2026),
            deadline: DateTime(2027),
          ),
        ],
      );
      expect(
        () => validateProfileFunding(p, s, today),
        throwsA(isA<DomainError>()),
      );
      final cards = run(AnalysisPolicy(profile: p), s: s);
      expect(
        cards.singleWhere((i) => i.rule == 'A6').amounts['Защищено'],
        1000,
      );
      expect(
        cards.singleWhere((i) => i.rule == 'K3').kind,
        InsightKind.insufficient,
      );
      expect(cards.where((i) => i.rule == 'K4' || i.rule == 'K5'), isEmpty);
    },
  );
  test('goal arithmetic uses remaining months and own completed contribution intervals', () {
    final cards = run(policy);
    expect(
      cards.singleWhere((i) => i.rule == 'K4').amounts['На месяц'],
      200000,
    );
    expect(cards.singleWhere((i) => i.rule == 'K5').amounts['Разница'], 400000);
    final goal = policy.profile.goals.single.toJson();
    final past = policy.copyWith(
      profile: policy.profile.patch({
        'goals': [
          {...goal, 'deadline': '2026-10-31'},
        ],
      }),
    );
    expect(
      run(past).singleWhere((i) => i.rule == 'K4').amounts['На месяц'],
      400000,
    );
  });
  test('reserve runway requires explicit roles for every expense in verified months', () {
    final tags = Map<String, Object?>.from(
      policy.profile.toJson()['annotations']! as Map,
    )..remove('day-2026-08-02');
    final p = policy.copyWith(
      profile: policy.profile.patch({'annotations': tags}),
    );
    expect(
      run(p).singleWhere((i) => i.rule == 'K2').kind,
      InsightKind.insufficient,
    );
    expect(run(p).singleWhere((i) => i.rule == 'K2').amounts, isEmpty);
  });
  test('debt balance and payments reconcile exactly including fees and final small payment', () {
    final debt = DebtPlan(
      id: 'd',
      name: 'Долг',
      principalMinor: 1000,
      annualRateBp: 0,
      monthlyPaymentMinor: 300,
      monthlyFeeMinor: 10,
      firstDue: DateTime(2028, 1, 31),
    );
    final schedule = debtSchedule(debt);
    expect(schedule.amortizes, isTrue);
    expect(schedule.capped, isFalse);
    expect(schedule.months.map((m) => m.paymentMinor), [300, 300, 300, 140]);
    expect(schedule.months.map((m) => m.date), [
      DateTime(2028, 1, 31),
      DateTime(2028, 2, 29),
      DateTime(2028, 3, 31),
      DateTime(2028, 4, 30),
    ]);
    expect(schedule.months.last.remainingMinor, 0);
    expect(
      sumMinor(schedule.months.map((m) => m.paymentMinor)),
      debt.principalMinor +
          sumMinor(schedule.months.map((m) => m.interestMinor + m.feeMinor)),
    );
  });
  test('interest rounds upward and non-amortizing payment has no false payoff date', () {
    final tiny = debtSchedule(
      DebtPlan(
        id: 'd',
        name: 'Долг',
        principalMinor: 1,
        annualRateBp: 1,
        monthlyPaymentMinor: 2,
        monthlyFeeMinor: 0,
        firstDue: today,
      ),
    );
    expect(tiny.months.single.interestMinor, 1);
    final impossible = debtSchedule(
      DebtPlan(
        id: 'd',
        name: 'Долг',
        principalMinor: 10000,
        annualRateBp: 1200,
        monthlyPaymentMinor: 120,
        monthlyFeeMinor: 20,
        firstDue: today,
      ),
    );
    expect(impossible.amortizes, isFalse);
    expect(impossible.months, isEmpty);
  });
  test('past debt schedule asks for updated principal instead of forecasting old dates', () {
    final changed = policy.copyWith(
      profile: policy.profile.patch({
        'debts': [
          for (final d in policy.profile.debts)
            {...d.toJson(), 'firstDue': '2026-10-01'},
        ],
      }),
    );
    final card = InsightEngine()
        .analyze(snapshot, DateTime(2026, 11), today, changed)
        .singleWhere((i) => i.rule == 'K6');
    expect(card.kind, InsightKind.insufficient);
    expect(card.timeline, isEmpty);
  });
  test('debt horizon is bounded without pretending full repayment', () {
    final schedule = debtSchedule(
      DebtPlan(
        id: 'd',
        name: 'Долг',
        principalMinor: 1000000,
        annualRateBp: 0,
        monthlyPaymentMinor: 1,
        monthlyFeeMinor: 0,
        firstDue: today,
      ),
    );
    expect(schedule.months, hasLength(600));
    expect(schedule.capped, isTrue);
    expect(schedule.months.last.remainingMinor, 999400);
  });
  test('overlapping reductions use max per entry and never cut refunded money twice', () {
    final f = AnalysisFacts(
          snapshot,
          DateTime(2026, 11),
          today,
          profile: policy.profile,
        ),
        cuts = scenarioCuts(f, policy);
    for (final e in cuts.cuts.entries) {
      expect(e.value, lessThanOrEqualTo(f.entryById[e.key]!.amountMinor));
    }
    expect(cuts.cuts['fixed-11'], 1000);
    expect(cuts.variableBase.containsKey('сервис'), isFalse);
    final without = policy.copyWith(
      profile: policy.profile.patch({'pausePlanIds': []}),
    );
    final noPause = scenarioCuts(
      AnalysisFacts(
        snapshot,
        DateTime(2026, 11),
        today,
        profile: without.profile,
      ),
      without,
    );
    expect(sumMinor(cuts.cuts.values) - sumMinor(noPause.cuts.values), 1000);
  });
  test('refunds reduce cost available to all savings scenarios', () {
    final e = LedgerEntry(
          id: 'x',
          kind: EntryKind.expense,
          amountMinor: 300,
          date: DateTime(2026, 11, 2),
          accountId: 'a',
          category: 'Еда',
        ),
        refund = LedgerEntry(
          id: 'r',
          kind: EntryKind.refund,
          amountMinor: 200,
          date: DateTime(2026, 11, 3),
          accountId: 'a',
          category: 'Еда',
          refundOf: 'x',
        );
    final s = LedgerSnapshot(
      currency: 'AZN',
      accounts: snapshot.accounts,
      entries: [e, refund],
    );
    final p = AnalysisProfile(
      annotations: {
        'x': EntryAnnotation(
          entryId: 'x',
          sourceHash: annotationHash(e),
          reviewedOn: e.date,
          role: ExpenseRole.flexible,
        ),
      },
      scenarioCategories: {'еда'},
      smallSkipCount: 1,
      flexibleCaps: {'еда': 0},
    );
    final configured = AnalysisPolicy(profile: p),
        cuts = scenarioCuts(
          AnalysisFacts(s, DateTime(2026, 11), today, profile: p),
          configured,
        );
    expect(cuts.cuts['x'], 100);
    expect(cuts.capSavings['еда'], 100);
  });
  test('expected refunds count linked receipts after baseline and ignore future dates', () {
    LedgerSnapshot withRefund(int amount, DateTime date) => LedgerSnapshot(
      currency: snapshot.currency,
      accounts: snapshot.accounts,
      entries: [
        ...snapshot.entries,
        LedgerEntry(
          id: 'receipt',
          kind: EntryKind.refund,
          amountMinor: amount,
          date: date,
          accountId: 'a',
          category: 'Покупки',
          refundOf: 'purchase-refund',
        ),
      ],
      obligations: snapshot.obligations,
      settlements: snapshot.settlements,
      purchases: snapshot.purchases,
    );
    final partial = withRefund(4000, DateTime(2026, 11, 10));
    expect(
      run(
        policy,
        s: partial,
      ).singleWhere((i) => i.rule == 'L6').amounts['Ещё ожидается'],
      6000,
    );
    expect(
      run(
        policy,
        s: withRefund(10000, DateTime(2026, 11, 10)),
      ).where((i) => i.rule == 'L6'),
      isEmpty,
    );
    expect(
      run(
        policy,
        s: withRefund(10000, DateTime(2026, 11, 20)),
      ).singleWhere((i) => i.rule == 'L6').amounts['Ещё ожидается'],
      10000,
    );
  });
  test(
    'tracked recommendation becomes insufficient after changing its baseline',
    () {
      final changed = snapshot.entries
          .map(
            (e) => e.id == 'day-2026-08-02'
                ? LedgerEntry.fromJson({
                    ...e.toJson(),
                    'amountMinor': e.amountMinor + 1,
                  })
                : e,
          )
          .toList();
      final s = LedgerSnapshot(
        currency: snapshot.currency,
        accounts: snapshot.accounts,
        entries: changed,
        purchases: snapshot.purchases,
      );
      expect(
        run(policy, s: s, month: 10).singleWhere((i) => i.rule == 'O4').kind,
        InsightKind.insufficient,
      );
      expect(
        run(policy).singleWhere((i) => i.rule == 'O4').kind,
        InsightKind.insufficient,
      );
      expect(
        run(policy, month: 10).singleWhere((i) => i.rule == 'O4').kind,
        InsightKind.fact,
      );
    },
  );
  test('backup reminder uses explicit export day and configurable age', () {
    expect(run(policy).where((i) => i.rule == 'M6'), hasLength(1));
    final fresh = policy.copyWith(
      profile: policy.profile.patch({'lastBackupOn': calendarDate(today)}),
    );
    expect(run(fresh).where((i) => i.rule == 'M6'), isEmpty);
  });
  test(
    'zero MAD does not label a normal frequent expensive mode as an outlier',
    () {
      final stats = RobustStats([
        for (var n = 0; n < 70; n++) 100,
        for (var n = 0; n < 30; n++) 300,
      ]);
      expect(stats.mad4, BigInt.zero);
      expect(stats.high(300, minimumDifference: 100), isFalse);
      expect(stats.high(1000, minimumDifference: 100), isTrue);
      expect(
        RobustStats([for (var n = 0; n < 19; n++) 100, 10000])
            .high(1000, minimumDifference: 100),
        isTrue,
      );
    },
  );
  test(
    'per-rule and per-category absolute thresholds really alter eligibility',
    () {
      final rows = [
        LedgerEntry(
          id: 'old',
          kind: EntryKind.expense,
          amountMinor: 10,
          date: DateTime(2026, 10, 2),
          accountId: 'a',
          category: 'Еда',
        ),
        LedgerEntry(
          id: 'new',
          kind: EntryKind.expense,
          amountMinor: 15,
          date: DateTime(2026, 11, 2),
          accountId: 'a',
          category: 'Питание',
        ),
      ];
      final s = LedgerSnapshot(
            currency: 'AZN',
            accounts: snapshot.accounts,
            entries: rows,
          ),
          dates = [DateTime(2026, 10, 14), today];
      final base = AnalysisPolicy(
        profile: AnalysisProfile(categoryAliases: {'еда': 'питание'}),
        verifiedThrough: {for (final d in dates) monthKey(d): calendarDate(d)},
        verifiedHashes: {
          for (final d in dates) monthKey(d): coverageHash(s, d),
        },
      );
      expect(
        run(base, s: s).where((i) => i.rule == 'B1' || i.rule == 'B2'),
        isEmpty,
      );
      final custom = base.copyWith(
        profile: base.profile.patch({
          'ruleMinimums': {'B1': 1},
          'categoryMinimums': {'питание': 1},
        }),
      );
      expect(run(custom, s: s).map((i) => i.rule), containsAll(['B1', 'B2']));
    },
  );
  test('ambiguous limits are not silently added or compared after aliases', () {
    final s = LedgerSnapshot(
      currency: snapshot.currency,
      accounts: snapshot.accounts,
      entries: snapshot.entries,
      budgets: [
        CategoryBudget(
          id: 'one',
          month: '2026-11',
          category: 'Еда',
          limitMinor: 100,
        ),
        CategoryBudget(
          id: 'two',
          month: '2026-11',
          category: 'Питание',
          limitMinor: 5000,
        ),
      ],
    );
    final cards = run(policy, s: s);
    expect(
      cards.where((i) => ['D1', 'D2', 'D3', 'D4', 'D5'].contains(i.rule)),
      isEmpty,
    );
    expect(
      cards.singleWhere((i) => i.rule == 'M4').explanation,
      contains('несколько лимитов'),
    );
  });
}
