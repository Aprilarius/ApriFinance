import '../models.dart';
import 'analysis_facts.dart';
import 'analysis_profile.dart';
import 'insight.dart';
import 'series_plan_link.dart';
import 'series_review.dart';

class ScenarioCuts {
  const ScenarioCuts(
    this.cuts,
    this.smallIds,
    this.capSavings,
    this.variableBase,
    this.variableCuts,
  );
  final Map<String, int> cuts, capSavings, variableBase, variableCuts;
  final Set<String> smallIds;
}

ScenarioCuts scenarioCuts(AnalysisFacts f, AnalysisPolicy policy) {
  final p = f.profile,
      s = f.snapshot,
      expenses = f.entries.where((e) => e.kind == EntryKind.expense).toList();
  final net = {
    for (final e in expenses)
      e.id:
          (e.amountMinor -
                  sumMinor(
                    (f.refunds[e.id] ?? [])
                        .where((r) => !r.date.isAfter(f.end))
                        .map((r) => r.amountMinor),
                  ))
              .clamp(0, e.amountMinor),
  };
  final flexible = expenses
      .where(
        (e) => p.annotation(e)?.role == ExpenseRole.flexible && net[e.id]! > 0,
      )
      .toList();
  final cuts = <String, int>{};
  void cut(String id, int amount) {
    final capped = amount.clamp(0, net[id] ?? 0);
    if (capped > (cuts[id] ?? 0)) cuts[id] = capped;
  }

  for (final e in flexible.where(
    (e) =>
        p.scenarioCategories.map(p.category).contains(p.category(e.category)),
  )) {
    cut(e.id, percentMinor(net[e.id]!, policy.scenarioPercent));
  }
  final small =
      flexible
          .where(
            (e) =>
                net[e.id]! <=
                (p.ruleMinimums['C5'] ?? policy.smallExpenseMinor),
          )
          .toList()
        ..sort((a, b) {
          final c = a.date.compareTo(b.date);
          return c != 0 ? c : a.id.compareTo(b.id);
        });
  final smallIds = small.take(p.smallSkipCount).map((e) => e.id).toSet();
  for (final id in smallIds) {
    cut(id, net[id]!);
  }
  final caps = <String, int>{};
  for (final cap in p.flexibleCaps.entries) {
    final rows =
        flexible
            .where((e) => p.category(e.category) == p.category(cap.key))
            .toList()
          ..sort((a, b) {
            final c = net[b.id]!.compareTo(net[a.id]!);
            return c != 0 ? c : a.id.compareTo(b.id);
          });
    final total = sumMinor(rows.map((e) => net[e.id]!)),
        reduction = total > cap.value ? difference(total, cap.value) : 0;
    caps[p.category(cap.key)] = reduction;
    var remaining = reduction;
    for (final e in rows) {
      final value = remaining < net[e.id]! ? remaining : net[e.id]!;
      cut(e.id, value);
      remaining -= value;
      if (remaining == 0) break;
    }
  }
  final paused = s.obligations
      .where(
        (o) => o.kind == EntryKind.expense && p.pausePlanIds.contains(o.id),
      )
      .map((o) => o.id)
      .toSet();
  final fixed = s.settlements
      .where((r) => !r.skipped && r.entryId != null)
      .map((r) => r.entryId!)
      .toSet();
  final pausedEntries = s.settlements
      .where(
        (r) =>
            !r.skipped && paused.contains(r.obligationId) && r.entryId != null,
      )
      .map((r) => r.entryId!)
      .toSet();
  final fixedKeys = <String>{}, pausedKeys = <String>{};
  for (final review in policy.seriesReviews.values) {
    final plan = linkedSeriesPlan(s, review, f.end, allowInactive: true);
    if (plan != null) {
      fixedKeys.add(review.proposal.key);
      if (paused.contains(plan.id)) pausedKeys.add(review.proposal.key);
    }
  }
  final identities = <String, String>{};
  String identity(LedgerEntry e) => identities.putIfAbsent(
    seriesRawKey(s.currency!, e),
    () => seriesKey(s.currency!, e),
  );
  final variableBase = <String, List<int>>{},
      variableCuts = <String, List<int>>{};
  for (final e in expenses) {
    final key = fixedKeys.isEmpty ? '' : identity(e),
        category = p.category(e.category);
    if (pausedEntries.contains(e.id) || pausedKeys.contains(key)) {
      cut(e.id, net[e.id]!);
    }
    if (!fixed.contains(e.id) &&
        !fixedKeys.contains(key) &&
        !(p.annotation(e)?.oneOff ?? false)) {
      variableBase.putIfAbsent(category, () => []).add(net[e.id]!);
      variableCuts.putIfAbsent(category, () => []).add(cuts[e.id] ?? 0);
    }
  }
  return ScenarioCuts(
    Map.unmodifiable(cuts),
    Set.unmodifiable(smallIds),
    Map.unmodifiable(caps),
    {for (final e in variableBase.entries) e.key: sumMinor(e.value)},
    {for (final e in variableCuts.entries) e.key: sumMinor(e.value)},
  );
}
