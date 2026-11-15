import '../../models.dart';
import '../analysis_facts.dart';
import '../insight.dart';
import '../series_review.dart';
import '../statistics/robust_stats.dart';

int labelDistance(String a, String b) {
  var previous = List.generate(b.length + 1, (n) => n);
  for (var i = 0; i < a.length; i++) {
    final current = <int>[i + 1];
    for (var j = 0; j < b.length; j++) {
      final substitution = previous[j] + (a[i] == b[j] ? 0 : 1),
          insertion = current[j] + 1,
          deletion = previous[j + 1] + 1;
      current.add(
        [substitution, insertion, deletion].reduce((x, y) => x < y ? x : y),
      );
    }
    previous = current;
  }
  return previous.last;
}

List<Insight> historyInsights(AnalysisFacts f, AnalysisPolicy policy) {
  final result = <Insight>[], s = f.snapshot, p = f.profile;
  void emit(
    String rule,
    String entity,
    String title,
    String explanation, {
    Map<String, int> amounts = const {},
    Iterable<InsightEvidence> evidence = const [],
    InsightKind kind = InsightKind.fact,
    InsightGroup group = InsightGroup.patterns,
  }) => result.add(
    Insight(
      rule: rule,
      entity: entity,
      period: f.period,
      title: title,
      explanation: explanation,
      amounts: amounts,
      evidence: evidence,
      kind: kind,
      group: group,
    ),
  );
  final usedEntries = s.purchases
      .map((r) => r.entryId)
      .whereType<String>()
      .toSet();
  for (final purchase in s.purchases.where(
    (r) => !r.archived && r.entryId == null && !r.date.isAfter(f.end),
  )) {
    final candidates =
        s.entries
            .where(
              (e) =>
                  e.kind == EntryKind.expense &&
                  !e.date.isAfter(f.end) &&
                  !usedEntries.contains(e.id) &&
                  e.amountMinor == purchase.amountMinor &&
                  calendarDaysBetween(e.date, purchase.date).abs() <= 3,
            )
            .toList()
          ..sort((a, b) {
            final x = calendarDaysBetween(
              a.date,
              purchase.date,
            ).abs().compareTo(calendarDaysBetween(b.date, purchase.date).abs());
            return x != 0 ? x : a.id.compareTo(b.id);
          });
    if (candidates.isNotEmpty) {
      emit(
        'L5',
        purchase.id,
        'Покупка может относиться к расходу: ${purchase.name}',
        'Есть расходы с той же суммой и датой в пределах трёх дней. Откройте карточку покупки и вручную выберите исходный расход. Совпадение не доказывает связь; новый расход автоматически не создаётся.',
        amounts: {'Стоимость покупки': purchase.amountMinor},
        evidence: [
          InsightEvidence(EvidenceKind.purchase, purchase.id),
          for (final e in candidates.take(3))
            InsightEvidence(EvidenceKind.entry, e.id),
        ],
        kind: InsightKind.check,
        group: InsightGroup.quality,
      );
    }
  }
  final categories =
      s.entries
          .where((e) => !e.date.isAfter(f.end))
          .map((e) => categoryKey(e.category))
          .toSet()
          .toList()
        ..sort();
  final sellers =
      p.annotations.values
          .where((t) {
            final e = f.entryById[t.entryId];
            return e != null &&
                !e.date.isAfter(f.end) &&
                t.valid(e) &&
                t.counterparty.isNotEmpty;
          })
          .map((t) => categoryKey(t.counterparty))
          .toSet()
          .toList()
        ..sort();
  for (final (labels, resolve, kind) in [
    (categories.take(200).toList(), p.category, 'category'),
    (sellers.take(200).toList(), p.counterparty, 'seller'),
  ]) {
    var shown = 0;
    for (var a = 0; a < labels.length && shown < 10; a++) {
      for (var b = a + 1; b < labels.length && shown < 10; b++) {
        final x = labels[a],
            y = labels[b],
            length = x.length > y.length ? x.length : y.length;
        if (x.length < 5 ||
            y.length < 5 ||
            (x.length - y.length).abs() > 2 ||
            resolve(x) == resolve(y)) {
          continue;
        }
        final distance = labelDistance(x, y);
        if (distance <= 2 && distance * 5 <= length) {
          emit(
            'M5',
            seriesDigest([kind, x, y]),
            'Проверьте похожие названия',
            '«$x» и «$y» отличаются на $distance символов. Это могут быть разные сущности. При необходимости добавьте подтверждённый алиас в данных анализа; оригинальные записи не меняются.',
            evidence: [
              InsightEvidence(
                EvidenceKind.profile,
                kind == 'category' ? 'categoryAliases' : 'counterpartyAliases',
              ),
            ],
            kind: InsightKind.check,
            group: InsightGroup.quality,
          );
          shown++;
        }
      }
    }
  }
  for (final tracked in p.tracked) {
    if (!f.start.isAfter(tracked.baselineMonth)) continue;
    final end = DateTime(
          tracked.baselineMonth.year,
          tracked.baselineMonth.month + 1,
          0,
        ),
        category = p.category(tracked.category);
    final rows = s.entries
            .where(
              (e) => AnalysisFacts.within(e.date, tracked.baselineMonth, end),
            )
            .toList(),
        base =
            f.categoryTotals(
              s.entries.where(
                (e) => AnalysisFacts.within(e.date, tracked.baselineMonth, end),
              ),
            )[category] ??
            0;
    final valid =
        coverageHash(s, end) == tracked.baselineHash &&
        base == tracked.baselineMinor &&
        f.covered(policy, end);
    final evidence = [
      InsightEvidence(EvidenceKind.profile, 'tracked:${tracked.id}'),
      for (final e in [
        ...rows,
        ...f.entries,
      ].where((e) => p.category(e.category) == category))
        InsightEvidence(EvidenceKind.entry, e.id),
    ];
    if (!valid || f.current || !f.covered(policy, f.end)) {
      emit(
        'O4',
        tracked.id,
        'Для проверки рекомендации нужен полный период',
        valid
            ? 'Следующий месяц должен завершиться, а полнота его учёта — быть подтверждена. Частичный месяц не сравнивается с полной базой.'
            : 'Базовые записи, алиасы или подтверждение полноты изменились. Удалите устаревшее отслеживание и выберите рекомендацию заново.',
        evidence: evidence,
        kind: InsightKind.insufficient,
        group: InsightGroup.summaries,
      );
      continue;
    }
    final actual = f.categories[category] ?? 0;
    emit(
      'O4',
      tracked.id,
      'Результат выбранной рекомендации: $category',
      'База ${monthKey(tracked.baselineMonth)}, полный последующий период ${monthKey(f.start)}. ${actual <= tracked.targetMinor ? 'Выбранный денежный ориентир достигнут.' : 'Расходы выше выбранного ориентира.'} Это сравнение сумм, без утверждения, что изменение вызвано рекомендацией.',
      amounts: {
        'База': tracked.baselineMinor,
        'Выбранный ориентир': tracked.targetMinor,
        'Факт полного месяца': actual,
        'Изменение к базе': difference(actual, tracked.baselineMinor),
      },
      evidence: evidence,
      group: InsightGroup.summaries,
    );
  }
  final annual = policy.seriesReviews.values.where(
    (r) =>
        r.decision == SeriesDecision.accepted &&
        r.proposal.cadence == SeriesCadence.yearly &&
        r.validAt(s, f.end),
  );
  if (f.current) {
    for (final review in annual) {
      final sources = review.proposal.sources(s)!;
      if (sources.first.kind != EntryKind.expense) continue;
      final amount = RobustStats(sources.map((e) => e.amountMinor)).medianFloor;
      if (amount < policy.minimumChangeMinor) continue;
      final last = sources.last.date,
          year = last.year + 1,
          day = last.day.clamp(1, DateTime(year, last.month + 1, 0).day),
          next = DateTime(year, last.month, day);
      if (!next.isAfter(f.today)) continue;
      final months =
              (next.year - f.today.year) * 12 +
              next.month -
              f.today.month +
              (next.day >= f.today.day ? 1 : 0),
          count = months < 1 ? 1 : months;
      emit(
        'N5',
        review.proposal.key,
        'Крупный годовой расход: ${sources.first.note}',
        'Подтверждённая годовая серия; следующий годовой ориентир ${calendarDate(next)}. Если сумма повторится, до него можно распределить резерв на $count ежемесячных пополнений. Это сценарий, не установленная дата счёта или обещание цены.',
        amounts: {
          'Типичная сумма': amount,
          'На одно пополнение': checked(
            (BigInt.from(amount) + BigInt.from(count - 1)) ~/
                BigInt.from(count),
          ),
        },
        evidence: sources.map((e) => InsightEvidence(EvidenceKind.entry, e.id)),
        kind: InsightKind.scenario,
      );
    }
  }
  final incomes = policy.seriesReviews.values.where(
    (r) => r.decision == SeriesDecision.accepted && r.validAt(s, f.end),
  );
  for (final review in incomes) {
    final sources = review.proposal.sources(s)!;
    if (sources.first.kind != EntryKind.income) continue;
    final dates =
        s.entries
            .where(
              (e) =>
                  e.kind == EntryKind.income &&
                  !e.date.isAfter(f.end) &&
                  seriesKey(s.currency!, e) == review.proposal.key,
            )
            .map((e) => e.date)
            .toSet()
            .toList()
          ..sort();
    final before = <LedgerEntry>[], after = <LedgerEntry>[];
    var windows = 0;
    DateTime? previous;
    for (final date in dates) {
      final start = DateTime(date.year, date.month, date.day - 7),
          end = DateTime(date.year, date.month, date.day + 7);
      if (end.isAfter(f.end) ||
          (previous != null && calendarDaysBetween(previous, date) < 15) ||
          !f.coveredRange(policy, start, end)) {
        continue;
      }
      before.addAll(
        s.entries.where(
          (e) =>
              e.kind == EntryKind.expense &&
              !e.date.isBefore(start) &&
              e.date.isBefore(date),
        ),
      );
      after.addAll(
        s.entries.where(
          (e) =>
              e.kind == EntryKind.expense &&
              e.date.isAfter(date) &&
              !e.date.isAfter(end),
        ),
      );
      previous = date;
      windows++;
    }
    if (windows >= 3) {
      emit(
        'N3',
        review.proposal.key,
        'Расходы вокруг регулярного дохода',
        '$windows непересекающихся наблюдений: по семь подтверждённых дней до и после поступления, без самого дня дохода. Показаны одинаковые по длительности окна; связи с причиной расходов это не доказывает.',
        amounts: {
          'За окна до поступления': sumMinor(before.map((e) => e.amountMinor)),
          'За окна после поступления': sumMinor(
            after.map((e) => e.amountMinor),
          ),
        },
        evidence: [
          ...sources,
          ...before,
          ...after,
        ].map((e) => InsightEvidence(EvidenceKind.entry, e.id)),
      );
    }
  }
  final latest = f.current
          ? DateTime(f.start.year, f.start.month - 1)
          : f.start,
      months = [
        for (var n = 23; n >= 0; n--) DateTime(latest.year, latest.month - n),
      ];
  if (months.every(
    (m) => f.covered(policy, DateTime(m.year, m.month + 1, 0)),
  )) {
    final eligible = s.entries
        .where(
          (e) =>
              e.kind == EntryKind.expense &&
              AnalysisFacts.within(
                e.date,
                months.first,
                DateTime(latest.year, latest.month + 1, 0),
              ) &&
              !(p.annotation(e)?.oneOff ?? false),
        )
        .toList();
    final totals = {for (final m in months) monthKey(m): <int>[]};
    for (final e in eligible) {
      totals[monthKey(e.date)]!.add(e.amountMinor);
    }
    final values = [for (final m in months) sumMinor(totals[monthKey(m)]!)],
        firstYear = sumMinor([for (var n = 0; n < 12; n++) values[n]]),
        secondYear = sumMinor([for (var n = 12; n < 24; n++) values[n]]);
    var count = 0;
    for (var n = 0; n < 12 && count < 3; n++) {
      bool peak(int value, int yearTotal) =>
          yearTotal > 0 &&
          BigInt.from(value) * BigInt.from(1200) >=
              BigInt.from(yearTotal) *
                  BigInt.from(100 + policy.changePercent) &&
          BigInt.from(value) * BigInt.from(12) - BigInt.from(yearTotal) >=
              BigInt.from(policy.minimumChangeMinor) * BigInt.from(12);
      if (peak(values[n], firstYear) && peak(values[n + 12], secondYear)) {
        emit(
          'N4',
          '${months[n].month}',
          'Повторяющийся сезонный месяц: ${months[n].month}',
          '24 полных подтверждённых месяца, по два наблюдения каждого календарного месяца. В обеих годовых группах этот месяц выше собственного среднего года на выбранный порог. Помеченные разовые расходы исключены. Два повтора — описательный сигнал, не надёжный сезонный прогноз.',
          amounts: {
            monthKey(months[n]): values[n],
            monthKey(months[n + 12]): values[n + 12],
          },
          evidence: eligible
              .where((e) => e.date.month == months[n].month)
              .map((e) => InsightEvidence(EvidenceKind.entry, e.id)),
        );
        count++;
      }
    }
  }
  return result;
}
