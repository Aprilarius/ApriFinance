import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/domain/insights/insight.dart';
import 'package:personal_finance/domain/insights/insight_engine.dart';
import 'package:personal_finance/domain/insights/series_review.dart';
import 'package:personal_finance/domain/models.dart';

LedgerSnapshot seriesFixture({
  EntryKind kind = EntryKind.expense,
  int? nextAmount,
  String currency = 'AZN',
  List<LedgerEntry>? entries,
}) => LedgerSnapshot(
  currency: currency,
  accounts: const [
    Account(id: 'a', name: 'Карта', kind: 'Карта', openingMinor: 500000),
  ],
  entries:
      entries ??
      [
        for (var m = 9; m <= (nextAmount == null ? 11 : 12); m++)
          LedgerEntry(
            id: 'series$m',
            kind: kind,
            amountMinor: m == 12 ? nextAmount! : 10000,
            date: DateTime(2026, m, 12),
            accountId: 'a',
            category: 'Сервис',
            note: kind == EntryKind.income ? 'Работа' : 'Интернет',
          ),
      ],
);
List<Insight> seriesScan(
  LedgerSnapshot s, {
  AnalysisPolicy? policy,
  int month = 12,
}) => InsightEngine().analyze(
  s,
  DateTime(2026, month),
  DateTime(2026, month, 14),
  policy ?? AnalysisPolicy(),
);
SeriesProposal expenseProposal() => seriesScan(
  seriesFixture(),
  month: 11,
).singleWhere((i) => i.rule == 'G1').seriesProposal!;
AnalysisPolicy acceptedPolicy({
  SeriesProposal? proposal,
  SeriesDecision decision = SeriesDecision.accepted,
}) {
  final p = proposal ?? expenseProposal();
  return AnalysisPolicy(
    seriesReviews: {
      p.key: SeriesReview(
        proposal: p,
        decision: decision,
        reviewedOn: DateTime(2026, 11, 14),
      ),
    },
  );
}

void main() {
  test(
    'weekly and yearly expense proposals can be confirmed with valid cadence',
    () {
      for (final (cadence, dates, rule) in [
        (
          SeriesCadence.weekly,
          [for (var n = 0; n < 4; n++) DateTime(2026, 10, 24 + n * 7)],
          'G2',
        ),
        (
          SeriesCadence.yearly,
          [for (var year = 2024; year <= 2026; year++) DateTime(year, 11, 12)],
          'G3',
        ),
      ]) {
        final s = seriesFixture(
          entries: [
            for (var n = 0; n < dates.length; n++)
              LedgerEntry(
                id: 'cadence$n',
                kind: EntryKind.expense,
                amountMinor: 10000,
                date: dates[n],
                accountId: 'a',
                category: 'Сервис',
                note: 'Интернет',
              ),
          ],
        );
        final p = seriesScan(
          s,
          month: 11,
        ).singleWhere((i) => i.rule == rule).seriesProposal!;
        expect(p.cadence, cadence);
        expect(
          acceptedPolicy(proposal: p).seriesReviews.values.single
              .validAt(s, DateTime(2026, 11, 14)),
          isTrue,
        );
      }
    },
  );
  test(
    'old preferences acquire empty decisions and new preferences roundtrip',
    () {
      final old = AnalysisPolicy().toJson()..remove('seriesReviews');
      expect(AnalysisPolicy.fromJson(old).seriesReviews, isEmpty);
      final policy = acceptedPolicy();
      final decoded = AnalysisPolicy.fromJson(
        jsonDecode(jsonEncode(policy.toJson())) as Map<String, dynamic>,
      );
      final review = decoded.seriesReviews.values.single;
      expect(review.decision, SeriesDecision.accepted);
      expect(review.validAt(seriesFixture(), DateTime(2026, 11, 14)), isTrue);
      expect(decoded.toJson(), policy.toJson());
    },
  );
  test('review parser rejects malformed identity duplicate ids and mismatched map key', () {
    final json = acceptedPolicy().seriesReviews.values.single.toJson();
    expect(
      () => SeriesReview.fromJson({...json, 'key': 'raw note'}),
      throwsFormatException,
    );
    expect(
      () => SeriesReview.fromJson({
        ...json,
        'sourceIds': ['same', 'same', 'same'],
      }),
      throwsFormatException,
    );
    final saved = acceptedPolicy().toJson()
      ..['seriesReviews'] = {'wrong': json};
    expect(() => AnalysisPolicy.fromJson(saved), throwsFormatException);
  });
  test(
    'series identity separates currencies kinds accounts and note boundaries',
    () {
      final e = seriesFixture().entries.first;
      expect(seriesKey('AZN', e), isNot(seriesKey('USD', e)));
      expect(
        seriesKey('AZN', e),
        isNot(
          seriesKey('AZN', seriesFixture(kind: EntryKind.income).entries.first),
        ),
      );
      expect(seriesKey('AZN', e), matches(r'^[a-f0-9]{64}$'));
      expect(
        seriesSourceHash('AZN', seriesFixture().entries),
        seriesSourceHash('AZN', seriesFixture().entries.reversed),
      );
    },
  );
  test('decisions suppress accepted and rejected candidates and undo restores them', () {
    for (final decision in SeriesDecision.values) {
      expect(
        seriesScan(
          seriesFixture(),
          month: 11,
          policy: acceptedPolicy(decision: decision),
        ).where((i) => i.rule == 'G1'),
        isEmpty,
      );
    }
    expect(
      seriesScan(seriesFixture(), month: 11).where((i) => i.rule == 'G1'),
      hasLength(1),
    );
  });
  test('changes deletions and currency restore invalidate confirmation', () {
    final review = acceptedPolicy().seriesReviews.values.single;
    final s = seriesFixture();
    expect(
      review.validAt(seriesFixture(currency: 'USD'), DateTime(2026, 12, 14)),
      isFalse,
    );
    expect(
      review.validAt(
        seriesFixture(entries: s.entries.skip(1).toList()),
        DateTime(2026, 12, 14),
      ),
      isFalse,
    );
    final changed = s.entries
        .map(
          (e) => LedgerEntry(
            id: e.id,
            kind: e.kind,
            amountMinor: e.amountMinor + 1,
            date: e.date,
            accountId: e.accountId,
            category: e.category,
            note: e.note,
          ),
        )
        .toList();
    expect(
      review.validAt(seriesFixture(entries: changed), DateTime(2026, 12, 14)),
      isFalse,
    );
  });
  test('confirmation cannot use future source entries or future decisions', () {
    final review = acceptedPolicy().seriesReviews.values.single;
    expect(review.validAt(seriesFixture(), DateTime(2026, 10, 31)), isFalse);
    final premature = SeriesReview(
      proposal: review.proposal,
      decision: SeriesDecision.accepted,
      reviewedOn: DateTime(2026, 10),
    );
    expect(premature.validAt(seriesFixture(), DateTime(2026, 12, 14)), isFalse);
  });
  test('G4 and H5 require confirmed source plus new appropriately timed observation', () {
    final s = seriesFixture(nextAmount: 100000);
    final cards = seriesScan(s, policy: acceptedPolicy());
    expect(cards.where((i) => i.rule == 'G4'), hasLength(1));
    expect(cards.where((i) => i.rule == 'H5'), hasLength(1));
    expect(cards.singleWhere((i) => i.rule == 'H5').evidence, hasLength(4));
    for (final p in [
      AnalysisPolicy(),
      acceptedPolicy(decision: SeriesDecision.rejected),
    ]) {
      expect(
        seriesScan(s, policy: p).where((i) => i.rule == 'G4' || i.rule == 'H5'),
        isEmpty,
      );
    }
    expect(
      seriesScan(
        seriesFixture(),
        month: 11,
        policy: acceptedPolicy(),
      ).where((i) => i.rule == 'G4'),
      isEmpty,
    );
  });
  test('price threshold is inclusive but below-threshold changes and bad intervals stay quiet', () {
    expect(
      seriesScan(
        seriesFixture(nextAmount: 12000),
        policy: acceptedPolicy(),
      ).where((i) => i.rule == 'G4'),
      hasLength(1),
    );
    expect(
      seriesScan(
        seriesFixture(nextAmount: 11999),
        policy: acceptedPolicy(),
      ).where((i) => i.rule == 'G4'),
      isEmpty,
    );
    final rows = seriesFixture().entries.toList()
      ..add(
        LedgerEntry(
          id: 'bad-date',
          kind: EntryKind.expense,
          amountMinor: 100000,
          date: DateTime(2026, 12, 3),
          accountId: 'a',
          category: 'Сервис',
          note: 'Интернет',
        ),
      );
    expect(
      seriesScan(
        seriesFixture(entries: rows),
        policy: acceptedPolicy(),
      ).where((i) => i.rule == 'G4' || i.rule == 'H5'),
      isEmpty,
    );
  });
  test('decimal check uses exact 10 or 100 ratio in either direction', () {
    for (final amount in [100000, 1000000, 1000, 100]) {
      expect(
        seriesScan(
          seriesFixture(nextAmount: amount),
          policy: acceptedPolicy(),
        ).where((i) => i.rule == 'H5'),
        hasLength(1),
      );
    }
    expect(
      seriesScan(
        seriesFixture(nextAmount: 100001),
        policy: acceptedPolicy(),
      ).where((i) => i.rule == 'H5'),
      isEmpty,
    );
  });
  test('income regularity remains a candidate until explicit confirmation', () {
    final base = seriesFixture(kind: EntryKind.income);
    final candidate = seriesScan(
      base,
      month: 11,
    ).singleWhere((i) => i.rule == 'E3');
    expect(candidate.kind, InsightKind.check);
    final p = acceptedPolicy(proposal: candidate.seriesProposal!);
    final card = seriesScan(
      seriesFixture(kind: EntryKind.income, nextAmount: 10000),
      policy: p,
    ).singleWhere((i) => i.rule == 'E3');
    expect(card.kind, InsightKind.fact);
    expect(card.seriesProposal, isNull);
    expect(card.explanation, contains('медиана интервала 30 дн.'));
    expect(card.amounts['Медиана поступления'], 10000);
  });
  test('future price records cannot leak into prior period and output is deterministic', () {
    final s = seriesFixture(nextAmount: 100000), p = acceptedPolicy();
    expect(
      seriesScan(
        s,
        month: 11,
        policy: p,
      ).where((i) => i.rule == 'G4' || i.rule == 'H5'),
      isEmpty,
    );
    final a = seriesScan(s, policy: p),
        b = seriesScan(
          seriesFixture(entries: s.entries.reversed.toList()),
          policy: p,
        );
    expect(a.map((i) => i.key), b.map((i) => i.key));
    expect(
      a.singleWhere((i) => i.rule == 'G4').evidence,
      b.singleWhere((i) => i.rule == 'G4').evidence,
    );
  });
}
