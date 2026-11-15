import '../../models.dart';
import '../../schedule_math.dart';
import '../analysis_facts.dart';
import '../cash_calendar.dart';
import '../insight.dart';
import '../series_plan_link.dart';
import '../series_review.dart';
import '../statistics/robust_stats.dart';

List<Insight> calendarInsights(AnalysisFacts f, AnalysisPolicy policy) {
  final result = <Insight>[], s = f.snapshot;
  if (!f.current) return result;
  for (final review in policy.seriesReviews.values) {
    if (review.decision != SeriesDecision.accepted ||
        !review.validAt(s, f.end) ||
        review.planLink != null) {
      continue;
    }
    final sources = review.proposal.sources(s)!, last = sources.last;
    final typical = RobustStats(sources.map((e) => e.amountMinor)).medianFloor;
    var recommendations = 0;
    for (final plan in availableSeriesPlans(s, policy, review, f.end).where(
      (o) =>
          categoryKey(o.name) == categoryKey(last.note) &&
          categoryKey(o.category) == categoryKey(last.category),
    )) {
      final delta = (BigInt.from(plan.amountMinor) - BigInt.from(typical))
          .abs();
      if (delta * BigInt.from(100) > BigInt.from(typical) * BigInt.from(10) ||
          !followsCadence(
            last.date,
            periodDate(plan, plan.nextIndex),
            review.proposal.cadence,
          )) {
        continue;
      }
      result.add(
        Insight(
          rule: 'G6',
          entity: '${review.proposal.key}:${plan.id}',
          period: f.period,
          title: 'Серия может относиться к существующему плану',
          explanation: 'Совпадают название плана и комментарий серии, категория, тип и периодичность; суммы и ближайшая дата близки. В разделе «Серии» можно явно выбрать связь. Это не подтверждает оплату: для фактического платежа используйте действие оплаты плана. Календарный сценарий не создаёт отдельное повторение по серии.',
          group: InsightGroup.patterns,
          kind: InsightKind.check,
          priority: 10,
          amounts: {'Сумма плана': plan.amountMinor, 'Медиана серии': typical},
          evidence: [
            for (final e in sources) InsightEvidence(EvidenceKind.entry, e.id),
            InsightEvidence(EvidenceKind.obligation, plan.id),
          ],
        ),
      );
      if (++recommendations == 3) break;
    }
  }
  final base = cashCalendar(f);
  if (!base.hasEvents) return result;
  const assumptions =
      'Баланс по внесённым операциям на сегодня, затем будущие записи и неоплаченные активные планы до указанной даты включительно. Баланс обзора включает и будущие записи; здесь они учитываются в свою дату. Ожидаемые доходы условны; повседневные траты не прогнозируются. Просроченные расходы условно списаны сегодня, просроченный доход не добавлен. Оплаченные/пропущенные периоды не добавляются повторно. Остатки на конец дня, без внутридневного порядка.';
  final timeline = [
    for (final d in base.days) InsightDay(d.date, d.balanceMinor),
  ];
  result.add(
    Insight(
      rule: 'I1',
      entity: 'calendar',
      period: f.period,
      title: 'Остаток после известных платежей',
      explanation: assumptions,
      group: InsightGroup.scenarios,
      kind: InsightKind.scenario,
      amounts: {
        'На начало сценария (записи по сегодня)': sumMinor(f.balances.values),
        for (final n in [7, 30, 90])
          'На ${calendarDate(base.at(n).date)} (+$n дн.)': base
              .at(n)
              .balanceMinor,
        'Просроченные расходы, учтённые сегодня': base.overdueExpense,
        'Ожидаемый доход без счёта за 90 дней': base.unassignedIncome,
        'Расходы без счёта за 90 дней': base.unassignedExpense,
      },
      evidence: base.evidence,
      timeline: timeline,
    ),
  );
  final negative = base.firstNegative;
  if (negative != null) {
    result.add(
      Insight(
        rule: 'I2',
        entity: 'negative',
        period: f.period,
        title: 'В сценарии возможен отрицательный остаток',
        explanation:
            'Первый отрицательный итог дня: ${calendarDate(negative.date)}. $assumptions',
        group: InsightGroup.scenarios,
        kind: InsightKind.scenario,
        priority: 70,
        amounts: {
          'Остаток в этот день': negative.balanceMinor,
          'Минимум за 90 дней': base.minimum,
        },
        evidence: base.evidence,
        timeline: timeline,
      ),
    );
  }
  final accountIds = base.debitAccounts.toList()..sort();
  var warnings = 0;
  for (final id in accountIds) {
    final first = base.days
        .where((d) => d.balanceMinor >= 0 && (d.accounts[id] ?? 0) < 0)
        .firstOrNull;
    if (first == null) continue;
    final account = s.accounts.where((a) => a.id == id).firstOrNull;
    result.add(
      Insight(
        rule: 'I3',
        entity: id,
        period: f.period,
        title: 'На счёте может не хватить средств: ${account?.name ?? id}',
        explanation:
            '${calendarDate(first.date)}: общий сценарный остаток неотрицателен, но остаток этого счёта отрицателен. Планы без счёта входят только в общий итог, автоматического перераспределения нет. Это не проверка возможности банковского перевода. $assumptions',
        group: InsightGroup.scenarios,
        kind: InsightKind.scenario,
        priority: 60,
        amounts: {
          'На этом счёте': first.accounts[id]!,
          'Общий остаток': first.balanceMinor,
        },
        evidence: base.evidence,
        timelineTitle: 'Этот счёт: остаток на конец дня',
        timeline: [
          for (final d in base.days) InsightDay(d.date, d.accounts[id] ?? 0),
        ],
      ),
    );
    if (++warnings == 3) break;
  }
  if (base.hasExpectedIncome) {
    final delayed = cashCalendar(f, incomeDelayDays: policy.incomeDelayDays);
    result.add(
      Insight(
        rule: 'I5',
        entity: 'income-delay',
        period: f.period,
        title: 'Сценарий задержки ожидаемого дохода',
        explanation:
            'Только ожидаемые плановые поступления сдвинуты на ${policy.incomeDelayDays} дн. (меняется в настройках анализа); будущие внесённые операции не сдвигаются. Это выбранное допущение, не прогноз задержки. Первый отрицательный день: база — ${base.firstNegative == null ? 'нет в интервале' : calendarDate(base.firstNegative!.date)}, при задержке — ${delayed.firstNegative == null ? 'нет в интервале' : calendarDate(delayed.firstNegative!.date)}. $assumptions',
        group: InsightGroup.scenarios,
        kind: InsightKind.scenario,
        priority: 15,
        amounts: {
          'База, через 30 дней': base.at(30).balanceMinor,
          'Задержка, через 30 дней': delayed.at(30).balanceMinor,
          'База, через 90 дней': base.at(90).balanceMinor,
          'Задержка, через 90 дней': delayed.at(90).balanceMinor,
          'Минимум базы': base.minimum,
          'Минимум при задержке': delayed.minimum,
        },
        evidence: base.evidence,
        timelineTitle: 'При задержке: остаток на конец дня',
        timeline: [
          for (final d in delayed.days) InsightDay(d.date, d.balanceMinor),
        ],
      ),
    );
  }
  return result;
}
