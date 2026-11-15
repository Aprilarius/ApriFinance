import 'dart:convert';

import 'backup_data.dart';
import 'ledger_math.dart';
import 'models.dart';

export 'canonical_json.dart';
import 'canonical_json.dart';
import 'sync_analysis.dart';
import 'insights/insight.dart';

/// Private queues, local backup acknowledgements and restore flags stay local.
BackupData syncData(BackupData data) {
  final policyRow = data.tables['settings']!
      .where((r) => r['key'] == 'analysis_policy')
      .firstOrNull;
  final settings = <Map<String, Object?>>[
    ...data.tables['settings']!.where((r) => r['key'] == 'currency'),
    if (policyRow != null) ...[
      {
        'key': 'analysis_policy',
        'value': canonicalJson(
          sharedAnalysisPolicy(
            AnalysisPolicy.fromJson(
              jsonDecode(policyRow['value']! as String) as Map<String, dynamic>,
            ),
          ).toJson(),
        ),
      },
      {'key': 'analysis_revision', 'value': '1'},
    ],
  ]..sort((a, b) => (a['key']! as String).compareTo(b['key']! as String));
  return BackupData.fromJson({
    'schema': policyRow == null ? 4 : 5,
    'tables': {
      for (final table in BackupData.columns.keys)
        table: table == 'outbox'
            ? <Object?>[]
            : table == 'settings'
            ? settings
            : (data.tables[table]!.toList()..sort(
                (a, b) => (a['id']! as String).compareTo(b['id']! as String),
              )),
    },
  });
}

bool sameSyncData(BackupData a, BackupData b) =>
    canonicalJson(syncData(a).toJson()) == canonicalJson(syncData(b).toJson());
bool hasFinanceData(BackupData data) =>
    BackupData.columns.keys
        .where((t) => t != 'settings' && t != 'outbox')
        .any((t) => data.tables[t]!.isNotEmpty) ||
    data.tables['settings']!.any((r) => r['key'] == 'analysis_policy');

class SyncMerge {
  const SyncMerge(this.data, this.conflicts);
  final BackupData? data;
  final List<String> conflicts;
}

/// Three-way row merge. Tombstones remain rows. Money is validated as a complete
/// graph after merging; no partial refund/payment/purchase graphs are committed.
SyncMerge mergeSyncData(
  BackupData base,
  BackupData local,
  BackupData remote, {
  DateTime? today,
}) {
  final b = syncData(base), l = syncData(local), r = syncData(remote);
  final conflicts = <String>[];
  final tables = <String, Object?>{};
  for (final table in BackupData.columns.keys) {
    final key = table == 'settings' ? 'key' : 'id';
    Map<String, Map<String, Object?>> index(BackupData d) => {
      for (final row in d.tables[table]!) row[key]! as String: row,
    };
    final bi = index(b), li = index(l), ri = index(r);
    final ids = {...bi.keys, ...li.keys, ...ri.keys}.toList()..sort();
    final rows = <Map<String, Object?>>[];
    for (final id in ids) {
      final bv = bi[id], lv = li[id], rv = ri[id];
      final bs = canonicalJson(bv),
          ls = canonicalJson(lv),
          rs = canonicalJson(rv);
      Map<String, Object?>? selected;
      if (ls == rs) {
        selected = lv;
      } else if (ls == bs) {
        selected = rv;
      } else if (rs == bs) {
        selected = lv;
      } else if (table == 'settings' &&
          id == 'analysis_policy' &&
          lv != null &&
          rv != null) {
        final merged = mergeAnalysisPolicy(
          bv?['value'] as String?,
          lv['value']! as String,
          rv['value']! as String,
        );
        conflicts.addAll(merged.conflicts);
        selected = merged.value == null
            ? null
            : {'key': 'analysis_policy', 'value': merged.value};
      } else {
        conflicts.add('$table:$id');
        continue;
      }
      if (selected != null) rows.add(selected);
    }
    tables[table] = rows;
  }
  if (conflicts.isNotEmpty) {
    return SyncMerge(null, List.unmodifiable(conflicts));
  }
  try {
    final candidate = syncData(
      BackupData.fromJson({
        'schema':
            (tables['settings']! as List).any(
              (r) => (r as Map)['key'] == 'analysis_policy',
            )
            ? 5
            : 4,
        'tables': tables,
      }),
    );
    final snapshot = LedgerSnapshot(
      currency: candidate.currency,
      accounts: candidate.tables['accounts']!.map(
        (r) => Account(
          id: r['id']! as String,
          name: r['name']! as String,
          kind: r['kind']! as String,
          openingMinor: r['opening_minor']! as int,
          archived: r['archived'] == 1,
        ),
      ),
      entries: candidate.tables['entries']!
          .where((r) => r['deleted_at'] == null)
          .map(
            (r) => LedgerEntry.fromJson(
              (jsonDecode(r['body']! as String) as Map).cast<String, Object?>(),
            ),
          ),
    );
    final balances = accountBalances(snapshot);
    final current = today == null
        ? balances
        : accountBalances(snapshot, through: today);
    if (snapshot.accounts.any(
      (a) => a.archived && (balances[a.id] != 0 || current[a.id] != 0),
    )) {
      return const SyncMerge(null, [
        'Архивирование счёта противоречит новой операции на другом устройстве',
      ]);
    }
    return SyncMerge(candidate, const []);
  } catch (_) {
    return const SyncMerge(null, [
      'Изменения связанных записей противоречат друг другу',
    ]);
  }
}
