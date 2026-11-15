import 'dart:convert';
import 'dart:typed_data';
import 'dart:isolate';

import '../domain/purchases.dart';
import '../domain/sync_merge.dart';

import 'package:uuid/uuid.dart';
import 'package:drift/drift.dart' show Variable;

import '../domain/ledger_math.dart';
import '../domain/models.dart';
import '../domain/backup_data.dart';
import '../domain/money.dart';
import 'ledger_database.dart';
import '../domain/schedule_math.dart';
import '../domain/insights/insight.dart';
import '../domain/insights/analysis_profile.dart';

export '../domain/models.dart' show supportedCurrencies, accountKinds;

part 'obligations_repository.dart';
part 'purchases_repository.dart';
part 'sync_repository.dart';
part 'analysis_repository.dart';

const expenseCategories = [
  'Продукты',
  'Дом',
  'Транспорт',
  'Кафе и доставка',
  'Подписки',
  'Здоровье',
  'Покупки',
  'Отдых',
  'Другое',
];
const incomeCategories = ['Зарплата', 'Подработка', 'Подарки', 'Другое'];

class FinanceRepository {
  FinanceRepository(this.db, {DateTime Function()? clock})
    : clock = clock ?? DateTime.now;
  final LedgerDatabase db;
  final DateTime Function() clock;
  static const _uuid = Uuid();
  String newId() => _uuid.v4();
  String get _now => clock().toUtc().toIso8601String();

  Future<LedgerSnapshot> load() => db.transaction(() async {
    final accountRows = await db
        .customSelect('SELECT * FROM accounts ORDER BY rowid')
        .get();
    final entryRows = await db
        .customSelect('SELECT body FROM entries WHERE deleted_at IS NULL')
        .get();
    final currencyRows = await db
        .customSelect("SELECT value FROM settings WHERE key = 'currency'")
        .get();
    final count = await db
        .customSelect("SELECT COUNT(*) AS count FROM outbox")
        .getSingle();
    final budgetRows = await db
        .customSelect(
          'SELECT * FROM budgets WHERE deleted_at IS NULL ORDER BY category',
        )
        .get();
    final obligationRows = await db
        .customSelect(
          'SELECT body FROM obligations WHERE deleted_at IS NULL ORDER BY rowid',
        )
        .get();
    final settlementRows = await db
        .customSelect(
          'SELECT * FROM settlements WHERE deleted_at IS NULL ORDER BY due_date DESC',
        )
        .get();
    final purchaseRows = await db
        .customSelect(
          'SELECT body FROM purchases WHERE deleted_at IS NULL ORDER BY rowid DESC',
        )
        .get();
    final documentRows = await db
        .customSelect(
          'SELECT id, purchase_id, name, mime, size, version FROM documents WHERE deleted_at IS NULL',
        )
        .get();
    return LedgerSnapshot(
      purchases: purchaseRows.map(
        (r) => Purchase.fromJson(
          (jsonDecode(r.read<String>('body')) as Map<String, dynamic>)
              .cast<String, Object?>(),
        ),
      ),
      documents: documentRows.map(
        (r) => PurchaseDocument(
          id: r.read<String>('id'),
          purchaseId: r.read<String>('purchase_id'),
          name: r.read<String>('name'),
          mime: r.read<String>('mime'),
          size: r.read<int>('size'),
          version: r.read<int>('version'),
        ),
      ),
      obligations: obligationRows.map(
        (r) => Obligation.fromJson(
          (jsonDecode(r.read<String>('body')) as Map<String, dynamic>)
              .cast<String, Object?>(),
        ),
      ),
      settlements: settlementRows.map(
        (r) => Settlement(
          id: r.read<String>('id'),
          obligationId: r.read<String>('obligation_id'),
          periodIndex: r.read<int>('period_index'),
          dueDate: parseCalendarDate(r.read<String>('due_date')),
          entryId: r.readNullable<String>('entry_id'),
          skipped: r.read<String>('status') == 'skipped',
          version: r.read<int>('version'),
        ),
      ),
      accounts: accountRows.map(
        (r) => Account(
          id: r.read<String>('id'),
          name: r.read<String>('name'),
          kind: r.read<String>('kind'),
          openingMinor: r.read<int>('opening_minor'),
          archived: r.read<int>('archived') != 0,
          version: r.read<int>('version'),
        ),
      ),
      entries: entryRows.map(
        (r) => LedgerEntry.fromJson(
          (jsonDecode(r.read<String>('body')) as Map<String, dynamic>)
              .cast<String, Object?>(),
        ),
      ),
      currency: currencyRows.isEmpty
          ? null
          : currencyRows.first.read<String>('value'),
      pendingChanges: count.read<int>('count'),
      budgets: budgetRows.map(
        (r) => CategoryBudget(
          id: r.read<String>('id'),
          month: r.read<String>('month'),
          category: r.read<String>('category'),
          limitMinor: r.read<int>('limit_minor'),
          version: r.read<int>('version'),
        ),
      ),
    );
  });

  Future<void> setCurrency(String currency) => db.transaction(() async {
    if (!supportedCurrencies.contains(currency)) {
      throw const DomainError('Выберите валюту');
    }
    final current = await load();
    if (current.currency == currency) return;
    final analysis = await readAnalysisPolicy();
    if (analysis?.profile.hasMonetaryInputs ?? false) {
      throw const DomainError(
        'После настройки денежных целей, долгов или резервов валюту базы изменить нельзя.',
      );
    }
    // Include tombstones: deleting a plan must not reinterpret its history.
    final history = await db.customSelect('''
      SELECT 1 FROM accounts UNION ALL SELECT 1 FROM budgets
      UNION ALL SELECT 1 FROM obligations UNION ALL SELECT 1 FROM purchases
      LIMIT 1
    ''').get();
    if (history.isNotEmpty) {
      throw const DomainError(
        'После создания счетов, лимитов, платежей или покупок валюту базы изменить нельзя',
      );
    }
    await db.customStatement(
      'INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)',
      ['currency', currency],
    );
  });

  Future<BackupData> exportData() => db.transaction(() async {
    final tables = <String, Object?>{};
    for (final table in BackupData.columns.keys) {
      final rows = await db
          .customSelect('SELECT * FROM $table ORDER BY rowid')
          .get();
      tables[table] = rows.map((r) => r.data).toList();
    }
    final hasAnalysis = (tables['settings']! as List).any(
      (r) => (r as Map)['key'] == 'analysis_policy',
    );
    return BackupData.fromJson({
      'schema': hasAnalysis ? 5 : 4,
      'tables': tables,
    });
  });

  /// Hold the transaction while writing the recovery copy so no local operation
  /// can slip between the safety snapshot and replacement.
  Future<void> replaceData(
    BackupData data, {
    required Future<void> Function(BackupData previous) beforeReplace,
  }) => db.transaction(() async {
    final previous = await exportData();
    await beforeReplace(previous);
    await db.customStatement('PRAGMA defer_foreign_keys = ON');
    for (final table in [
      'outbox',
      'documents',
      'purchases',
      'settlements',
      'entries',
      'obligations',
      'budgets',
      'accounts',
      'settings',
    ]) {
      await db.customStatement('DELETE FROM $table');
    }
    for (final table in BackupData.columns.entries) {
      for (final row in data.tables[table.key]!) {
        await db.customStatement(
          'INSERT INTO ${table.key} (${table.value.join(',')}) VALUES (${List.filled(table.value.length, '?').join(',')})',
          table.value.map((key) => row[key]).toList(),
        );
      }
    }
    // A future sync implementation must reconcile a restored ledger explicitly.
    await db.customStatement(
      "INSERT OR REPLACE INTO settings VALUES ('sync_restore_required', 'true')",
    );
  });

  Future<void> _enqueue(
    String type,
    String id,
    int version,
    Map<String, Object?> payload,
  ) => db.customStatement('INSERT INTO outbox VALUES (?, ?, ?, ?, ?, ?)', [
    newId(),
    type,
    id,
    version,
    jsonEncode(payload),
    _now,
  ]);

  /// Check affected balances inside the same transaction, including former
  /// transfer endpoints. Old unrelated invalid archives remain repairable.
  Future<void> _checkArchivedBalances(Set<String?> affected) async {
    final snapshot = await load();
    final balances = accountBalances(snapshot);
    final currentBalances = accountBalances(
      snapshot,
      through: dayOnly(clock()),
    );
    if (snapshot.accounts.any(
      (a) =>
          affected.contains(a.id) &&
          a.archived &&
          (balances[a.id] != 0 || currentBalances[a.id] != 0),
    )) {
      throw const DomainError(
        'В архиве может быть только счёт с нулевым балансом. Для изменения его истории сначала верните счёт из архива.',
      );
    }
  }

  Future<void> saveAccount({
    String? id,
    required String name,
    required String kind,
    required int openingMinor,
    int? expectedVersion,
    bool archived = false,
  }) => db.transaction(() async {
    final snapshot = await load();
    if (snapshot.currency == null) {
      throw const DomainError('Сначала выберите валюту');
    }
    final cleaned = name.trim();
    if (cleaned.isEmpty || cleaned.length > 60) {
      throw const DomainError('Название счёта: от 1 до 60 символов');
    }
    if (!accountKinds.contains(kind)) {
      throw const DomainError('Неизвестный тип счёта');
    }
    if (openingMinor.abs() > maxMoneyMinor) {
      throw const DomainError('Сумма слишком велика');
    }
    if (snapshot.accounts.any(
      (a) => a.id != id && a.name.toLowerCase() == cleaned.toLowerCase(),
    )) {
      throw const DomainError('Счёт с таким названием уже есть');
    }
    Account? previous;
    if (id != null) {
      previous = snapshot.accounts.where((a) => a.id == id).firstOrNull;
      if (previous == null || previous.version != expectedVersion) {
        throw const DomainError('Счёт изменился. Откройте его заново');
      }
    }
    final accountId = id ?? newId();
    final version = (previous?.version ?? 0) + 1;
    await db.customStatement(
      '''INSERT INTO accounts VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET name=excluded.name, kind=excluded.kind,
      opening_minor=excluded.opening_minor, archived=excluded.archived,
      version=excluded.version, updated_at=excluded.updated_at''',
      [accountId, cleaned, kind, openingMinor, archived ? 1 : 0, version, _now],
    );
    await _checkArchivedBalances({accountId});
    await _enqueue('account', accountId, version, {
      'id': accountId,
      'name': cleaned,
      'kind': kind,
      'openingMinor': openingMinor,
      'archived': archived,
      'version': version,
      'updatedAt': _now,
    });
  });

  Future<String> saveEntry({
    String? id,
    int? expectedVersion,
    required EntryKind kind,
    required int amountMinor,
    required DateTime date,
    required String accountId,
    String? targetAccountId,
    String category = '',
    String note = '',
    String? refundOf,
  }) => db.transaction(() async {
    final snapshot = await load();
    if (amountMinor <= 0 || amountMinor > maxMoneyMinor) {
      throw const DomainError('Сумма должна быть больше нуля');
    }
    if (date.year < 2000 || date.year > 2100) {
      throw const DomainError('Дата должна быть между 2000 и 2100 годом');
    }
    final account = snapshot.accounts
        .where((a) => a.id == accountId)
        .firstOrNull;
    if (account == null || account.archived) {
      throw const DomainError('Выберите действующий счёт');
    }
    if (note.trim().length > 500) {
      throw const DomainError('Комментарий: не больше 500 символов');
    }
    final previous = snapshot.entries.where((e) => e.id == id).firstOrNull;
    if (id != null &&
        (previous == null || previous.version != expectedVersion)) {
      throw const DomainError('Операция изменена или удалена. Обновите журнал');
    }
    if (id != null && snapshot.entries.any((e) => e.refundOf == id)) {
      throw const DomainError('Сначала удалите связанные возвраты');
    }
    if (id != null && snapshot.purchases.any((p) => p.entryId == id)) {
      throw const DomainError(
        'Расход связан с покупкой. Сначала уберите связь в карточке покупки.',
      );
    }
    if (id != null && snapshot.settlements.any((s) => s.entryId == id)) {
      throw const DomainError(
        'Операция связана с платежом. Сначала отмените оплату в разделе «Платежи».',
      );
    }
    if (kind == EntryKind.transfer) {
      final target = snapshot.accounts
          .where((a) => a.id == targetAccountId)
          .firstOrNull;
      if (target == null || target.archived || target.id == accountId) {
        throw const DomainError(
          'Для перевода выберите два разных действующих счёта',
        );
      }
      category = '';
      refundOf = null;
    } else {
      targetAccountId = null;
      if (kind == EntryKind.refund) {
        final original = snapshot.entries
            .where((e) => e.id == refundOf)
            .firstOrNull;
        if (original == null ||
            original.kind != EntryKind.expense ||
            original.id == id) {
          throw const DomainError('Выберите исходный расход для возврата');
        }
        final refunded = snapshot.entries
            .where((e) => e.refundOf == original.id && e.id != id)
            .fold(0, (sum, e) => sum + e.amountMinor);
        if (refunded + amountMinor > original.amountMinor) {
          throw const DomainError('Возврат превышает оставшуюся сумму расхода');
        }
        category = original.category;
      } else {
        refundOf = null;
      }
      category = category.trim();
      if (category.isEmpty || category.length > 60) {
        throw const DomainError('Укажите категорию: до 60 символов');
      }
    }
    final entry = LedgerEntry(
      id: id ?? newId(),
      kind: kind,
      amountMinor: amountMinor,
      date: DateTime(date.year, date.month, date.day),
      accountId: accountId,
      targetAccountId: targetAccountId,
      category: category,
      note: note.trim(),
      refundOf: refundOf,
      version: (previous?.version ?? 0) + 1,
    );
    await db.customStatement(
      '''INSERT INTO entries VALUES (?, ?, ?, ?, ?, ?, NULL, ?)
      ON CONFLICT(id) DO UPDATE SET body=excluded.body, account_id=excluded.account_id,
      target_account_id=excluded.target_account_id, refund_of=excluded.refund_of,
      version=excluded.version, updated_at=excluded.updated_at''',
      [
        entry.id,
        jsonEncode(entry.toJson()),
        accountId,
        targetAccountId,
        refundOf,
        entry.version,
        _now,
      ],
    );
    await _checkArchivedBalances({
      accountId,
      targetAccountId,
      previous?.accountId,
      previous?.targetAccountId,
    });
    await _enqueue('entry', entry.id, entry.version, {
      ...entry.toJson(),
      'updatedAt': _now,
    });
    return entry.id;
  });

  Future<void> saveBudget({
    String? id,
    int? expectedVersion,
    required DateTime month,
    required String category,
    required int limitMinor,
  }) => db.transaction(() async {
    final snapshot = await load();
    if (snapshot.currency == null) {
      throw const DomainError('Сначала выберите валюту');
    }
    final clean = category.trim();
    if (clean.isEmpty || clean.length > 60) {
      throw const DomainError('Укажите категорию: до 60 символов');
    }
    if (limitMinor <= 0 || limitMinor > maxMoneyMinor) {
      throw const DomainError('Лимит должен быть больше нуля');
    }
    if (month.year < 2000 || month.year > 2100) {
      throw const DomainError('Недопустимый месяц');
    }
    final key = calendarDate(DateTime(month.year, month.month)).substring(0, 7);
    final analysis = await readAnalysisPolicy();
    if (analysis != null &&
        snapshot.budgets.any(
          (b) =>
              b.id != id &&
              b.month == key &&
              analysis.profile.category(b.category) ==
                  analysis.profile.category(clean),
        )) {
      throw const DomainError(
        'Для этой категории с учётом подтверждённых алиасов уже есть лимит. Измените существующий лимит.',
      );
    }
    final previous = snapshot.budgets.where((b) => b.id == id).firstOrNull;
    if (id != null &&
        (previous == null || previous.version != expectedVersion)) {
      throw const DomainError('Лимит изменился. Откройте его заново');
    }
    if (snapshot.budgets.any(
      (b) =>
          b.id != id &&
          b.month == key &&
          b.category.toLowerCase() == clean.toLowerCase(),
    )) {
      throw const DomainError(
        'Для этой категории уже есть лимит на выбранный месяц',
      );
    }
    final budgetId = id ?? newId();
    final version = (previous?.version ?? 0) + 1;
    await db.customStatement(
      '''INSERT INTO budgets VALUES (?, ?, ?, ?, ?, NULL, ?)
      ON CONFLICT(id) DO UPDATE SET month=excluded.month, category=excluded.category,
      limit_minor=excluded.limit_minor, version=excluded.version, updated_at=excluded.updated_at''',
      [budgetId, key, clean, limitMinor, version, _now],
    );
    await _enqueue('budget', budgetId, version, {
      'id': budgetId,
      'month': key,
      'category': clean,
      'limitMinor': limitMinor,
      'version': version,
      'updatedAt': _now,
    });
  });

  Future<void> deleteBudget(CategoryBudget budget) => db.transaction(() async {
    final snapshot = await load();
    if (!snapshot.budgets.any(
      (b) => b.id == budget.id && b.version == budget.version,
    )) {
      throw const DomainError('Лимит уже изменён или удалён');
    }
    await db.customStatement(
      'UPDATE budgets SET deleted_at=?, updated_at=?, version=? WHERE id=?',
      [_now, _now, budget.version + 1, budget.id],
    );
    await _enqueue('budget', budget.id, budget.version + 1, {
      'id': budget.id,
      'deletedAt': _now,
      'version': budget.version + 1,
    });
  });

  Future<void> deleteEntry(LedgerEntry entry) => db.transaction(() async {
    final snapshot = await load();
    if (snapshot.settlements.any((s) => s.entryId == entry.id)) {
      throw const DomainError(
        'Операция связана с платежом. Сначала отмените оплату в разделе «Платежи».',
      );
    }
    if (snapshot.purchases.any((p) => p.entryId == entry.id)) {
      throw const DomainError(
        'Сначала уберите связь с расходом в карточке покупки.',
      );
    }
    final current = snapshot.entries.where((e) => e.id == entry.id).firstOrNull;
    if (current == null || current.version != entry.version) {
      throw const DomainError('Операция уже изменена');
    }
    if (snapshot.entries.any((e) => e.refundOf == entry.id)) {
      throw const DomainError('Сначала удалите связанные возвраты');
    }
    await db.customStatement(
      'UPDATE entries SET deleted_at=?, updated_at=?, version=? WHERE id=?',
      [_now, _now, entry.version + 1, entry.id],
    );
    await _checkArchivedBalances({current.accountId, current.targetAccountId});
    await _enqueue('entry', entry.id, entry.version + 1, {
      'id': entry.id,
      'deletedAt': _now,
      'version': entry.version + 1,
    });
  });
}
