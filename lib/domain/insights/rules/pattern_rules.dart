import '../../models.dart';
import '../../schedule_math.dart';
import '../analysis_facts.dart';
import '../insight.dart';
import '../series_review.dart';
import '../statistics/robust_stats.dart';

List<Insight> patternInsights(AnalysisFacts f, AnalysisPolicy policy) {
  final s = f.snapshot, result = <Insight>[];
  final asOf = s.entries.where((e) => !e.date.isAfter(f.end)).toList();
  final expenses = asOf.where((e) => e.kind == EntryKind.expense).toList();
  List<InsightEvidence> refs(Iterable<LedgerEntry> entries) =>
      entries.map((e) => InsightEvidence(EvidenceKind.entry, e.id)).toList();
  void add(
    String rule,
    String entity,
    String title,
    String explanation, {
    Map<String, int> amounts = const {},
    Iterable<InsightEvidence> evidence = const [],
    InsightGroup group = InsightGroup.patterns,
    InsightKind kind = InsightKind.check,
    int priority = 10,
    SeriesProposal? seriesProposal,
  }) => result.add(
    Insight(
      rule: rule,
      entity: entity,
      period: f.period,
      title: title,
      explanation: explanation,
      amounts: amounts,
      evidence: evidence,
      group: group,
      kind: kind,
      priority: priority,
      seriesProposal: seriesProposal,
    ),
  );
  bool rangeCovered(DateTime from, DateTime through) {
    for (
      var m = DateTime(from.year, from.month);
      !m.isAfter(through);
      m = DateTime(m.year, m.month + 1)
    ) {
      final last = DateTime(m.year, m.month + 1, 0);
      if (!f.covered(policy, last.isAfter(through) ? through : last)) {
        return false;
      }
    }
    return true;
  }

  final duplicates = <String, List<LedgerEntry>>{};
  for (final e in f.entries.where(
    (e) => e.kind == EntryKind.income || e.kind == EntryKind.expense,
  )) {
    final key = patternIdentity([
      calendarDate(e.date),
      e.accountId,
      e.kind.name,
      e.amountMinor.toString(),
      categoryKey(e.category),
      categoryKey(e.note),
    ]);
    duplicates.putIfAbsent(key, () => []).add(e);
  }
  final duplicateGroups = duplicates.values.where((g) => g.length >= 2).toList()
    ..sort((a, b) {
      final d = b.length.compareTo(a.length);
      return d != 0
          ? d
          : a
                .map((e) => e.id)
                .reduce((x, y) => x.compareTo(y) < 0 ? x : y)
                .compareTo(
                  b
                      .map((e) => e.id)
                      .reduce((x, y) => x.compareTo(y) < 0 ? x : y),
                );
    });
  for (final group in duplicateGroups.take(10)) {
    final sorted = group.toList()..sort((a, b) => a.id.compareTo(b.id));
    final e = sorted.first;
    add(
      'H4',
      sorted.map((e) => e.id).join('/'),
      'Проверьте похожие операции',
      '${sorted.length} записей с одинаковыми датой, счётом, типом, суммой, категорией и нормализованным комментарием. Это могут быть разные реальные покупки. Удаление не выполняется автоматически.',
      amounts: {
        'Сумма одной записи': e.amountMinor,
        'Сумма всех записей группы': sumMinor(sorted.map((e) => e.amountMinor)),
      },
      evidence: refs(sorted),
      priority: 20,
    );
  }
  final series = <String, List<LedgerEntry>>{};
  final seriesStart = DateTime(f.end.year - 3, f.end.month, f.end.day);
  for (final e in expenses.where(
    (e) => !e.date.isBefore(seriesStart) && categoryKey(e.note).length >= 3,
  )) {
    series
        .putIfAbsent(
          patternIdentity([
            e.accountId,
            categoryKey(e.category),
            categoryKey(e.note),
          ]),
          () => [],
        )
        .add(e);
  }
  final seriesKeys = series.keys.toList()..sort();
  var candidates = 0;
  for (final key in seriesKeys) {
    final values = series[key]!
      ..sort((a, b) {
        final d = a.date.compareTo(b.date);
        return d != 0 ? d : a.id.compareTo(b.id);
      });
    if (!values.any((e) => AnalysisFacts.within(e.date, f.start, f.end))) {
      continue;
    }
    for (final (rule, needed, label) in [
      ('G1', 3, 'ежемесячную'),
      ('G2', 4, 'еженедельную'),
      ('G3', 3, 'ежегодную'),
    ]) {
      if (values.length < needed) continue;
      final tail = values.sublist(values.length - needed);
      var matches = true;
      for (var n = 1; n < tail.length; n++) {
        final a = tail[n - 1].date, b = tail[n].date;
        final days = calendarDaysBetween(a, b),
            months = (b.year - a.year) * 12 + b.month - a.month;
        final bothEnds =
            a.day == DateTime(a.year, a.month + 1, 0).day &&
            b.day == DateTime(b.year, b.month + 1, 0).day;
        final fits = rule == 'G2'
            ? days >= 6 && days <= 8
            : rule == 'G1'
            ? months == 1 && ((a.day - b.day).abs() <= 3 || bothEnds)
            : b.year - a.year == 1 &&
                  a.month == b.month &&
                  (a.day - b.day).abs() <= 7;
        if (!fits) {
          matches = false;
          break;
        }
      }
      final amounts = tail.map((e) => e.amountMinor).toList()..sort();
      if (!matches ||
          BigInt.from(amounts.last) * BigInt.from(100) >
              BigInt.from(amounts.first) * BigInt.from(110)) {
        continue;
      }
      final stats = RobustStats(amounts);
      final proposal = SeriesProposal(
        key: seriesKey(s.currency!, tail.first),
        cadence: switch (rule) {
          'G1' => SeriesCadence.monthly,
          'G2' => SeriesCadence.weekly,
          _ => SeriesCadence.yearly,
        },
        sourceIds: tail.map((e) => e.id),
        sourceHash: seriesSourceHash(s.currency!, tail),
      );
      final review = policy.seriesReviews[proposal.key];
      if (review != null && review.validAt(s, f.end)) break;
      add(
        rule,
        key,
        'Похоже на $label трату',
        '${tail.length} последних записей с одним счётом, категорией и одинаковым непустым комментарием. Интервалы близки, суммы различаются не более чем на 10%. Подтвердите смысл самостоятельно: это не установленная подписка. Комментарий не считается проверенным продавцом.',
        amounts: {'Типичная сумма': stats.medianFloor},
        evidence: refs(tail),
        seriesProposal: proposal,
      );
      candidates++;
      break;
    }
    if (candidates >= 10) break;
  }
  final plans = <String, List<Obligation>>{};
  for (final o in s.obligations.where((o) => o.active)) {
    final key = patternIdentity([
      categoryKey(o.name),
      o.kind.name,
      o.repeat.name,
      calendarDate(periodDate(o, o.nextIndex)),
    ]);
    plans.putIfAbsent(key, () => []).add(o);
  }
  final planKeys = plans.keys.toList()..sort();
  for (final key in planKeys) {
    final group = plans[key]!;
    if (group.length < 2) continue;
    final amounts = group.map((o) => o.amountMinor).toList()..sort();
    if (BigInt.from(amounts.last) * BigInt.from(100) >
        BigInt.from(amounts.first) * BigInt.from(110)) {
      continue;
    }
    final ids = group.map((o) => o.id).toList()..sort();
    add(
      'G5',
      ids.join('/'),
      'Возможные дубли планов',
      '${group.length} активных планов с одинаковыми нормализованным названием, типом, периодичностью и ближайшей датой. Суммы близки. Это могут быть разные договоры; откройте обе карточки и проверьте.',
      group: InsightGroup.quality,
      evidence: group.map(
        (o) => InsightEvidence(EvidenceKind.obligation, o.id),
      ),
      priority: 20,
    );
  }
  final baselineStart = DateTime(f.start.year, f.start.month - 6);
  final categoryBaseline = <String, List<LedgerEntry>>{};
  for (final e in expenses.where(
    (e) => !e.date.isBefore(baselineStart) && e.date.isBefore(f.start),
  )) {
    categoryBaseline
        .putIfAbsent(f.canonicalCategory(e.category), () => [])
        .add(e);
  }
  final statistics = <String, RobustStats>{
    for (final c in categoryBaseline.entries.where((c) => c.value.length >= 20))
      c.key: RobustStats(c.value.map((e) => e.amountMinor)),
  };
  final unusual =
      f.entries
          .where(
            (e) =>
                e.kind == EntryKind.expense &&
                statistics[f.canonicalCategory(e.category)]?.high(
                      e.amountMinor,
                      minimumDifference: policy.minimumFor('H1', e.category),
                    ) ==
                    true,
          )
          .toList()
        ..sort((a, b) {
          final d = b.amountMinor.compareTo(a.amountMinor);
          return d != 0 ? d : a.id.compareTo(b.id);
        });
  for (final e in unusual.take(3)) {
    final stats = statistics[f.canonicalCategory(e.category)]!;
    add(
      'H1',
      e.id,
      'Сумма заметно выше привычной: ${e.category}',
      'Сравнение с ${stats.count} расходами этой категории до выбранного месяца, за предыдущие шесть месяцев. Медиана и MAD: ${stats.mad4 == BigInt.zero ? 'разброс равен нулю, использован порог в три медианы с превышением 90-го процентиля истории' : 'модифицированный показатель выше 3,5'}. Это повод проверить запись, а не доказательство ошибки.',
      amounts: {
        'Эта запись': e.amountMinor,
        'Медиана прошлых расходов': stats.medianFloor,
      },
      evidence: [
        ...refs([e]),
        ...refs(categoryBaseline[f.canonicalCategory(e.category)]!),
      ],
      priority: 35,
    );
  }
  final dayEntries = <String, List<LedgerEntry>>{};
  for (final e in expenses) {
    dayEntries.putIfAbsent(calendarDate(e.date), () => []).add(e);
  }
  int daily(DateTime d) =>
      sumMinor((dayEntries[calendarDate(d)] ?? []).map((e) => e.amountMinor));
  int dailyCount(DateTime d) => dayEntries[calendarDate(d)]?.length ?? 0;
  final previousEnd = DateTime(f.start.year, f.start.month, f.start.day - 1);
  final previousStart = DateTime(f.start.year, f.start.month, f.start.day - 56);
  if (rangeCovered(previousStart, previousEnd) && f.covered(policy, f.end)) {
    final byWeekday = <int, List<DateTime>>{};
    for (var n = 0; n < 56; n++) {
      final d = DateTime(
        previousStart.year,
        previousStart.month,
        previousStart.day + n,
      );
      byWeekday.putIfAbsent(d.weekday, () => []).add(d);
    }
    final moneyStats = {
      for (final day in byWeekday.entries)
        day.key: RobustStats(day.value.map(daily)),
    };
    final countStats = {
      for (final day in byWeekday.entries)
        day.key: RobustStats(day.value.map(dailyCount)),
    };
    final moneyDays = <DateTime>[], countDays = <DateTime>[];
    for (var n = 0; n < calendarDaysBetween(f.start, f.end) + 1; n++) {
      final d = DateTime(f.start.year, f.start.month, f.start.day + n);
      if (moneyStats[d.weekday]!.high(
        daily(d),
        minimumDifference: policy.minimumChangeMinor,
      )) {
        moneyDays.add(d);
      }
      if (countStats[d.weekday]!.high(dailyCount(d), minimumDifference: 3)) {
        countDays.add(d);
      }
    }
    // Rank excess over each weekday's own median; materialize evidence only
    // for the selected days rather than for every date in the month.
    void rank(
      List<DateTime> days,
      Map<int, RobustStats> stats,
      int Function(DateTime) value,
    ) {
      BigInt excess(DateTime d) =>
          BigInt.from(value(d)) * BigInt.two - stats[d.weekday]!.center2;
      days.sort((a, b) {
        final difference = excess(b).compareTo(excess(a));
        return difference != 0 ? difference : a.compareTo(b);
      });
    }

    rank(moneyDays, moneyStats, daily);
    rank(countDays, countStats, dailyCount);
    List<InsightEvidence> dayEvidence(DateTime d) => [
      ...refs(dayEntries[calendarDate(d)] ?? []),
      ...refs(
        byWeekday[d.weekday]!.expand(
          (day) => dayEntries[calendarDate(day)] ?? <LedgerEntry>[],
        ),
      ),
    ];
    for (final d in moneyDays.take(3)) {
      final key = calendarDate(d);
      add(
        'H2',
        key,
        'Необычная сумма за день: $key',
        'Сравнение с восемью такими же днями недели до выбранного месяца. Полнота учёта подтверждена, включая дни без записей. Суммы до возвратов; необычный день не обязательно ошибочен.',
        amounts: {
          'За этот день': daily(d),
          'Медиана сопоставимых дней': moneyStats[d.weekday]!.medianFloor,
        },
        evidence: dayEvidence(d),
        priority: 30,
      );
    }
    for (final d in countDays.take(3)) {
      final key = calendarDate(d), count = dailyCount(d);
      add(
        'H6',
        key,
        'Необычно много покупок: $key',
        '$count расходных записей против медианы ${countStats[d.weekday]!.medianFloor} за восемь сопоставимых дней недели. Это количество записей, а не товаров; одинаковые реальные покупки допустимы.',
        evidence: dayEvidence(d),
        priority: 25,
      );
    }
  }
  final recentStart = DateTime(f.end.year, f.end.month, f.end.day - 55);
  if (rangeCovered(recentStart, f.end)) {
    const labels = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];
    final amounts = <int, List<int>>{}, counts = <int, int>{};
    for (var n = 0; n < 56; n++) {
      final d = DateTime(
        recentStart.year,
        recentStart.month,
        recentStart.day + n,
      );
      amounts.putIfAbsent(d.weekday, () => []).add(daily(d));
      counts.update(d.weekday, (v) => v + 1, ifAbsent: () => 1);
    }
    final evidence = refs(
      expenses.where((e) => AnalysisFacts.within(e.date, recentStart, f.end)),
    );
    add(
      'N1',
      'weekdays',
      'Расходы по дням недели',
      '${calendarDate(recentStart)} — ${calendarDate(f.end)}. Средние исходные списания на один подтверждённый день, включая нулевые дни; округлены вниз. Разные дни недели наблюдались по восемь раз.',
      kind: InsightKind.fact,
      amounts: {
        for (var d = 1; d <= 7; d++)
          labels[d - 1]: sumMinor(amounts[d]!) ~/ counts[d]!,
      },
      evidence: evidence,
      priority: 0,
    );
    add(
      'N2',
      'weekends',
      'Выходные и будни',
      'За те же 56 подтверждённых дней: 16 выходных и 40 будней. Сравниваются средние списания на день, не общие суммы за разное число дней. Это описание, без оценки хорошо или плохо.',
      kind: InsightKind.fact,
      amounts: {
        'В среднем за выходной':
            sumMinor([...amounts[6]!, ...amounts[7]!]) ~/ 16,
        'В среднем за будний':
            sumMinor([for (var d = 1; d <= 5; d++) ...amounts[d]!]) ~/ 40,
      },
      evidence: evidence,
      priority: 0,
    );
  }
  final levelStart = DateTime(f.end.year, f.end.month, f.end.day - 83),
      split = DateTime(f.end.year, f.end.month, f.end.day - 27);
  if (rangeCovered(levelStart, f.end)) {
    final old = expenses
        .where(
          (e) => AnalysisFacts.within(
            e.date,
            levelStart,
            DateTime(split.year, split.month, split.day - 1),
          ),
        )
        .toList();
    final recent = expenses
        .where((e) => AnalysisFacts.within(e.date, split, f.end))
        .toList();
    final oldTotal = sumMinor(old.map((e) => e.amountMinor)),
        recentTotal = sumMinor(recent.map((e) => e.amountMinor));
    final difference2 =
        BigInt.from(recentTotal) * BigInt.two - BigInt.from(oldTotal);
    if (oldTotal > 0 &&
        difference2.abs() >=
            BigInt.from(policy.minimumChangeMinor) * BigInt.two &&
        difference2.abs() * BigInt.from(100) >=
            BigInt.from(oldTotal) * BigInt.from(policy.changePercent)) {
      var consistent = 0;
      for (var w = 0; w < 4; w++) {
        final begin = DateTime(split.year, split.month, split.day + w * 7),
            end = DateTime(split.year, split.month, split.day + w * 7 + 6);
        final weekly = sumMinor(
          recent
              .where((e) => AnalysisFacts.within(e.date, begin, end))
              .map((e) => e.amountMinor),
        );
        final sign =
            (BigInt.from(weekly) * BigInt.from(8) - BigInt.from(oldTotal)).sign;
        if (sign == difference2.sign) consistent++;
      }
      if (consistent >= 3) {
        add(
          'N6',
          'level',
          'Изменился привычный уровень расходов',
          'Последние четыре недели против предыдущих восьми, с нормализацией на одинаковые 28 дней. Не менее трёх последних недель изменились в ту же сторону. Списания до возвратов; причины не определяются.',
          amounts: {
            'Последние 28 дней': recentTotal,
            'Прежний уровень на 28 дней': oldTotal ~/ 2,
          },
          evidence: refs([...old, ...recent]),
          priority: 20,
        );
      }
    }
  }
  final latest = f.current
      ? DateTime(f.start.year, f.start.month - 1)
      : f.start;
  final months = [
    for (var n = 5; n >= 0; n--) DateTime(latest.year, latest.month - n),
  ];
  final rowsByMonth = <String, List<LedgerEntry>>{};
  for (final e in asOf) {
    rowsByMonth.putIfAbsent(monthKey(e.date), () => []).add(e);
  }
  bool complete(DateTime m) =>
      f.covered(policy, DateTime(m.year, m.month + 1, 0));
  final three = months.sublist(3);
  if (three.every(complete)) {
    final values = [
      for (final m in three)
        difference(
          AnalysisFacts.total(
            rowsByMonth[monthKey(m)] ?? [],
            EntryKind.expense,
          ),
          AnalysisFacts.total(rowsByMonth[monthKey(m)] ?? [], EntryKind.refund),
        ),
    ];
    final delta = BigInt.from(values.last) - BigInt.from(values.first);
    if (values.first >= 0 &&
        values[0] < values[1] &&
        values[1] < values[2] &&
        delta >= BigInt.from(policy.minimumChangeMinor) &&
        (values.first == 0 ||
            delta * BigInt.from(100) >=
                BigInt.from(values.first) *
                    BigInt.from(policy.changePercent))) {
      add(
        'B3',
        'trend',
        'Расходы росли три месяца подряд',
        '${three.map(monthKey).join(', ')}: чистые расходы строго увеличиваются. Наклон по трём равноотстоящим месяцам положительный; это наблюдение прошлого, не прогноз.',
        kind: InsightKind.fact,
        amounts: {for (var n = 0; n < 3; n++) monthKey(three[n]): values[n]},
        evidence: refs(
          three.expand((m) => rowsByMonth[monthKey(m)] ?? <LedgerEntry>[]),
        ),
        priority: 20,
      );
    }
  }
  if (months.every(complete)) {
    final income = [
      for (final m in months)
        AnalysisFacts.total(rowsByMonth[monthKey(m)] ?? [], EntryKind.income),
    ]..sort();
    final incomeStats = RobustStats(income);
    final center = incomeStats.medianFloor,
        iqr = difference(income[4], income[1]);
    if (iqr >= policy.minimumChangeMinor &&
        (incomeStats.center2 == BigInt.zero ||
            BigInt.from(iqr) * BigInt.from(200) >=
                incomeStats.center2 * BigInt.from(policy.changePercent))) {
      add(
        'E5',
        'income_variability',
        'Месячные доходы заметно различались',
        '${months.map(monthKey).join(', ')}. Шесть полных подтверждённых месяцев; разброс между квартилями. Метод квартилей: медианы нижней и верхней половин. Нулевые месяцы включены, возвраты исключены. Будущий доход не предсказывается.',
        kind: InsightKind.fact,
        amounts: {
          'Медиана дохода': center,
          'Нижний квартиль': income[1],
          'Верхний квартиль': income[4],
          'Межквартильный разброс': iqr,
        },
        evidence: refs(
          months
              .expand((m) => rowsByMonth[monthKey(m)] ?? <LedgerEntry>[])
              .where((e) => e.kind == EntryKind.income),
        ),
        priority: 15,
      );
    }
  }
  if (!f.current && f.covered(policy, f.end)) {
    final prior = [
      for (var n = 6; n >= 1; n--) DateTime(f.start.year, f.start.month - n),
    ];
    if (prior.every(complete)) {
      final values = [
        for (final m in prior)
          AnalysisFacts.total(
            rowsByMonth[monthKey(m)] ?? [],
            EntryKind.expense,
          ),
      ];
      final stats = RobustStats(values);
      if (stats.high(f.gross, minimumDifference: policy.minimumChangeMinor)) {
        add(
          'H3',
          'monthly',
          'Необычный месячный итог',
          'Списания до возвратов за завершённый месяц выше устойчивого ориентира шести предыдущих полных месяцев. Медиана/MAD — эвристика для проверки, не доказательство ошибки или вероятностный прогноз.',
          amounts: {
            'Списания выбранного месяца': f.gross,
            'Медиана шести предыдущих': stats.medianFloor,
          },
          evidence: refs([
            ...f.entries.where((e) => e.kind == EntryKind.expense),
            ...prior
                .expand((m) => rowsByMonth[monthKey(m)] ?? <LedgerEntry>[])
                .where((e) => e.kind == EntryKind.expense),
          ]),
          priority: 30,
        );
      }
    }
  }
  return result;
}

// Length-prefixed fields prevent accidental collisions from separators in notes.
String patternIdentity(List<String> fields) =>
    fields.map((s) => '${s.length}:$s').join();
