import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:personal_finance/domain/purchases.dart';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:personal_finance/app.dart';
import 'package:personal_finance/data/finance_repository.dart';
import 'package:personal_finance/data/ledger_database.dart';
import 'package:personal_finance/data/backup_service.dart';
import 'package:personal_finance/data/cloud_transport.dart';
import 'package:personal_finance/data/sync_service.dart';
import 'package:personal_finance/domain/models.dart';
import 'package:personal_finance/domain/ledger_math.dart';
import 'package:personal_finance/ui/finance_view_model.dart';
import 'package:personal_finance/ui/cloud_controller.dart';

class IntegrationCloud implements SnapshotRemote {
  RemoteSnapshot? snapshot;
  @override
  String get scope =>
      'https://project.supabase.co|12345678-1234-1234-1234-123456789abc';
  @override
  Future<RemoteSnapshot?> read() async => snapshot;
  @override
  Future<int> write(int expectedRevision, String payload) async {
    if ((snapshot?.revision ?? 0) != expectedRevision) {
      throw const CloudChanged();
    }
    snapshot = RemoteSnapshot(expectedRevision + 1, payload);
    return expectedRevision + 1;
  }
}

class IntegrationTransport implements CloudTransport {
  IntegrationTransport(this.cloud);
  final IntegrationCloud cloud;
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
      final snapshot = await cloud.read();
      return CloudReply(
        200,
        snapshot == null
            ? <Object?>[]
            : [
                {'revision': snapshot.revision, 'payload': snapshot.payload},
              ],
      );
    }
    if (uri.path == '/rest/v1/rpc/put_finance_snapshot_v2') {
      final input = body! as Map;
      return CloudReply(
        200,
        await cloud.write(
          input['expected_revision']! as int,
          input['encrypted_payload']! as String,
        ),
      );
    }
    return const CloudReply(204, null);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('first launch, account, income, expense, reopen database', (
    tester,
  ) async {
    final tempRoot = await getTemporaryDirectory();
    final directory = await tempRoot.createTemp(
      'personal-finance-integration-',
    );
    final file = File(p.join(directory.path, 'test.sqlite'));
    var db = LedgerDatabase(NativeDatabase.createInBackground(file));
    var vm = FinanceViewModel(FinanceRepository(db));
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

      await tester.tap(find.text('Счета').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('new-account')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('account-name')), 'Проверка');
      await tester.enterText(find.byKey(const Key('account-opening')), '100');
      await tester.tap(find.byKey(const Key('save-account')));
      await tester.pumpAndSettle();
      expect(find.text('100,00 USD'), findsOneWidget);

      await tester.tap(find.text('Обзор').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('new-entry')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Расход').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Доход').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('entry-amount')), '1000');
      await tester.tap(find.byKey(const Key('save-entry')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('new-entry')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('entry-amount')), '250');
      await tester.tap(find.byKey(const Key('save-entry')));
      await tester.pumpAndSettle();
      expect(vm.totalBalance, 85000);
      expect(find.text('850,00 USD'), findsAtLeastNWidgets(1));

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
      await tester.enterText(
        find.byKey(const Key('budget-category')),
        'Продукты',
      );
      await tester.enterText(find.byKey(const Key('budget-amount')), '300');
      await tester.tap(find.byKey(const Key('save-budget')));
      await tester.pumpAndSettle();
      expect(vm.snapshot!.budgets.single.limitMinor, 30000);

      debugPrint('Native QA: budget saved, preparing backup');
      final backup = BackupService(
        vm.repository,
        Directory(p.join(directory.path, 'recovery')),
      );
      const password = 'native-test-password-123';
      final expense = vm.snapshot!.entries.singleWhere(
        (e) => e.kind == EntryKind.expense,
      );
      final receipt = Uint8List.fromList(
        utf8.encode('%PDF-1.7\nfictional receipt\n%%EOF'),
      );
      await vm.repository.savePurchase(
        Purchase(
          id: 'native-purchase',
          name: 'Техника',
          date: expense.date,
          amountMinor: expense.amountMinor,
          entryId: expense.id,
        ),
      );
      await vm.repository.addDocument('native-purchase', 'Чек.pdf', receipt);
      debugPrint('Native QA: creating encrypted backup');
      final bytes = await backup.create(password);
      debugPrint('Native QA: encrypted backup created');
      await File(p.join(directory.path, 'copy.mfin'))
          .writeAsBytes(bytes, flush: true);
      await vm.repository.saveEntry(
        kind: EntryKind.expense,
        amountMinor: 5000,
        date: DateTime.now(),
        accountId: vm.snapshot!.accounts.single.id,
        category: 'Дом',
      );
      await vm.refresh();
      expect(vm.totalBalance, 80000);
      final preview = await backup.inspect(
        await File(p.join(directory.path, 'copy.mfin')).readAsBytes(),
        password,
      );
      debugPrint('Native QA: restoring backup');
      final recovery = await backup.restore(preview, password);
      debugPrint('Native QA: backup restored');
      expect(await recovery.exists(), isTrue);
      await vm.refresh();
      expect(vm.totalBalance, 85000);
      expect(vm.snapshot!.purchases.single.entryId, expense.id);
      expect(
        await vm.repository.readDocument(vm.snapshot!.documents.single),
        receipt,
      );

      await tester.tap(find.byKey(const Key('nav-3')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('new-payment')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('payment-name')), 'Интернет');
      await tester.enterText(find.byKey(const Key('payment-amount')), '10');
      await tester.tap(find.byKey(const Key('save-payment')));
      await tester.pumpAndSettle();
      final payment = vm.snapshot!.obligations.single;
      expect(vm.totalBalance, 85000);
      await tester.tap(find.byKey(ValueKey('pay-${payment.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-settlement')));
      await tester.pumpAndSettle();
      expect(vm.totalBalance, 84000);
      await tester.tap(find.byKey(const Key('open-purchases')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('new-purchase')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('purchase-name')), 'Кабель');
      await tester.enterText(find.byKey(const Key('purchase-amount')), '12.50');
      await tester.tap(find.byKey(const Key('save-purchase')));
      await tester.pumpAndSettle();
      expect(vm.snapshot!.purchases.length, 2);
      expect(vm.totalBalance, 84000);

      debugPrint('Native QA: validating local mock exchange');
      final cloud = IntegrationCloud();
      final sync = SyncService(vm.repository, backup, cloud);
      final syncPlan = await sync.preview(password);
      expect(
        syncPlan.needsChoice,
        isTrue,
      ); // Earlier restore requires explicit reattachment.
      await sync.commit(syncPlan, password, choice: SyncChoice.local);
      expect((await vm.repository.captureSync()).revision, 1);

      await tester.pumpWidget(const SizedBox.shrink());
      vm.dispose();
      await db.close();
      db = LedgerDatabase(NativeDatabase.createInBackground(file));
      debugPrint('Native QA: reopening database');
      final reopenedRepository = FinanceRepository(db);
      vm = FinanceViewModel(
        reopenedRepository,
        backup: BackupService(
          reopenedRepository,
          Directory(p.join(directory.path, 'recovery')),
        ),
      );
      await vm.refresh();
      expect(accountBalances(vm.snapshot!).values.single, 84000);
      expect(vm.snapshot!.entries.length, 3);
      expect((await vm.repository.captureSync()).revision, 1);
      expect(vm.snapshot!.pendingChanges, 0);
      expect(vm.snapshot!.purchases.length, 2);
      expect(
        await vm.repository.readDocument(vm.snapshot!.documents.single),
        receipt,
      );
      expect(vm.snapshot!.obligations.single.nextIndex, 1);
      expect(vm.snapshot!.settlements.length, 1);
      expect(vm.snapshot!.budgets.single.limitMinor, 30000);
      await tester.pumpWidget(FinanceApp(viewModel: vm));
      await tester.pumpAndSettle();
      expect(find.text('840,00 USD'), findsAtLeastNWidgets(1));
      debugPrint('Native QA: validating mock automatic exchange');
      final controller = CloudController(
        vm,
        transport: IntegrationTransport(cloud),
        schedule: (_, _) => () {},
      );
      try {
        await controller.initialize();
        await controller.signIn(
          'https://project.supabase.co',
          'sb_publishable_fictional_key_123456',
          'owner@example.invalid',
          'fictional-password',
        );
        controller.setAutomatic(true);
        await controller.check(password);
        await controller.commit();
        expect(controller.automaticReady, isTrue);
        await tester.tap(find.byKey(const Key('new-entry')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('entry-amount')), '1');
        await tester.tap(find.byKey(const Key('save-entry')));
        await tester.pumpAndSettle();
        await controller.exchangeAutomatically();
        expect(vm.totalBalance, 83900);
        expect(vm.snapshot!.pendingChanges, 0);
        expect((await vm.repository.captureSync()).revision, 2);
      } finally {
        controller.dispose();
      }
      await tester.pumpWidget(const SizedBox.shrink());
      vm.dispose();
      await db.close();
      db = LedgerDatabase(NativeDatabase.createInBackground(file));
      vm = FinanceViewModel(FinanceRepository(db));
      await vm.refresh();
      expect(vm.totalBalance, 83900);
      expect(vm.snapshot!.entries.length, 4);
      expect((await vm.repository.captureSync()).revision, 2);
      expect(
        await vm.repository.readDocument(vm.snapshot!.documents.single),
        receipt,
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      vm.dispose();
      await db.close();
      await directory.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
