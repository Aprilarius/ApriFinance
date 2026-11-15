import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/data/reminders_service.dart';
import 'package:personal_finance/domain/models.dart';
import 'package:personal_finance/domain/reminder_plan.dart';

class FakeReminderBackend implements ReminderBackend {
  @override
  bool supported = true;
  @override
  String zone = 'Asia/Baku';
  bool granted = true, fail = false;
  int cancels = 0, requests = 0;
  List<ReminderItem> pending = [];
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> permission({bool request = false}) async {
    if (request) requests++;
    return granted;
  }

  @override
  Future<void> cancel() async {
    cancels++;
    pending = [];
  }

  @override
  Future<int> schedule(List<ReminderItem> items) async {
    if (fail) throw StateError('OS error');
    pending = items;
    return items.length;
  }
}

class DelayedPermissionBackend extends FakeReminderBackend {
  final requested = Completer<void>();
  final permissionResult = Completer<bool>();
  @override
  Future<bool> permission({bool request = false}) async {
    if (!request) return true;
    requested.complete();
    return permissionResult.future;
  }
}

class FailedInitBackend extends FakeReminderBackend {
  bool broken = true;
  @override
  Future<void> initialize() async {
    if (broken) throw StateError('fictional Android init failure');
  }
}

void main() {
  final now = DateTime(2026, 11, 14, 12);
  Obligation plan(String id, {bool paused = false}) => Obligation(
    id: id,
    name: 'Секретное название',
    kind: EntryKind.expense,
    amountMinor: 10000,
    category: 'Дом',
    anchor: DateTime(2026, 11, 20),
    repeat: RepeatRule.once,
    reminderDays: 3,
    trialEnd: DateTime(2026, 11, 20),
    paused: paused,
  );
  LedgerSnapshot snapshot(List<Obligation> plans) => LedgerSnapshot(
    accounts: [],
    entries: [],
    currency: 'USD',
    obligations: plans,
  );

  test(
    'failed native initialization reports failure and can retry safely',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'finance-android-init-',
      );
      final backend = FailedInitBackend();
      final service = RemindersService(
        backend,
        File('${dir.path}/prefs.json'),
        clock: () => now,
      );
      try {
        await service.initialize();
        expect(service.status, contains('Не удалось'));
        await expectLater(
          service.configure(snapshot([plan('qa')]), turnOn: true),
          throwsA(isA<DomainError>()),
        );
        expect(service.enabled, isFalse);
        expect(backend.pending, isEmpty);
        backend.broken = false;
        await service.configure(snapshot([plan('qa')]), turnOn: true);
        expect(service.enabled, isTrue);
        expect(backend.pending, isNotEmpty);
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );

  test('last disable wins when enable permission is still pending', () async {
    final dir = await Directory.systemTemp.createTemp(
      'finance-reminder-order-',
    );
    final backend = DelayedPermissionBackend();
    final service = RemindersService(
      backend,
      File('${dir.path}/prefs.json'),
      clock: () => now,
    );
    await service.initialize();
    try {
      final enable = service.configure(snapshot([plan('qa')]), turnOn: true);
      await backend.requested.future;
      final disable = service.configure(snapshot([plan('qa')]), turnOn: false);
      backend.permissionResult.complete(true);
      await Future.wait([enable, disable]);
      expect(service.enabled, isFalse);
      expect(backend.pending, isEmpty);
      final reopened = RemindersService(backend, service.preferences);
      await reopened.initialize();
      expect(reopened.enabled, isFalse);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test(
    'failed preferences write preserves settings and queue remains usable',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'finance-reminder-write-',
      );
      final blocker = File('${dir.path}/blocked');
      await blocker.writeAsString('fictional blocker');
      final backend = FakeReminderBackend();
      final service = RemindersService(
        backend,
        File('${blocker.path}/prefs.json'),
        clock: () => now,
      );
      await service.initialize();
      try {
        await expectLater(
          service.configure(snapshot([plan('qa')]), turnOn: true, atHour: 20),
          throwsA(isA<FileSystemException>()),
        );
        expect(service.enabled, isFalse);
        expect(service.hour, 9);
        expect(backend.pending, isEmpty);
        await blocker.delete();
        await service.configure(
          snapshot([plan('qa')]),
          turnOn: true,
          atHour: 20,
        );
        expect(service.enabled, isTrue);
        expect(service.hour, 20);
        expect(backend.pending, isNotEmpty);
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );

  test('plan has future day-before/day-of events, no date duplicates and no paused payments', () {
    final items = reminderPlan(
      snapshot([plan('a'), plan('paused', paused: true)]),
      now,
      hour: 9,
    );
    expect(items.length, 2);
    expect(items.first.fireAt, DateTime(2026, 11, 17, 9));
    expect(items.last.fireAt, DateTime(2026, 11, 20, 9));
    expect(
      items.every((i) => i.fireAt.isAfter(now) && !i.key.contains('paused')),
      isTrue,
    );
    expect(
      reminderPlan(snapshot([plan('a')]), DateTime(2026, 11, 20, 10)),
      isEmpty,
    );
  });

  test('enable requests permission, caps nearest 60, reschedules changes and disable cancels', () async {
    final dir = await Directory.systemTemp.createTemp('finance-reminders-');
    final backend = FakeReminderBackend();
    final file = File('${dir.path}/prefs.json');
    final service = RemindersService(backend, file, clock: () => now);
    await service.initialize();
    try {
      await service.configure(
        snapshot(List.generate(80, (i) => plan('id-$i'))),
        turnOn: true,
      );
      expect(service.scheduled, 60);
      expect(backend.requests, 1);
      expect(backend.pending.length, 60);
      await service.synchronize(snapshot([plan('a')]));
      expect(backend.pending.length, 2);
      await service.configure(snapshot([plan('a')]), turnOn: false);
      expect(backend.pending, isEmpty);
      final reopened = RemindersService(backend, file, clock: () => now);
      await reopened.initialize();
      expect(reopened.enabled, isFalse);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('denied permission and scheduler errors are reported without pretending to have notifications', () async {
    final dir = await Directory.systemTemp.createTemp('finance-reminders-');
    final backend = FakeReminderBackend()..granted = false;
    final service = RemindersService(
      backend,
      File('${dir.path}/prefs.json'),
      clock: () => now,
    );
    await service.initialize();
    try {
      await service.configure(snapshot([plan('a')]), turnOn: true);
      expect(service.enabled, isFalse);
      expect(service.scheduled, 0);
      backend.granted = true;
      backend.fail = true;
      await service.configure(snapshot([plan('a')]), turnOn: true);
      expect(service.scheduled, 0);
      expect(backend.pending, isEmpty);
      expect(service.status, contains('Не удалось'));
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
