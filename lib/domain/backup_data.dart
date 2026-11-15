import 'dart:convert';

import 'models.dart';
import 'purchases.dart';
import 'money.dart';
import 'schedule_math.dart';
import 'insights/insight.dart';

/// A checked, immutable logical snapshot. No SQL, paths or arbitrary settings
/// from an imported file are ever executed.
class BackupData {
  BackupData._(this.tables);
  final Map<String, List<Map<String, Object?>>> tables;
  static const columns = {
    'purchases': [
      'id',
      'body',
      'entry_id',
      'version',
      'deleted_at',
      'updated_at',
    ],
    'documents': [
      'id',
      'purchase_id',
      'name',
      'mime',
      'size',
      'data',
      'version',
      'deleted_at',
      'updated_at',
    ],
    'settings': ['key', 'value'],
    'accounts': [
      'id',
      'name',
      'kind',
      'opening_minor',
      'archived',
      'version',
      'updated_at',
    ],
    'entries': [
      'id',
      'body',
      'account_id',
      'target_account_id',
      'refund_of',
      'version',
      'deleted_at',
      'updated_at',
    ],
    'budgets': [
      'id',
      'month',
      'category',
      'limit_minor',
      'version',
      'deleted_at',
      'updated_at',
    ],
    'outbox': [
      'id',
      'entity_type',
      'entity_id',
      'version',
      'payload',
      'created_at',
    ],
    'obligations': ['id', 'body', 'version', 'deleted_at', 'updated_at'],
    'settlements': [
      'id',
      'obligation_id',
      'period_index',
      'due_date',
      'entry_id',
      'status',
      'version',
      'deleted_at',
      'updated_at',
    ],
  };

  static Never _invalid() => throw const DomainError(
    'Структура копии повреждена или не поддерживается',
  );
  static String _text(Object? value, {int max = 500, bool empty = false}) {
    if (value is! String ||
        value.length > max ||
        (!empty && value.trim().isEmpty)) {
      _invalid();
    }
    return value;
  }

  static int _integer(Object? value, {int min = 1, int max = maxMoneyMinor}) {
    if (value is! int || value < min || value > max) _invalid();
    return value;
  }

  static void _timestamp(Object? value) {
    final text = _text(value, max: 40);
    if (DateTime.tryParse(text) == null) _invalid();
  }

  factory BackupData.fromJson(Object? value) {
    if (value is! Map ||
        ![2, 3, 4, 5].contains(value['schema']) ||
        value['tables'] is! Map) {
      _invalid();
    }
    final raw = Map<String, Object?>.from(value['tables'] as Map);
    if (value['schema'] == 2) {
      if (raw.length != 5 ||
          raw.containsKey('obligations') ||
          raw.containsKey('settlements')) {
        _invalid();
      }
      raw['obligations'] = <Object?>[];
      raw['settlements'] = <Object?>[];
    }
    if ((value['schema'] as int) < 4) {
      if (raw.length != 7 ||
          raw.containsKey('purchases') ||
          raw.containsKey('documents')) {
        _invalid();
      }
      raw['purchases'] = <Object?>[];
      raw['documents'] = <Object?>[];
    }
    if (raw.length != columns.length || !raw.keys.every(columns.containsKey)) {
      _invalid();
    }
    final tables = <String, List<Map<String, Object?>>>{};
    var count = 0;
    for (final table in columns.entries) {
      final rows = raw[table.key];
      if (rows is! List) _invalid();
      count += rows.length;
      if (count > 100000) {
        throw const DomainError('В копии слишком много записей');
      }
      final ids = <String>{};
      tables[table.key] = List.unmodifiable(
        rows.map((r) {
          if (r is! Map ||
              r.length != table.value.length ||
              !r.keys.every(table.value.contains)) {
            _invalid();
          }
          final row = Map<String, Object?>.from(r);
          final id = _text(
            row[table.key == 'settings' ? 'key' : 'id'],
            max: 100,
          );
          if (!ids.add(id)) _invalid();
          if (table.key != 'settings') {
            _integer(row['version'], max: 2147483647);
            _timestamp(
              row[table.key == 'outbox' ? 'created_at' : 'updated_at'],
            );
          }
          if (table.value.contains('deleted_at') && row['deleted_at'] != null) {
            _timestamp(row['deleted_at']);
          }
          return Map<String, Object?>.unmodifiable(row);
        }),
      );
    }
    final settings = {
      for (final r in tables['settings']!) r['key']: r['value'],
    };
    if (settings.keys.any(
      (k) => ![
        'currency',
        'sync_restore_required',
        'analysis_policy',
        'analysis_revision',
      ].contains(k),
    )) {
      _invalid();
    }
    if (settings.containsKey('currency') &&
        !supportedCurrencies.contains(settings['currency'])) {
      _invalid();
    }
    if (settings.containsKey('analysis_policy')) {
      try {
        if (value['schema'] != 5 ||
            utf8.encode(settings['analysis_policy'] as String).length >
                4 * 1024 * 1024) {
          _invalid();
        }
        final analysis = AnalysisPolicy.fromJson(
          jsonDecode(_text(settings['analysis_policy'], max: 4 * 1024 * 1024))
              as Map<String, dynamic>,
        );
        if (analysis.profile.hasMonetaryInputs &&
            !settings.containsKey('currency')) {
          _invalid();
        }
        if (int.parse(settings['analysis_revision'] as String) < 1) _invalid();
      } catch (_) {
        _invalid();
      }
    } else if (settings.containsKey('analysis_revision')) {
      _invalid();
    }
    if (settings.containsKey('sync_restore_required') &&
        settings['sync_restore_required'] != 'true') {
      _invalid();
    }
    final accounts = <String>{};
    final names = <String>{};
    for (final a in tables['accounts']!) {
      accounts.add(a['id']! as String);
      if (!names.add(_text(a['name'], max: 60).toLowerCase()) ||
          !accountKinds.contains(a['kind'])) {
        _invalid();
      }
      _integer(a['opening_minor'], min: -maxMoneyMinor);
      _integer(a['archived'], min: 0, max: 1);
    }
    if ([
          'accounts',
          'budgets',
          'obligations',
          'purchases',
        ].any((table) => tables[table]!.isNotEmpty) &&
        !settings.containsKey('currency')) {
      _invalid();
    }
    final entries = <String, LedgerEntry>{};
    final deleted = <String>{};
    for (final r in tables['entries']!) {
      LedgerEntry entry;
      try {
        entry = LedgerEntry.fromJson(
          Map<String, Object?>.from(
            jsonDecode(_text(r['body'], max: 10000)) as Map,
          ),
        );
      } catch (_) {
        _invalid();
      }
      if (entry.id != r['id'] ||
          entry.accountId != r['account_id'] ||
          entry.targetAccountId != r['target_account_id'] ||
          entry.refundOf != r['refund_of'] ||
          !accounts.contains(entry.accountId) ||
          entry.version < 1 ||
          entry.version > (r['version']! as int)) {
        _invalid();
      }
      if (r['deleted_at'] == null && entry.version != r['version']) _invalid();
      final body = jsonDecode(r['body']! as String) as Map;
      if (body['date'] != calendarDate(entry.date) ||
          entry.date.year < 2000 ||
          entry.date.year > 2100) {
        _invalid();
      }
      _integer(entry.amountMinor);
      _text(entry.note, empty: true);
      if (entry.kind == EntryKind.transfer) {
        if (!accounts.contains(entry.targetAccountId) ||
            entry.accountId == entry.targetAccountId ||
            entry.refundOf != null ||
            entry.category.isNotEmpty) {
          _invalid();
        }
      } else {
        if (entry.targetAccountId != null) _invalid();
        _text(entry.category, max: 60);
        if (entry.kind != EntryKind.refund && entry.refundOf != null) {
          _invalid();
        }
      }
      entries[entry.id] = entry;
      if (r['deleted_at'] != null) deleted.add(entry.id);
    }
    final refunds = <String, BigInt>{};
    for (final e in entries.values.where((e) => e.kind == EntryKind.refund)) {
      final source = entries[e.refundOf];
      // Tombstones retain historical links. The source can legitimately change
      // type/category after its last live refund has been deleted.
      if (source == null || source.id == e.id) _invalid();
      if (!deleted.contains(e.id)) {
        if (deleted.contains(source.id) ||
            source.kind != EntryKind.expense ||
            source.category != e.category) {
          _invalid();
        }
        refunds.update(
          source.id,
          (v) => v + BigInt.from(e.amountMinor),
          ifAbsent: () => BigInt.from(e.amountMinor),
        );
      }
    }
    for (final refund in refunds.entries) {
      if (refund.value > BigInt.from(entries[refund.key]!.amountMinor)) {
        _invalid();
      }
    }
    final budgetKeys = <String>{};
    for (final b in tables['budgets']!) {
      final month = _text(b['month'], max: 7);
      if (!RegExp(r'^(20\d\d|2100)-(0[1-9]|1[0-2])$').hasMatch(month)) {
        _invalid();
      }
      final category = _text(b['category'], max: 60);
      _integer(b['limit_minor']);
      if (b['deleted_at'] == null &&
          !budgetKeys.add('$month:${category.toLowerCase()}')) {
        _invalid();
      }
    }
    final obligations = <String, Obligation>{};
    final deletedObligations = <String>{};
    for (final row in tables['obligations']!) {
      Obligation o;
      try {
        o = Obligation.fromJson(
          Map<String, Object?>.from(
            jsonDecode(_text(row['body'], max: 10000)) as Map,
          ),
        );
        validateObligation(o);
      } catch (_) {
        _invalid();
      }
      if (o.id != row['id'] ||
          o.version > (row['version']! as int) ||
          (row['deleted_at'] == null && o.version != row['version']) ||
          (o.accountId != null && !accounts.contains(o.accountId))) {
        _invalid();
      }
      obligations[o.id] = o;
      if (row['deleted_at'] != null) deletedObligations.add(o.id);
    }
    final paidIndices = <String, Set<int>>{};
    final linkedEntries = <String>{};
    for (final row in tables['settlements']!) {
      final id = _text(row['obligation_id'], max: 100);
      final o = obligations[id];
      final index = _integer(row['period_index'], min: 0, max: 6000);
      if (o == null ||
          row['id'] != '$id:$index' ||
          row['due_date'] != calendarDate(periodDate(o, index)) ||
          (o.repeat == RepeatRule.once && index != 0) ||
          !['paid', 'skipped'].contains(row['status'])) {
        _invalid();
      }
      final entryId = row['entry_id'];
      if (row['status'] == 'skipped' && entryId != null) _invalid();
      if (row['status'] == 'paid' &&
          (!entries.containsKey(entryId) || entries[entryId]!.kind != o.kind)) {
        _invalid();
      }
      if (row['deleted_at'] == null) {
        if (deletedObligations.contains(id) || index >= o.nextIndex) _invalid();
        if (!(paidIndices[id] ??= <int>{}).add(index)) _invalid();
        if (entryId != null &&
            (deleted.contains(entryId) ||
                !linkedEntries.add(entryId as String))) {
          _invalid();
        }
      }
    }
    for (final o in obligations.values) {
      if (!deletedObligations.contains(o.id) &&
          (paidIndices[o.id]?.length ?? 0) != o.nextIndex) {
        _invalid();
      }
    }
    final purchases = <String, Purchase>{};
    final deletedPurchases = <String>{};
    final purchaseEntries = <String>{};
    for (final row in tables['purchases']!) {
      Purchase p;
      try {
        p = Purchase.fromJson(
          Map<String, Object?>.from(
            jsonDecode(_text(row['body'], max: 10000)) as Map,
          ),
        );
        validatePurchase(p);
      } catch (_) {
        _invalid();
      }
      if (p.id != row['id'] ||
          p.entryId != row['entry_id'] ||
          p.version > (row['version']! as int) ||
          (row['deleted_at'] == null && p.version != row['version'])) {
        _invalid();
      }
      if (p.entryId != null && !entries.containsKey(p.entryId)) _invalid();
      if (row['deleted_at'] == null && p.entryId != null) {
        final e = entries[p.entryId]!;
        if (deleted.contains(e.id) ||
            e.kind != EntryKind.expense ||
            e.amountMinor != p.amountMinor ||
            !purchaseEntries.add(e.id)) {
          _invalid();
        }
      }
      purchases[p.id] = p;
      if (row['deleted_at'] != null) deletedPurchases.add(p.id);
    }
    var documentBytes = 0;
    for (final row in tables['documents']!) {
      final parent = _text(row['purchase_id'], max: 100);
      if (!purchases.containsKey(parent)) _invalid();
      final name = _text(row['name'], max: 120);
      if (RegExp(r'[\\/\x00-\x1f]').hasMatch(name)) _invalid();
      final size = _integer(row['size'], min: 1, max: maxDocumentBytes);
      if (![
        'image/png',
        'image/jpeg',
        'application/pdf',
      ].contains(row['mime'])) {
        _invalid();
      }
      final content = _text(row['data'], max: 3 * 1024 * 1024, empty: true);
      if (row['deleted_at'] != null) {
        if (content.isNotEmpty) _invalid();
      } else {
        if (deletedPurchases.contains(parent)) _invalid();
        try {
          final bytes = base64Decode(content);
          if (bytes.length != size ||
              documentMime(bytes) != row['mime'] ||
              base64Encode(bytes) != content) {
            _invalid();
          }
        } catch (_) {
          _invalid();
        }
        documentBytes += size;
      }
    }
    if (documentBytes > maxStoredDocumentBytes) _invalid();
    for (final r in tables['outbox']!) {
      if (![
        'account',
        'entry',
        'budget',
        'obligation',
        'settlement',
        'purchase',
        'document',
        'analysis',
      ].contains(r['entity_type'])) {
        _invalid();
      }
      _text(r['entity_id'], max: 100);
      try {
        if (jsonDecode(
          _text(
            r['payload'],
            max: r['entity_type'] == 'analysis' ? 4 * 1024 * 1024 : 10000,
          ),
        ) is! Map) {
          _invalid();
        }
      } catch (_) {
        _invalid();
      }
    }
    return BackupData._(Map.unmodifiable(tables));
  }

  Map<String, Object?> toJson() => {
    'schema': tables['settings']!.any((r) => r['key'] == 'analysis_policy')
        ? 5
        : 4,
    'tables': tables,
  };
  String? get currency =>
      tables['settings']!
              .where((r) => r['key'] == 'currency')
              .firstOrNull?['value']
          as String?;
  int get purchaseCount =>
      tables['purchases']!.where((r) => r['deleted_at'] == null).length;
  int get documentCount =>
      tables['documents']!.where((r) => r['deleted_at'] == null).length;
  int get accountCount => tables['accounts']!.length;
  int get entryCount =>
      tables['entries']!.where((r) => r['deleted_at'] == null).length;
  int get budgetCount =>
      tables['budgets']!.where((r) => r['deleted_at'] == null).length;
  int get obligationCount =>
      tables['obligations']!.where((r) => r['deleted_at'] == null).length;
}
