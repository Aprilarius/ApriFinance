import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/domain/insights/analysis_facts.dart';
import 'package:personal_finance/domain/insights/analysis_profile.dart';
import 'package:personal_finance/domain/insights/insight.dart';
import 'package:personal_finance/domain/insights/insight_engine.dart';
import 'package:personal_finance/domain/insights/series_review.dart';
import 'package:personal_finance/domain/insights/series_plan_link.dart';
import 'package:personal_finance/domain/insights/variable_forecast.dart';
import 'package:personal_finance/domain/models.dart';

final forecastToday = DateTime(2026, 11, 14),
    forecastStart = DateTime(2026, 7, 25);
LedgerSnapshot forecastFixture({
  int Function(int, DateTime)? amount,
  List<LedgerEntry>? entries,
  List<Obligation> plans = const [],
  List<Settlement> settlements = const [],
}) => LedgerSnapshot(
  currency: 'AZN',
  accounts: const [
    Account(id: 'a', name: 'Карта', kind: 'Карта', openingMinor: 5000000),
  ],
  entries:
      entries ??
      [
        for (var n = 0; n < 112; n++)
          LedgerEntry(
            id: 'day-$n',
            kind: EntryKind.expense,
            amountMinor:
                amount?.call(
                  n,
                  DateTime(
                    forecastStart.year,
                    forecastStart.month,
                    forecastStart.day + n,
                  ),
                ) ??
                (DateTime(
                          forecastStart.year,
                          forecastStart.month,
                          forecastStart.day + n,
                        ).weekday >=
                        6
                    ? 401
                    : 101),
            date: DateTime(
              forecastStart.year,
              forecastStart.month,
              forecastStart.day + n,
            ),
            accountId: 'a',
            category: n.isEven ? 'А' : 'Б',
          ),
      ],
  obligations: plans,
  settlements: settlements,
);
AnalysisPolicy forecastPolicy(LedgerSnapshot s, {AnalysisProfile? profile}) {
  final dates = [
    for (var m = 7; m <= 10; m++) DateTime(2026, m + 1, 0),
    forecastToday,
  ];
  return AnalysisPolicy(
    profile: profile ?? AnalysisProfile(trackingStart: DateTime(2026, 7, 1)),
    verifiedThrough: {for (final d in dates) monthKey(d): calendarDate(d)},
    verifiedHashes: {for (final d in dates) monthKey(d): coverageHash(s, d)},
  );
}

VariableForecast evaluateForecast(LedgerSnapshot s, AnalysisPolicy p) =>
    variableForecast(
      AnalysisFacts(s, DateTime(2026, 11), forecastToday, profile: p.profile),
      p,
    );
void main() {
  test('weekday median beats constant baseline on a stable weekly pattern', () {
    final s = forecastFixture(),
        result = evaluateForecast(s, forecastPolicy(s));
    expect(result.usable, isTrue);
    expect(result.method, ForecastMethod.weekdayMedian);
    expect(result.errors[ForecastMethod.weekdayMedian], 0);
    expect(result.errors[ForecastMethod.mean], greaterThan(0));
    final expected = sumMinor([
      for (var n = 1; n <= 30; n++)
        DateTime(
                  forecastToday.year,
                  forecastToday.month,
                  forecastToday.day + n,
                ).weekday >=
                6
            ? 401
            : 101,
    ]);
    expect(result.total(30), expected);
    expect(result.folds, hasLength(4));
    expect(
      result.folds.every(
        (f) =>
            f.actual.length == 14 &&
            f.predictions.values.every((v) => v.length == 14),
      ),
      isTrue,
    );
  });
  test('mean wins ties rather than choosing complexity without evidence', () {
    final s = forecastFixture(amount: (_, _) => 100),
        result = evaluateForecast(s, forecastPolicy(s));
    expect(result.method, ForecastMethod.mean);
    expect(result.total(30), 3000);
    expect(result.usable, isTrue);
  });
  test('smoothing is selected only when it really improves rolling MAE', () {
    final s = forecastFixture(amount: (n, _) => 100 + n * 5),
        result = evaluateForecast(s, forecastPolicy(s));
    expect(result.usable, isTrue);
    expect(result.method, ForecastMethod.smoothing);
    expect(
      result.errors[ForecastMethod.smoothing]!,
      lessThan(result.errors[ForecastMethod.mean]!),
    );
  });
  test('holdout shock cannot change its own training prediction', () {
    final s = forecastFixture(), a = evaluateForecast(s, forecastPolicy(s));
    final changed = s.entries
        .map(
          (e) => e.id == 'day-56'
              ? LedgerEntry.fromJson({...e.toJson(), 'amountMinor': 99999})
              : e,
        )
        .toList();
    final shocked = forecastFixture(entries: changed),
        b = evaluateForecast(shocked, forecastPolicy(shocked));
    expect(b.folds.first.predictions, a.folds.first.predictions);
    expect(b.folds.first.actual.first, 99999);
    expect(a.folds.first.origin, DateTime(2026, 9, 18));
  });
  test('future ledger values do not leak into training or evaluation', () {
    final s = forecastFixture(), a = evaluateForecast(s, forecastPolicy(s));
    final future = forecastFixture(
      entries: [
        ...s.entries,
        LedgerEntry(
          id: 'future',
          kind: EntryKind.expense,
          amountMinor: 1000000,
          date: DateTime(2026, 11, 20),
          accountId: 'a',
          category: 'А',
        ),
      ],
    );
    final b = evaluateForecast(future, forecastPolicy(future));
    expect(b.errors, a.errors);
    expect(b.method, a.method);
    expect(b.folds.first.predictions, a.folds.first.predictions);
    for (var n = 0; n < 90; n++) {
      expect(b.categoryDays[n]['б'], a.categoryDays[n]['б']);
      expect(b.categoryDays[n]['а'], n == 5 ? 0 : a.categoryDays[n]['а']);
    }
    final oneOff = EntryAnnotation(
      entryId: 'future',
      sourceHash: annotationHash(future.entries.last),
      reviewedOn: forecastToday,
      oneOff: true,
    );
    final tagged = evaluateForecast(
      future,
      forecastPolicy(
        future,
        profile: AnalysisProfile(
          trackingStart: DateTime(2026, 7, 1),
          annotations: {'future': oneOff},
        ),
      ),
    );
    expect(
      tagged.days.map((d) => d.balanceMinor),
      a.days.map((d) => d.balanceMinor),
    );
  });
  test('incomplete or edited history disables prediction instead of inventing zeros', () {
    final s = forecastFixture(),
        p = forecastPolicy(s),
        missing = {...p.verifiedThrough}..remove('2026-08');
    expect(
      evaluateForecast(s, p.copyWith(verifiedThrough: missing)).usable,
      isFalse,
    );
    final changed = forecastFixture(
      entries: s.entries
          .map(
            (e) => e.id == 'day-110'
                ? LedgerEntry.fromJson({
                    ...e.toJson(),
                    'amountMinor': e.amountMinor + 1,
                  })
                : e,
          )
          .toList(),
    );
    expect(evaluateForecast(changed, p).usable, isFalse);
    expect(evaluateForecast(s, AnalysisPolicy()).days, isEmpty);
  });
  test('volatile unforecastable spending fails quality gate and falls back to calendar', () {
    final all = forecastFixture(amount: (n, _) => n.isEven ? 10000 : 0),
        s = forecastFixture(
          entries: all.entries.where((e) => e.amountMinor > 0).toList(),
        );
    final p = forecastPolicy(s), result = evaluateForecast(s, p);
    expect(result.usable, isFalse);
    final cards = InsightEngine().analyze(
      s,
      DateTime(2026, 11),
      forecastToday,
      p,
    );
    expect(cards.where((i) => i.rule == 'I4'), isEmpty);
    expect(
      cards.singleWhere((i) => i.rule == 'I6').kind,
      InsightKind.insufficient,
    );
  });
  test('confirmed zero days are usable and do not divide by zero', () {
    final s = forecastFixture(entries: []),
        result = evaluateForecast(s, forecastPolicy(s));
    expect(result.usable, isTrue);
    expect(result.total(90), 0);
    expect(result.meanErrorMinor, 0);
  });
  test('category shares reconcile to every predicted minor unit', () {
    final s = forecastFixture(),
        result = evaluateForecast(s, forecastPolicy(s));
    for (var n = 0; n < 90; n++) {
      expect(
        sumMinor(result.categoryDays[n].values),
        result.days[n].balanceMinor,
      );
    }
    expect(() => result.categoryDays.first['а'] = 0, throwsUnsupportedError);
    expect(
      () => result.folds.first.predictions[ForecastMethod.mean]!.clear(),
      throwsUnsupportedError,
    );
  });
  test(
    'future-dated one-off annotation cannot improve historical backtest',
    () {
      final s = forecastFixture(),
          selected = s.entries[70],
          base = evaluateForecast(s, forecastPolicy(s));
      final future = AnalysisProfile(
        trackingStart: DateTime(2026, 7, 1),
        annotations: {
          selected.id: EntryAnnotation(
            entryId: selected.id,
            sourceHash: annotationHash(selected),
            reviewedOn: DateTime(2026, 12),
            oneOff: true,
          ),
        },
      );
      final result = evaluateForecast(s, forecastPolicy(s, profile: future));
      expect(result.errors, base.errors);
      expect(result.total(30), base.total(30));
    },
  );
  test('paid and explicitly linked planned expenses are excluded from final variable model', () {
    final base = forecastFixture(amount: (_, _) => 100),
        fixed = [
          for (var m = 8; m <= 11; m++)
            LedgerEntry(
              id: 'fixed-$m',
              kind: EntryKind.expense,
              amountMinor: 5000,
              date: DateTime(2026, m, 10),
              accountId: 'a',
              category: 'Планы',
              note: 'Интернет',
            ),
        ];
    final plan = Obligation(
      id: 'internet',
      name: 'Интернет',
      kind: EntryKind.expense,
      amountMinor: 5000,
      category: 'Планы',
      anchor: DateTime(2026, 8, 10),
      repeat: RepeatRule.monthly,
      accountId: 'a',
      nextIndex: 4,
    );
    final s = forecastFixture(
      entries: [...base.entries, ...fixed],
      plans: [plan],
      settlements: [
        for (var n = 0; n < 4; n++)
          Settlement(
            id: 'paid-$n',
            obligationId: plan.id,
            periodIndex: n,
            dueDate: fixed[n].date,
            entryId: fixed[n].id,
            skipped: false,
            version: 1,
          ),
      ],
    );
    final sources = fixed.take(3).toList(),
        proposal = SeriesProposal(
          key: seriesKey('AZN', sources.first),
          cadence: SeriesCadence.monthly,
          sourceHash: seriesSourceHash('AZN', sources),
          sourceIds: sources.map((e) => e.id),
        ),
        review = SeriesReview(
          proposal: proposal,
          decision: SeriesDecision.accepted,
          reviewedOn: DateTime(2026, 10, 11),
          planLink: SeriesPlanLink(
            planId: plan.id,
            planHash: planLinkHash(plan),
            linkedOn: DateTime(2026, 10, 11),
          ),
        );
    final result = evaluateForecast(
      s,
      forecastPolicy(s).copyWith(seriesReviews: {proposal.key: review}),
    );
    expect(result.usable, isTrue);
    expect(result.total(30), 3000);
    expect(result.evidence.any((e) => e.id.startsWith('fixed-')), isFalse);
    final paused = forecastFixture(
      entries: s.entries,
      plans: [
        Obligation.fromJson({...plan.toJson(), 'active': false}),
      ],
      settlements: s.settlements,
    );
    expect(
      evaluateForecast(
        paused,
        forecastPolicy(paused).copyWith(seriesReviews: {proposal.key: review}),
      ).total(30),
      3000,
    );
    final changed = forecastFixture(
      entries: s.entries,
      plans: [
        Obligation.fromJson({...plan.toJson(), 'amountMinor': 6000}),
      ],
      settlements: s.settlements,
    );
    expect(
      evaluateForecast(
        changed,
        forecastPolicy(changed).copyWith(seriesReviews: {proposal.key: review}),
      ).usable,
      isFalse,
    );
  });
  test(
    'MAE is rounded upward so nonzero error never becomes a zero-width range',
    () {
      final base = forecastFixture(amount: (_, _) => 100),
          changed = forecastFixture(
            entries: base.entries
                .map(
                  (e) => e.id == 'day-110'
                      ? LedgerEntry.fromJson({
                          ...e.toJson(),
                          'amountMinor': 101,
                        })
                      : e,
                )
                .toList(),
          );
      final result = evaluateForecast(changed, forecastPolicy(changed));
      expect(result.usable, isTrue);
      expect(result.meanErrorMinor, 1);
    },
  );
  test('declared tracking start cannot turn earlier unknown days into zero spending', () {
    final s = forecastFixture(),
        p = forecastPolicy(
          s,
          profile: AnalysisProfile(trackingStart: DateTime(2026, 9)),
        );
    expect(evaluateForecast(s, p).usable, isFalse);
  });
}
