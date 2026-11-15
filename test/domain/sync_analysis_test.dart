import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/domain/insights/analysis_profile.dart';
import 'package:personal_finance/domain/insights/insight.dart';
import 'package:personal_finance/domain/sync_analysis.dart';

void main() {
  final base = AnalysisPolicy();
  String encode(AnalysisPolicy p) => jsonEncode(p.toJson());
  AnalysisPolicy merge(AnalysisPolicy b, AnalysisPolicy l, AnalysisPolicy r) {
    final result = mergeAnalysisPolicy(encode(b), encode(l), encode(r));
    expect(result.conflicts, isEmpty);
    return AnalysisPolicy.fromJson(
      jsonDecode(result.value!) as Map<String, dynamic>,
    );
  }

  SavingsGoal goal(String id, int amount) => SavingsGoal(
    id: id,
    name: id,
    accountId: 'card',
    targetMinor: amount,
    allocatedMinor: 0,
    start: DateTime(2026, 11),
    deadline: DateTime(2027, 11),
  );
  test(
    'independent settings, sets and goals merge without losing either device',
    () {
      final local = base.copyWith(
        disabled: {'A1'},
        profile: AnalysisProfile(
          goals: [goal('travel', 10000)],
          categoryAliases: {'еда': 'продукты'},
        ),
      );
      final remote = base.copyWith(
        changePercent: 30,
        hidden: {'B1'},
        profile: AnalysisProfile(
          goals: [goal('computer', 20000)],
          reserves: {'card': 1000},
        ),
      );
      for (final pair in [(local, remote), (remote, local)]) {
        final result = merge(base, pair.$1, pair.$2);
        expect(result.disabled, {'A1'});
        expect(result.hidden, {'B1'});
        expect(result.changePercent, 30);
        expect(result.profile.goals.map((g) => g.id).toSet(), {
          'travel',
          'computer',
        });
        expect(result.profile.categoryAliases, {'еда': 'продукты'});
        expect(result.profile.reserves, {'card': 1000});
      }
    },
  );
  test(
    'different edits of one goal and deletion against edit require choice',
    () {
      final original = base.copyWith(
        profile: AnalysisProfile(goals: [goal('travel', 10000)]),
      );
      final local = base.copyWith(
        profile: AnalysisProfile(goals: [goal('travel', 12000)]),
      );
      final remote = base.copyWith(
        profile: AnalysisProfile(goals: [goal('travel', 14000)]),
      );
      for (final l in [local, base]) {
        final result = mergeAnalysisPolicy(
          encode(original),
          encode(l),
          encode(remote),
        );
        expect(result.value, isNull);
        expect(result.conflicts, contains('Настройки анализа: цели'));
      }
      expect(merge(original, base, original).profile.goals, isEmpty);
    },
  );
  test('coverage date and hash stay an atomic pair for each month', () {
    final original = base.copyWith(
      verifiedThrough: {'2026-10': '2026-10-15'},
      verifiedHashes: {'2026-10': 'a' * 64},
    );
    final local = original.copyWith(
      verifiedThrough: {'2026-10': '2026-10-31'},
      verifiedHashes: {'2026-10': 'b' * 64},
    );
    final remote = original.copyWith(verifiedHashes: {'2026-10': 'c' * 64});
    expect(
      mergeAnalysisPolicy(
        encode(original),
        encode(local),
        encode(remote),
      ).value,
      isNull,
    );
    final independent = original.copyWith(
      verifiedThrough: {'2026-10': '2026-10-15', '2026-09': '2026-09-30'},
      verifiedHashes: {'2026-10': 'a' * 64, '2026-09': 'd' * 64},
    );
    final result = merge(original, local, independent);
    expect(result.verifiedHashes, {'2026-10': 'b' * 64, '2026-09': 'd' * 64});
    expect(result.verifiedThrough['2026-10'], '2026-10-31');
  });
  test('individually valid aliases cannot merge into a cycle', () {
    final local = base.copyWith(
      profile: AnalysisProfile(categoryAliases: {'еда': 'дом'}),
    );
    final remote = base.copyWith(
      profile: AnalysisProfile(categoryAliases: {'дом': 'еда'}),
    );
    final result = mergeAnalysisPolicy(
      encode(base),
      encode(local),
      encode(remote),
    );
    expect(result.value, isNull);
    expect(result.conflicts, isNotEmpty);
  });
  test('backup acknowledgement belongs to the device', () {
    final policy = base.copyWith(
      profile: AnalysisProfile(
        lastBackupOn: DateTime(2026, 11, 15),
        goals: [goal('travel', 10000)],
      ),
    );
    final shared = sharedAnalysisPolicy(policy);
    expect(shared.profile.lastBackupOn, isNull);
    expect(policy.profile.lastBackupOn, DateTime(2026, 11, 15));
    expect(shared.profile.goals.single.id, 'travel');
  });
}
