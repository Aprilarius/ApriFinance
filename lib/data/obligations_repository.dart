part of 'finance_repository.dart';

extension ObligationOperations on FinanceRepository {
  Future<void> _writeObligation(Obligation o) async {
    validateObligation(o);
    await db.customStatement(
      '''INSERT INTO obligations VALUES (?,?,?,NULL,?)
      ON CONFLICT(id) DO UPDATE SET body=excluded.body,version=excluded.version,updated_at=excluded.updated_at''',
      [o.id, jsonEncode(o.toJson()), o.version, _now],
    );
    await _enqueue('obligation', o.id, o.version, {
      ...o.toJson(),
      'updatedAt': _now,
    });
  }

  Future<void> saveObligation(Obligation value, {int? expectedVersion}) =>
      db.transaction(() async {
        final snapshot = await load();
        if (snapshot.currency == null) {
          throw const DomainError('Сначала выберите валюту');
        }
        final previous = snapshot.obligations
            .where((o) => o.id == value.id)
            .firstOrNull;
        if ((previous == null && expectedVersion != null) ||
            (previous != null && previous.version != expectedVersion)) {
          throw const DomainError('Платёж изменился. Откройте его заново');
        }
        if (value.accountId != null &&
            !snapshot.accounts.any((a) => a.id == value.accountId)) {
          throw const DomainError('Счёт не найден');
        }
        final history = await db
            .customSelect('SELECT obligation_id FROM settlements')
            .get();
        if (previous != null &&
            history.any((r) => r.read<String>('obligation_id') == value.id) &&
            (calendarDate(previous.anchor) != calendarDate(value.anchor) ||
                previous.repeat != value.repeat ||
                previous.kind != value.kind)) {
          throw const DomainError(
            'После первой оплаты или пропуска нельзя менять начальную дату, тип и периодичность. Создайте новый платёж.',
          );
        }
        final o = Obligation.fromJson({
          ...value.toJson(),
          'name': value.name.trim(),
          'category': value.category.trim(),
          'manageUrl': value.manageUrl.trim(),
          'nextIndex': previous?.nextIndex ?? 0,
          'version': (previous?.version ?? 0) + 1,
        });
        await _writeObligation(o);
      });

  Future<void> settleObligation(
    String id, {
    required int expectedVersion,
    required int periodIndex,
    required DateTime paidOn,
    int? amountMinor,
    String? accountId,
    bool skip = false,
  }) => db.transaction(() async {
    final snapshot = await load();
    final o = snapshot.obligations.where((o) => o.id == id).firstOrNull;
    if (o == null ||
        o.version != expectedVersion ||
        o.nextIndex != periodIndex) {
      throw const DomainError(
        'Этот период уже обработан или платёж изменён. Обновите список.',
      );
    }
    if (!o.active) throw const DomainError('Платёж приостановлен или завершён');
    final settlementId = '$id:$periodIndex';
    if (snapshot.settlements.any((s) => s.id == settlementId)) {
      throw const DomainError('Этот период уже обработан');
    }
    String? entryId;
    if (!skip) {
      final source = accountId ?? o.accountId;
      if (source == null) throw const DomainError('Выберите счёт');
      entryId = await saveEntry(
        kind: o.kind,
        amountMinor: amountMinor ?? o.amountMinor,
        date: paidOn,
        accountId: source,
        category: o.category,
        note: o.name,
      );
    }
    final history = await db
        .customSelect('SELECT id,version FROM settlements')
        .get();
    final old = history
        .where((r) => r.read<String>('id') == settlementId)
        .firstOrNull;
    final version = (old?.read<int>('version') ?? 0) + 1;
    final due = calendarDate(periodDate(o, periodIndex));
    await db.customStatement(
      '''INSERT INTO settlements VALUES (?,?,?,?,?,?,?,NULL,?)
      ON CONFLICT(id) DO UPDATE SET entry_id=excluded.entry_id,status=excluded.status,
      version=excluded.version,deleted_at=NULL,updated_at=excluded.updated_at''',
      [
        settlementId,
        id,
        periodIndex,
        due,
        entryId,
        skip ? 'skipped' : 'paid',
        version,
        _now,
      ],
    );
    await _enqueue('settlement', settlementId, version, {
      'id': settlementId,
      'obligationId': id,
      'periodIndex': periodIndex,
      'dueDate': due,
      'entryId': entryId,
      'status': skip ? 'skipped' : 'paid',
      'version': version,
    });
    await _writeObligation(
      Obligation.fromJson({
        ...o.toJson(),
        'nextIndex': o.nextIndex + 1,
        'version': o.version + 1,
      }),
    );
  });

  Future<void> undoSettlement(Settlement settlement) => db.transaction(
    () async {
      final snapshot = await load();
      final current = snapshot.settlements
          .where((s) => s.id == settlement.id)
          .firstOrNull;
      final o = snapshot.obligations
          .where((o) => o.id == settlement.obligationId)
          .firstOrNull;
      if (current == null ||
          current.version != settlement.version ||
          o == null ||
          current.periodIndex != o.nextIndex - 1) {
        throw const DomainError(
          'Можно отменить только последний обработанный период этого платежа. Обновите список.',
        );
      }
      await db.customStatement(
        'UPDATE settlements SET deleted_at=?,updated_at=?,version=? WHERE id=?',
        [_now, _now, current.version + 1, current.id],
      );
      if (current.entryId != null) {
        await deleteEntry(
          snapshot.entries.singleWhere((e) => e.id == current.entryId),
        );
      }
      await _enqueue('settlement', current.id, current.version + 1, {
        'id': current.id,
        'deletedAt': _now,
        'version': current.version + 1,
      });
      await _writeObligation(
        Obligation.fromJson({
          ...o.toJson(),
          'nextIndex': current.periodIndex,
          'version': o.version + 1,
        }),
      );
    },
  );
}
