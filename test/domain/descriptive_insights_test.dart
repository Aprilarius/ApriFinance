import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/domain/insights/analysis_facts.dart';
import 'package:personal_finance/domain/insights/insight.dart';
import 'package:personal_finance/domain/insights/insight_engine.dart';
import 'package:personal_finance/domain/models.dart';
import 'package:personal_finance/domain/purchases.dart';

const newRules = {
  'A2',
  'A4',
  'B4',
  'B5',
  'B6',
  'C3',
  'C5',
  'D5',
  'D6',
  'E6',
  'K1',
  'L3',
  'O1',
  'O2',
  'O3',
};
LedgerSnapshot historyFixture({bool documents = false, bool archive = false}) {
  final entries = <LedgerEntry>[];
  void add(
    String id,
    int month,
    int day,
    int amount, {
    String category = 'Еда',
    EntryKind kind = EntryKind.expense,
  }) => entries.add(
    LedgerEntry(
      id: id,
      kind: kind,
      amountMinor: amount,
      date: DateTime(2026, month, day),
      accountId: 'a',
      category: category,
    ),
  );
  for (final month in [8, 9, 10]) {
    add('rent$month', month, 2, 3000, category: 'Жильё');
    add('cafe$month', month, 3, 500 + (month - 8) * 200, category: 'Кафе');
  }
  for (var n = 0; n < 3; n++) {
    add('old-food$n', 10, 4 + n, 300);
  }
  add('old-income', 10, 1, 30000, kind: EntryKind.income);
  add('income', 11, 1, 33000, kind: EntryKind.income);
  add('rent', 11, 2, 6000, category: 'Жильё');
  add('tech', 11, 3, 10000, category: 'Техника');
  for (var n = 0; n < 6; n++) {
    add('small$n', 11, 10 + n % 4, 100, category: 'Мелочи');
  }
  for (var n = 0; n < 2; n++) {
    add('food$n', 11, 4 + n, 2000);
  }
  return LedgerSnapshot(
    currency: 'AZN',
    accounts: const [
      Account(id: 'a', name: 'Карта', kind: 'Карта', openingMinor: 100000),
      Account(id: 'b', name: 'Наличные', kind: 'Наличные', openingMinor: 10000),
    ],
    entries: entries,
    budgets: [
      for (final month in [8, 9, 10])
        CategoryBudget(
          id: 'budget$month',
          month: '2026-${month.toString().padLeft(2, '0')}',
          category: 'Жильё',
          limitMinor: 2000,
        ),
      const CategoryBudget(
        id: 'budget11',
        month: '2026-11',
        category: 'Жильё',
        limitMinor: 4000,
      ),
    ],
    purchases: [
      Purchase(
        id: 'p',
        name: 'Товар',
        date: DateTime(2026, 11, 3),
        amountMinor: 10000,
        warrantyUntil: DateTime(2027, 11, 3),
        archived: archive,
      ),
    ],
    documents: documents
        ? const [
            PurchaseDocument(
              id: 'd',
              purchaseId: 'p',
              name: 'Чек',
              mime: 'application/pdf',
              size: 100,
              version: 1,
            ),
          ]
        : [],
  );
}

AnalysisPolicy covered(LedgerSnapshot snapshot) {
  final dates = [
    DateTime(2026, 8, 31),
    DateTime(2026, 9, 30),
    DateTime(2026, 10, 31),
    DateTime(2026, 11, 14),
  ];
  return AnalysisPolicy(
    minimumChangeMinor: 100,
    smallExpenseMinor: 200,
    verifiedThrough: {for (final d in dates) monthKey(d): calendarDate(d)},
    verifiedHashes: {
      for (final d in dates) monthKey(d): coverageHash(snapshot, d),
    },
  );
}

List<Insight> results(
  LedgerSnapshot snapshot, {
  AnalysisPolicy? policy,
  int month = 11,
}) => InsightEngine().analyze(
  snapshot,
  DateTime(2026, month),
  DateTime(2026, 11, 14),
  policy ?? covered(snapshot),
);

void main() {
  test('rounded averages do not trigger a false percentage threshold', () {
    final s = LedgerSnapshot(
      currency: 'AZN',
      accounts: [],
      entries: [
        for (var n = 0; n < 3; n++)
          LedgerEntry(
            id: 'old$n',
            kind: EntryKind.expense,
            amountMinor: [1, 2, 2][n],
            date: DateTime(2026, 10, 2),
            accountId: 'a',
            category: 'Еда',
          ),
        for (var n = 0; n < 3; n++)
          LedgerEntry(
            id: 'now$n',
            kind: EntryKind.expense,
            amountMinor: [2, 3, 3][n],
            date: DateTime(2026, 11, 2),
            accountId: 'a',
            category: 'Еда',
          ),
      ],
    );
    expect(
      results(
        s,
        policy: covered(s).copyWith(minimumChangeMinor: 1, changePercent: 100),
      ).where((i) => i.rule == 'B4'),
      isEmpty,
    );
  });
  test('refund contributions reconcile and negative historical months do not propose a limit', () {
    final s = historyFixture();
    final changed = LedgerSnapshot(
      currency: s.currency,
      accounts: s.accounts,
      entries: [
        ...s.entries,
        LedgerEntry(
          id: 'refund',
          kind: EntryKind.refund,
          amountMinor: 5000,
          date: DateTime(2026, 11, 4),
          accountId: 'a',
          category: 'Техника',
          refundOf: 'tech',
        ),
        LedgerEntry(
          id: 'old-refund',
          kind: EntryKind.refund,
          amountMinor: 5000,
          date: DateTime(2026, 8, 4),
          accountId: 'a',
          category: 'Кафе',
          refundOf: 'cafe8',
        ),
      ],
    );
    final cards = results(changed),
        drivers = cards.singleWhere((i) => i.rule == 'O3');
    expect(drivers.amounts['Общее изменение'], 10800);
    expect(
      sumMinor(
        drivers.amounts.entries
            .where((e) => e.key != 'Общее изменение')
            .map((e) => e.value),
      ),
      10800,
    );
    expect(drivers.evidence.map((e) => e.id), contains('refund'));
    expect(cards.where((i) => i.rule == 'D6' && i.entity == 'кафе'), isEmpty);
  });
  test(
    'overview selects diverse cards without removing full analysis results',
    () {
      final all = results(historyFixture()),
          preview = selectInsightPreview(all);
      expect(preview.length, lessThanOrEqualTo(3));
      expect(
        preview
            .where((i) => {'A1', 'A2', 'A4', 'K1', 'O2'}.contains(i.rule))
            .length,
        lessThanOrEqualTo(1),
      );
      expect(
        preview
            .where(
              (i) => {
                'B1',
                'B2',
                'B4',
                'B5',
                'B6',
                'E1',
                'E6',
                'O3',
              }.contains(i.rule),
            )
            .length,
        lessThanOrEqualTo(1),
      );
      expect(all.where((i) => i.rule == 'A2'), isNotEmpty);
    },
  );
  test('15 additional rules produce verified results across current and closed months', () {
    final s = historyFixture();
    final all = [...results(s), ...results(s, month: 10)];
    expect(all.map((i) => i.rule).toSet(), containsAll(newRules));
    expect(insightRules.length, 90);
    for (final rule in newRules) {
      expect(
        results(
          s,
          policy: covered(s).copyWith(disabled: {rule}),
        ).where((i) => i.rule == rule),
        isEmpty,
      );
    }
  });
  test(
    'account balance change equals income minus net expense, transfers cancel',
    () {
      final s = historyFixture();
      final a = results(s).singleWhere((i) => i.rule == 'A2');
      expect(a.amounts['Изменение'], 12400);
      expect(
        difference(
          a.amounts['На конец периода']!,
          a.amounts['На начало периода']!,
        ),
        12400,
      );
      final withTransfer = LedgerSnapshot(
        currency: s.currency,
        accounts: s.accounts,
        entries: [
          ...s.entries,
          LedgerEntry(
            id: 't',
            kind: EntryKind.transfer,
            amountMinor: 5000,
            date: DateTime(2026, 11, 7),
            accountId: 'a',
            targetAccountId: 'b',
          ),
        ],
      );
      expect(
        results(withTransfer).singleWhere((i) => i.rule == 'A2').amounts,
        a.amounts,
      );
    },
  );
  test('positive-account shares use positive denominator and unique account identities', () {
    final s = LedgerSnapshot(
      currency: 'AZN',
      accounts: const [
        Account(id: 'a', name: 'Карта', kind: 'Карта', openingMinor: 300),
        Account(id: 'b', name: 'Карта', kind: 'Карта', openingMinor: 100),
        Account(id: 'c', name: 'Минус', kind: 'Карта', openingMinor: -200),
      ],
      entries: [],
    );
    final cards = results(s).where((i) => i.rule == 'A4').toList();
    expect(cards.length, 2);
    expect(cards.first.explanation, contains('75%'));
    expect(cards.last.explanation, contains('25%'));
    expect(cards.first.amounts['Положительные остатки всех счетов'], 400);
  });
  test(
    'average compares original purchases and frequency is a separate fact',
    () {
      final s = historyFixture(), cards = results(historyFixture());
      final average = cards.singleWhere((i) => i.rule == 'B4');
      expect(average.amounts['Сейчас в среднем'], 20600 ~/ 10);
      expect(average.amounts['Раньше в среднем'], 4800 ~/ 5);
      expect(
        cards.singleWhere((i) => i.rule == 'B5').explanation,
        contains('10 списаний против 5'),
      );
      final incomplete = covered(s).copyWith(verifiedThrough: {});
      expect(
        results(
          s,
          policy: incomplete,
        ).where((i) => ['B4', 'B5', 'B6', 'E6', 'O3'].contains(i.rule)),
        isEmpty,
      );
    },
  );
  test('new category must be absent from all earlier recorded expenses', () {
    final s = historyFixture();
    final changed = LedgerSnapshot(
      currency: s.currency,
      accounts: s.accounts,
      entries: [
        ...s.entries,
        LedgerEntry(
          id: 'old-tech',
          kind: EntryKind.expense,
          amountMinor: 100,
          date: DateTime(2026, 8, 1),
          accountId: 'a',
          category: 'Техника',
        ),
      ],
    );
    expect(
      results(changed).where((i) => i.rule == 'B6' && i.entity == 'техника'),
      isEmpty,
    );
    expect(
      results(s).where((i) => i.rule == 'B6' && i.entity == 'техника'),
      isNotEmpty,
    );
  });
  test(
    'concentration is computed on gross expenses and reaches 80 percent',
    () {
      final s = historyFixture();
      final c = results(s).singleWhere((i) => i.rule == 'C3');
      expect(c.amounts['Все расходы до возвратов'], 20600);
      expect(
        c.amounts['Расходы этих категорий']! * 100,
        greaterThanOrEqualTo(20600 * 80),
      );
      expect(c.evidence.map((e) => e.id), isNot(contains('income')));
    },
  );
  test(
    'small-spend threshold is inclusive and at least five records are needed',
    () {
      final s = historyFixture();
      expect(
        results(s).singleWhere((i) => i.rule == 'C5').amounts['В сумме'],
        600,
      );
      expect(
        results(
          s,
          policy: covered(s).copyWith(smallExpenseMinor: 99),
        ).where((i) => i.rule == 'C5'),
        isEmpty,
      );
      final few = LedgerSnapshot(
        currency: s.currency,
        accounts: s.accounts,
        entries: s.entries.where((e) => !['small4', 'small5'].contains(e.id)),
      );
      expect(results(few).where((i) => i.rule == 'C5'), isEmpty);
    },
  );
  test('historical budget advice needs three complete unchanged months', () {
    final s = historyFixture();
    final cards = results(s);
    expect(
      cards.singleWhere((i) => i.rule == 'D5').explanation,
      contains('3 из трёх'),
    );
    final cafe = cards.singleWhere((i) => i.rule == 'D6' && i.entity == 'кафе');
    expect(cafe.amounts, {'Медиана за месяц': 700, 'Сценарный лимит': 630});
    expect(cards.where((i) => i.rule == 'D6' && i.entity == 'жильё'), isEmpty);
    expect(
      results(
        s,
        policy: covered(s).copyWith(verifiedThrough: {'2026-11': '2026-11-14'}),
      ).where((i) => i.rule == 'D5' || i.rule == 'D6'),
      isEmpty,
    );
    final changed = LedgerSnapshot(
      currency: s.currency,
      accounts: s.accounts,
      entries: s.entries.where((e) => e.id != 'cafe8'),
      budgets: s.budgets,
    );
    expect(
      results(
        changed,
        policy: covered(s),
      ).where((i) => i.rule == 'D5' || i.rule == 'D6'),
      isEmpty,
    );
  });
  test(
    'relative growth uses exact cross products and positive income bases',
    () {
      final s = historyFixture();
      expect(results(s).where((i) => i.rule == 'E6'), isNotEmpty);
      final withoutIncome = LedgerSnapshot(
        currency: s.currency,
        accounts: s.accounts,
        entries: s.entries.where((e) => e.kind != EntryKind.income),
      );
      expect(results(withoutIncome).where((i) => i.rule == 'E6'), isEmpty);
      expect(results(withoutIncome).where((i) => i.rule == 'K1'), isEmpty);
    },
  );
  test('remaining-income ratio is not presented as actual savings', () {
    final c = results(historyFixture()).singleWhere((i) => i.rule == 'K1');
    expect(c.amounts['Разница доходов и чистых расходов'], 12400);
    expect(c.explanation, contains('а не подтверждённые накопления'));
  });
  test('missing-document check excludes archived or documented purchases', () {
    expect(results(historyFixture()).where((i) => i.rule == 'L3'), isNotEmpty);
    expect(
      results(historyFixture(documents: true)).where((i) => i.rule == 'L3'),
      isEmpty,
    );
    expect(
      results(historyFixture(archive: true)).where((i) => i.rule == 'L3'),
      isEmpty,
    );
  });
  test('weekly and monthly summaries retain separate refund amounts and exact dates', () {
    final s = historyFixture();
    final week = results(s).singleWhere((i) => i.rule == 'O1');
    expect(week.explanation, contains('2026-11-08 — 2026-11-14'));
    expect(week.amounts['Расходы до возвратов'], 600);
    final month = results(s, month: 10).singleWhere((i) => i.rule == 'O2');
    expect(month.amounts['Расходы до возвратов'], 4800);
    expect(month.explanation, contains('2026-10-01 — 2026-10-31'));
    expect(results(s).where((i) => i.rule == 'O2'), isEmpty);
    expect(
      results(
        s,
        month: 10,
        policy: AnalysisPolicy(),
      ).where((i) => i.rule == 'O2'),
      isEmpty,
    );
  });
  test('category drivers plus the remainder reconcile to total change', () {
    final c = results(historyFixture()).singleWhere((i) => i.rule == 'O3');
    expect(c.amounts['Общее изменение'], 15800);
    expect(
      sumMinor(
        c.amounts.entries
            .where((e) => e.key != 'Общее изменение')
            .map((e) => e.value),
      ),
      15800,
    );
  });
  test('old policy JSON gets the default threshold and preserves existing settings', () {
    final json = AnalysisPolicy(
      disabled: {'A1'},
      smallExpenseMinor: 700,
    ).toJson()..remove('smallExpenseMinor');
    final restored = AnalysisPolicy.fromJson(json);
    expect(restored.smallExpenseMinor, 500);
    expect(restored.disabled, {'A1'});
    expect(() => AnalysisPolicy(smallExpenseMinor: 0), throwsFormatException);
  });
  test(
    'additional rules remain deterministic under record and account reorder',
    () {
      final s = historyFixture();
      final reverse = LedgerSnapshot(
        currency: s.currency,
        accounts: s.accounts.reversed,
        entries: s.entries.reversed,
        budgets: s.budgets.reversed,
        purchases: s.purchases,
      );
      final a = results(s).where((i) => newRules.contains(i.rule)).toList(),
          b = results(reverse).where((i) => newRules.contains(i.rule)).toList();
      expect(a.map((i) => i.key), b.map((i) => i.key));
      for (var n = 0; n < a.length; n++) {
        expect(a[n].amounts, b[n].amounts);
        expect(a[n].explanation, b[n].explanation);
        expect(a[n].evidence, b[n].evidence);
      }
    },
  );
}
