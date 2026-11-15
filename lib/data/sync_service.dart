import 'dart:convert';
import 'dart:typed_data';

import '../domain/backup_data.dart';
import '../domain/models.dart';
import '../domain/sync_merge.dart';
import 'finance_repository.dart';
import 'backup_service.dart';
import 'cloud_transport.dart';

enum SyncChoice { local, cloud }

class SyncUnlockError extends DomainError {
  const SyncUnlockError(super.message);
}

class SyncPreview {
  const SyncPreview._({
    required this.local,
    required this.remote,
    required this.cloudData,
    required this.merged,
    required this.conflicts,
    required this.scope,
    required this._password,
  });
  final String _password;
  final LocalSyncCapture local;
  final RemoteSnapshot? remote;
  final BackupData? cloudData, merged;
  final List<String> conflicts;
  final String scope;
  bool get needsChoice => merged == null;
  int get revision => remote?.revision ?? 0;
}

class SyncService {
  SyncService(this.repository, this.backup, this.remote);
  final FinanceRepository repository;
  final BackupService backup;
  final SnapshotRemote remote;
  bool _busy = false;
  Future<BackupData> _openEncrypted(String payload, String password) async {
    try {
      return await backup.inspect(
        Uint8List.fromList(utf8.encode(payload)),
        password,
      );
    } on DomainError catch (e) {
      throw SyncUnlockError(e.message);
    }
  }

  Future<SyncPreview> preview(String password) async {
    final scope = remote.scope;
    final local = await repository.captureSync();
    final snapshot = await remote.read();
    final cloud = snapshot == null
        ? null
        : syncData(await _openEncrypted(snapshot.payload, password));
    BackupData? base;
    if (local.scope == scope && local.payload != null) {
      base = local.payload == snapshot?.payload
          ? cloud
          : syncData(await _openEncrypted(local.payload!, password));
    }
    BackupData? merged;
    var conflicts = <String>[];
    if (local.scope == scope &&
        snapshot != null &&
        local.revision != null &&
        (snapshot.revision < local.revision! ||
            (snapshot.revision == local.revision &&
                snapshot.payload != local.payload))) {
      conflicts = ['Серверная версия откатилась или изменилась вне протокола'];
    } else if (local.restored ||
        (local.scope != null && local.scope != scope)) {
      conflicts = [
        'После восстановления или смены аккаунта выберите исходную версию',
      ];
    } else if (cloud == null) {
      if (base == null) {
        merged = local.data;
      } else {
        conflicts = ['Ранее подключённая облачная копия отсутствует'];
      }
    } else if (sameSyncData(local.data, cloud)) {
      merged = cloud;
    } else if (base != null) {
      final result = mergeSyncData(base, local.data, cloud);
      merged = result.data;
      conflicts = result.conflicts;
    } else if (!hasFinanceData(local.data) &&
        (local.data.currency == null ||
            local.data.currency == cloud.currency)) {
      merged = cloud;
    } else {
      conflicts = [
        'На обоих устройствах уже есть данные. Выберите исходную версию',
      ];
    }
    return SyncPreview._(
      local: local,
      remote: snapshot,
      cloudData: cloud,
      merged: merged,
      conflicts: List.unmodifiable(conflicts),
      scope: scope,
      password: password,
    );
  }

  Future<void> commit(
    SyncPreview plan,
    String password, {
    SyncChoice? choice,
  }) async {
    if (_busy) throw const DomainError('Обмен уже выполняется');
    _busy = true;
    try {
      if (remote.scope != plan.scope) {
        throw const DomainError('Аккаунт изменился. Повторите проверку');
      }
      final data = choice == SyncChoice.local
          ? plan.local.data
          : choice == SyncChoice.cloud
          ? plan.cloudData
          : plan.merged;
      if (data == null) {
        throw const DomainError('Выберите версию для продолжения');
      }
      if (password != plan._password) {
        throw const DomainError(
          'Пароль изменился после проверки. Проверьте данные заново.',
        );
      }
      // Re-read before any write. CAS below closes the remaining concurrent-write window.
      final current = await remote.read();
      if (current?.revision != plan.remote?.revision ||
          current?.payload != plan.remote?.payload) {
        throw const CloudChanged();
      }
      await repository.checkSyncCapture(plan.local);
      final upload =
          plan.cloudData == null || !sameSyncData(data, plan.cloudData!);
      var payload = plan.remote?.payload;
      var revision = plan.revision;
      if (upload) {
        payload = utf8.decode(await backup.encode(syncData(data), password));
        // A manual replacement preserves the losing cloud version before CAS.
        if (choice == SyncChoice.local && plan.remote != null) {
          await backup.saveRecoveryBytes(
            Uint8List.fromList(utf8.encode(plan.remote!.payload)),
          );
        }
        await repository.checkSyncCapture(plan.local);
        revision = await remote.write(plan.revision, payload);
      }
      await repository.finishSync(
        expected: plan.local,
        data: data,
        scope: plan.scope,
        revision: revision,
        payload: payload!,
        beforeReplace: (previous) async {
          await backup.saveRecovery(previous, password);
        },
      );
    } finally {
      _busy = false;
    }
  }
}
