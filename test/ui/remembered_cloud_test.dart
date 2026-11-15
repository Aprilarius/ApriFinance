import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/data/cloud_credentials.dart';
import 'package:personal_finance/data/finance_repository.dart';
import 'package:personal_finance/data/ledger_database.dart';
import 'package:personal_finance/ui/cloud_controller.dart';
import 'package:personal_finance/ui/finance_view_model.dart';

import '../support/fast_sync_backup.dart';
import '../support/remembered_cloud.dart';

void main() {
  late LedgerDatabase db;
  late FinanceRepository repo;
  late FinanceViewModel vm;
  late CloudController controller;
  late MemoryCredentials store;
  late RememberedCloud cloud;
  late RememberedSchedule schedule;
  late Directory directory;
  const password = 'fictional-copy-password';
  CloudController create() => CloudController(
    vm,
    credentials: store,
    transport: cloud,
    configuredCloud: fixtureCloudConfig(),
    schedule: schedule.schedule,
    preferences: File('${directory.path}/cloud.json'),
  );
  Future<void> login() => controller.signIn(
    controller.url,
    controller.publicKey,
    'owner@example.invalid',
    'fictional-account-password',
  );
  Future<void> attach() async {
    await login();
    expect(controller.signedIn, isTrue, reason: controller.status);
    await controller.connectCopy(password);
    expect(controller.hasSavedCopy, isTrue, reason: controller.status);
  }

  Future<void> reopen() async {
    controller.dispose();
    schedule = RememberedSchedule();
    controller = create();
    await controller.initialize();
  }

  Future<void> fire() async {
    schedule.fire();
    for (var i = 0; i < 1000 && controller.busy; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(controller.busy, isFalse, reason: controller.status);
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('apri-remember-');
    db = LedgerDatabase(NativeDatabase.memory());
    repo = FinanceRepository(db, clock: () => DateTime(2026, 11, 15));
    await repo.setCurrency('AZN');
    await repo.saveAccount(
      name: 'Тестовая карта',
      kind: 'Карта',
      openingMinor: 10000,
    );
    vm = FinanceViewModel(
      repo,
      backup: FastSyncBackup(repo, Directory('${directory.path}/recovery')),
    );
    await vm.refresh();
    store = MemoryCredentials();
    cloud = RememberedCloud();
    schedule = RememberedSchedule();
    controller = create();
    await controller.initialize();
  });
  tearDown(() async {
    controller.dispose();
    vm.dispose();
    await db.close();
    await directory.delete(recursive: true);
  });
  test(
    'one connection restores without account password or copy password input',
    () async {
      await attach();
      final record = CloudCredentials.decode(store.value!);
      expect(record.copyPassword, password);
      expect(record.session!.canRemember, isTrue);
      expect(store.value, isNot(contains('fictional-account-password')));
      final preferences = await File('${directory.path}/cloud.json')
          .readAsString();
      expect(preferences, isNot(contains(password)));
      expect(preferences, isNot(contains('fictional-refresh')));
      await reopen();
      expect(controller.signedIn, isTrue);
      expect(controller.needsCopyPassword, isFalse);
      expect(controller.automaticReady, isTrue);
      expect(schedule.delay, const Duration(seconds: 1));
      await fire();
      expect(cloud.logins, 1);
      expect(cloud.writes, 1);
      expect((await repo.load()).accounts.single.name, 'Тестовая карта');
    },
  );
  test('automatic opt-out survives reopen and manual sync uses remembered encryption key', () async {
    await attach();
    await controller.setAutomatic(false);
    await reopen();
    expect(controller.automaticEnabled, isFalse);
    expect(schedule.task, isNull);
    await controller.synchronizeNow();
    expect(controller.status, 'Всё синхронизировано.');
    expect(controller.hasSavedCopy, isTrue);
    expect(cloud.logins, 1);
  });
  test('offline restore keeps keys and retries instead of requesting another login', () async {
    await attach();
    final data = jsonDecode(store.value!) as Map<String, dynamic>;
    (data['session'] as Map)['expiresAt'] = '2001-01-01T00:00:00Z';
    store.value = jsonEncode(data);
    cloud.offline = true;
    await reopen();
    expect(controller.signedIn, isTrue);
    await fire();
    expect(controller.automaticReady, isTrue);
    expect(schedule.delay, const Duration(seconds: 5));
    expect(CloudCredentials.decode(store.value!).copyPassword, password);
    cloud.offline = false;
    await fire();
    expect(cloud.refreshes, 1);
    expect(
      CloudCredentials.decode(store.value!).session!.refreshToken,
      'fictional-refresh-1',
    );
  });
  test('copy key is never reused across owner or project changes', () async {
    await attach();
    cloud.userId = '44444444-4444-4444-8444-444444444444';
    await login();
    expect(controller.hasSavedCopy, isFalse);
    expect(CloudCredentials.decode(store.value!).userId, cloud.userId);
    await controller.connectCopy(password);
    await controller.signIn(
      'https://other.supabase.co',
      fixtureCloudKey,
      'owner@example.invalid',
      'fictional-account-password',
    );
    expect(controller.hasSavedCopy, isFalse);
  });
  test(
    'failed new login cannot leave a previous owner active in memory',
    () async {
      await attach();
      cloud.rejectLogin = true;
      await login();
      expect(controller.signedIn, isFalse);
      expect(controller.automaticReady, isFalse);
      expect(cloud.writes, 1);
      expect((await repo.load()).accounts, hasLength(1));
    },
  );
  test('vault write failure prevents claiming a remembered login or sending finance', () async {
    store.failWrite = true;
    await login();
    expect(controller.signedIn, isFalse);
    expect(store.value, isNull);
    expect(cloud.writes, 0);
    expect(controller.status, contains('защищённое хранилище'));
  });
  test(
    'public preferences failure cannot commit a hidden remembered login',
    () async {
      controller.dispose();
      final blocked = Directory('${directory.path}/blocked.json');
      await blocked.create();
      controller = CloudController(
        vm,
        credentials: store,
        transport: cloud,
        configuredCloud: fixtureCloudConfig(),
        schedule: schedule.schedule,
        preferences: File(blocked.path),
      );
      await controller.initialize();
      await login();
      expect(controller.signedIn, isFalse);
      expect(store.value, isNull);
      expect(cloud.writes, 0);
      await reopen();
      expect(controller.signedIn, isFalse);
    },
  );
  test(
    'damaged vault record or locked OS store keeps local finance available',
    () async {
      for (final locked in [false, true]) {
        store.value = 'corrupt fictional session';
        store.failRead = locked;
        await reopen();
        expect(controller.signedIn, isFalse);
        expect(controller.status, contains('защищённое хранилище'));
        expect((await repo.load()).accounts, hasLength(1));
        expect(cloud.reads, 0);
      }
    },
  );
  test(
    'offline sign out removes the device secrets and does not erase finance',
    () async {
      await attach();
      cloud.offline = true;
      await controller.signOut();
      expect(store.value, isNull);
      expect(controller.signedIn, isFalse);
      expect((await repo.load()).accounts, hasLength(1));
      await reopen();
      expect(controller.signedIn, isFalse);
      expect(schedule.task, isNull);
    },
  );
  test(
    'failed protected deletion reports failure and can be retried locally',
    () async {
      await attach();
      store.failDelete = true;
      await controller.signOut();
      expect(controller.signedIn, isFalse);
      expect(store.value, isNotNull);
      expect(controller.status, contains('защищённое хранилище'));
      store.failDelete = false;
      await controller.signOut();
      expect(store.value, isNull);
      await reopen();
      expect(controller.signedIn, isFalse);
    },
  );
  test(
    'late startup read cannot resurrect a connection after explicit sign out',
    () async {
      await attach();
      controller.dispose();
      controller = create();
      final held = Completer<void>();
      store.holdRead = held;
      final startup = controller.initialize();
      while (store.holdRead != null) {
        await Future<void>.delayed(Duration.zero);
      }
      await controller.signOut();
      held.complete();
      await startup;
      expect(controller.signedIn, isFalse);
      expect(store.value, isNull);
      expect(schedule.task, isNull);
    },
  );
  test(
    'late startup read cannot override a newly authenticated owner',
    () async {
      await attach();
      controller.dispose();
      controller = create();
      final held = Completer<void>();
      store.holdRead = held;
      final startup = controller.initialize();
      while (store.holdRead != null) {
        await Future<void>.delayed(Duration.zero);
      }
      cloud.userId = '44444444-4444-4444-8444-444444444444';
      await login();
      held.complete();
      await startup;
      expect(CloudCredentials.decode(store.value!).userId, cloud.userId);
      expect(controller.hasSavedCopy, isFalse);
      expect(controller.signedIn, isTrue);
    },
  );

  test(
    'unreadable cloud copy forgets only copy key and pauses automatic exchange',
    () async {
      await attach();
      cloud.payload = 'corrupt-encrypted-copy';
      cloud.revision++;
      await fire();
      expect(controller.needsAttention, isTrue);
      expect(controller.needsCopyPassword, isTrue);
      final saved = CloudCredentials.decode(store.value!);
      expect(saved.copyPassword, isNull);
      expect(saved.session, isNotNull);
      expect(schedule.task, isNull);
    },
  );
  test('dispose during protected write cannot activate a late login', () async {
    final held = Completer<void>();
    store.holdWrite = held;
    final work = login();
    while (store.holdWrite != null) {
      await Future<void>.delayed(Duration.zero);
    }
    controller.dispose();
    held.complete();
    await work;
    expect(controller.signedIn, isFalse);
    expect(schedule.task, isNull);
    // Replace the disposed instance for normal teardown.
    controller = create();
  });
}
