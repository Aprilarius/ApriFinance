import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/data/finance_repository.dart';
import 'package:personal_finance/data/ledger_database.dart';
import 'package:personal_finance/domain/ledger_math.dart';
import 'package:personal_finance/domain/models.dart';

void main() {
  late LedgerDatabase db;
  late FinanceRepository repo;
  late String source, other;
  final today = DateTime(2026, 11, 14);
  setUp(() async {
    db = LedgerDatabase(NativeDatabase.memory());
    repo = FinanceRepository(db, clock: () => today);
    await repo.setCurrency('USD');
    await repo.saveAccount(name: 'Карта', kind: 'Карта', openingMinor: 10000);
    await repo.saveAccount(name: 'Наличные', kind: 'Наличные', openingMinor: 0);
    final s = await repo.load();
    source = s.accounts.first.id;
    other = s.accounts.last.id;
  });
  tearDown(() => db.close());
  Future<void> archive(String id, {bool value = true}) async {
    final a = (await repo.load()).accounts.singleWhere((a) => a.id == id);
    await repo.saveAccount(
      id: a.id,
      expectedVersion: a.version,
      name: a.name,
      kind: a.kind,
      openingMinor: a.openingMinor,
      archived: value,
    );
  }

  Future<LedgerEntry> spendToZero() async {
    await repo.saveEntry(
      kind: EntryKind.expense,
      amountMinor: 10000,
      date: today,
      accountId: source,
      category: 'Дом',
    );
    await archive(source);
    return (await repo.load()).entries.single;
  }

  Future<void> unchanged(Future<void> Function() mutation) async {
    final before = (await repo.exportData()).toJson();
    await expectLater(mutation(), throwsA(isA<DomainError>()));
    expect((await repo.exportData()).toJson(), before);
  }

  test('future expense cannot make a currently funded account eligible for archive', () async {
    await repo.saveEntry(
      kind: EntryKind.expense,
      amountMinor: 10000,
      date: DateTime(2026, 11, 15),
      accountId: source,
      category: 'Дом',
    );
    expect(accountBalances(await repo.load())[source], 0);
    await unchanged(() => archive(source));
    expect((await repo.load()).accounts.first.archived, isFalse);
  });
  test('new archived account cannot start with nonzero money', () async {
    await unchanged(
      () => repo.saveAccount(
        name: 'Архив',
        kind: 'Карта',
        openingMinor: 1,
        archived: true,
      ),
    );
  });
  test('opening edits cannot revive archived balance; rename and unarchive remain possible', () async {
    await spendToZero();
    var a = (await repo.load()).accounts.first;
    await unchanged(
      () => repo.saveAccount(
        id: a.id,
        expectedVersion: a.version,
        name: a.name,
        kind: a.kind,
        openingMinor: 11000,
        archived: true,
      ),
    );
    await repo.saveAccount(
      id: a.id,
      expectedVersion: a.version,
      name: 'Старая карта',
      kind: a.kind,
      openingMinor: a.openingMinor,
      archived: true,
    );
    a = (await repo.load()).accounts.first;
    await repo.saveAccount(
      id: a.id,
      expectedVersion: a.version,
      name: a.name,
      kind: a.kind,
      openingMinor: 11000,
      archived: false,
    );
    expect(accountBalances(await repo.load())[source], 1000);
  });
  test('deleting history on archived source rolls back; unarchive allows correction', () async {
    final entry = await spendToZero();
    await unchanged(() => repo.deleteEntry(entry));
    await archive(source, value: false);
    await repo.deleteEntry(entry);
    expect(accountBalances(await repo.load())[source], 10000);
  });
  test(
    'moving an old expense out of archived source cannot change its balance',
    () async {
      final entry = await spendToZero();
      await unchanged(
        () => repo.saveEntry(
          id: entry.id,
          expectedVersion: entry.version,
          kind: EntryKind.expense,
          amountMinor: 10000,
          date: today,
          accountId: other,
          category: 'Дом',
        ),
      );
    },
  );
  test(
    'editing or deleting a transfer cannot change an archived former target',
    () async {
      final id = await repo.saveEntry(
        kind: EntryKind.transfer,
        amountMinor: 2000,
        date: today,
        accountId: source,
        targetAccountId: other,
      );
      await repo.saveEntry(
        kind: EntryKind.expense,
        amountMinor: 2000,
        date: today,
        accountId: other,
        category: 'Дом',
      );
      await archive(other);
      final transfer = (await repo.load()).entries.singleWhere(
        (e) => e.id == id,
      );
      await unchanged(
        () => repo.saveEntry(
          id: id,
          expectedVersion: 1,
          kind: EntryKind.expense,
          amountMinor: 2000,
          date: today,
          accountId: source,
          category: 'Дом',
        ),
      );
      await unchanged(() => repo.deleteEntry(transfer));
    },
  );
  test('undoing linked payment on archived account rolls back whole settlement transaction', () async {
    await repo.saveObligation(
      Obligation(
        id: 'payment',
        name: 'Покупка',
        kind: EntryKind.expense,
        amountMinor: 10000,
        category: 'Дом',
        anchor: today,
        repeat: RepeatRule.once,
        accountId: source,
      ),
    );
    await repo.settleObligation(
      'payment',
      expectedVersion: 1,
      periodIndex: 0,
      paidOn: today,
    );
    await archive(source);
    final settled = (await repo.load()).settlements.single;
    await unchanged(() => repo.undoSettlement(settled));
    expect((await repo.load()).obligations.single.nextIndex, 1);
    await archive(source, value: false);
    await repo.undoSettlement(settled);
    expect((await repo.load()).obligations.single.nextIndex, 0);
    expect(accountBalances(await repo.load())[source], 10000);
  });
  test('legacy invalid archive does not block unrelated account; it can be reopened', () async {
    await db.customStatement('UPDATE accounts SET archived=1 WHERE id=?', [
      source,
    ]);
    await repo.saveEntry(
      kind: EntryKind.expense,
      amountMinor: 100,
      date: today,
      accountId: other,
      category: 'Дом',
    );
    await archive(source, value: false);
    expect((await repo.load()).accounts.first.archived, isFalse);
    expect(accountBalances(await repo.load())[other], -100);
  });
}
