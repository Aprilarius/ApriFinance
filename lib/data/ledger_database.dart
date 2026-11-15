import 'package:drift/drift.dart';

/// SQL is centralized here; UI never reads or writes the database directly.
/// Entity versions and tombstones reserve a safe path to later synchronization.
class LedgerDatabase extends GeneratedDatabase {
  LedgerDatabase(super.executor);

  @override
  int get schemaVersion => 5;

  Future<void> _createSyncState() =>
      customStatement('''CREATE TABLE sync_state (
    id INTEGER PRIMARY KEY CHECK(id=1), scope TEXT NOT NULL,
    revision INTEGER NOT NULL, payload TEXT NOT NULL, last_at TEXT NOT NULL
  )''');

  Future<void> _createPurchases() async {
    await customStatement('''CREATE TABLE purchases (
      id TEXT PRIMARY KEY, body TEXT NOT NULL, entry_id TEXT REFERENCES entries(id),
      version INTEGER NOT NULL, deleted_at TEXT, updated_at TEXT NOT NULL
    )''');
    await customStatement('''CREATE TABLE documents (
      id TEXT PRIMARY KEY, purchase_id TEXT NOT NULL REFERENCES purchases(id),
      name TEXT NOT NULL, mime TEXT NOT NULL, size INTEGER NOT NULL,
      data TEXT NOT NULL, version INTEGER NOT NULL, deleted_at TEXT, updated_at TEXT NOT NULL
    )''');
  }

  Future<void> _createObligations() async {
    await customStatement('''CREATE TABLE obligations (
      id TEXT PRIMARY KEY, body TEXT NOT NULL, version INTEGER NOT NULL,
      deleted_at TEXT, updated_at TEXT NOT NULL
    )''');
    await customStatement('''CREATE TABLE settlements (
      id TEXT PRIMARY KEY, obligation_id TEXT NOT NULL REFERENCES obligations(id),
      period_index INTEGER NOT NULL, due_date TEXT NOT NULL,
      entry_id TEXT REFERENCES entries(id), status TEXT NOT NULL,
      version INTEGER NOT NULL, deleted_at TEXT, updated_at TEXT NOT NULL,
      UNIQUE(obligation_id, period_index)
    )''');
  }

  Future<void> _createBudgets() => customStatement('''CREATE TABLE budgets (
    id TEXT PRIMARY KEY, month TEXT NOT NULL, category TEXT NOT NULL,
    limit_minor INTEGER NOT NULL CHECK(limit_minor > 0),
    version INTEGER NOT NULL, deleted_at TEXT, updated_at TEXT NOT NULL
  )''');

  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];

  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => const [];

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async {
      await _createBudgets();
      await customStatement('''CREATE TABLE settings (
        key TEXT PRIMARY KEY, value TEXT NOT NULL
      )''');
      await customStatement('''CREATE TABLE accounts (
        id TEXT PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL,
        opening_minor INTEGER NOT NULL, archived INTEGER NOT NULL DEFAULT 0,
        version INTEGER NOT NULL, updated_at TEXT NOT NULL
      )''');
      await customStatement('''CREATE TABLE entries (
        id TEXT PRIMARY KEY, body TEXT NOT NULL,
        account_id TEXT NOT NULL REFERENCES accounts(id),
        target_account_id TEXT REFERENCES accounts(id),
        refund_of TEXT REFERENCES entries(id),
        version INTEGER NOT NULL, deleted_at TEXT, updated_at TEXT NOT NULL
      )''');
      await customStatement('''CREATE TABLE outbox (
        id TEXT PRIMARY KEY, entity_type TEXT NOT NULL, entity_id TEXT NOT NULL,
        version INTEGER NOT NULL, payload TEXT NOT NULL, created_at TEXT NOT NULL
      )''');
      await _createObligations();
      await _createPurchases();
      await _createSyncState();
    },
    onUpgrade: (_, from, to) async {
      if (from < 2) await _createBudgets();
      if (from < 3) await _createObligations();
      if (from < 4) await _createPurchases();
      if (from < 5) await _createSyncState();
    },
    beforeOpen: (_) => customStatement('PRAGMA foreign_keys = ON'),
  );
}
