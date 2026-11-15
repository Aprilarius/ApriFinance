part of 'finance_repository.dart';

AnalysisPolicy _parseStoredPolicy(String value) =>
    AnalysisPolicy.fromJson(jsonDecode(value) as Map<String, dynamic>);
Future<AnalysisPolicy> _parseLargeStoredPolicy(String value) =>
    Isolate.run(() => _parseStoredPolicy(value));
Future<String> _encodeStoredPolicy(AnalysisPolicy policy) =>
    Isolate.run(() => jsonEncode(policy.toJson()));

extension AnalysisStorage on FinanceRepository {
  Future<AnalysisPolicy?> readAnalysisPolicy() async {
    final rows = await db
        .customSelect("SELECT value FROM settings WHERE key='analysis_policy'")
        .get();
    if (rows.isEmpty) return null;
    final value = rows.single.read<String>('value');
    if (utf8.encode(value).length > 4 * 1024 * 1024) {
      throw const FormatException('Настройки анализа слишком велики');
    }
    return value.length > 64000
        ? _parseLargeStoredPolicy(value)
        : _parseStoredPolicy(value);
  }

  Future<void> writeAnalysisPolicy(AnalysisPolicy policy) async {
    final encoded = await _encodeStoredPolicy(policy);
    if (utf8.encode(encoded).length > 4 * 1024 * 1024) {
      throw const FormatException('Настройки анализа слишком велики');
    }
    await db.transaction(() async {
      final current = await db
          .customSelect(
            "SELECT value FROM settings WHERE key='analysis_revision'",
          )
          .get();
      final version =
          (current.isEmpty
              ? 0
              : int.parse(current.single.read<String>('value'))) +
          1;
      if (version > 2147483647) {
        throw const DomainError('Достигнут предел версий настроек анализа');
      }
      await db.customStatement(
        'INSERT OR REPLACE INTO settings(key,value) VALUES(?,?)',
        ['analysis_policy', encoded],
      );
      await db.customStatement(
        'INSERT OR REPLACE INTO settings(key,value) VALUES(?,?)',
        ['analysis_revision', '$version'],
      );
      await db.customStatement(
        "DELETE FROM outbox WHERE entity_type='analysis' AND entity_id='policy'",
      );
      await db.customStatement('INSERT INTO outbox VALUES(?,?,?,?,?,?)', [
        newId(),
        'analysis',
        'policy',
        version,
        encoded,
        _now,
      ]);
    });
  }
}
