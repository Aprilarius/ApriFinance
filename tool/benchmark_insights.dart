import 'dart:convert';
import 'dart:io';

import 'package:personal_finance/domain/insights/insight.dart';
import 'package:personal_finance/domain/insights/analysis_profile.dart';
import 'package:personal_finance/domain/insights/insight_engine.dart';
import 'package:personal_finance/domain/insights/series_review.dart';
import 'package:personal_finance/domain/insights/series_plan_link.dart';
import 'package:personal_finance/domain/models.dart';

void main() {
  final rows = <Map<String, Object>>[];
  for (final (scenario, count) in [
    for (final n in [1000, 10000, 100000]) ('two_months', n),
    for (final n in [1000, 10000, 100000]) ('verified_history', n),
    for (final n in [1000, 10000, 100000]) ('calendar_and_link', n),
    for (final n in [1000, 10000, 100000]) ('full_profile_24_months', n),
  ]) {
    final full = scenario == 'full_profile_24_months';
    final historical = scenario == 'verified_history';
    final calendar = scenario == 'calendar_and_link';
    final sources = [
      for (var m = 9; m <= 11; m++)
        LedgerEntry(
          id: 'series-$m',
          kind: EntryKind.expense,
          amountMinor: 10000,
          date: DateTime(2026, m, 12),
          accountId: 'a',
          category: 'Сервис',
          note: 'Интернет',
        ),
    ];
    final plan = Obligation(
      id: 'linked',
      name: 'Интернет',
      kind: EntryKind.expense,
      amountMinor: 10000,
      category: 'Сервис',
      anchor: DateTime(2026, 12, 12),
      repeat: RepeatRule.monthly,
      accountId: 'a',
    );
    final snapshot = LedgerSnapshot(
      currency: 'AZN',
      accounts: const [
        Account(id: 'a', name: 'Synthetic', kind: 'Карта', openingMinor: 0),
      ],
      entries: [
        ...List.generate(
          count - (calendar ? 3 : 0),
          (n) => LedgerEntry(
            id: 'synthetic-$n',
            kind: n % 10 == 0 ? EntryKind.income : EntryKind.expense,
            amountMinor: 100 + n % 10000,
            date: full
                ? DateTime(2024, 11, 1 + n % 743)
                : calendar && n % 20 == 0
                ? DateTime(2026, 11, 15 + n % 90)
                : historical
                ? DateTime(2026, 5, 1 + n % 198)
                : DateTime(2026, n % 2 == 0 ? 10 : 11, 1 + n % 14),
            accountId: 'a',
            category: 'Category ${n % 64}',
          ),
        ),
        if (calendar) ...sources,
      ],
      obligations: calendar
          ? [
              plan,
              for (var n = 0; n < 99; n++)
                Obligation(
                  id: 'plan-$n',
                  name: 'Synthetic plan $n',
                  kind: n % 4 == 0 ? EntryKind.income : EntryKind.expense,
                  amountMinor: 1000 + n,
                  category: 'Планы',
                  anchor: DateTime(2026, 11, 15 + n % 90),
                  repeat: RepeatRule.once,
                  accountId: n.isEven ? 'a' : null,
                ),
            ]
          : [],
    );
    final verifiedDates = full
        ? [
            for (var m = 0; m < 24; m++) DateTime(2024, 12 + m, 0),
            DateTime(2026, 11, 14),
          ]
        : historical
        ? [
            for (var m = 5; m <= 10; m++) DateTime(2026, m + 1, 0),
            DateTime(2026, 11, 14),
          ]
        : [DateTime(2026, 10, 14), DateTime(2026, 11, 14)];
    final review = SeriesReview(
      proposal: SeriesProposal(
        key: seriesKey('AZN', sources.first),
        cadence: SeriesCadence.monthly,
        sourceHash: seriesSourceHash('AZN', sources),
        sourceIds: sources.map((e) => e.id),
      ),
      decision: SeriesDecision.accepted,
      reviewedOn: DateTime(2026, 11, 14),
      planLink: SeriesPlanLink(
        planId: plan.id,
        planHash: planLinkHash(plan),
        linkedOn: DateTime(2026, 11, 14),
      ),
    );
    final policy = AnalysisPolicy(
      profile: full
          ? AnalysisProfile(
              trackingStart: DateTime(2024, 11),
              touched: true,
              annotations: {
                for (final e in snapshot.entries.take(1000))
                  e.id: EntryAnnotation(
                    entryId: e.id,
                    sourceHash: annotationHash(e),
                    reviewedOn: DateTime(2026, 11, 14),
                    role: ExpenseRole.flexible,
                    counterparty: 'Synthetic',
                  ),
              },
              flexibleCaps: {'category 1': 10000},
              scenarioCategories: {'category 1'},
              debts: [
                DebtPlan(
                  id: 'd',
                  name: 'Synthetic',
                  principalMinor: 100000,
                  annualRateBp: 1200,
                  monthlyPaymentMinor: 10000,
                  monthlyFeeMinor: 0,
                  firstDue: DateTime(2026, 12),
                ),
              ],
            )
          : null,
      seriesReviews: calendar ? {review.proposal.key: review} : {},
      verifiedThrough: {
        for (final d in verifiedDates) monthKey(d): calendarDate(d),
      },
      verifiedHashes: {
        for (final d in verifiedDates) monthKey(d): coverageHash(snapshot, d),
      },
    );
    final engine = InsightEngine();
    engine.analyze(
      snapshot,
      DateTime(2026, 11),
      DateTime(2026, 11, 14),
      policy,
    );
    final before = ProcessInfo.currentRss;
    final samples = <double>[];
    var cards = 0;
    for (var i = 0; i < 5; i++) {
      final watch = Stopwatch()..start();
      final result = engine.analyze(
        snapshot,
        DateTime(2026, 11),
        DateTime(2026, 11, 14),
        policy,
      );
      watch.stop();
      samples.add(watch.elapsedMicroseconds / 1000);
      cards = result.length;
    }
    samples.sort();
    rows.add({
      'scenario': scenario,
      'snapshot_json_bytes': utf8
          .encode(
            jsonEncode({
              'entries': snapshot.entries.map((e) => e.toJson()).toList(),
              'profile': policy.profile.toJson(),
            }),
          )
          .length,
      'records': count,
      'samples': 5,
      'median_ms': samples[2],
      'maximum_ms': samples.last,
      'cards': cards,
      'rss_before_bytes': before,
      'rss_after_bytes': ProcessInfo.currentRss,
      'process_peak_rss_bytes': ProcessInfo.maxRss,
    });
  }
  stdout.writeln(
    jsonEncode({
      'synthetic_data_only': true,
      'runtime': 'Dart AOT when compiled',
      'measurements': rows,
    }),
  );
}
