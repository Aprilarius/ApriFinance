import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/domain/insights/insight.dart';
import 'package:personal_finance/domain/insights/series_review.dart';
import 'package:personal_finance/domain/insights/series_plan_link.dart';
import 'package:personal_finance/domain/insights/cash_calendar.dart';
import 'package:personal_finance/domain/insights/analysis_facts.dart';
import 'package:personal_finance/domain/models.dart';

import 'confirmed_series_test.dart'
    show seriesFixture, acceptedPolicy, seriesScan;

Obligation linkPlan({
  int amount = 10000,
  String? account = 'a',
  EntryKind kind = EntryKind.expense,
  RepeatRule repeat = RepeatRule.monthly,
  bool paused = false,
  int next = 0,
}) => Obligation(
  id: 'plan',
  name: 'Интернет',
  kind: kind,
  amountMinor: amount,
  category: 'Сервис',
  anchor: DateTime(2026, 12, 12),
  repeat: repeat,
  accountId: account,
  paused: paused,
  nextIndex: next,
);
LedgerSnapshot linkedFixture([Obligation? plan]) {
  final s = seriesFixture();
  return LedgerSnapshot(
    currency: s.currency,
    accounts: s.accounts,
    entries: s.entries,
    obligations: [plan ?? linkPlan()],
  );
}

AnalysisPolicy linkedPolicy([Obligation? plan]) {
  final policy = acceptedPolicy(), review = policy.seriesReviews.values.single;
  final link = SeriesPlanLink(
    planId: (plan ?? linkPlan()).id,
    planHash: planLinkHash(plan ?? linkPlan()),
    linkedOn: DateTime(2026, 11, 14),
  );
  return policy.copyWith(
    seriesReviews: {review.proposal.key: review.withLink(link)},
  );
}

void main() {
  test('ineligible early plans do not hide a later valid recommendation', () {
    final s = linkedFixture();
    final snapshot = LedgerSnapshot(
      currency: s.currency,
      accounts: s.accounts,
      entries: s.entries,
      obligations: [
        for (final id in ['a', 'b', 'c', 'd'])
          Obligation.fromJson({
            ...linkPlan().toJson(),
            'id': id,
            'amountMinor': id == 'd' ? 10000 : 30000,
          }),
      ],
    );
    final card = seriesScan(
      snapshot,
      month: 11,
      policy: acceptedPolicy(),
    ).singleWhere((i) => i.rule == 'G6');
    expect(
      card.evidence.where((e) => e.kind == EvidenceKind.obligation).single.id,
      'd',
    );
  });
  test(
    'G6 proposes exact matching plan and stored link suppresses proposal',
    () {
      final s = linkedFixture();
      final card = seriesScan(
        s,
        month: 11,
        policy: acceptedPolicy(),
      ).singleWhere((i) => i.rule == 'G6');
      expect(
        card.evidence.where((e) => e.kind == EvidenceKind.obligation).single.id,
        'plan',
      );
      expect(
        seriesScan(
          s,
          month: 11,
          policy: linkedPolicy(),
        ).where((i) => i.rule == 'G6'),
        isEmpty,
      );
      expect(seriesScan(s, month: 11).where((i) => i.rule == 'G6'), isEmpty);
    },
  );
  test('link JSON roundtrips and old review remains unlinked', () {
    final policy = AnalysisPolicy.fromJson(linkedPolicy().toJson());
    expect(
      linkedSeriesPlan(
        linkedFixture(),
        policy.seriesReviews.values.single,
        DateTime(2026, 11, 14),
      )?.id,
      'plan',
    );
    expect(
      AnalysisPolicy.fromJson(acceptedPolicy().toJson())
          .seriesReviews
          .values
          .single
          .planLink,
      isNull,
    );
    expect(
      () => SeriesPlanLink.fromJson({
        'planId': '',
        'planHash': 'bad',
        'linkedOn': '2026-11-14',
      }),
      throwsFormatException,
    );
  });
  test(
    'link compatibility requires active matching kind cadence and account',
    () {
      final s = linkedFixture(),
          policy = acceptedPolicy(),
          review = policy.seriesReviews.values.single;
      for (final plan in [
        linkPlan(paused: true),
        linkPlan(account: 'other'),
        linkPlan(kind: EntryKind.income),
        linkPlan(repeat: RepeatRule.once),
      ]) {
        expect(
          compatibleSeriesPlan(s, review, plan, DateTime(2026, 11, 14)),
          isFalse,
        );
      }
      expect(
        compatibleSeriesPlan(
          s,
          review,
          linkPlan(account: null),
          DateTime(2026, 11, 14),
        ),
        isTrue,
      );
    },
  );
  test('amount change invalidates link while paying next period preserves its identity', () {
    final review = linkedPolicy().seriesReviews.values.single;
    expect(
      linkedSeriesPlan(
        linkedFixture(linkPlan(amount: 12000)),
        review,
        DateTime(2026, 11, 14),
      ),
      isNull,
    );
    expect(
      linkedSeriesPlan(
        linkedFixture(linkPlan(next: 1)),
        review,
        DateTime(2026, 11, 14),
      )?.id,
      'plan',
    );
    expect(
      linkedSeriesPlan(
        linkedFixture(linkPlan(paused: true)),
        review,
        DateTime(2026, 11, 14),
      ),
      isNull,
    );
    expect(
      linkedSeriesPlan(linkedFixture(), review, DateTime(2026, 11, 13)),
      isNull,
    );
  });
  test('linking does not add a second recurrence or mark any period paid', () {
    final s = linkedFixture();
    final before = cashCalendar(
      AnalysisFacts(s, DateTime(2026, 11), DateTime(2026, 11, 14)),
    );
    final after = seriesScan(
      s,
      month: 11,
      policy: linkedPolicy(),
    ).singleWhere((i) => i.rule == 'I1');
    expect(
      after.timeline.map((d) => d.balanceMinor),
      before.days.map((d) => d.balanceMinor),
    );
    expect(before.at(90).balanceMinor, 440000);
    expect(s.settlements, isEmpty);
  });
  test(
    'two reviews cannot reserve the same plan including invalid old review',
    () {
      final policy = linkedPolicy(),
          review = policy.seriesReviews.values.single;
      final other = SeriesReview(
        proposal: SeriesProposal(
          key: seriesDigest('other'),
          cadence: SeriesCadence.monthly,
          sourceHash: review.proposal.sourceHash,
          sourceIds: review.proposal.sourceIds,
        ),
        decision: SeriesDecision.accepted,
        reviewedOn: review.reviewedOn,
      );
      expect(
        availableSeriesPlans(
          linkedFixture(),
          policy,
          other,
          DateTime(2026, 11, 14),
        ),
        isEmpty,
      );
      expect(
        () => policy.copyWith(
          seriesReviews: {
            ...policy.seriesReviews,
            other.proposal.key: other.withLink(review.planLink),
          },
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'unlink preserves acceptance and fingerprint while releasing reservation',
    () {
      final review = linkedPolicy().seriesReviews.values.single,
          unlinked = linkedPolicy().seriesReviews.values.single.withLink(null);
      expect(unlinked.decision, SeriesDecision.accepted);
      expect(unlinked.proposal.sourceHash, review.proposal.sourceHash);
      expect(unlinked.planLink, isNull);
    },
  );
}
