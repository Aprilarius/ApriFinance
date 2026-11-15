import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/data/finance_repository.dart';
import 'package:personal_finance/data/ledger_database.dart';
import 'package:personal_finance/domain/backup_data.dart';
import 'package:personal_finance/domain/ledger_math.dart';
import 'package:personal_finance/domain/models.dart';
import 'package:personal_finance/domain/schedule_math.dart';

void main() {
  late LedgerDatabase db;
  late FinanceRepository repo;
  late String account;
  final today = DateTime(2026, 11, 14);
  Obligation plan({
    String id = 'subscription',
    DateTime? anchor,
    RepeatRule repeat = RepeatRule.monthly,
    EntryKind kind = EntryKind.expense,
  }) => Obligation(
    id: id,
    name: 'Интернет',
    kind: kind,
    amountMinor: 1000,
    category: 'Подписки',
    anchor: anchor ?? today,
    repeat: repeat,
    accountId: account,
  );
  setUp(() async {
    db = LedgerDatabase(NativeDatabase.memory());
    repo = FinanceRepository(db, clock: () => today);
    await repo.setCurrency('USD');
    await repo.saveAccount(name: 'Карта', kind: 'Карта', openingMinor: 10000);
    account = (await repo.load()).accounts.single.id;
  });
  tearDown(() => db.close());

  test('calendar preserves day 31 and Feb 29 anchors, weekly and one-off schedules', () {
    final monthly = plan(anchor: DateTime(2026, 1, 31));
    expect(periodDate(monthly, 1), DateTime(2026, 2, 28));
    expect(periodDate(monthly, 2), DateTime(2026, 3, 31));
    final annual = plan(
      anchor: DateTime(2024, 2, 29),
      repeat: RepeatRule.yearly,
    );
    expect(periodDate(annual, 1), DateTime(2025, 2, 28));
    expect(periodDate(annual, 4), DateTime(2028, 2, 29));
    expect(
      periodDate(
        plan(anchor: DateTime(2026, 12, 30), repeat: RepeatRule.weekly),
        1,
      ),
      DateTime(2027, 1, 6),
    );
    expect(
      occurrences(plan(repeat: RepeatRule.once), today, DateTime(2027)).length,
      1,
    );
  });

  test('planning does not spend money; confirmation creates exactly one entry and advances period', () async {
    await repo.saveObligation(plan());
    var s = await repo.load();
    expect(s.entries, isEmpty);
    expect(accountBalances(s)[account], 10000);
    final first = s.obligations.single;
    await repo.settleObligation(
      first.id,
      expectedVersion: first.version,
      periodIndex: 0,
      paidOn: today,
      amountMinor: 1200,
    );
    s = await repo.load();
    expect(s.entries.single.amountMinor, 1200);
    expect(accountBalances(s)[account], 8800);
    expect(s.obligations.single.nextIndex, 1);
    expect(s.settlements.single.dueDate, today);
    final before = (await repo.exportData()).toJson();
    await expectLater(
      repo.settleObligation(
        first.id,
        expectedVersion: first.version,
        periodIndex: 0,
        paidOn: today,
      ),
      throwsA(isA<DomainError>()),
    );
    expect((await repo.exportData()).toJson(), before);
  });

  test('linked entries cannot be independently changed or deleted; undo is atomic and allows re-confirmation', () async {
    await repo.saveObligation(plan());
    var o = (await repo.load()).obligations.single;
    await repo.settleObligation(
      o.id,
      expectedVersion: o.version,
      periodIndex: 0,
      paidOn: today,
    );
    var s = await repo.load();
    final entry = s.entries.single;
    await expectLater(repo.deleteEntry(entry), throwsA(isA<DomainError>()));
    await expectLater(
      repo.saveEntry(
        id: entry.id,
        expectedVersion: entry.version,
        kind: entry.kind,
        amountMinor: 500,
        date: today,
        accountId: account,
        category: 'Дом',
      ),
      throwsA(isA<DomainError>()),
    );
    await repo.undoSettlement(s.settlements.single);
    s = await repo.load();
    expect(s.entries, isEmpty);
    expect(s.obligations.single.nextIndex, 0);
    expect(accountBalances(s)[account], 10000);
    o = s.obligations.single;
    await repo.settleObligation(
      o.id,
      expectedVersion: o.version,
      periodIndex: 0,
      paidOn: today,
    );
    s = await repo.load();
    expect(s.entries.length, 1);
    expect(s.settlements.single.version, 3);
    expect((await repo.exportData()).tables['entries']!.length, 2);
  });

  test(
    'refund prevents undo until removed, without partial cancellation',
    () async {
      await repo.saveObligation(plan());
      final o = (await repo.load()).obligations.single;
      await repo.settleObligation(
        o.id,
        expectedVersion: o.version,
        periodIndex: 0,
        paidOn: today,
      );
      var s = await repo.load();
      final entry = s.entries.single;
      await repo.saveEntry(
        kind: EntryKind.refund,
        amountMinor: 100,
        date: today,
        accountId: account,
        refundOf: entry.id,
      );
      final before = (await repo.exportData()).toJson();
      await expectLater(
        repo.undoSettlement(s.settlements.single),
        throwsA(isA<DomainError>()),
      );
      expect((await repo.exportData()).toJson(), before);
      s = await repo.load();
      await repo.deleteEntry(
        s.entries.singleWhere((e) => e.kind == EntryKind.refund),
      );
      await repo.undoSettlement(s.settlements.single);
      expect((await repo.load()).entries, isEmpty);
    },
  );

  test(
    'skip, pause, one-off completion and expected income do not double count',
    () async {
      await repo.saveObligation(plan(repeat: RepeatRule.once));
      var o = (await repo.load()).obligations.single;
      await repo.settleObligation(
        o.id,
        expectedVersion: o.version,
        periodIndex: 0,
        paidOn: today,
        skip: true,
      );
      var s = await repo.load();
      expect(s.entries, isEmpty);
      expect(s.obligations.single.complete, isTrue);
      await repo.undoSettlement(s.settlements.single);
      o = (await repo.load()).obligations.single;
      await repo.saveObligation(
        Obligation.fromJson({...o.toJson(), 'paused': true}),
        expectedVersion: o.version,
      );
      o = (await repo.load()).obligations.single;
      await expectLater(
        repo.settleObligation(
          o.id,
          expectedVersion: o.version,
          periodIndex: 0,
          paidOn: today,
        ),
        throwsA(isA<DomainError>()),
      );
      await repo.saveObligation(plan(id: 'salary', kind: EntryKind.income));
      o = (await repo.load()).obligations.singleWhere((o) => o.id == 'salary');
      await repo.settleObligation(
        o.id,
        expectedVersion: o.version,
        periodIndex: 0,
        paidOn: today,
      );
      s = await repo.load();
      expect(accountBalances(s)[account], 11000);
      expect(monthTotals(s.entries, today).income, 1000);
    },
  );

  test('only latest period can be undone; anchor changes are refused after history starts', () async {
    await repo.saveObligation(plan());
    var o = (await repo.load()).obligations.single;
    await repo.settleObligation(
      o.id,
      expectedVersion: o.version,
      periodIndex: 0,
      paidOn: today,
      skip: true,
    );
    var s = await repo.load();
    final first = s.settlements.single;
    o = s.obligations.single;
    await repo.settleObligation(
      o.id,
      expectedVersion: o.version,
      periodIndex: 1,
      paidOn: today,
      skip: true,
    );
    await expectLater(repo.undoSettlement(first), throwsA(isA<DomainError>()));
    o = (await repo.load()).obligations.single;
    await expectLater(
      repo.saveObligation(
        Obligation.fromJson({...o.toJson(), 'anchor': '2026-11-15'}),
        expectedVersion: o.version,
      ),
      throwsA(isA<DomainError>()),
    );
  });

  test('backup v3 retains payment relations and rejects broken links; v2 imports with empty plans', () async {
    await repo.saveObligation(plan());
    final o = (await repo.load()).obligations.single;
    await repo.settleObligation(
      o.id,
      expectedVersion: o.version,
      periodIndex: 0,
      paidOn: today,
    );
    final data = await repo.exportData();
    expect(BackupData.fromJson(data.toJson()).obligationCount, 1);
    await repo.replaceData(data, beforeReplace: (_) async {});
    final restored = await repo.load();
    expect(restored.settlements.single.entryId, restored.entries.single.id);
    expect(restored.obligations.single.nextIndex, 1);
    final broken =
        jsonDecode(jsonEncode(data.toJson())) as Map<String, dynamic>;
    ((broken['tables'] as Map)['settlements'] as List).clear();
    expect(() => BackupData.fromJson(broken), throwsA(isA<DomainError>()));
    final legacy =
        jsonDecode(jsonEncode(data.toJson())) as Map<String, dynamic>;
    legacy['schema'] = 2;
    final tables = legacy['tables'] as Map;
    tables.remove('obligations');
    tables.remove('settlements');
    tables.remove('purchases');
    tables.remove('documents');
    final upgraded = BackupData.fromJson(legacy);
    expect(upgraded.obligationCount, 0);
    expect(upgraded.toJson()['schema'], 4);
  });

  test('forecast includes outstanding past expenses, excludes past unreceived income and paid periods', () async {
    await repo.saveObligation(
      plan(id: 'bill', anchor: DateTime(2026, 11, 10), repeat: RepeatRule.once),
    );
    await repo.saveObligation(
      plan(
        id: 'old-income',
        anchor: DateTime(2026, 11, 10),
        repeat: RepeatRule.once,
        kind: EntryKind.income,
      ),
    );
    await repo.saveObligation(
      plan(
        id: 'new-income',
        anchor: DateTime(2026, 11, 20),
        repeat: RepeatRule.once,
        kind: EntryKind.income,
      ),
    );
    var s = await repo.load();
    var f = forecast30Days(s, today);
    expect(f.expense, 1000);
    expect(f.overdueExpense, 1000);
    expect(f.income, 1000);
    expect(f.after(10000), 10000);
    final o = s.obligations.singleWhere((o) => o.id == 'bill');
    await repo.settleObligation(
      o.id,
      expectedVersion: o.version,
      periodIndex: 0,
      paidOn: today,
    );
    s = await repo.load();
    f = forecast30Days(s, today);
    expect(f.expense, 0);
    expect(f.after(accountBalances(s)[account]!), 10000);
  });
}
