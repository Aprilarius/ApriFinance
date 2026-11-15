import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../domain/models.dart';
import 'backup_codec.dart';

abstract interface class BackupFiles {
  Future<Uint8List?> open();
  Future<bool> save(Uint8List bytes, String name);
}

class DeviceBackupFiles implements BackupFiles {
  const DeviceBackupFiles();

  @override
  Future<Uint8List?> open() async {
    final file = await FilePicker.pickFile(
      dialogTitle: 'Открыть резервную копию',
      type: FileType.custom,
      allowedExtensions: ['mfin'],
    );
    if (file == null) return null;
    final size = await file.length();
    if (size != null && size > BackupCodec.maxFileBytes) {
      throw const DomainError('Файл копии слишком большой');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in file.readAsByteStream()) {
      if (builder.length + chunk.length > BackupCodec.maxFileBytes) {
        throw const DomainError('Файл копии слишком большой');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  @override
  Future<bool> save(Uint8List bytes, String name) async =>
      await FilePicker.saveFile(
        fileName: name,
        bytes: bytes,
        dialogTitle: 'Сохранить файл',
      ) !=
      null;
}
