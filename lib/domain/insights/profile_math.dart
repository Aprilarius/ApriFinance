import '../models.dart';
import 'analysis_facts.dart';
import 'analysis_profile.dart';

Map<String, int> requestedAllocations(AnalysisProfile profile) {
  final totals = {
    for (final e in profile.reserves.entries) e.key: BigInt.from(e.value),
  };
  for (final goal in profile.goals) {
    totals[goal.accountId] =
        (totals[goal.accountId] ?? BigInt.zero) +
        BigInt.from(goal.allocatedMinor);
  }
  return {for (final e in totals.entries) e.key: checked(e.value)};
}

Set<String> underfundedAccounts(AnalysisFacts f) =>
    requestedAllocations(f.profile).entries
        .where(
          (e) =>
              e.value > (f.balances[e.key] ?? 0) ||
              !f.balances.containsKey(e.key),
        )
        .map((e) => e.key)
        .toSet();
void validateProfileFunding(
  AnalysisProfile profile,
  LedgerSnapshot snapshot,
  DateTime today,
) {
  final facts = AnalysisFacts(
    snapshot,
    DateTime(today.year, today.month),
    today,
    profile: profile,
  );
  if (underfundedAccounts(facts).isNotEmpty) {
    throw const DomainError(
      'Резервы и суммы целей не могут превышать сегодняшний остаток соответствующего счёта. Одни деньги нельзя распределить дважды.',
    );
  }
}
