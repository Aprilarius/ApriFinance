import 'dart:typed_data';

import 'models.dart';
import 'money.dart';

const maxDocumentBytes = 2 * 1024 * 1024;
const maxStoredDocumentBytes = 8 * 1024 * 1024;

class Purchase {
  const Purchase({
    required this.id,
    required this.name,
    required this.date,
    required this.amountMinor,
    this.store = '',
    this.serial = '',
    this.note = '',
    this.entryId,
    this.returnBy,
    this.warrantyUntil,
    this.archived = false,
    this.version = 1,
  });
  final String id, name, store, serial, note;
  final DateTime date;
  final int amountMinor, version;
  final String? entryId;
  final DateTime? returnBy, warrantyUntil;
  final bool archived;
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'date': calendarDate(date),
    'amountMinor': amountMinor,
    'store': store,
    'serial': serial,
    'note': note,
    'entryId': entryId,
    'returnBy': returnBy == null ? null : calendarDate(returnBy!),
    'warrantyUntil': warrantyUntil == null
        ? null
        : calendarDate(warrantyUntil!),
    'archived': archived,
    'version': version,
  };
  factory Purchase.fromJson(Map<String, Object?> j) => Purchase(
    id: j['id']! as String,
    name: j['name']! as String,
    date: parseCalendarDate(j['date']! as String),
    amountMinor: j['amountMinor']! as int,
    store: j['store']! as String,
    serial: j['serial']! as String,
    note: j['note']! as String,
    entryId: j['entryId'] as String?,
    returnBy: j['returnBy'] == null
        ? null
        : parseCalendarDate(j['returnBy']! as String),
    warrantyUntil: j['warrantyUntil'] == null
        ? null
        : parseCalendarDate(j['warrantyUntil']! as String),
    archived: j['archived']! as bool,
    version: j['version']! as int,
  );
}

void validatePurchase(Purchase p) {
  if (p.id.isEmpty ||
      p.id.length > 100 ||
      p.name.trim().isEmpty ||
      p.name.length > 100 ||
      p.store.length > 100 ||
      p.serial.length > 100 ||
      p.note.length > 500 ||
      p.version < 1 ||
      p.version > 2147483647 ||
      p.amountMinor <= 0 ||
      p.amountMinor > maxMoneyMinor ||
      (p.entryId != null && (p.entryId!.isEmpty || p.entryId!.length > 100))) {
    throw const DomainError('Проверьте название, стоимость и описание покупки');
  }
  for (final date in [p.date, p.returnBy, p.warrantyUntil].nonNulls) {
    if (date.year < 2000 ||
        date.year > 2100 ||
        date != DateTime(date.year, date.month, date.day)) {
      throw const DomainError('Укажите дату между 2000 и 2100 годом');
    }
  }
  if ((p.returnBy?.isBefore(p.date) ?? false) ||
      (p.warrantyUntil?.isBefore(p.date) ?? false)) {
    throw const DomainError('Срок не может быть раньше даты покупки');
  }
}

class PurchaseDocument {
  const PurchaseDocument({
    required this.id,
    required this.purchaseId,
    required this.name,
    required this.mime,
    required this.size,
    required this.version,
  });
  final String id, purchaseId, name, mime;
  final int size, version;
}

/// Only supported document formats are accepted. Never use a filename as a path.
String documentMime(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > maxDocumentBytes) {
    throw const DomainError('Размер документа: до 2 МБ');
  }
  bool prefix(List<int> signature) =>
      bytes.length >= signature.length &&
      List.generate(
        signature.length,
        (i) => bytes[i] == signature[i],
      ).every((v) => v);
  if (prefix([137, 80, 78, 71, 13, 10, 26, 10])) return 'image/png';
  if (prefix([255, 216, 255])) return 'image/jpeg';
  if (prefix([37, 80, 68, 70, 45])) return 'application/pdf';
  throw const DomainError('Выберите JPEG, PNG или PDF');
}

String documentExtension(String mime) => switch (mime) {
  'image/png' => 'png',
  'image/jpeg' => 'jpg',
  _ => 'pdf',
};
