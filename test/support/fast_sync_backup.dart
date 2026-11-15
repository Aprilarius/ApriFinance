import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:personal_finance/data/backup_service.dart';
import 'package:personal_finance/domain/backup_data.dart';
import 'package:personal_finance/domain/models.dart';

/// Test-only envelope. Tests of graph/concurrency behavior avoid repeatedly
/// running PBKDF2. A separate test uses the real encrypted BackupService.
class FastSyncBackup extends BackupService {
  FastSyncBackup(super.repository, super.recoveryDirectory);
  @override
  Future<Uint8List> encode(BackupData data, String password) async =>
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'testPassword': password,
            'testData': base64Encode(utf8.encode(jsonEncode(data.toJson()))),
          }),
        ),
      );
  @override
  Future<BackupData> inspect(Uint8List bytes, String password) async {
    try {
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (json['testPassword'] != password) {
        throw const DomainError('Неверный пароль');
      }
      return BackupData.fromJson(
        jsonDecode(utf8.decode(base64Decode(json['testData']! as String))),
      );
    } on DomainError {
      rethrow;
    } catch (_) {
      throw const DomainError('Повреждённая тестовая копия');
    }
  }

  @override
  Future<File> saveRecovery(BackupData data, String password) async =>
      saveRecoveryBytes(await encode(data, password));
}
