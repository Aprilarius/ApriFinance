import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../domain/models.dart';
import '../domain/purchases.dart';

class PickedDocument {
  const PickedDocument(this.name, this.bytes);
  final String name;
  final Uint8List bytes;
}

abstract interface class DocumentFiles {
  Future<PickedDocument?> pick();
  Future<bool> save(Uint8List bytes, String name);
}

class DeviceDocumentFiles implements DocumentFiles {
  const DeviceDocumentFiles();
  @override
  Future<PickedDocument?> pick() async {
    final file = await FilePicker.pickFile(
      dialogTitle: 'Добавить чек или документ',
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png', 'pdf'],
    );
    if (file == null) return null;
    final size = await file.length();
    if (size != null && size > maxDocumentBytes) {
      throw const DomainError('Размер документа: до 2 МБ');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in file.readAsByteStream()) {
      if (builder.length + chunk.length > maxDocumentBytes) {
        throw const DomainError('Размер документа: до 2 МБ');
      }
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    final mime = documentMime(bytes);
    // Keep the visible name portable and give it the extension of its contents.
    final safe = file.name.replaceAll(RegExp(r'[\\/\x00-\x1f]'), '_');
    final stem = safe.replaceFirst(RegExp(r'\.[^.]*$'), '');
    final short = stem.length > 100 ? stem.substring(0, 100) : stem;
    return PickedDocument(
      '${short.isEmpty ? 'Документ' : short}.${documentExtension(mime)}',
      bytes,
    );
  }

  @override
  Future<bool> save(Uint8List bytes, String name) async =>
      await FilePicker.saveFile(
        fileName: name,
        bytes: bytes,
        dialogTitle: 'Сохранить документ',
      ) !=
      null;
}
