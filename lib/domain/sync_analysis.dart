import 'dart:convert';

import 'canonical_json.dart';
import 'insights/insight.dart';
import 'insights/analysis_profile.dart';

AnalysisPolicy sharedAnalysisPolicy(AnalysisPolicy policy) => policy.copyWith(
  profile: AnalysisProfile.fromJson({
    ...policy.profile.toJson(),
    'lastBackupOn': null,
  }),
);

({String? value, List<String> conflicts}) mergeAnalysisPolicy(
  String? base,
  String local,
  String remote,
) {
  final b = base == null
      ? AnalysisPolicy().toJson()
      : jsonDecode(base) as Map<String, dynamic>;
  final l = jsonDecode(local) as Map<String, dynamic>,
      r = jsonDecode(remote) as Map<String, dynamic>;
  final conflicts = <String>[];
  Object? select(Object? bv, Object? lv, Object? rv, String label) {
    final bs = canonicalJson(bv),
        ls = canonicalJson(lv),
        rs = canonicalJson(rv);
    if (ls == rs) return lv;
    if (ls == bs) return rv;
    if (rs == bs) return lv;
    conflicts.add('Настройки анализа: $label');
    return lv;
  }

  Map<String, Object?> map(Object? bv, Object? lv, Object? rv, String label) {
    final bm = (bv as Map?) ?? {},
        lm = (lv as Map?) ?? {},
        rm = (rv as Map?) ?? {};
    final keys = {
      ...bm.keys.cast<String>(),
      ...lm.keys.cast<String>(),
      ...rm.keys.cast<String>(),
    }.toList()..sort();
    final result = <String, Object?>{};
    for (final key in keys) {
      final value = select(bm[key], lm[key], rm[key], label);
      if (value != null) result[key] = value;
    }
    return result;
  }

  List<String> set(Object? bv, Object? lv, Object? rv, String label) {
    final bs = (bv as List? ?? []).cast<String>().toSet(),
        ls = (lv as List? ?? []).cast<String>().toSet(),
        rs = (rv as List? ?? []).cast<String>().toSet();
    final keys = {...bs, ...ls, ...rs}.toList()..sort();
    return [
      for (final key in keys)
        if (select(
              bs.contains(key),
              ls.contains(key),
              rs.contains(key),
              label,
            ) ==
            true)
          key,
    ];
  }

  List<Object?> records(Object? bv, Object? lv, Object? rv, String label) {
    Map<String, Object?> index(Object? rows) => {
      for (final row in rows as List? ?? []) (row as Map)['id']! as String: row,
    };
    return map(index(bv), index(lv), index(rv), label).values.toList();
  }

  final result = <String, Object?>{};
  for (final key in {...b.keys, ...l.keys, ...r.keys}) {
    if (key == 'profile' ||
        key == 'verifiedThrough' ||
        key == 'verifiedHashes') {
      continue;
    }
    result[key] = switch (key) {
      'disabled' ||
      'hidden' => set(b[key], l[key], r[key], 'отключения и скрытые карточки'),
      'snoozed' || 'seriesReviews' => map(
        b[key],
        l[key],
        r[key],
        key == 'snoozed' ? 'паузы карточек' : 'подтверждённые серии',
      ),
      _ => select(b[key], l[key], r[key], key),
    };
  }
  Map<String, Object?> coverage(Map<String, dynamic> data) => {
    for (final key in (data['verifiedThrough'] as Map).keys.cast<String>())
      key: [
        (data['verifiedThrough'] as Map)[key],
        (data['verifiedHashes'] as Map? ?? {})[key],
      ],
  };
  final verified = map(
    coverage(b),
    coverage(l),
    coverage(r),
    'полнота периода',
  );
  result['verifiedThrough'] = {
    for (final e in verified.entries) e.key: (e.value as List)[0],
  };
  result['verifiedHashes'] = {
    for (final e in verified.entries)
      if ((e.value as List)[1] != null) e.key: (e.value as List)[1],
  };
  final bp = b['profile'] as Map,
      lp = l['profile'] as Map,
      rp = r['profile'] as Map,
      profile = <String, Object?>{};
  for (final key in {
    ...bp.keys.cast<String>(),
    ...lp.keys.cast<String>(),
    ...rp.keys.cast<String>(),
  }) {
    profile[key] = switch (key) {
      'lastBackupOn' => null,
      'annotations' ||
      'reserves' ||
      'categoryAliases' ||
      'counterpartyAliases' ||
      'flexibleCaps' ||
      'ruleMinimums' ||
      'categoryMinimums' ||
      'priorities' => map(bp[key], lp[key], rp[key], key),
      'goals' || 'debts' || 'refunds' || 'tracked' => records(
        bp[key],
        lp[key],
        rp[key],
        switch (key) {
          'goals' => 'цели',
          'debts' => 'долги',
          'refunds' => 'ожидаемые возвраты',
          _ => 'отслеживаемые рекомендации',
        },
      ),
      'scenarioCategories' ||
      'pausePlanIds' => set(bp[key], lp[key], rp[key], 'сценарии'),
      _ => select(bp[key], lp[key], rp[key], key),
    };
  }
  result['profile'] = profile;
  if (conflicts.isNotEmpty) {
    return (value: null, conflicts: conflicts.toSet().toList());
  }
  try {
    return (
      value: canonicalJson(AnalysisPolicy.fromJson(result).toJson()),
      conflicts: const [],
    );
  } catch (_) {
    return (
      value: null,
      conflicts: const [
        'Настройки анализа: объединённые параметры несовместимы',
      ],
    );
  }
}
