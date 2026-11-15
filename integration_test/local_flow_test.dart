import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:personal_finance/app.dart';
import 'package:personal_finance/data/finance_repository.dart';
import 'package:personal_finance/data/ledger_database.dart';
import 'package:personal_finance/data/backup_service.dart';
import 'package:personal_finance/domain/models.dart';
import 'package:personal_finance/domain/purchases.dart';
import 'package:personal_finance/ui/finance_view_model.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'local archive rollback, purchase calendar, encrypted receipt recovery and reopen',
    (tester) async {
      final directory = await (await getTemporaryDirectory()).createTemp(
        'finance-local-integration-',
      );
      final file = File('${directory.path}/ledger.sqlite');
      var db = LedgerDatabase(NativeDatabase.createInBackground(file));
      var repo = FinanceRepository(db, clock: () => DateTime(2026, 11, 14));
      var vm = FinanceViewModel(repo)..month = DateTime(2026, 11);
      Future<void> reopen() async {
        await tester.pumpWidget(const SizedBox.shrink());
        vm.dispose();
        await db.close();
        db = LedgerDatabase(NativeDatabase.createInBackground(file));
        repo = FinanceRepository(db, clock: () => DateTime(2026, 11, 14));
        vm = FinanceViewModel(repo)..month = DateTime(2026, 11);
        await vm.refresh();
      }

      try {
        await vm.refresh();
        await tester.pumpWidget(FinanceApp(viewModel: vm));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('currency-picker')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('USD').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Начать учёт'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('new-entry')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('account-name')), 'Карта');
        await tester.enterText(find.byKey(const Key('account-opening')), '100');
        await tester.tap(find.byKey(const Key('save-account')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('entry-amount')), '100');
        await tester.tap(find.byKey(const Key('save-entry')));
        await tester.pumpAndSettle();
        expect(vm.totalBalance, 0);
        var account = vm.snapshot!.accounts.single;
        await repo.saveAccount(
          id: account.id,
          expectedVersion: account.version,
          name: account.name,
          kind: account.kind,
          openingMinor: account.openingMinor,
          archived: true,
        );
        final before = (await repo.exportData()).toJson();
        await expectLater(
          repo.deleteEntry(vm.snapshot!.entries.single),
          throwsA(isA<DomainError>()),
        );
        expect((await repo.exportData()).toJson(), before);
        await reopen();
        expect(vm.totalBalance, 0);
        expect(vm.snapshot!.accounts.single.archived, isTrue);
        expect(vm.snapshot!.entries.length, 1);
        account = vm.snapshot!.accounts.single;
        await repo.saveAccount(
          id: account.id,
          expectedVersion: account.version,
          name: account.name,
          kind: account.kind,
          openingMinor: account.openingMinor,
          archived: false,
        );
        await vm.refresh();
        await tester.pumpWidget(FinanceApp(viewModel: vm));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byKey(const Key('open-insights')),
          300,
          scrollable: find
              .descendant(
                of: find.byKey(const Key('finance-content')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('open-insights')));
        await tester.pumpAndSettle();
        expect(find.text('Анализ и рекомендации'), findsOneWidget);
        expect(vm.insights.results.where((i) => i.rule == 'A1'), isNotEmpty);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('nav-3')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('open-purchases')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('new-purchase')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('purchase-name')),
          'Наушники',
        );
        await tester.enterText(find.byKey(const Key('purchase-amount')), '100');
        await tester.tap(find.byKey(const Key('save-purchase')));
        await tester.pumpAndSettle();
        final purchase = vm.snapshot!.purchases.single;
        await repo.savePurchase(
          Purchase.fromJson({
            ...purchase.toJson(),
            'returnBy': '2026-11-21',
            'warrantyUntil': '2026-12-31',
          }),
          expectedVersion: purchase.version,
        );
        final receipt = Uint8List.fromList(
          utf8.encode('%PDF-1.7\nfictional receipt\n%%EOF'),
        );
        await repo.addDocument(purchase.id, 'Чек.pdf', receipt);
        await vm.refresh();
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('Открыть карточку'),
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text('Открыть карточку'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextFormField>(find.byKey(const Key('purchase-name')))
              .controller!
              .text,
          'Наушники',
        );
        await tester.tap(find.text('Отмена'));
        await tester.pumpAndSettle();
        expect(vm.totalBalance, 0);
        expect(vm.snapshot!.entries.length, 1);
        final backup = BackupService(
          repo,
          Directory('${directory.path}/recovery'),
        );
        const password = 'fictional-local-password';
        final bytes = await backup.create(password);
        await repo.deletePurchase(vm.snapshot!.purchases.single);
        expect((await repo.load()).documents, isEmpty);
        await backup.restore(await backup.inspect(bytes, password), password);
        await reopen();
        expect(vm.totalBalance, 0);
        expect(vm.snapshot!.entries.length, 1);
        expect(vm.snapshot!.purchases.single.returnBy, DateTime(2026, 11, 21));
        expect(vm.purchaseDeadlines.single.purchase.name, 'Наушники');
        expect(await repo.readDocument(vm.snapshot!.documents.single), receipt);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        vm.dispose();
        await db.close();
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
