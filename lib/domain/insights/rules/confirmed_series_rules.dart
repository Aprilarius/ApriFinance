import 'dart:convert';

import '../../models.dart';
import '../analysis_facts.dart';
import '../insight.dart';
import '../series_review.dart';
import '../statistics/robust_stats.dart';

List<Insight> confirmedSeriesInsights(AnalysisFacts f, AnalysisPolicy policy) {
  final s = f.snapshot, result = <Insight>[];
  final asOf = s.entries.where((e) => !e.date.isAfter(f.end)).toList();
  List<InsightEvidence> refs(Iterable<LedgerEntry> rows) =>
      rows.map((e) => InsightEvidence(EvidenceKind.entry, e.id)).toList();
  void sort(List<LedgerEntry> rows) => rows.sort((a, b) {
    final date = a.date.compareTo(b.date);
    return date != 0 ? date : a.id.compareTo(b.id);
  });
  String identity(LedgerEntry e) => jsonEncode([
    e.accountId,
    e.kind.name,
    categoryKey(e.category),
    categoryKey(e.note),
  ]);
  final confirmed = <SeriesReview, List<LedgerEntry>>{};
  for (final review in policy.seriesReviews.values) {
    if (review.decision == SeriesDecision.accepted &&
        review.validAt(s, f.end)) {
      confirmed[review] = review.proposal.sources(s)!;
    }
  }
  final wanted = confirmed.values.map((rows) => identity(rows.first)).toSet();
  final groups = <String, List<LedgerEntry>>{};
  for (final e in asOf.where(
    (e) =>
        (e.kind == EntryKind.income ||
            (e.kind == EntryKind.expense &&
                wanted.isNotEmpty &&
                wanted.contains(identity(e)))) &&
        categoryKey(e.note).length >= 3,
  )) {
    groups.putIfAbsent(identity(e), () => []).add(e);
  }
  for (final rows in groups.values) {
    sort(rows);
  }
  final keys = groups.keys.toList()..sort();
  var incomeCandidates = 0;
  for (final key in keys) {
    final rows = groups[key]!;
    if (rows.first.kind != EntryKind.income ||
        !rows.any((e) => AnalysisFacts.within(e.date, f.start, f.end))) {
      continue;
    }
    final reviewKey = seriesKey(s.currency!, rows.first);
    final review = policy.seriesReviews[reviewKey];
    if (review != null && review.validAt(s, f.end)) continue;
    for (final (cadence, needed) in [
      (SeriesCadence.monthly, 3),
      (SeriesCadence.weekly, 4),
      (SeriesCadence.yearly, 3),
    ]) {
      if (rows.length < needed) continue;
      final tail = rows.sublist(rows.length - needed);
      if (!List.generate(
        tail.length - 1,
        (n) => followsCadence(tail[n].date, tail[n + 1].date, cadence),
      ).every((v) => v)) {
        continue;
      }
      result.add(
        Insight(
          rule: 'E3',
          entity: reviewKey,
          period: f.period,
          title: 'Похоже на регулярное поступление',
          explanation:
              '${tail.length} поступлений с одинаковыми счётом, категорией и непустым комментарием, с близкими интервалами. Подтвердите, относятся ли они к одному источнику. Будущий доход не считается полученным и не прогнозируется.',
          group: InsightGroup.patterns,
          kind: InsightKind.check,
          amounts: {
            'Медиана поступления': RobustStats(tail.map((e) => e.amountMinor))
                .medianFloor,
          },
          evidence: refs(tail),
          seriesProposal: SeriesProposal(
            key: reviewKey,
            cadence: cadence,
            sourceHash: seriesSourceHash(s.currency!, tail),
            sourceIds: tail.map((e) => e.id),
          ),
        ),
      );
      incomeCandidates++;
      break;
    }
    if (incomeCandidates >= 10) break;
  }
  final reviews = confirmed.keys.toList()
    ..sort((a, b) => a.proposal.key.compareTo(b.proposal.key));
  for (final review in reviews) {
    final sources = confirmed[review]!;
    final rows = groups[identity(sources.first)] ?? [];
    if (rows.length < 3 ||
        !AnalysisFacts.within(rows.last.date, f.start, f.end)) {
      continue;
    }
    final last = rows.last;
    if (last.kind == EntryKind.income) {
      final intervals = [
        for (var n = 1; n < rows.length; n++)
          calendarDaysBetween(rows[n - 1].date, rows[n].date),
      ]..sort();
      result.add(
        Insight(
          rule: 'E3',
          entity: review.proposal.key,
          period: f.period,
          title: 'Интервалы подтверждённого дохода',
          explanation:
              'Вы подтвердили связь операций ${calendarDate(review.reviewedOn)}. Внесено ${rows.length} поступлений; медиана интервала ${RobustStats(intervals).medianFloor} дн., минимум ${intervals.first}, максимум ${intervals.last}. Разброс описывает записи, а не гарантирует срок следующего дохода. При пропусках учёта интервалы могут быть завышены.',
          group: InsightGroup.patterns,
          amounts: {
            'Медиана поступления': RobustStats(rows.map((e) => e.amountMinor))
                .medianFloor,
          },
          evidence: refs(rows),
        ),
      );
      continue;
    }
    if (rows.length < 4 || review.proposal.sourceIds.contains(last.id)) {
      continue;
    }
    final tail = rows.sublist(rows.length - 4);
    if (!List.generate(
      3,
      (n) => followsCadence(
        tail[n].date,
        tail[n + 1].date,
        review.proposal.cadence,
      ),
    ).every((v) => v)) {
      continue;
    }
    final previous = tail.take(3).toList(),
        stats = RobustStats(tail.take(3).map((e) => e.amountMinor));
    final value2 = BigInt.from(last.amountMinor) * BigInt.two,
        delta2 = value2 - stats.center2;
    if (delta2.abs() < BigInt.from(policy.minimumChangeMinor) * BigInt.two) {
      continue;
    }
    final evidence = refs([...sources, ...previous, last]);
    if (delta2.abs() * BigInt.from(100) >=
        stats.center2 * BigInt.from(policy.changePercent)) {
      result.add(
        Insight(
          rule: 'G4',
          entity: review.proposal.key,
          period: f.period,
          title: delta2.isNegative
              ? 'Стоимость серии уменьшилась'
              : 'Стоимость серии выросла',
          explanation: 'Подтверждённая вами серия: последняя новая операция против медианы трёх предыдущих. Интервалы соответствуют подтверждённому повторению. Это изменение записанной суммы, без утверждения об изменении тарифа. Возвраты не включены; показанная медиана округлена вниз.',
          group: InsightGroup.patterns,
          kind: InsightKind.check,
          priority: 25,
          amounts: {
            'Последняя сумма': last.amountMinor,
            'Медиана трёх предыдущих': stats.medianFloor,
          },
          evidence: evidence,
        ),
      );
    }
    final factor = [10, 100]
        .where(
          (n) =>
              value2 == stats.center2 * BigInt.from(n) ||
              value2 * BigInt.from(n) == stats.center2,
        )
        .firstOrNull;
    if (factor != null) {
      result.add(
        Insight(
          rule: 'H5',
          entity: review.proposal.key,
          period: f.period,
          title: 'Проверьте десятичный разряд суммы',
          explanation:
              'В подтверждённой серии последняя сумма отличается от медианы трёх предыдущих ровно в $factor раз. Это может быть реальная покупка или другой объём услуги. Исправление не выполняется автоматически.',
          group: InsightGroup.quality,
          kind: InsightKind.check,
          priority: 40,
          amounts: {
            'Последняя сумма': last.amountMinor,
            'Медиана трёх предыдущих': stats.medianFloor,
          },
          evidence: evidence,
        ),
      );
    }
  }
  return result;
}
