import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_finance/app.dart';
import 'package:personal_finance/data/backup_files.dart';
import 'package:personal_finance/data/backup_service.dart';
import 'package:personal_finance/data/finance_repository.dart';
import 'package:personal_finance/data/ledger_database.dart';
import 'package:personal_finance/domain/backup_data.dart';
import 'package:personal_finance/ui/backup_panel.dart';
import 'package:personal_finance/ui/finance_view_model.dart';

class FakeFiles implements BackupFiles {
  int saved = 0;
  bool accept = true;
  @override
  Future<Uint8List?> open() async => Uint8List.fromList([1, 2, 3]);
  @override
  Future<bool> save(Uint8List bytes, String name) async {
    saved++;
    return accept;
  }
}

class FakeBackup extends BackupService {
  FakeBackup(FinanceRepository repository)
    : super(repository, Directory.systemTemp);
  int restored = 0, created = 0;
  Completer<void>? createGate;
  @override
  Future<Uint8List> create(String password) async {
    created++;
    await createGate?.future;
    return Uint8List.fromList([1, 2, 3]);
  }

  @override
  Future<BackupData> inspect(Uint8List bytes, String password) =>
      repository.exportData();
  @override
  Future<File> restore(BackupData data, String password) async {
    restored++;
    return File('unused-in-widget-test.mfin');
  }
}

void main() {
  late LedgerDatabase db;
  late FinanceViewModel vm;
  late FakeBackup backup;
  setUp(() async {
    db = LedgerDatabase(NativeDatabase.memory());
    final repo = FinanceRepository(db);
    await repo.setCurrency('USD');
    await repo.saveAccount(name: 'Карта', kind: 'Карта', openingMinor: 10000);
    backup = FakeBackup(repo);
    vm = FinanceViewModel(repo, backup: backup)..month = DateTime(2026, 11);
    await vm.refresh();
  });
  tearDown(() async {
    vm.dispose();
    await db.close();
  });

  testWidgets('backup ignores repeated callback while encryption is running', (
    tester,
  ) async {
    final files = FakeFiles();
    backup.createGate = Completer<void>();
    await tester.binding.setSurfaceSize(const Size(1100, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BackupPanel(vm: vm, files: files),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('create-backup')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('backup-password')),
      'fictional-password',
    );
    await tester.enterText(
      find.byKey(const Key('backup-confirm')),
      'fictional-password',
    );
    final action = tester
        .widget<FilledButton>(find.byKey(const Key('backup-action')))
        .onPressed!;
    action();
    action();
    // Release pending work even when the assertion fails.
    final calls = backup.created;
    backup.createGate!.complete();
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(files.saved, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'budget form validates amount then stores monthly category limit',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(FinanceApp(viewModel: vm));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('new-budget')),
        300,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('finance-content')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('new-budget')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('budget-category')), 'Кафе');
      await tester.enterText(find.byKey(const Key('budget-amount')), '0');
      await tester.tap(find.byKey(const Key('save-budget')));
      await tester.pumpAndSettle();
      expect(find.text('Лимит должен быть больше нуля'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('budget-amount')), '50');
      await tester.tap(find.byKey(const Key('save-budget')));
      await tester.runAsync(() async {
        for (var i = 0; i < 30 && vm.snapshot!.budgets.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pumpAndSettle();
      expect(vm.snapshot!.budgets.single.month, '2026-11');
      expect(vm.snapshot!.budgets.single.limitMinor, 5000);
      expect(find.text('Осталось: 50,00 USD'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'backup password confirmation blocks export; valid password opens save',
    (tester) async {
      final files = FakeFiles();
      await tester.binding.setSurfaceSize(const Size(1100, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BackupPanel(vm: vm, files: files),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('create-backup')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('backup-password')), 'short');
      await tester.enterText(find.byKey(const Key('backup-confirm')), 'short');
      await tester.tap(find.byKey(const Key('backup-action')));
      await tester.pumpAndSettle();
      expect(files.saved, 0);
      await tester.enterText(
        find.byKey(const Key('backup-password')),
        'test-password-123',
      );
      await tester.enterText(
        find.byKey(const Key('backup-confirm')),
        'test-password-123',
      );
      await tester.tap(find.byKey(const Key('backup-action')));
      await tester.pumpAndSettle();
      expect(files.saved, 1);
      expect(vm.insights.policy.profile.lastBackupOn, vm.today);
      expect(find.text('Зашифрованная копия сохранена'), findsOneWidget);
    },
  );

  testWidgets('cancelled file save does not acknowledge backup', (
    tester,
  ) async {
    final files = FakeFiles()..accept = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BackupPanel(vm: vm, files: files),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('create-backup')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('backup-password')),
      'fictional-password',
    );
    await tester.enterText(
      find.byKey(const Key('backup-confirm')),
      'fictional-password',
    );
    await tester.tap(find.byKey(const Key('backup-action')));
    await tester.pumpAndSettle();
    expect(files.saved, 1);
    expect(vm.insights.policy.profile.lastBackupOn, isNull);
  });

  testWidgets(
    'restore shows preview and cannot replace data without explicit checkbox',
    (tester) async {
      final files = FakeFiles();
      await tester.binding.setSurfaceSize(const Size(1100, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BackupPanel(vm: vm, files: files),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('restore-backup')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('backup-password')),
        'test-password-123',
      );
      await tester.tap(find.byKey(const Key('backup-action')));
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Счетов: 1'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('backup-action')))
            .onPressed,
        isNull,
      );
      expect(backup.restored, 0);
      await tester.tap(find.byKey(const Key('restore-confirmation')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('backup-action')));
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(backup.restored, 1);
      expect(
        find.text(
          'Данные восстановлены. Защитная копия доступна в настройках.',
        ),
        findsOneWidget,
      );
    },
  );
}
