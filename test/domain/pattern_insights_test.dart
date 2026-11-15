import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/domain/insights/insight.dart';
import 'package:personal_finance/domain/insights/insight_engine.dart';
import 'package:personal_finance/domain/insights/rules/pattern_rules.dart';
import 'package:personal_finance/domain/insights/statistics/robust_stats.dart';
import 'package:personal_finance/domain/models.dart';

const patternIds = {
  'B3',
  'E5',
  'G1',
  'G2',
  'G3',
  'G5',
  'H1',
  'H2',
  'H3',
  'H4',
  'H6',
  'N1',
  'N2',
  'N6',
};
LedgerSnapshot patternFixture() {
  final entries = <LedgerEntry>[];
  void add(
    String id,
    DateTime date,
    int amount, {
    String category = 'Повседневные',
    String note = '',
    EntryKind kind = EntryKind.expense,
  }) => entries.add(
    LedgerEntry(
      id: id,
      kind: kind,
      amountMinor: amount,
      date: date,
      accountId: 'a',
      category: category,
      note: note,
    ),
  );
  for (
    var d = DateTime(2026, 5);
    !d.isAfter(DateTime(2026, 11, 14));
    d = DateTime(d.year, d.month, d.day + 1)
  ) {
    add(
      'daily-${calendarDate(d)}',
      d,
      d.isBefore(DateTime(2026, 10, 18)) ? 100 : 2000,
    );
  }
  for (final (m, value) in [
    (5, 1000),
    (6, 20000),
    (7, 5000),
    (8, 40000),
    (9, 10000),
    (10, 80000),
  ]) {
    add(
      'income$m',
      DateTime(2026, m, 1),
      value,
      kind: EntryKind.income,
      category: 'Доход',
    );
  }
  for (final (m, value) in [(8, 1000), (9, 10000), (10, 20000)]) {
    add('growth$m', DateTime(2026, m, 4), value, category: 'Рост');
  }
  for (final m in [9, 10, 11]) {
    add(
      'monthly$m',
      DateTime(2026, m, 12),
      9000,
      category: 'Подписки',
      note: 'Сервис',
    );
  }
  for (var n = 0; n < 4; n++) {
    add(
      'weekly$n',
      DateTime(2026, 10, 24 + n * 7),
      700,
      category: 'Доставка',
      note: 'Доставка',
    );
  }
  for (final y in [2024, 2025, 2026]) {
    add(
      'yearly$y',
      DateTime(y, 11, 8),
      3000,
      category: 'Лицензии',
      note: 'Лицензия',
    );
  }
  for (var n = 0; n < 6; n++) {
    add('unusual$n', DateTime(2026, 11, 10), 10000, note: 'Вручную');
  }
  for (var n = 0; n < 2; n++) {
    add(
      'duplicate$n',
      DateTime(2026, 11, 9),
      600,
      category: 'Канцелярия',
      note: 'Покупка',
    );
  }
  return LedgerSnapshot(
    currency: 'AZN',
    accounts: const [
      Account(id: 'a', name: 'Карта', kind: 'Карта', openingMinor: 500000),
    ],
    entries: entries,
    obligations: [
      for (var n = 0; n < 2; n++)
        Obligation(
          id: 'plan$n',
          name: n == 0 ? 'Интернет' : ' интернет ',
          kind: EntryKind.expense,
          amountMinor: 2000,
          category: 'Связь',
          anchor: DateTime(2026, 11, 16),
          repeat: RepeatRule.monthly,
        ),
    ],
  );
}

AnalysisPolicy patternPolicy(LedgerSnapshot s) {
  final dates = [
    for (var m = 1; m <= 10; m++) DateTime(2026, m + 1, 0),
    DateTime(2026, 11, 14),
  ];
  return AnalysisPolicy(
    verifiedThrough: {for (final d in dates) monthKey(d): calendarDate(d)},
    verifiedHashes: {for (final d in dates) monthKey(d): coverageHash(s, d)},
  );
}

List<Insight> scan(
  LedgerSnapshot s, {
  AnalysisPolicy? policy,
  int month = 11,
}) => InsightEngine().analyze(
  s,
  DateTime(2026, month),
  DateTime(2026, 11, 14),
  policy ?? patternPolicy(s),
);
LedgerSnapshot only(
  List<LedgerEntry> entries, {
  List<Obligation> plans = const [],
}) => LedgerSnapshot(
  currency: 'AZN',
  accounts: const [
    Account(id: 'a', name: 'Карта', kind: 'Карта', openingMinor: 0),
  ],
  entries: entries,
  obligations: plans,
);
LedgerEntry expense(
  String id,
  DateTime date,
  int amount, {
  String note = '',
  String category = 'Еда',
}) => LedgerEntry(
  id: id,
  kind: EntryKind.expense,
  amountMinor: amount,
  date: date,
  accountId: 'a',
  category: category,
  note: note,
);

void main() {
  test('median and MAD retain exact half-unit arithmetic', () {
    expect(medianTwice([BigInt.from(1), BigInt.from(2)]), BigInt.from(3));
    final stats = RobustStats([10, 12, 14, 16, 18]);
    expect(stats.center2, BigInt.from(28));
    expect(stats.mad4, BigInt.from(8));
    expect(stats.high(30, minimumDifference: 1), isTrue);
    expect(stats.high(20, minimumDifference: 1), isFalse);
    expect(stats.high(30, minimumDifference: 100), isFalse);
    expect(() => RobustStats([]), throwsArgumentError);
  });
  test('zero MAD uses an explicit conservative fallback and no division', () {
    final constant = RobustStats(List.filled(20, 100));
    expect(constant.high(299, minimumDifference: 10), isFalse);
    expect(constant.high(300, minimumDifference: 10), isTrue);
    final zeros = RobustStats(List.filled(8, 0));
    expect(zeros.high(999, minimumDifference: 1000), isFalse);
    expect(zeros.high(1000, minimumDifference: 1000), isTrue);
  });
  test('statistics handle maximum integers without overflow', () {
    final stats = RobustStats([9223372036854775806, 9223372036854775807]);
    expect(stats.medianFloor, 9223372036854775806);
    expect(stats.high(9223372036854775807, minimumDifference: 1), isFalse);
  });
  test(
    '14 new rules have positive evidence across current and closed months',
    () {
      final s = patternFixture();
      final all = [...scan(s), ...scan(s, month: 10)];
      expect(all.map((i) => i.rule).toSet(), containsAll(patternIds));
      expect(insightRules.length, 90);
      for (final rule in patternIds) {
        expect(
          scan(
            s,
            policy: patternPolicy(s).copyWith(disabled: {rule}),
          ).where((i) => i.rule == rule),
          isEmpty,
        );
      }
    },
  );
  test('monthly weekly and yearly candidates remain hypotheses', () {
    final cards = scan(patternFixture());
    for (final rule in ['G1', 'G2', 'G3']) {
      final c = cards.singleWhere((i) => i.rule == rule);
      expect(c.kind, InsightKind.check);
      expect(c.evidence.length, rule == 'G2' ? 4 : 3);
      expect(c.explanation, contains('не установленная подписка'));
    }
  });
  test(
    'empty comments and irregular dates do not invent a recurring series',
    () {
      final s = only([
        for (var m = 9; m <= 11; m++)
          expense('e$m', DateTime(2026, m, m == 10 ? 23 : 10), 1000),
      ]);
      expect(
        scan(s).where((i) => ['G1', 'G2', 'G3'].contains(i.rule)),
        isEmpty,
      );
      final notes = only([
        for (var m = 9; m <= 11; m++)
          expense(
            'e$m',
            DateTime(2026, m, m == 10 ? 23 : 10),
            1000,
            note: 'Сервис',
          ),
      ]);
      expect(
        scan(notes).where((i) => ['G1', 'G2', 'G3'].contains(i.rule)),
        isEmpty,
      );
    },
  );
  test(
    'monthly candidates accept month-end clipping and reject price jumps',
    () {
      final rows = [
        expense('e1', DateTime(2026, 8, 31), 1000, note: 'Сервис'),
        expense('e2', DateTime(2026, 9, 30), 1000, note: 'Сервис'),
        expense('e3', DateTime(2026, 10, 31), 1000, note: 'Сервис'),
      ];
      expect(
        scan(only(rows), month: 10).where((i) => i.rule == 'G1'),
        isNotEmpty,
      );
      final jump = [
        ...rows.take(2),
        expense('e3', DateTime(2026, 10, 31), 2000, note: 'Сервис'),
      ];
      expect(scan(only(jump), month: 10).where((i) => i.rule == 'G1'), isEmpty);
    },
  );
  test(
    'duplicate identity is normalized but respects amount category and comment',
    () {
      final date = DateTime(2026, 11, 9);
      final rows = [
        expense('one', date, 1000, note: ' Чек ', category: 'Еда'),
        expense('two', date, 1000, note: 'чек', category: 'еда'),
      ];
      final d = scan(only(rows)).singleWhere((i) => i.rule == 'H4');
      expect(d.evidence.length, 2);
      expect(d.explanation, contains('разные реальные покупки'));
      expect(
        scan(only([rows.first, expense('two', date, 1001, note: 'чек')]))
            .where((i) => i.rule == 'H4'),
        isEmpty,
      );
      expect(
        scan(only([rows.first, expense('two', date, 1000, note: 'Другой чек')]))
            .where((i) => i.rule == 'H4'),
        isEmpty,
      );
      expect(patternIdentity(['ab', 'c']), isNot(patternIdentity(['a', 'bc'])));
    },
  );
  test('plan duplicate check ignores paused or different due dates', () {
    final s = patternFixture();
    expect(scan(s).where((i) => i.rule == 'G5'), isNotEmpty);
    final changed = only(
      [],
      plans: [
        s.obligations.first,
        Obligation.fromJson({...s.obligations.last.toJson(), 'paused': true}),
      ],
    );
    expect(scan(changed).where((i) => i.rule == 'G5'), isEmpty);
    final moved = only(
      [],
      plans: [
        s.obligations.first,
        Obligation.fromJson({
          ...s.obligations.last.toJson(),
          'anchor': '2026-11-17',
        }),
      ],
    );
    expect(scan(moved).where((i) => i.rule == 'G5'), isEmpty);
  });
  test(
    'unusual transactions require 20 earlier same-category observations',
    () {
      final rows = [
        for (var n = 0; n < 19; n++)
          expense('base$n', DateTime(2026, 10, 1 + n), 100),
        expense('high', DateTime(2026, 11, 2), 10000),
      ];
      expect(scan(only(rows)).where((i) => i.rule == 'H1'), isEmpty);
      final s = only([...rows, expense('base19', DateTime(2026, 10, 25), 100)]);
      expect(scan(s).singleWhere((i) => i.rule == 'H1').entity, 'high');
      final future = only([
        ...rows,
        expense('future', DateTime(2026, 12, 1), 100),
      ]);
      expect(scan(future).where((i) => i.rule == 'H1'), isEmpty);
    },
  );
  test('daily and weekday rules require verified complete coverage', () {
    final s = patternFixture(), cards = scan(patternFixture());
    expect(cards.where((i) => i.rule == 'H2'), isNotEmpty);
    expect(cards.where((i) => i.rule == 'H6'), isNotEmpty);
    final without = scan(s, policy: AnalysisPolicy());
    expect(
      without.where(
        (i) => ['H2', 'H6', 'N1', 'N2', 'N6', 'B3', 'E5'].contains(i.rule),
      ),
      isEmpty,
    );
  });
  test('weekday averages include confirmed zero days', () {
    final s = only([expense('one', DateTime(2026, 11, 9), 800)]);
    final n = scan(s).singleWhere((i) => i.rule == 'N1');
    expect(n.amounts['Пн'], 100);
    for (final day in ['Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс']) {
      expect(n.amounts[day], 0);
    }
    final weekend = scan(s).singleWhere((i) => i.rule == 'N2');
    expect(weekend.amounts['В среднем за будний'], 20);
    expect(weekend.amounts['В среднем за выходной'], 0);
  });
  test(
    'one isolated expensive week does not establish a new spending level',
    () {
      final end = DateTime(2026, 11, 14), start = DateTime(2026, 8, 23);
      final rows = <LedgerEntry>[];
      for (
        var d = start;
        !d.isAfter(end);
        d = DateTime(d.year, d.month, d.day + 1)
      ) {
        rows.add(
          expense(
            calendarDate(d),
            d,
            d.isBefore(DateTime(2026, 11, 8)) ? 100 : 10000,
          ),
        );
      }
      expect(scan(only(rows)).where((i) => i.rule == 'N6'), isEmpty);
      expect(scan(patternFixture()).where((i) => i.rule == 'N6'), isNotEmpty);
    },
  );
  test(
    'monthly shock needs a closed month and six verified earlier months',
    () {
      final s = patternFixture();
      expect(scan(s).where((i) => i.rule == 'H3'), isEmpty);
      expect(scan(s, month: 10).where((i) => i.rule == 'H3'), isNotEmpty);
      expect(
        scan(
          s,
          month: 10,
          policy: AnalysisPolicy(),
        ).where((i) => i.rule == 'H3'),
        isEmpty,
      );
    },
  );
  test('trend requires strictly rising complete months and income dispersion excludes refunds', () {
    final s = patternFixture();
    expect(scan(s).where((i) => i.rule == 'B3'), isNotEmpty);
    final income = scan(s).singleWhere((i) => i.rule == 'E5');
    expect(income.amounts['Медиана дохода'], 15000);
    expect(income.amounts['Межквартильный разброс'], 35000);
    final lower = only(
      s.entries
          .where((e) => e.kind != EntryKind.expense || e.date.month != 10)
          .toList(),
    );
    expect(scan(lower).where((i) => i.rule == 'B3'), isEmpty);
  });
  test(
    'daily alerts retain the three greatest excesses rather than earliest days',
    () {
      final rows = patternFixture().entries
          .where((e) => e.id.startsWith('daily-') && e.date.month < 11)
          .toList();
      for (var day = 1; day <= 4; day++) {
        for (var n = 0; n < day + 3; n++) {
          rows.add(
            LedgerEntry(
              id: 'day$day-$n',
              kind: EntryKind.expense,
              amountMinor: 1000,
              date: DateTime(2026, 11, day),
              accountId: 'a',
              category: 'Повседневные',
            ),
          );
        }
      }
      final cards = scan(only(rows));
      for (final rule in ['H2', 'H6']) {
        expect(
          cards.where((i) => i.rule == rule).map((i) => i.entity).toSet(),
          {'2026-11-02', '2026-11-03', '2026-11-04'},
        );
      }
    },
  );
  test('pattern results and evidence are deterministic under reordering', () {
    final s = patternFixture(),
        r = LedgerSnapshot(
          currency: 'AZN',
          accounts: patternFixture().accounts,
          entries: patternFixture().entries.reversed,
          obligations: patternFixture().obligations.reversed,
        );
    final a = scan(s).where((i) => patternIds.contains(i.rule)).toList(),
        b = scan(r).where((i) => patternIds.contains(i.rule)).toList();
    expect(a.map((i) => i.key), b.map((i) => i.key));
    for (var n = 0; n < a.length; n++) {
      expect(a[n].amounts, b[n].amounts);
      expect(a[n].explanation, b[n].explanation);
      expect(a[n].evidence, b[n].evidence);
    }
  });
}
