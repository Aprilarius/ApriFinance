part of 'finance_repository.dart';

class LocalSyncCapture {
  const LocalSyncCapture(
    this.data,
    this.scope,
    this.revision,
    this.payload,
    this.restored,
    this.lastAt,
    this.pendingChanges,
  );
  final BackupData data;
  final String? scope, payload, lastAt;
  final int? revision;
  final bool restored;
  final int pendingChanges;
}

extension SyncOperations on FinanceRepository {
  Future<String?> lastSyncAt() async =>
      (await db.customSelect('SELECT last_at FROM sync_state WHERE id=1').get())
          .firstOrNull
          ?.read<String>('last_at');
  Future<LocalSyncCapture> captureSync() => db.transaction(() async {
    final data = await exportData();
    final state = await db
        .customSelect('SELECT * FROM sync_state WHERE id=1')
        .get();
    final row = state.firstOrNull;
    return LocalSyncCapture(
      syncData(data),
      row?.read<String>('scope'),
      row?.read<int>('revision'),
      row?.read<String>('payload'),
      data.tables['settings']!.any((r) => r['key'] == 'sync_restore_required'),
      row?.read<String>('last_at'),
      data.tables['outbox']!.length,
    );
  });

  Future<void> checkSyncCapture(LocalSyncCapture expected) async {
    final current = await captureSync();
    if (!sameSyncData(current.data, expected.data) ||
        current.restored != expected.restored ||
        current.scope != expected.scope ||
        current.revision != expected.revision ||
        current.payload != expected.payload) {
      throw const DomainError(
        'Данные изменились во время обмена. Повторите проверку; новые записи сохранены.',
      );
    }
  }

  Future<void> finishSync({
    required LocalSyncCapture expected,
    required BackupData data,
    required String scope,
    required int revision,
    required String payload,
    required Future<void> Function(BackupData previous) beforeReplace,
  }) => db.transaction(() async {
    await checkSyncCapture(expected);
    final localPolicy = await readAnalysisPolicy();
    final revisions = await db
        .customSelect(
          "SELECT value FROM settings WHERE key='analysis_revision'",
        )
        .get();
    final revisionBefore = revisions.isEmpty
        ? 0
        : int.parse(revisions.single.read<String>('value'));
    final replacement = !sameSyncData(expected.data, data);
    if (replacement) {
      await replaceData(syncData(data), beforeReplace: beforeReplace);
      final received = await readAnalysisPolicy();
      if (received != null) {
        final preserved = received.copyWith(
          profile: AnalysisProfile.fromJson({
            ...received.profile.toJson(),
            'lastBackupOn': localPolicy?.profile.lastBackupOn == null
                ? null
                : calendarDate(localPolicy!.profile.lastBackupOn!),
          }),
        );
        final version = revisionBefore + 1;
        if (version > 2147483647) {
          throw const DomainError('Достигнут предел версий настроек анализа');
        }
        await db.customStatement(
          "INSERT OR REPLACE INTO settings(key,value) VALUES('analysis_policy',?)",
          [jsonEncode(preserved.toJson())],
        );
        await db.customStatement(
          "INSERT OR REPLACE INTO settings(key,value) VALUES('analysis_revision',?)",
          ['$version'],
        );
      }
    }
    await db.customStatement('DELETE FROM outbox');
    await db.customStatement(
      "DELETE FROM settings WHERE key='sync_restore_required'",
    );
    await db.customStatement(
      'INSERT OR REPLACE INTO sync_state VALUES(1,?,?,?,?)',
      [scope, revision, payload, _now],
    );
  });
}
