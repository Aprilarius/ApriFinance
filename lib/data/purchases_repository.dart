part of 'finance_repository.dart';

extension PurchaseOperations on FinanceRepository {
  /// An existing expense is linked without inserting another ledger entry.
  /// Creating a new expense is explicit and shares this transaction.
  Future<void> savePurchase(
    Purchase value, {
    int? expectedVersion,
    String? newExpenseAccountId,
  }) => db.transaction(() async {
    validatePurchase(value);
    final s = await load();
    if (s.currency == null) throw const DomainError('Сначала выберите валюту');
    final old = s.purchases.where((p) => p.id == value.id).firstOrNull;
    final rows = await db.customSelect('SELECT id FROM purchases').get();
    if ((old == null &&
            (expectedVersion != null ||
                rows.any((r) => r.read<String>('id') == value.id))) ||
        (old != null && old.version != expectedVersion)) {
      throw const DomainError(
        'Покупка уже изменена или удалена. Откройте её заново',
      );
    }
    String? entryId = value.entryId;
    if (newExpenseAccountId != null) {
      if (entryId != null || old != null) {
        throw const DomainError(
          'Новый расход создаётся только для новой покупки',
        );
      }
      entryId = await saveEntry(
        kind: EntryKind.expense,
        amountMinor: value.amountMinor,
        date: value.date,
        accountId: newExpenseAccountId,
        category: 'Покупки',
        note: value.name.trim(),
      );
    }
    if (entryId != null) {
      final entries = (await load()).entries;
      final e = entries.where((e) => e.id == entryId).firstOrNull;
      if (e == null ||
          e.kind != EntryKind.expense ||
          e.amountMinor != value.amountMinor) {
        throw const DomainError(
          'Стоимость покупки должна совпадать с выбранным расходом',
        );
      }
      if (s.purchases.any((p) => p.id != value.id && p.entryId == entryId)) {
        throw const DomainError('Этот расход уже связан с другой покупкой');
      }
    }
    final p = Purchase.fromJson({
      ...value.toJson(),
      'entryId': entryId,
      'name': value.name.trim(),
      'store': value.store.trim(),
      'serial': value.serial.trim(),
      'note': value.note.trim(),
      'version': (old?.version ?? 0) + 1,
    });
    await db.customStatement(
      '''INSERT INTO purchases VALUES (?,?,?,?,NULL,?)
      ON CONFLICT(id) DO UPDATE SET body=excluded.body,entry_id=excluded.entry_id,
      version=excluded.version,updated_at=excluded.updated_at''',
      [p.id, jsonEncode(p.toJson()), p.entryId, p.version, _now],
    );
    await _enqueue('purchase', p.id, p.version, {
      ...p.toJson(),
      'updatedAt': _now,
    });
  });

  Future<void> deletePurchase(Purchase p) => db.transaction(() async {
    final s = await load();
    if (!s.purchases.any((v) => v.id == p.id && v.version == p.version)) {
      throw const DomainError('Покупка уже изменена или удалена');
    }
    for (final d in s.documents.where((d) => d.purchaseId == p.id)) {
      await deleteDocument(d);
    }
    await db.customStatement(
      'UPDATE purchases SET deleted_at=?,updated_at=?,version=? WHERE id=?',
      [_now, _now, p.version + 1, p.id],
    );
    await _enqueue('purchase', p.id, p.version + 1, {
      'id': p.id,
      'version': p.version + 1,
      'deletedAt': _now,
    });
    // Removing a purchase card never changes money or removes its expense.
  });

  Future<void> addDocument(
    String purchaseId,
    String name,
    Uint8List bytes,
  ) => db.transaction(() async {
    final mime = documentMime(bytes);
    final clean = name.trim();
    if (clean.isEmpty ||
        clean.length > 120 ||
        RegExp(r'[\\/\x00-\x1f]').hasMatch(clean)) {
      throw const DomainError(
        'Имя документа: до 120 символов без разделителей пути',
      );
    }
    final s = await load();
    if (!s.purchases.any((p) => p.id == purchaseId)) {
      throw const DomainError('Покупка удалена');
    }
    if (s.documents.fold(0, (n, d) => n + d.size) + bytes.length >
        maxStoredDocumentBytes) {
      throw const DomainError(
        'Документы занимают больше 8 МБ. Сохраните и удалите ненужные вложения',
      );
    }
    final id = newId();
    await db.customStatement(
      'INSERT INTO documents VALUES (?,?,?,?,?,?,1,NULL,?)',
      [id, purchaseId, clean, mime, bytes.length, base64Encode(bytes), _now],
    );
    await _enqueue('document', id, 1, {
      'id': id,
      'purchaseId': purchaseId,
      'name': clean,
      'mime': mime,
      'size': bytes.length,
      'version': 1,
      'updatedAt': _now,
    });
  });

  Future<Uint8List> readDocument(PurchaseDocument d) async {
    final rows = await db
        .customSelect(
          'SELECT data,version FROM documents WHERE id=? AND deleted_at IS NULL',
          variables: [Variable<String>(d.id)],
        )
        .get();
    if (rows.isEmpty || rows.single.read<int>('version') != d.version) {
      throw const DomainError('Документ уже удалён или изменён');
    }
    return base64Decode(rows.single.read<String>('data'));
  }

  Future<void> deleteDocument(PurchaseDocument d) => db.transaction(() async {
    final s = await load();
    if (!s.documents.any((v) => v.id == d.id && v.version == d.version)) {
      throw const DomainError('Документ уже изменён или удалён');
    }
    await db.customStatement(
      "UPDATE documents SET data='',deleted_at=?,updated_at=?,version=? WHERE id=?",
      [_now, _now, d.version + 1, d.id],
    );
    await _enqueue('document', d.id, d.version + 1, {
      'id': d.id,
      'version': d.version + 1,
      'deletedAt': _now,
    });
  });
}
