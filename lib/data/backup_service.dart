import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../domain/backup_data.dart';
import '../domain/models.dart';
import 'backup_codec.dart';
import 'finance_repository.dart';

// Keep isolate closures outside the service: capturing a service method's
// context can inadvertently capture the database connection (not sendable).
Future<Uint8List> _encrypt(BackupData data, String password) =>
    Isolate.run(() => BackupCodec.encrypt(data, password));
Future<BackupData> _decrypt(Uint8List bytes, String password) =>
    Isolate.run(() => BackupCodec.decrypt(bytes, password));

class RecoveryCopy {
  const RecoveryCopy(this.name, this.modified, this.size);
  final String name;
  final DateTime modified;
  final int size;
}

class BackupService {
  BackupService(this.repository, this.recoveryDirectory);
  final FinanceRepository repository;
  final Directory recoveryDirectory;

  Future<Uint8List> create(String password) async {
    final data = await repository.exportData();
    return _encrypt(data, password);
  }

  Future<Uint8List> encode(BackupData data, String password) =>
      _encrypt(data, password);

  Future<File> saveRecovery(BackupData data, String password) async =>
      saveRecoveryBytes(await _encrypt(data, password));

  Future<File> saveRecoveryBytes(Uint8List bytes) async {
    await recoveryDirectory.create(recursive: true);
    final name =
        'before-restore-${DateTime.now().microsecondsSinceEpoch}-${repository.newId()}.mfin';
    final temporary = File(p.join(recoveryDirectory.path, '$name.tmp'));
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      return await temporary.rename(p.join(recoveryDirectory.path, name));
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<BackupData> inspect(Uint8List bytes, String password) =>
      _decrypt(bytes, password);

  Future<Uint8List?> latestRecovery() async {
    final copies = await recoveryCopies();
    return copies.isEmpty ? null : readRecovery(copies.first.name);
  }

  Future<List<RecoveryCopy>> recoveryCopies() async {
    if (!await recoveryDirectory.exists()) return const [];
    final result = <RecoveryCopy>[];
    await for (final entity in recoveryDirectory.list(followLinks: false)) {
      if (entity is! File ||
          !p.basename(entity.path).startsWith('before-restore-') ||
          !entity.path.endsWith('.mfin')) {
        continue;
      }
      final stat = await entity.stat();
      result.add(
        RecoveryCopy(p.basename(entity.path), stat.modified, stat.size),
      );
    }
    result.sort((a, b) => b.name.compareTo(a.name));
    return List.unmodifiable(result);
  }

  Future<Uint8List> readRecovery(String name) async {
    if (p.basename(name) != name ||
        !(await recoveryCopies()).any((c) => c.name == name)) {
      throw const DomainError('Защитная копия не найдена');
    }
    final file = File(p.join(recoveryDirectory.path, name));
    if (await file.length() > BackupCodec.maxFileBytes) {
      throw const DomainError('Копия слишком большая');
    }
    return file.readAsBytes();
  }

  Future<File> restore(BackupData data, String password) async {
    File? recovery;
    await repository.replaceData(
      data,
      beforeReplace: (previous) async {
        recovery = await saveRecovery(previous, password);
      },
    );
    return recovery!;
  }
}
