import '../models.dart';
import 'insight.dart';
import 'series_review.dart';

String planLinkHash(Obligation plan) => seriesDigest([
  plan.id,
  plan.name,
  plan.kind.name,
  plan.amountMinor,
  plan.category,
  calendarDate(plan.anchor),
  plan.repeat.name,
  plan.accountId,
]);
bool compatibleSeriesPlan(
  LedgerSnapshot snapshot,
  SeriesReview review,
  Obligation plan,
  DateTime through, {
  bool allowInactive = false,
}) {
  if (review.decision != SeriesDecision.accepted ||
      !review.validAt(snapshot, through) ||
      (!plan.active && !allowInactive)) {
    return false;
  }
  final source = review.proposal.sources(snapshot)!.first;
  return _matchesPlan(review, source, plan, allowInactive: allowInactive);
}

bool _matchesPlan(
  SeriesReview review,
  LedgerEntry source,
  Obligation plan, {
  bool allowInactive = false,
}) {
  final repeat = switch (review.proposal.cadence) {
    SeriesCadence.weekly => RepeatRule.weekly,
    SeriesCadence.monthly => RepeatRule.monthly,
    SeriesCadence.yearly => RepeatRule.yearly,
  };
  return (plan.active || allowInactive) &&
      plan.repeat == repeat &&
      plan.kind == source.kind &&
      (plan.accountId == null || plan.accountId == source.accountId);
}

Obligation? linkedSeriesPlan(
  LedgerSnapshot snapshot,
  SeriesReview review,
  DateTime through, {
  bool allowInactive = false,
}) {
  final link = review.planLink;
  if (link == null ||
      link.linkedOn.isAfter(through) ||
      link.linkedOn.isBefore(review.reviewedOn)) {
    return null;
  }
  final plan = snapshot.obligations
      .where((o) => o.id == link.planId)
      .firstOrNull;
  return plan != null &&
          compatibleSeriesPlan(
            snapshot,
            review,
            plan,
            through,
            allowInactive: allowInactive,
          ) &&
          planLinkHash(plan) == link.planHash
      ? plan
      : null;
}

List<Obligation> availableSeriesPlans(
  LedgerSnapshot snapshot,
  AnalysisPolicy policy,
  SeriesReview review,
  DateTime through,
) {
  if (review.decision != SeriesDecision.accepted ||
      !review.validAt(snapshot, through)) {
    return [];
  }
  final source = review.proposal.sources(snapshot)!.first;
  final reserved = policy.seriesReviews.entries
      .where((e) => e.key != review.proposal.key)
      .map((e) => e.value.planLink?.planId)
      .whereType<String>()
      .toSet();
  return snapshot.obligations
      .where((o) => !reserved.contains(o.id) && _matchesPlan(review, source, o))
      .toList()
    ..sort((a, b) {
      final name = a.name.compareTo(b.name);
      return name != 0 ? name : a.id.compareTo(b.id);
    });
}
