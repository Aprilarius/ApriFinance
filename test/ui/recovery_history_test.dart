import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_finance/data/backup_files.dart';
import 'package:personal_finance/data/finance_repository.dart';
import 'package:personal_finance/data/ledger_database.dart';
import 'package:personal_finance/domain/models.dart';
import 'package:personal_finance/ui/backup_panel.dart';
import 'package:personal_finance/ui/finance_view_model.dart';
import 'package:personal_finance/ui/theme.dart';

import '../support/fast_sync_backup.dart';

class HistoryFiles implements BackupFiles {
  Uint8List? saved;
  @override
  Future<Uint8List?> open() async => null;
  @override
  Future<bool> save(Uint8List bytes, String name) async {
    saved = bytes;
    return true;
  }
}

void main() {
  testWidgets(
    'older protective copy can be exported on narrow screen with large text',
    (tester) async {
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('history-ui-'),
      ))!;
      final db = LedgerDatabase(NativeDatabase.memory());
      final repo = FinanceRepository(db, clock: () => DateTime(2026, 11, 14));
      final backup = FastSyncBackup(repo, directory);
      final vm = FinanceViewModel(repo, backup: backup);
      final files = HistoryFiles();
      const password = 'fictional-password';
      try {
        await tester.runAsync(() async {
          await repo.setCurrency('USD');
          await repo.saveAccount(
            name: 'Карта',
            kind: 'Карта',
            openingMinor: 10000,
          );
          await backup.saveRecovery(await repo.exportData(), password);
          await repo.saveEntry(
            kind: EntryKind.expense,
            amountMinor: 1500,
            date: DateTime(2026, 11, 14),
            accountId: (await repo.load()).accounts.single.id,
            category: 'Дом',
          );
          await backup.saveRecovery(await repo.exportData(), password);
          await vm.refresh();
        });
        await tester.binding.setSurfaceSize(const Size(390, 844));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            theme: ledgerTheme(),
            builder: (c, child) => MediaQuery(
              data: MediaQuery.of(c)
                  .copyWith(textScaler: TextScaler.linear(1.5)),
              child: child!,
            ),
            home: Scaffold(
              body: SingleChildScrollView(
                child: BackupPanel(vm: vm, files: files),
              ),
            ),
          ),
        );
        await tester.ensureVisible(find.byKey(const Key('recovery-history')));
        await tester.tap(find.byKey(const Key('recovery-history')));
        Future<void> settleIo() async {
          await tester.pump();
          for (
            var i = 0;
            i < 200 &&
                tester
                        .widget<TextButton>(
                          find.widgetWithText(TextButton, 'Закрыть'),
                        )
                        .onPressed ==
                    null;
            i++
          ) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump(const Duration(milliseconds: 10));
          }
          await tester.pumpAndSettle();
        }

        await settleIo();
        await tester.scrollUntilVisible(
          find.byKey(const Key('export-recovery-1')),
          250,
          scrollable: find
              .descendant(
                of: find.byType(AlertDialog),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('export-recovery-1')));
        await settleIo();
        final restored = await backup.inspect(files.saved!, password);
        expect(restored.entryCount, 0);
        expect(vm.snapshot!.entries.length, 1);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        vm.dispose();
        await db.close();
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    },
  );
}
