import '../models.dart';
import 'analysis_facts.dart';
import 'insight.dart';
import 'series_plan_link.dart';
import 'series_review.dart';

enum ForecastMethod { mean, weekdayMedian, smoothing }

String forecastMethodLabel(ForecastMethod method) => switch (method) {
  ForecastMethod.mean => 'Среднее за 28 дней',
  ForecastMethod.weekdayMedian => 'Медиана по дням недели',
  ForecastMethod.smoothing => 'Сглаживание с весом 1/4',
};

class VariableForecast {
  VariableForecast({
    required this.usable,
    required this.reason,
    required this.method,
    required Map<ForecastMethod, int> errors,
    required this.meanErrorMinor,
    required List<InsightDay> days,
    required List<Map<String, int>> categoryDays,
    required List<InsightEvidence> evidence,
    List<ForecastFold> folds = const [],
  }) : errors = Map.unmodifiable(errors),
       days = List.unmodifiable(days),
       categoryDays = List.unmodifiable(
         categoryDays.map((e) => Map<String, int>.unmodifiable(e)),
       ),
       evidence = List.unmodifiable(evidence),
       folds = List.unmodifiable(folds);
  final bool usable;
  final String reason;
  final ForecastMethod method;
  final Map<ForecastMethod, int> errors;
  final int meanErrorMinor;
  final List<InsightDay> days;
  final List<Map<String, int>> categoryDays;
  final List<InsightEvidence> evidence;
  final List<ForecastFold> folds;
  int total(int daysCount) =>
      sumMinor(days.take(daysCount).map((d) => d.balanceMinor));
}

class ForecastFold {
  ForecastFold(
    this.origin,
    Map<ForecastMethod, List<int>> predictions,
    List<int> actual,
  ) : predictions = Map.unmodifiable(
        predictions.map(
          (key, values) => MapEntry(key, List<int>.unmodifiable(values)),
        ),
      ),
      actual = List.unmodifiable(actual);
  final DateTime origin;
  final Map<ForecastMethod, List<int>> predictions;
  final List<int> actual;
}

int _median(List<int> values) {
  final sorted = values.toList()..sort();
  return sorted.length.isOdd
      ? sorted[sorted.length ~/ 2]
      : checked(
          (BigInt.from(sorted[sorted.length ~/ 2 - 1]) +
                  BigInt.from(sorted[sorted.length ~/ 2])) ~/
              BigInt.two,
        );
}

VariableForecast variableForecast(AnalysisFacts f, AnalysisPolicy policy) {
  VariableForecast unavailable(String reason) => VariableForecast(
    usable: false,
    reason: reason,
    method: ForecastMethod.mean,
    errors: const {},
    meanErrorMinor: 0,
    days: const [],
    categoryDays: const [],
    evidence: const [],
  );
  if (!f.current) {
    return unavailable('Прогноз доступен только от сегодняшней даты.');
  }
  final through = DateTime(f.today.year, f.today.month, f.today.day - 1),
      from = DateTime(f.today.year, f.today.month, f.today.day - 112);
  if (!f.coveredRange(policy, from, through)) {
    return unavailable(
      'Нужны 112 последовательных подтверждённых дней до сегодня для обучения и четырёх проверочных окон.',
    );
  }
  final s = f.snapshot;
  if (policy.seriesReviews.values.any(
    (r) =>
        r.decision == SeriesDecision.accepted &&
        r.planLink != null &&
        linkedSeriesPlan(s, r, f.today, allowInactive: true) == null,
  )) {
    return unavailable(
      'Проверьте изменившиеся связи серий с планами. Без актуальной связи нельзя надёжно отделить фиксированные оплаты от переменных трат.',
    );
  }
  final rows = s.entries
      .where(
        (e) =>
            e.kind == EntryKind.expense &&
            AnalysisFacts.within(e.date, from, through),
      )
      .toList();
  final paid = s.settlements
      .where((p) => !p.skipped && p.entryId != null)
      .map((p) => p.entryId!)
      .toSet();
  final identityByEntry = <String, String>{};
  String identity(LedgerEntry e) => identityByEntry.putIfAbsent(
    seriesRawKey(s.currency!, e),
    () => seriesKey(s.currency!, e),
  );
  List<LedgerEntry> variableRows(DateTime origin) {
    final fixed = <String>{};
    for (final review in policy.seriesReviews.values) {
      if (linkedSeriesPlan(s, review, origin, allowInactive: true) != null) {
        fixed.add(review.proposal.key);
      }
    }
    return rows
        .where(
          (e) =>
              !(paid.contains(e.id) && !e.date.isAfter(origin)) &&
              !(f.profile.annotation(e, knownThrough: origin)?.oneOff ??
                  false) &&
              (fixed.isEmpty || !fixed.contains(identity(e))),
        )
        .toList();
  }

  List<int> history(List<LedgerEntry> eligible, DateTime start, int length) {
    final values = List<BigInt>.filled(length, BigInt.zero);
    for (final e in eligible) {
      final offset = calendarDaysBetween(start, e.date);
      if (offset >= 0 && offset < length) {
        values[offset] += BigInt.from(e.amountMinor);
      }
    }
    return values.map(checked).toList();
  }

  List<int> predict(
    List<int> training,
    DateTime start,
    int length,
    ForecastMethod method,
  ) {
    final mean = sumMinor(training.skip(training.length - 28)) ~/ 28;
    if (method == ForecastMethod.mean) return List.filled(length, mean);
    if (method == ForecastMethod.smoothing) {
      var value = BigInt.from(training.first);
      for (final day in training.skip(1)) {
        value = (value * BigInt.from(3) + BigInt.from(day)) ~/ BigInt.from(4);
      }
      return List.filled(length, checked(value));
    }
    final weekdays = <int, List<int>>{};
    for (var n = 0; n < training.length; n++) {
      weekdays
          .putIfAbsent(
            DateTime(start.year, start.month, start.day + n).weekday,
            () => [],
          )
          .add(training[n]);
    }
    return [
      for (var n = 0; n < length; n++)
        _median(
          weekdays[DateTime(
            start.year,
            start.month,
            start.day + training.length + n,
          ).weekday]!,
        ),
    ];
  }

  final totals = {
    for (final method in ForecastMethod.values) method: BigInt.zero,
  };
  var actualTotal = BigInt.zero;
  final folds = <ForecastFold>[];
  for (var fold = 0; fold < 4; fold++) {
    final trainStart = DateTime(from.year, from.month, from.day + fold * 14),
        origin = DateTime(
          trainStart.year,
          trainStart.month,
          trainStart.day + 55,
        );
    final values = history(variableRows(origin), trainStart, 70),
        training = values.take(56).toList(),
        actual = values.skip(56).toList();
    actualTotal += actual.fold(BigInt.zero, (a, b) => a + BigInt.from(b));
    final predictions = <ForecastMethod, List<int>>{};
    for (final method in ForecastMethod.values) {
      final prediction = predict(training, trainStart, 14, method);
      predictions[method] = prediction;
      for (var n = 0; n < 14; n++) {
        totals[method] =
            totals[method]! +
            (BigInt.from(prediction[n]) - BigInt.from(actual[n])).abs();
      }
    }
    folds.add(ForecastFold(origin, predictions, actual));
  }
  var best = ForecastMethod.mean;
  for (final method in [
    ForecastMethod.weekdayMedian,
    ForecastMethod.smoothing,
  ]) {
    if (totals[method]! < totals[best]! &&
        totals[method]! * BigInt.from(100) <=
            totals[ForecastMethod.mean]! * BigInt.from(95)) {
      best = method;
    }
  }
  final errors = {
    for (final e in totals.entries)
      e.key: checked((e.value + BigInt.from(55)) ~/ BigInt.from(56)),
  };
  final usable = actualTotal == BigInt.zero
      ? totals[best] == BigInt.zero
      : totals[best]! * BigInt.from(100) <= actualTotal * BigInt.from(75);
  final eligible = variableRows(f.today),
      trainStart = DateTime(f.today.year, f.today.month, f.today.day - 56);
  final training = history(eligible, trainStart, 56),
      predicted = predict(training, trainStart, 91, best).skip(1).toList();
  final categories = <String, BigInt>{};
  for (final e in eligible.where((e) => !e.date.isBefore(trainStart))) {
    final key = f.canonicalCategory(e.category);
    categories[key] =
        (categories[key] ?? BigInt.zero) + BigInt.from(e.amountMinor);
  }
  final categoryTotal = categories.values.fold(BigInt.zero, (a, b) => a + b),
      keys = categories.keys.toList()..sort();
  Map<String, int> allocate(int total) {
    if (categoryTotal == BigInt.zero) return {};
    final values = {
      for (final key in keys)
        key: checked(BigInt.from(total) * categories[key]! ~/ categoryTotal),
    };
    var remainder = total - sumMinor(values.values);
    final ranked = keys.toList()
      ..sort((a, b) {
        final x = (BigInt.from(total) * categories[b]!) % categoryTotal,
            y = (BigInt.from(total) * categories[a]!) % categoryTotal;
        final c = x.compareTo(y);
        return c != 0 ? c : a.compareTo(b);
      });
    for (final key in ranked) {
      if (remainder-- <= 0) break;
      values[key] = values[key]! + 1;
    }
    return values;
  }

  final allocatedDays = predicted.map(allocate).toList();
  final fixedNow = policy.seriesReviews.values
      .where(
        (r) => linkedSeriesPlan(s, r, f.today, allowInactive: true) != null,
      )
      .map((r) => r.proposal.key)
      .toSet();
  for (final e in s.entries.where(
    (e) => e.kind == EntryKind.expense && e.date.isAfter(f.today),
  )) {
    final index = calendarDaysBetween(f.today, e.date) - 1;
    if (index < 0 ||
        index >= 90 ||
        paid.contains(e.id) ||
        (f.profile.annotation(e, knownThrough: f.today)?.oneOff ?? false) ||
        (fixedNow.isNotEmpty && fixedNow.contains(identity(e)))) {
      continue;
    }
    final category = f.canonicalCategory(e.category),
        expected = allocatedDays[index][category] ?? 0;
    allocatedDays[index][category] = expected > e.amountMinor
        ? expected - e.amountMinor
        : 0;
  }
  return VariableForecast(
    folds: folds,
    usable: usable,
    reason: usable
        ? 'Четыре rolling-окна по 14 дней, обучение по 56 прошлым дням. Порог средней ошибки — не более 75% среднего факта; это продуктовое ограничение.'
        : 'На проверочных окнах ошибка слишком велика; переменный прогноз не включён.',
    method: best,
    errors: errors,
    meanErrorMinor: errors[best]!,
    days: [
      for (var n = 0; n < 90; n++)
        InsightDay(
          DateTime(f.today.year, f.today.month, f.today.day + n + 1),
          sumMinor(allocatedDays[n].values),
        ),
    ],
    categoryDays: allocatedDays,
    evidence: eligible
        .map((e) => InsightEvidence(EvidenceKind.entry, e.id))
        .toList(),
  );
}
