import 'dart:convert';

import 'package:personal_finance/domain/insights/insight.dart';
import 'package:personal_finance/domain/insights/analysis_profile.dart';

import '../support/fast_sync_backup.dart';

import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/data/finance_repository.dart';
import 'package:personal_finance/data/ledger_database.dart';
import 'package:personal_finance/data/backup_service.dart';
import 'package:personal_finance/data/cloud_transport.dart';
import 'package:personal_finance/data/sync_service.dart';
import 'package:personal_finance/domain/models.dart';
import 'package:personal_finance/domain/purchases.dart';
import 'package:personal_finance/domain/sync_merge.dart';
import 'package:personal_finance/domain/ledger_math.dart';

class MemoryCloud implements SnapshotRemote {
  @override
  String scope = 'test-project|owner';
  RemoteSnapshot? snapshot;
  bool fail = false, failAfterWrite = false, race = false;
  Future<void> Function()? afterWrite;
  @override
  Future<RemoteSnapshot?> read() async {
    if (fail) throw const DomainError('Нет сети');
    return snapshot;
  }

  @override
  Future<int> write(int expectedRevision, String payload) async {
    if (race) throw const CloudChanged();
    if (expectedRevision != (snapshot?.revision ?? 0)) {
      throw const CloudChanged();
    }
    final version = expectedRevision + 1;
    snapshot = RemoteSnapshot(version, payload);
    if (afterWrite != null) await afterWrite!();
    if (failAfterWrite) {
      failAfterWrite = false;
      throw const DomainError('Ответ потерян');
    }
    return version;
  }
}

void main() {
  late Directory directory;
  late LedgerDatabase dbA, dbB;
  late FinanceRepository a, b;
  late String account;
  late BackupService ba, bb;
  late SyncService sa, sb;
  late MemoryCloud remote;
  const password = 'fictional-sync-password';
  final today = DateTime(2026, 11, 14);
  Future<void> sync(SyncService s) async =>
      s.commit(await s.preview(password), password);
  Future<void> seed() async {
    await a.setCurrency('USD');
    await a.saveAccount(name: 'Карта', kind: 'Карта', openingMinor: 10000);
    account = (await a.load()).accounts.single.id;
    await sync(sa);
    await sync(sb);
  }

  Future<void> expense(FinanceRepository r, int amount, {String? id}) async {
    await r.saveEntry(
      id: id,
      expectedVersion: id == null ? null : 1,
      kind: EntryKind.expense,
      amountMinor: amount,
      date: today,
      accountId: account,
      category: 'Дом',
    );
  }

  final oldWarnings = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  tearDownAll(
    () => driftRuntimeOptions.dontWarnAboutMultipleDatabases = oldWarnings,
  );
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sync-test-');
    dbA = LedgerDatabase(NativeDatabase.memory());
    dbB = LedgerDatabase(NativeDatabase.memory());
    a = FinanceRepository(dbA, clock: () => today);
    b = FinanceRepository(dbB, clock: () => today);
    ba = FastSyncBackup(a, Directory('${directory.path}/a'));
    bb = FastSyncBackup(b, Directory('${directory.path}/b'));
    remote = MemoryCloud();
    sa = SyncService(a, ba, remote);
    sb = SyncService(b, bb, remote);
  });
  tearDown(() async {
    await dbA.close();
    await dbB.close();
    await directory.delete(recursive: true);
  });

  test('real encrypted transfer decrypts on a second device without sending cleartext', () async {
    ba = BackupService(a, Directory('${directory.path}/real-a'));
    bb = BackupService(b, Directory('${directory.path}/real-b'));
    sa = SyncService(a, ba, remote);
    sb = SyncService(b, bb, remote);
    await seed();
    expect((await b.load()).accounts.single.name, 'Карта');
    expect(remote.snapshot!.payload, contains('my-finances-encrypted'));
    expect(remote.snapshot!.payload, isNot(contains('Карта')));
    expect(
      (await bb.inspect(
        Uint8List.fromList(utf8.encode(remote.snapshot!.payload)),
        password,
      )).accountCount,
      1,
    );
  });

  test('three independent devices converge after offline changes', () async {
    await seed();
    final dbC = LedgerDatabase(NativeDatabase.memory());
    try {
      final c = FinanceRepository(dbC, clock: () => today);
      final sc = SyncService(
        c,
        FastSyncBackup(c, Directory('${directory.path}/c')),
        remote,
      );
      await sync(sc);
      await expense(a, 1000);
      await expense(b, 2000);
      await expense(c, 500);
      await sync(sa);
      await sync(sb);
      await sync(sc);
      await sync(sa);
      await sync(sb);
      for (final repo in [a, b, c]) {
        expect((await repo.load()).entries.length, 3);
        expect(accountBalances(await repo.load())[account], 6500);
        expect((await repo.load()).pendingChanges, 0);
      }
    } finally {
      await dbC.close();
    }
  });

  test(
    'three devices merge analysis and preserve their own backup dates',
    () async {
      await seed();
      final dbC = LedgerDatabase(NativeDatabase.memory());
      try {
        final c = FinanceRepository(dbC, clock: () => today);
        final sc = SyncService(
          c,
          FastSyncBackup(c, Directory('${directory.path}/c')),
          remote,
        );
        await sync(sc);
        await a.writeAnalysisPolicy(
          AnalysisPolicy(
            disabled: {'A1'},
            profile: AnalysisProfile(
              lastBackupOn: today,
              reserves: {account: 1000},
            ),
          ),
        );
        await b.writeAnalysisPolicy(
          AnalysisPolicy(
            changePercent: 30,
            profile: AnalysisProfile(categoryAliases: {'еда': 'продукты'}),
          ),
        );
        await c.writeAnalysisPolicy(
          AnalysisPolicy(
            hidden: {'B1'},
            profile: AnalysisProfile(
              lastBackupOn: DateTime(2026, 11, 1),
              debts: [
                DebtPlan(
                  id: 'debt',
                  name: 'Тестовый долг',
                  principalMinor: 10000,
                  annualRateBp: 1200,
                  monthlyPaymentMinor: 1000,
                  monthlyFeeMinor: 0,
                  firstDue: DateTime(2026, 12),
                ),
              ],
            ),
          ),
        );
        await sync(sa);
        await sync(sb);
        await sync(sc);
        await sync(sa);
        await sync(sb);
        for (final repo in [a, b, c]) {
          final p = (await repo.readAnalysisPolicy())!;
          expect(p.disabled, {'A1'});
          expect(p.hidden, {'B1'});
          expect(p.changePercent, 30);
          expect(p.profile.reserves, {account: 1000});
          expect(p.profile.debts.single.id, 'debt');
          expect(p.profile.categoryAliases, {'еда': 'продукты'});
          expect((await repo.captureSync()).pendingChanges, 0);
        }
        expect((await a.readAnalysisPolicy())!.profile.lastBackupOn, today);
        expect((await b.readAnalysisPolicy())!.profile.lastBackupOn, isNull);
        expect(
          (await c.readAnalysisPolicy())!.profile.lastBackupOn,
          DateTime(2026, 11, 1),
        );
        final version = remote.snapshot!.revision;
        await sync(sa);
        await sync(sb);
        await sync(sc);
        expect(remote.snapshot!.revision, version);
      } finally {
        await dbC.close();
      }
    },
  );

  test(
    'analysis edited while upload is in progress is retained and retried',
    () async {
      await seed();
      await a.writeAnalysisPolicy(AnalysisPolicy(changePercent: 30));
      final plan = await sa.preview(password);
      remote.afterWrite = () async {
        remote.afterWrite = null;
        await a.writeAnalysisPolicy(AnalysisPolicy(changePercent: 40));
      };
      await expectLater(sa.commit(plan, password), throwsA(isA<DomainError>()));
      expect((await a.readAnalysisPolicy())!.changePercent, 40);
      expect((await a.captureSync()).pendingChanges, 1);
      final retry = await sa.preview(password);
      expect(retry.needsChoice, isTrue);
      await sa.commit(retry, password, choice: SyncChoice.local);
      await sync(sb);
      expect((await b.readAnalysisPolicy())!.changePercent, 40);
      expect((await a.captureSync()).pendingChanges, 0);
    },
  );

  test(
    'archiving an empty account conflicts with a concurrent new expense',
    () async {
      await seed();
      await expense(a, 10000);
      await sync(sa);
      await sync(sb);
      final source = (await a.load()).accounts.single;
      await a.saveAccount(
        id: source.id,
        expectedVersion: source.version,
        name: source.name,
        kind: source.kind,
        openingMinor: source.openingMinor,
        archived: true,
      );
      await expense(b, 500);
      await sync(sa);
      expect((await sb.preview(password)).needsChoice, isTrue);
      expect(accountBalances(await b.load())[account], -500);
    },
  );

  test(
    'future income cannot hide a current archived-account conflict',
    () async {
      await seed();
      await expense(a, 10000);
      await sync(sa);
      await sync(sb);
      final source = (await a.load()).accounts.single;
      await a.saveAccount(
        id: source.id,
        expectedVersion: source.version,
        name: source.name,
        kind: source.kind,
        openingMinor: source.openingMinor,
        archived: true,
      );
      await expense(b, 500);
      await b.saveEntry(
        kind: EntryKind.income,
        amountMinor: 500,
        date: today.add(const Duration(days: 5)),
        accountId: account,
        category: 'Доход',
      );
      expect(accountBalances(await b.load())[account], 0);
      expect(accountBalances(await b.load(), through: today)[account], -500);
      await sync(sa);
      final result = await sb.preview(password);
      expect(result.needsChoice, isTrue);
      expect((await b.load()).accounts.single.archived, isFalse);
    },
  );

  test(
    'all losing snapshots remain exportable from recovery history',
    () async {
      await seed();
      await ba.saveRecovery(await a.exportData(), password);
      await expense(a, 1000);
      await ba.saveRecovery(await a.exportData(), password);
      final copies = await ba.recoveryCopies();
      expect(copies.length, 2);
      final counts = <int>[];
      for (final copy in copies) {
        counts.add(
          (await ba.inspect(
            await ba.readRecovery(copy.name),
            password,
          )).entryCount,
        );
      }
      expect(counts, [1, 0]);
      await expectLater(
        ba.readRecovery('../outside.mfin'),
        throwsA(isA<DomainError>()),
      );
    },
  );

  test('two offline devices merge independent expenses; queues ack and retry is idempotent', () async {
    await seed();
    await expense(a, 1000);
    await expense(b, 2000);
    await sync(sa);
    await sync(sb);
    await sync(sa);
    expect(accountBalances(await a.load())[account], 7000);
    expect(sameSyncData(await a.exportData(), await b.exportData()), isTrue);
    expect((await a.load()).pendingChanges, 0);
    final version = remote.snapshot!.revision;
    await sync(sa);
    expect(remote.snapshot!.revision, version);
    expect((await a.load()).entries.length, 2);
    expect(remote.snapshot!.payload, isNot(contains('Карта')));
    expect(
      (await ba.inspect(
        Uint8List.fromList(utf8.encode(remote.snapshot!.payload)),
        password,
      )).tables['outbox'],
      isEmpty,
    );
  });

  test('first connection with populated bases requires explicit choice; cloud survives local replacement', () async {
    await seed();
    await b.db.customStatement('DELETE FROM sync_state');
    await expense(b, 3000);
    final plan = await sb.preview(password);
    expect(plan.needsChoice, isTrue);
    await expectLater(sb.commit(plan, password), throwsA(isA<DomainError>()));
    await sb.commit(plan, password, choice: SyncChoice.cloud);
    expect((await b.load()).entries, isEmpty);
    final recovery = await bb.latestRecovery();
    final original = await bb.inspect(recovery!, password);
    expect(original.entryCount, 1);
    expect(remote.snapshot!.revision, 1);
  });

  test('same-record edits conflict; choosing local preserves losing encrypted cloud version', () async {
    await seed();
    await expense(a, 1000);
    await sync(sa);
    await sync(sb);
    final id = (await a.load()).entries.single.id;
    await expense(a, 2000, id: id);
    await expense(b, 3000, id: id);
    await sync(sa);
    final plan = await sb.preview(password);
    expect(plan.needsChoice, isTrue);
    expect(plan.conflicts, contains('entries:$id'));
    final cloudBefore = remote.snapshot!.payload;
    await sb.commit(plan, password, choice: SyncChoice.local);
    expect(utf8.decode((await bb.latestRecovery())!), cloudBefore);
    await sync(sa);
    expect((await a.load()).entries.single.amountMinor, 3000);
  });

  test(
    'concurrent payment of one period is rejected as a whole graph',
    () async {
      await seed();
      await a.saveObligation(
        Obligation(
          id: 'subscription',
          name: 'Интернет',
          kind: EntryKind.expense,
          amountMinor: 1000,
          category: 'Подписки',
          anchor: today,
          repeat: RepeatRule.monthly,
          accountId: account,
        ),
      );
      await sync(sa);
      await sync(sb);
      for (final r in [a, b]) {
        await r.settleObligation(
          'subscription',
          expectedVersion: 1,
          periodIndex: 0,
          paidOn: today,
        );
      }
      await sync(sa);
      final plan = await sb.preview(password);
      expect(plan.needsChoice, isTrue);
      await expectLater(sb.commit(plan, password), throwsA(isA<DomainError>()));
      expect((await b.load()).entries.length, 1);
      expect(accountBalances(await b.load())[account], 9000);
    },
  );

  test('cross-record refund versus source deletion fails graph validation; no partial changes', () async {
    await seed();
    await expense(a, 1000);
    await sync(sa);
    await sync(sb);
    final source = (await a.load()).entries.single;
    await a.deleteEntry(source);
    await b.saveEntry(
      kind: EntryKind.refund,
      amountMinor: 500,
      date: today,
      accountId: account,
      refundOf: source.id,
    );
    await sync(sa);
    final plan = await sb.preview(password);
    expect(plan.needsChoice, isTrue);
    expect((await b.load()).entries.length, 2);
  });

  test('documents and tombstones synchronize; receipt bytes and deleted records survive', () async {
    await seed();
    await a.savePurchase(
      Purchase(
        id: 'purchase',
        name: 'Наушники',
        amountMinor: 3000,
        date: today,
      ),
    );
    final pdf = Uint8List.fromList(utf8.encode('%PDF-1.7\nfictional\n%%EOF'));
    await a.addDocument('purchase', 'Чек.pdf', pdf);
    await sync(sa);
    await sync(sb);
    expect(await b.readDocument((await b.load()).documents.single), pdf);
    await b.deletePurchase((await b.load()).purchases.single);
    await sync(sb);
    await sync(sa);
    expect((await a.load()).purchases, isEmpty);
    expect((await a.load()).documents, isEmpty);
    expect(
      (await a.exportData()).tables['documents']!.single['deleted_at'],
      isNotNull,
    );
  });

  test('network loss and lost response never lose entries; retry acknowledges without duplicates', () async {
    await seed();
    await expense(a, 1000);
    remote.fail = true;
    await expectLater(sa.preview(password), throwsA(isA<DomainError>()));
    expect((await a.load()).pendingChanges, greaterThan(0));
    remote.fail = false;
    remote.failAfterWrite = true;
    await expectLater(sync(sa), throwsA(isA<DomainError>()));
    final version = remote.snapshot!.revision;
    await sync(sa);
    expect(remote.snapshot!.revision, version);
    expect((await a.load()).entries.length, 1);
    expect((await a.load()).pendingChanges, 0);
  });

  test('local edit during upload is retained; concurrent remote write fails CAS without ack', () async {
    await seed();
    await expense(a, 1000);
    final plan = await sa.preview(password);
    remote.race = true;
    await expectLater(sa.commit(plan, password), throwsA(isA<CloudChanged>()));
    expect((await a.load()).pendingChanges, greaterThan(0));
    remote.race = false;
    remote.afterWrite = () => expense(a, 2000);
    await expectLater(sa.commit(plan, password), throwsA(isA<DomainError>()));
    expect((await a.load()).entries.length, 2);
    expect(accountBalances(await a.load())[account], 7000);
    expect((await a.load()).pendingChanges, greaterThan(0));
    remote.afterWrite = null;
    await sync(sa);
    expect((await a.load()).pendingChanges, 0);
  });

  test('wrong password, corrupt cloud, account change and restore cannot silently overwrite', () async {
    await seed();
    await expectLater(
      sa.preview('incorrect-password'),
      throwsA(isA<DomainError>()),
    );
    final plan = await sa.preview(password);
    await expectLater(
      sa.commit(plan, 'incorrect-password'),
      throwsA(isA<DomainError>()),
    );
    final before = remote.snapshot!;
    remote.snapshot = RemoteSnapshot(before.revision, 'bad json');
    await expectLater(sa.preview(password), throwsA(isA<DomainError>()));
    remote.snapshot = before;
    await a.replaceData(await a.exportData(), beforeReplace: (_) async {});
    expect((await sa.preview(password)).needsChoice, isTrue);
    remote.scope = 'test-project|different-owner';
    expect((await sa.preview(password)).needsChoice, isTrue);
    expect((await a.load()).accounts.length, 1);
  });

  test(
    'failed recovery file rolls back pull and leaves baseline untouched',
    () async {
      await seed();
      await expense(a, 1000);
      await sync(sa);
      final blocked = File('${directory.path}/blocked');
      await blocked.writeAsString('file');
      final broken = SyncService(
        b,
        FastSyncBackup(b, Directory(blocked.path)),
        remote,
      );
      final oldRevision = (await b.captureSync()).revision;
      await expectLater(sync(broken), throwsA(isA<FileSystemException>()));
      expect((await b.load()).entries, isEmpty);
      expect((await b.captureSync()).revision, oldRevision);
    },
  );
}
