import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_finance/data/finance_repository.dart';
import 'package:personal_finance/data/ledger_database.dart';
import 'package:personal_finance/domain/models.dart';
import 'package:personal_finance/ui/dialogs.dart';
import 'package:personal_finance/ui/finance_view_model.dart';
import 'package:personal_finance/ui/theme.dart';

class HeldRepository extends FinanceRepository {
  HeldRepository(super.db) : super(clock: () => DateTime(2026, 11, 14));
  bool holdEntry = false, holdAccount = false;
  final gate = Completer<void>();
  int entryCalls = 0, accountCalls = 0;
  @override
  Future<String> saveEntry({
    String? id,
    int? expectedVersion,
    required EntryKind kind,
    required int amountMinor,
    required DateTime date,
    required String accountId,
    String? targetAccountId,
    String category = '',
    String note = '',
    String? refundOf,
  }) async {
    entryCalls++;
    if (holdEntry) await gate.future;
    return super.saveEntry(
      id: id,
      expectedVersion: expectedVersion,
      kind: kind,
      amountMinor: amountMinor,
      date: date,
      accountId: accountId,
      targetAccountId: targetAccountId,
      category: category,
      note: note,
      refundOf: refundOf,
    );
  }

  @override
  Future<void> saveAccount({
    String? id,
    required String name,
    required String kind,
    required int openingMinor,
    int? expectedVersion,
    bool archived = false,
  }) async {
    accountCalls++;
    if (holdAccount) await gate.future;
    return super.saveAccount(
      id: id,
      name: name,
      kind: kind,
      openingMinor: openingMinor,
      expectedVersion: expectedVersion,
      archived: archived,
    );
  }
}

void main() {
  late LedgerDatabase db;
  late HeldRepository repo;
  late FinanceViewModel vm;
  setUp(() async {
    db = LedgerDatabase(NativeDatabase.memory());
    repo = HeldRepository(db);
    await repo.setCurrency('USD');
    await repo.saveAccount(name: 'Карта', kind: 'Карта', openingMinor: 10000);
    await repo.saveAccount(name: 'Наличные', kind: 'Наличные', openingMinor: 0);
    vm = FinanceViewModel(repo);
    await vm.refresh();
    repo.accountCalls = 0;
  });
  tearDown(() async {
    vm.dispose();
    await db.close();
  });
  Widget host({bool account = false}) => MaterialApp(
    theme: ledgerTheme(),
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    supportedLocales: const [Locale('ru')],
    locale: const Locale('ru'),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: FilledButton(
            onPressed: () => showDialog<bool>(
              context: context,
              barrierDismissible: false,
              builder: (_) =>
                  account ? AccountDialog(vm: vm) : EntryDialog(vm: vm),
            ),
            child: const Text('Открыть'),
          ),
        ),
      ),
    ),
  );
  Future<void> open(WidgetTester tester, {bool account = false}) async {
    await tester.pumpWidget(host(account: account));
    await tester.tap(find.text('Открыть'));
    await tester.pumpAndSettle();
  }

  for (final account in [false, true]) {
    testWidgets(
      '${account ? 'account' : 'entry'} ignores double submit and blocks back until save completes',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1100, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await open(tester, account: account);
        if (account) {
          repo.holdAccount = true;
          await tester.enterText(
            find.byKey(const Key('account-name')),
            'Резерв',
          );
        } else {
          repo.holdEntry = true;
          await tester.enterText(
            find.byKey(const Key('entry-amount')),
            '12.50',
          );
        }
        final save = find.byKey(Key(account ? 'save-account' : 'save-entry'));
        await tester.tap(save);
        await tester.tap(save);
        await tester.pump();
        expect(account ? repo.accountCalls : repo.entryCalls, 1);
        expect(tester.widget<FilledButton>(save).onPressed, isNull);
        final field = find.byKey(
          Key(account ? 'account-name' : 'entry-amount'),
        );
        expect(tester.widget<TextFormField>(field).enabled, isFalse);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        repo.gate.complete();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        final snapshot = await repo.load();
        if (account) {
          expect(snapshot.accounts.length, 3);
        } else {
          expect(snapshot.entries.length, 1);
          expect(snapshot.entries.single.date, vm.today);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'switching transfer to refund does not reuse recipient selection',
    (tester) async {
      final source = vm.snapshot!.accounts.first.id;
      await repo.saveEntry(
        kind: EntryKind.expense,
        amountMinor: 1000,
        date: vm.today,
        accountId: source,
        category: 'Дом',
      );
      await vm.refresh();
      await open(tester);
      await tester.tap(find.byKey(const Key('entry-kind')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Перевод').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('target-$source')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Наличные').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('entry-kind')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Возврат').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('entry-refund-source')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('entry-refund-source')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Дом ·').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('entry-amount')), '2');
      await tester.tap(find.byKey(const Key('save-entry')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pumpAndSettle();
      expect(
        (await repo.load()).entries
            .where((e) => e.kind == EntryKind.refund)
            .single
            .amountMinor,
        200,
      );
    },
  );
}
