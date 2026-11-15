import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/domain/insights/analysis_facts.dart';
import 'package:personal_finance/domain/insights/cash_calendar.dart';
import 'package:personal_finance/domain/insights/insight.dart';
import 'package:personal_finance/domain/insights/insight_engine.dart';
import 'package:personal_finance/domain/models.dart';

Obligation calendarPlan(
  String id,
  int amount,
  int day, {
  EntryKind kind = EntryKind.expense,
  String? account = 'a',
  RepeatRule repeat = RepeatRule.once,
  bool paused = false,
  int next = 0,
}) => Obligation(
  id: id,
  name: id,
  kind: kind,
  amountMinor: amount,
  category: 'Планы',
  anchor: DateTime(2026, 11, day),
  repeat: repeat,
  accountId: account,
  paused: paused,
  nextIndex: next,
);
LedgerSnapshot calendarFixture({
  List<Obligation>? plans,
  List<LedgerEntry>? entries,
  List<Settlement> settlements = const [],
  List<Account>? accounts,
}) => LedgerSnapshot(
  currency: 'AZN',
  accounts:
      accounts ??
      const [
        Account(id: 'a', name: 'Карта', kind: 'Карта', openingMinor: 10000),
        Account(id: 'b', name: 'Запас', kind: 'Наличные', openingMinor: 20000),
      ],
  entries:
      entries ??
      [
        LedgerEntry(
          id: 'transfer',
          kind: EntryKind.transfer,
          amountMinor: 3000,
          date: DateTime(2026, 11, 17),
          accountId: 'a',
          targetAccountId: 'b',
          category: 'Перевод',
        ),
      ],
  obligations:
      plans ??
      [
        calendarPlan('expense', 15000, 16),
        calendarPlan('unassigned', 3000, 18, account: null),
        calendarPlan(
          'income',
          20000,
          20,
          kind: EntryKind.income,
          account: null,
        ),
        calendarPlan('large', 50000, 25),
      ],
  settlements: settlements,
);
AnalysisFacts calendarFacts(LedgerSnapshot s) =>
    AnalysisFacts(s, DateTime(2026, 11), DateTime(2026, 11, 14));
List<Insight> calendarScan(
  LedgerSnapshot s, {
  AnalysisPolicy? policy,
  int month = 11,
}) => InsightEngine().analyze(
  s,
  DateTime(2026, month),
  DateTime(2026, 11, 14),
  policy ?? AnalysisPolicy(),
);
void main() {
  test(
    'overview does not repeat several variants of the same calendar scenario',
    () {
      final preview = selectInsightPreview(
        calendarScan(calendarFixture())
            .where((i) => ['I1', 'I2', 'I5'].contains(i.rule)),
      );
      expect(preview, hasLength(1));
      expect(preview.single.rule, 'I2');
    },
  );
  test('end of day totals reconcile transfers and unassigned plans', () {
    final c = cashCalendar(calendarFacts(calendarFixture()));
    expect(c.days, hasLength(91));
    expect(c.at(2).balanceMinor, 15000);
    expect(c.at(2).accounts['a'], -5000);
    expect(c.at(3).balanceMinor, 15000);
    expect(c.at(3).accounts, {'a': -8000, 'b': 23000});
    expect(c.at(4).balanceMinor, 12000);
    expect(c.at(6).balanceMinor, 32000);
    expect(c.unassignedIncome, 20000);
    expect(c.unassignedExpense, 3000);
    expect(c.firstNegative!.date, DateTime(2026, 11, 25));
    expect(c.minimum, -18000);
  });
  test('four calendar rules show dated horizons account warning and delayed income', () {
    final cards = calendarScan(calendarFixture());
    expect(cards.map((i) => i.rule), containsAll(['I1', 'I2', 'I3', 'I5']));
    final main = cards.singleWhere((i) => i.rule == 'I1');
    expect(main.amounts['На начало сценария (записи по сегодня)'], 30000);
    expect(main.amounts['На 2026-11-21 (+7 дн.)'], 32000);
    expect(main.timeline, hasLength(91));
    expect(
      cards.singleWhere((i) => i.rule == 'I3').amounts['На этом счёте'],
      -5000,
    );
    expect(
      cards.singleWhere((i) => i.rule == 'I5').amounts['Минимум при задержке'],
      -38000,
    );
  });
  test(
    'settled future expense replaces plan exactly once and actual amount wins',
    () {
      final s = calendarFixture(
        plans: [calendarPlan('paid', 10000, 16, repeat: RepeatRule.monthly)],
        entries: [
          LedgerEntry(
            id: 'actual',
            kind: EntryKind.expense,
            amountMinor: 11000,
            date: DateTime(2026, 11, 18),
            accountId: 'a',
            category: 'Планы',
          ),
        ],
        settlements: [
          Settlement(
            id: 'settled',
            obligationId: 'paid',
            periodIndex: 0,
            dueDate: DateTime(2026, 11, 16),
            entryId: 'actual',
            skipped: false,
            version: 1,
          ),
        ],
      );
      expect(cashCalendar(calendarFacts(s)).at(7).balanceMinor, 19000);
      expect(cashCalendar(calendarFacts(s)).at(90).balanceMinor, -1000);
    },
  );
  test(
    'skipped periods and paused or completed plans do not become debits',
    () {
      final s = calendarFixture(
        plans: [
          calendarPlan('skip', 10000, 16),
          calendarPlan('paused', 10000, 16, paused: true),
          calendarPlan('done', 10000, 16, next: 1),
        ],
        entries: [],
        settlements: [
          Settlement(
            id: 'skip-s',
            obligationId: 'skip',
            periodIndex: 0,
            dueDate: DateTime(2026, 11, 16),
            entryId: null,
            skipped: true,
            version: 1,
          ),
        ],
      );
      final c = cashCalendar(calendarFacts(s));
      expect(c.hasEvents, isFalse);
      expect(c.at(90).balanceMinor, 30000);
    },
  );
  test('overdue expense moves to today once and overdue expected income is excluded', () {
    final c = cashCalendar(
      calendarFacts(
        calendarFixture(
          plans: [
            calendarPlan('late-expense', 500, 1),
            calendarPlan('late-income', 900, 1, kind: EntryKind.income),
          ],
          entries: [],
        ),
      ),
    );
    expect(c.at(0).balanceMinor, 29500);
    expect(c.overdueExpense, 500);
    expect(c.hasExpectedIncome, isFalse);
    expect(c.at(90).balanceMinor, 29500);
  });
  test(
    'today ledger is already in opening balance and future refunds add once',
    () {
      final rows = [
        LedgerEntry(
          id: 'today',
          kind: EntryKind.expense,
          amountMinor: 1000,
          date: DateTime(2026, 11, 14),
          accountId: 'a',
          category: 'Еда',
        ),
        LedgerEntry(
          id: 'refund',
          kind: EntryKind.refund,
          amountMinor: 500,
          date: DateTime(2026, 11, 16),
          accountId: 'a',
          category: 'Еда',
          refundOf: 'today',
        ),
      ];
      final c = cashCalendar(
        calendarFacts(calendarFixture(plans: [], entries: rows)),
      );
      expect(c.at(0).balanceMinor, 29000);
      expect(c.at(2).balanceMinor, 29500);
      expect(c.hasExpectedIncome, isFalse);
    },
  );
  test(
    'same-day operations are netted without inventing intraday risk or order',
    () {
      final plans = [
        calendarPlan('expense', 50000, 16),
        calendarPlan('income', 50000, 16, kind: EntryKind.income),
      ];
      final a = cashCalendar(
            calendarFacts(calendarFixture(plans: plans, entries: [])),
          ),
          b = cashCalendar(
            calendarFacts(
              calendarFixture(plans: plans.reversed.toList(), entries: []),
            ),
          );
      expect(a.firstNegative, isNull);
      expect(
        a.days.map((d) => d.balanceMinor),
        b.days.map((d) => d.balanceMinor),
      );
    },
  );
  test('horizons include exact end date and omit later dates', () {
    final c = cashCalendar(
      calendarFacts(
        calendarFixture(
          plans: [
            calendarPlan('edge', 100, 21),
            calendarPlan('after', 200, 22),
            calendarPlan('outside', 400, 105),
          ],
          entries: [],
        ),
      ),
    );
    expect(c.at(7).balanceMinor, 29900);
    expect(c.at(8).balanceMinor, 29700);
    expect(c.at(90).balanceMinor, 29700);
  });
  test(
    'month-end schedule clips leap day correctly without weekly multipliers',
    () {
      final s = calendarFixture(
        plans: [
          Obligation(
            id: 'end',
            name: 'Конец месяца',
            kind: EntryKind.expense,
            amountMinor: 100,
            category: 'Планы',
            anchor: DateTime(2028, 1, 31),
            repeat: RepeatRule.monthly,
          ),
        ],
        entries: [],
      );
      final c = cashCalendar(
        AnalysisFacts(s, DateTime(2028, 1), DateTime(2028, 1, 30)),
      );
      expect(c.at(30).date, DateTime(2028, 2, 29));
      expect(c.at(30).balanceMinor, 29800);
      expect(c.at(90).balanceMinor, 29700);
    },
  );
  test(
    'delay shifts only expected plans and can move them outside horizon',
    () {
      final c = cashCalendar(
        calendarFacts(
          calendarFixture(
            plans: [calendarPlan('expected', 1000, 20, kind: EntryKind.income)],
            entries: [
              LedgerEntry(
                id: 'recorded',
                kind: EntryKind.income,
                amountMinor: 500,
                date: DateTime(2026, 11, 16),
                accountId: 'a',
                category: 'Доход',
              ),
            ],
          ),
        ),
        incomeDelayDays: 90,
      );
      expect(c.at(2).balanceMinor, 30500);
      expect(c.at(90).balanceMinor, 30500);
    },
  );
  test('delay settings preserve old JSON defaults and reject invalid days', () {
    final old = AnalysisPolicy().toJson()..remove('incomeDelayDays');
    expect(AnalysisPolicy.fromJson(old).incomeDelayDays, 7);
    expect(
      AnalysisPolicy.fromJson(AnalysisPolicy(incomeDelayDays: 30).toJson())
          .incomeDelayDays,
      30,
    );
    for (final days in [0, 91]) {
      expect(
        () => AnalysisPolicy(incomeDelayDays: days),
        throwsFormatException,
      );
    }
  });
  test(
    'history and empty schedule do not get reconstructed using current plans',
    () {
      expect(
        calendarScan(
          calendarFixture(),
          month: 10,
        ).where((i) => i.rule.startsWith('I')),
        isEmpty,
      );
      expect(
        calendarScan(calendarFixture(plans: [], entries: []))
            .where((i) => i.rule.startsWith('I')),
        isEmpty,
      );
      expect(
        () => cashCalendar(
          AnalysisFacts(
            calendarFixture(),
            DateTime(2026, 10),
            DateTime(2026, 11, 14),
          ),
        ),
        throwsA(isA<DomainError>()),
      );
    },
  );
  test('all arithmetic fails explicitly on overflow instead of wrapping', () {
    final s = calendarFixture(
      accounts: const [
        Account(
          id: 'a',
          name: 'Тест',
          kind: 'Карта',
          openingMinor: 9223372036854775807,
        ),
      ],
      entries: [],
      plans: [calendarPlan('income', 1, 16, kind: EntryKind.income)],
    );
    expect(() => cashCalendar(calendarFacts(s)), throwsA(isA<DomainError>()));
  });
}
