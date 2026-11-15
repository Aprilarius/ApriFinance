import 'dart:async';

import 'package:personal_finance/data/insights_preferences_repository.dart';
import 'package:personal_finance/domain/insights/insight.dart';

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/data/cloud_transport.dart';
import 'package:personal_finance/data/finance_repository.dart';
import 'package:personal_finance/data/ledger_database.dart';
import 'package:personal_finance/data/sync_service.dart';
import 'package:personal_finance/domain/backup_data.dart';
import 'package:personal_finance/domain/models.dart';
import 'package:personal_finance/ui/cloud_controller.dart';
import 'package:personal_finance/ui/finance_view_model.dart';

import '../support/fast_sync_backup.dart';

class ScheduledExchange {
  ScheduledExchange(this.delay, this.task);
  final Duration delay;
  final void Function() task;
  bool cancelled = false;
}

class ManualScheduler {
  final tasks = <ScheduledExchange>[];
  CancelScheduledSync schedule(Duration delay, void Function() task) {
    final entry = ScheduledExchange(delay, task);
    tasks.add(entry);
    return () => entry.cancelled = true;
  }

  List<ScheduledExchange> get pending =>
      tasks.where((t) => !t.cancelled).toList();
  void fire() {
    final next = pending.single;
    next.cancelled = true;
    next.task();
  }
}

class SessionCloud implements CloudTransport {
  String? payload;
  int revision = 0, reads = 0, writes = 0;
  bool offline = false, expired = false;
  Completer<CloudReply>? holdRead;
  CloudReply get current => CloudReply(
    200,
    payload == null
        ? <Object?>[]
        : [
            {'revision': revision, 'payload': payload},
          ],
  );
  @override
  Future<CloudReply> request(
    Uri uri,
    String method,
    Map<String, String> headers,
    Object? body,
  ) async {
    if (uri.path == '/auth/v1/token') {
      return const CloudReply(200, {
        'access_token': 'fictional-token',
        'user': {'id': '12345678-1234-1234-1234-123456789abc'},
      });
    }
    if (method == 'GET') {
      reads++;
      if (expired) return const CloudReply(401, null);
      if (offline) return const CloudReply(503, null);
      final hold = holdRead;
      holdRead = null;
      if (hold != null) return hold.future;
      return current;
    }
    if (uri.path == '/rest/v1/rpc/put_finance_snapshot_v2') {
      final input = body! as Map;
      if (input['expected_revision'] != revision) {
        return const CloudReply(400, {'message': 'SYNC_CONFLICT'});
      }
      payload = input['encrypted_payload']! as String;
      writes++;
      return CloudReply(200, ++revision);
    }
    return const CloudReply(204, null);
  }
}

void main() {
  late Directory directory;
  late LedgerDatabase db;
  late FinanceRepository repo;
  late FinanceViewModel vm;
  late CloudController c;
  late SessionCloud cloud;
  late ManualScheduler scheduler;
  const password = 'fictional-session-password';
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('automatic-sync-');
    db = LedgerDatabase(NativeDatabase.memory());
    repo = FinanceRepository(db, clock: () => DateTime(2026, 11, 14));
    await repo.setCurrency('USD');
    await repo.saveAccount(name: 'Карта', kind: 'Карта', openingMinor: 10000);
    vm = FinanceViewModel(
      repo,
      backup: FastSyncBackup(repo, directory),
      insightsPreferences: DatabaseInsightsPreferences(repo),
    );
    await vm.refresh();
    scheduler = ManualScheduler();
    cloud = SessionCloud();
    c = CloudController(vm, transport: cloud, schedule: scheduler.schedule);
    await c.initialize();
    await c.signIn(
      'https://project.supabase.co',
      'sb_publishable_fictional_key_123456',
      'owner@example.invalid',
      'fictional-account-password',
    );
  });
  tearDown(() async {
    c.dispose();
    vm.dispose();
    await db.close();
    await directory.delete(recursive: true);
  });
  Future<void> unlock() async {
    c.setAutomatic(true);
    await c.check(password);
    await c.commit();
    expect(c.automaticReady, isTrue);
  }

  Future<void> settle() async {
    for (var i = 0; i < 1000 && c.busy; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(c.busy, isFalse);
  }

  Future<void> fire() async {
    scheduler.fire();
    await settle();
  }

  Future<void> expense() async {
    await repo.saveEntry(
      kind: EntryKind.expense,
      amountMinor: 1000,
      date: DateTime(2026, 11, 14),
      accountId: vm.snapshot!.accounts.single.id,
      category: 'Дом',
    );
    await vm.refresh();
  }

  test('opt-in and manual success required; local edits debounce and idle poll remains scheduled', () async {
    expect(scheduler.pending, isEmpty);
    c.setAutomatic(true);
    expect(c.automaticReady, isFalse);
    await c.exchangeAutomatically();
    expect(cloud.reads, 0);
    await c.check(password);
    await c.commit();
    expect(scheduler.pending.single.delay.inSeconds, 60);
    await expense();
    expect(scheduler.pending.single.delay.inSeconds, 2);
    await fire();
    expect(cloud.revision, 2);
    expect(vm.snapshot!.pendingChanges, 0);
    expect(scheduler.pending.single.delay.inSeconds, 60);
    c.setAutomatic(false);
    expect(c.automaticReady, isFalse);
    expect(scheduler.pending, isEmpty);
  });

  test(
    'background cancels new attempts; resume synchronizes pending edits',
    () async {
      await unlock();
      c.setForeground(false);
      await expense();
      expect(scheduler.pending, isEmpty);
      final reads = cloud.reads;
      await c.exchangeAutomatically();
      expect(cloud.reads, reads);
      c.setForeground(true);
      expect(scheduler.pending.single.delay.inSeconds, 1);
      await fire();
      expect(cloud.revision, 2);
    },
  );

  test('pause during a read prevents starting a write', () async {
    await unlock();
    await expense();
    final hold = Completer<CloudReply>();
    cloud.holdRead = hold;
    scheduler.fire();
    while (cloud.holdRead != null) {
      await Future<void>.delayed(Duration.zero);
    }
    c.setForeground(false);
    hold.complete(cloud.current);
    await settle();
    expect(cloud.revision, 1);
    expect(vm.snapshot!.pendingChanges, greaterThan(0));
    expect(scheduler.pending, isEmpty);
  });

  test(
    'network retries back off and recover without losing local entries',
    () async {
      await unlock();
      await expense();
      cloud.offline = true;
      for (final seconds in [5, 15, 60, 300, 300]) {
        await fire();
        expect(scheduler.pending.single.delay.inSeconds, seconds);
        vm.changeMonth(1);
        vm.setFilters(search: 'Дом');
        expect(scheduler.pending.single.delay.inSeconds, seconds);
        expect(vm.snapshot!.entries.length, 1);
      }
      cloud.offline = false;
      await fire();
      expect(vm.snapshot!.pendingChanges, 0);
      expect(scheduler.pending.single.delay.inSeconds, 60);
    },
  );

  test('conflict blocks automation until explicit manual resolution', () async {
    await unlock();
    final original = (await repo.exportData()).toJson();
    final other = (jsonDecode(jsonEncode(original)) as Map)
        .cast<String, Object?>();
    final row = (((other['tables'] as Map)['accounts'] as List).single as Map);
    row['name'] = 'Карта Mac';
    row['version'] = 2;
    cloud.payload = utf8.decode(
      await vm.backup!.encode(BackupData.fromJson(other), password),
    );
    cloud.revision = 2;
    final account = vm.snapshot!.accounts.single;
    await repo.saveAccount(
      id: account.id,
      expectedVersion: account.version,
      name: 'Карта Android',
      kind: account.kind,
      openingMinor: account.openingMinor,
    );
    await vm.refresh();
    await fire();
    expect(c.needsAttention, isTrue);
    expect(c.preview!.needsChoice, isTrue);
    expect(c.automaticReady, isFalse);
    expect(scheduler.pending, isEmpty);
    expect(cloud.writes, 1);
    c.forgetPreview();
    c.setForeground(true);
    expect(scheduler.pending, isEmpty);
    await c.check(password);
    await c.commit(choice: SyncChoice.cloud);
    expect(c.needsAttention, isFalse);
    expect(c.automaticReady, isTrue);
    expect(vm.snapshot!.accounts.single.name, 'Карта Mac');
  });

  test(
    'expired session stops retries and requires fresh opt-in after login',
    () async {
      await unlock();
      cloud.expired = true;
      await fire();
      expect(c.signedIn, isFalse);
      expect(c.needsAttention, isTrue);
      expect(c.automaticReady, isFalse);
      expect(scheduler.pending, isEmpty);
      cloud.expired = false;
      await c.signIn(
        'https://project.supabase.co',
        'sb_publishable_fictional_key_123456',
        'owner@example.invalid',
        'fictional-password',
      );
      expect(c.automaticEnabled, isFalse);
      expect(c.automaticReady, isFalse);
    },
  );

  test(
    'manual preview pauses automatic changes, leaving screen resumes polling',
    () async {
      await unlock();
      await c.check(password);
      expect(c.preview, isNotNull);
      expect(scheduler.pending, isEmpty);
      await c.exchangeAutomatically();
      expect(c.preview, isNotNull);
      c.forgetPreview();
      expect(scheduler.pending.single.delay.inSeconds, 60);
    },
  );

  test('concurrent request coalesces and retains edits entered during upload preparation', () async {
    await unlock();
    await expense();
    final hold = Completer<CloudReply>();
    cloud.holdRead = hold;
    scheduler.fire();
    while (cloud.holdRead != null) {
      await Future<void>.delayed(Duration.zero);
    }
    final reads = cloud.reads;
    await c.exchangeAutomatically();
    expect(cloud.reads, reads);
    await expense();
    hold.complete(cloud.current);
    await settle();
    expect(vm.snapshot!.entries.length, 2);
    expect(vm.snapshot!.pendingChanges, greaterThan(0));
    await fire();
    expect(vm.snapshot!.pendingChanges, 0);
    final data = await vm.backup!.inspect(
      Uint8List.fromList(utf8.encode(cloud.payload!)),
      password,
    );
    expect(data.entryCount, 2);
  });

  test(
    'restore requires explicit reattachment even in unlocked automatic mode',
    () async {
      await unlock();
      await repo.replaceData(
        await repo.exportData(),
        beforeReplace: (_) async {},
      );
      c.setForeground(true);
      await fire();
      expect(c.needsAttention, isTrue);
      expect(c.preview!.needsChoice, isTrue);
      expect(cloud.revision, 1);
    },
  );

  test(
    'unreadable encrypted cloud blocks automatic retries and keeps local data',
    () async {
      await unlock();
      cloud.payload = 'corrupt-encrypted-copy';
      cloud.revision++;
      await fire();
      expect(c.needsAttention, isTrue);
      expect(c.automaticReady, isFalse);
      expect(scheduler.pending, isEmpty);
      expect(vm.snapshot!.accounts.length, 1);
      expect(cloud.writes, 1);
    },
  );

  test(
    'analysis-only changes schedule an upload and do not create an echo loop',
    () async {
      await unlock();
      final oldWrites = cloud.writes;
      expect(
        await vm.insights.configure(AnalysisPolicy(changePercent: 30)),
        isTrue,
      );
      expect(scheduler.pending.single.delay.inSeconds, 2);
      await fire();
      expect(cloud.writes, oldWrites + 1);
      expect((await repo.captureSync()).pendingChanges, 0);
      final data = await vm.backup!.inspect(
        Uint8List.fromList(utf8.encode(cloud.payload!)),
        password,
      );
      final policyRow = data.tables['settings']!.singleWhere(
        (r) => r['key'] == 'analysis_policy',
      );
      expect(
        (jsonDecode(policyRow['value'] as String) as Map)['changePercent'],
        30,
      );
      expect(scheduler.pending.single.delay.inSeconds, 60);
      await fire();
      expect(cloud.writes, oldWrites + 1);
    },
  );

  test('disposing a controller cancels scheduled work and detaches finance listener', () async {
    final otherSchedule = ManualScheduler();
    final other = CloudController(
      vm,
      transport: cloud,
      schedule: otherSchedule.schedule,
    );
    await other.initialize();
    await other.signIn(
      'https://project.supabase.co',
      'sb_publishable_fictional_key_123456',
      'owner@example.invalid',
      'fictional-password',
    );
    other.setAutomatic(true);
    await other.check(password);
    await other.commit();
    expect(otherSchedule.pending.length, 1);
    other.dispose();
    await expense();
    expect(otherSchedule.pending, isEmpty);
  });
}
